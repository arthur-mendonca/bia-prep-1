#!/bin/bash

# Script de Configuração de Domínio e SSL - Projeto BIA
#
# Este script auxilia na configuração do domínio customizado:
# 1. Verifica/Valida o certificado ACM
# 2. Verifica a configuração do Load Balancer (ALB)
# 3. Configura o DNS no Route53

set -e

# Configurações
DOMAIN="formacao.labops.online"
ROOT_DOMAIN="labops.online"
REGION="us-east-1"
CLUSTER="cluster-bia"
SERVICE="service-bia"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_dependencies() {
    for cmd in aws jq; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd não encontrado. Instale primeiro."
            exit 1
        fi
    done
}

get_hosted_zone_id() {
    # Busca o ID da zona hospedada do domínio raiz
    aws route53 list-hosted-zones-by-name --dns-name "$ROOT_DOMAIN." --query "HostedZones[0].Id" --output text
}

handle_acm_certificate() {
    log_info "Verificando certificado ACM para $DOMAIN..."
    
    # Buscar certificado
    local cert_arn=$(aws acm list-certificates --region $REGION --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text)
    
    if [ -z "$cert_arn" ] || [ "$cert_arn" == "None" ]; then
        log_error "Certificado não encontrado. Por favor, solicite o certificado primeiro via Console AWS ou CLI."
        exit 1
    fi
    
    log_info "Certificado encontrado: $cert_arn"
    
    # Verificar status detalhado
    local cert_details=$(aws acm describe-certificate --certificate-arn $cert_arn --region $REGION --output json)
    local status=$(echo $cert_details | jq -r '.Certificate.Status')
    
    log_info "Status atual: $status"
    
    if [ "$status" == "ISSUED" ]; then
        log_success "Certificado já foi emitido e está válido."
        echo "$cert_arn"
        return
    fi
    
    if [ "$status" == "PENDING_VALIDATION" ]; then
        log_warning "Certificado pendente de validação. Tentando configurar DNS..."
        
        local zone_id=$(get_hosted_zone_id)
        if [ -z "$zone_id" ] || [ "$zone_id" == "None" ]; then
            log_error "Zona hospedada para $ROOT_DOMAIN não encontrada no Route53."
            exit 1
        fi
        
        # Pegar registro de validação
        local validation_record=$(echo $cert_details | jq -r '.Certificate.DomainValidationOptions[0].ResourceRecord')
        
        if [ "$validation_record" == "null" ]; then
             log_warning "Detalhes do registro de validação ainda não disponíveis. Aguarde alguns instantes e tente novamente."
             exit 1
        fi

        local record_name=$(echo $validation_record | jq -r '.Name')
        local record_value=$(echo $validation_record | jq -r '.Value')
        local record_type=$(echo $validation_record | jq -r '.Type')
        
        log_info "Criando registro de validação: $record_name -> $record_value ($record_type)"
        
        # Criar JSON para Route53
        cat > validation-record.json << EOF
{
  "Comment": "Validacao ACM para $DOMAIN",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$record_name",
        "Type": "$record_type",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$record_value"
          }
        ]
      }
    }
  ]
}
EOF
        aws route53 change-resource-record-sets --hosted-zone-id $zone_id --change-batch file://validation-record.json
        rm validation-record.json
        
        log_success "Registro DNS de validação criado/atualizado com sucesso!"
        log_info "Aguarde alguns minutos (pode levar até 30min) para o certificado mudar para 'ISSUED'."
        log_info "Execute este script novamente após a validação para continuar a configuração do Load Balancer."
        exit 0
    fi
}

check_load_balancer() {
    log_info "Verificando configuração do ECS Service..."
    
    local lb_config=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION --query "services[0].loadBalancers" --output json)
    
    if [ "$lb_config" == "[]" ] || [ "$lb_config" == "null" ]; then
        log_warning "O serviço ECS '$SERVICE' NÃO está conectado a um Load Balancer."
        log_info "Para usar o certificado ACM e o domínio, precisamos criar um ALB e reconectar o serviço."
        
        echo ""
        read -p "Deseja que eu crie a infraestrutura do Load Balancer e reconfigure o serviço agora? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Operação cancelada pelo usuário. O Load Balancer é obrigatório para esta configuração."
            exit 1
        fi
        
        setup_load_balancer_infrastructure
        
        # Recarrega a configuração
        lb_config=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION --query "services[0].loadBalancers" --output json)
    fi

    local target_group_arn=$(echo $lb_config | jq -r '.[0].targetGroupArn')
    
    # Encontrar o Load Balancer através do Target Group
    local lb_arn=$(aws elbv2 describe-target-groups --target-group-arns $target_group_arn --region $REGION --query "TargetGroups[0].LoadBalancerArns[0]" --output text)
    
    if [ -z "$lb_arn" ] || [ "$lb_arn" == "None" ]; then
        log_error "Load Balancer não encontrado para o Target Group."
        exit 1
    fi
    
    log_success "Load Balancer encontrado: $lb_arn"
    echo "$lb_arn"
}

setup_load_balancer_infrastructure() {
    log_info "Iniciando criação automática da infraestrutura..."

    # 1. Descobrir VPC e Subnets
    log_info "Detectando rede..."
    local vpc_id=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)
    local subnets=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$vpc_id --query "Subnets[].SubnetId" --output text)
    
    if [ -z "$vpc_id" ]; then
        log_error "Não foi possível detectar a VPC Default."
        exit 1
    fi
    log_info "VPC: $vpc_id"

    # 2. Criar Security Group para o ALB
    log_info "Verificando/Criando Security Group para o ALB..."
    local sg_name="bia-alb-sg"
    # Tenta buscar pelo nome e retorna APENAS o GroupId
    local sg_id=$(aws ec2 describe-security-groups --group-names $sg_name --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    
    if [ -z "$sg_id" ] || [ "$sg_id" == "None" ]; then
        sg_id=$(aws ec2 create-security-group --group-name $sg_name --description "Security Group for BIA ALB" --vpc-id $vpc_id --query "GroupId" --output text)
        log_success "Security Group criado: $sg_id"
    else
        log_info "Security Group já existe: $sg_id"
    fi

    # Garantir que as regras de entrada existam (mesmo se o SG já existia)
    log_info "Validando regras de firewall (Security Group)..."
    aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

    # Validação extra para garantir que temos um ID válido (começa com sg-)
    if [[ ! "$sg_id" =~ ^sg- ]]; then
        log_error "ID do Security Group inválido: $sg_id"
        exit 1
    fi

    # 3. Criar Load Balancer
    log_info "Criando Application Load Balancer..."
    local alb_arn=$(aws elbv2 create-load-balancer --name "bia-alb" --subnets $subnets --security-groups $sg_id --scheme internet-facing --type application --query "LoadBalancers[0].LoadBalancerArn" --output text)
    
    if [ -z "$alb_arn" ] || [ "$alb_arn" == "None" ]; then
        log_error "Falha ao criar o Load Balancer."
        exit 1
    fi
    log_success "ALB Criado: $alb_arn"

    # 4. Descobrir porta do container
    log_info "Analisando Task Definition..."
    local task_def_arn=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION --query "services[0].taskDefinition" --output text)
    local container_info=$(aws ecs describe-task-definition --task-definition $task_def_arn --query "taskDefinition.containerDefinitions[0]")
    local container_name=$(echo $container_info | jq -r .name)
    local container_port=$(echo $container_info | jq -r .portMappings[0].containerPort)
    
    if [ -z "$container_port" ] || [ "$container_port" == "null" ]; then
        container_port=80
        log_warning "Porta do container não detectada. Assumindo porta 80."
    else
        log_info "Container '$container_name' escutando na porta $container_port"
    fi

    # 5. Criar Target Group
    log_info "Criando Target Group..."
    # Verifica se já existe um TG com esse nome para evitar erro de duplicidade com config diferente
    local existing_tg=$(aws elbv2 describe-target-groups --names "bia-tg" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
    local tg_arn=""
    
    if [ -n "$existing_tg" ] && [ "$existing_tg" != "None" ]; then
        log_info "Target Group 'bia-tg' já existe: $existing_tg"
        tg_arn=$existing_tg
    else
        tg_arn=$(aws elbv2 create-target-group --name "bia-tg" --protocol HTTP --port $container_port --vpc-id $vpc_id --target-type instance --health-check-path "/" --query "TargetGroups[0].TargetGroupArn" --output text)
    fi

    if [ -z "$tg_arn" ] || [ "$tg_arn" == "None" ]; then
        log_error "Falha ao obter/criar Target Group."
        exit 1
    fi
    log_success "Target Group pronto: $tg_arn"

    # 5.5. Criar Listener HTTPS (Vincular TG ao ALB)
    # Isso é necessário ANTES de criar o serviço ECS, pois o ECS valida se o TG está associado a um LB
    log_info "Criando Listener HTTPS para vincular Target Group ao ALB..."
    
    # Buscar certificado ACM novamente (já validado no início do script)
    local cert_arn=$(aws acm list-certificates --region $REGION --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text)
    
    aws elbv2 create-listener \
        --load-balancer-arn $alb_arn \
        --protocol HTTPS \
        --port 443 \
        --certificates CertificateArn=$cert_arn \
        --default-actions Type=forward,TargetGroupArn=$tg_arn \
        --region $REGION > /dev/null
        
    log_success "Listener HTTPS criado (TG vinculado ao ALB)."

    # 6. Recriar Serviço ECS
    log_info "Recriando serviço ECS para vincular ao Load Balancer..."
    log_warning "O serviço atual será deletado e recriado. Isso pode causar uma breve interrupção."
    
    # Backup params
    local desired_count=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query "services[0].desiredCount" --output text)
    
    # Se a contagem for 0, forçar para 1 para garantir que o serviço suba
    if [ "$desired_count" -eq 0 ]; then
        log_warning "Contagem atual de tarefas é 0. Forçando para 1 para iniciar o serviço."
        desired_count=1
    fi
    
    aws ecs delete-service --cluster $CLUSTER --service $SERVICE --force > /dev/null
    log_info "Serviço antigo removido."
    
    sleep 5
    
    aws ecs create-service \
        --cluster $CLUSTER \
        --service-name $SERVICE \
        --task-definition $task_def_arn \
        --desired-count $desired_count \
        --load-balancers "targetGroupArn=$tg_arn,containerName=$container_name,containerPort=$container_port" \
        --launch-type EC2 \
        --region $REGION > /dev/null
        
    log_success "Serviço recriado e vinculado ao Load Balancer!"
    
    # Esperar o ALB ficar ativo
    log_info "Aguardando ALB ficar ativo (pode levar alguns minutos)..."
    aws elbv2 wait load-balancer-available --load-balancer-arns $alb_arn
}

add_https_listener() {
    local lb_arn=$1
    local cert_arn=$2
    
    # Obter Target Group do serviço
    local target_group_arn=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION --query "services[0].loadBalancers[0].targetGroupArn" --output text)
    
    log_info "Verificando Listener HTTPS no Load Balancer..."
    
    local https_listener=$(aws elbv2 describe-listeners --load-balancer-arn $lb_arn --region $REGION --query "Listeners[?Port==\`443\`].ListenerArn" --output text)
    
    if [ -z "$https_listener" ] || [ "$https_listener" == "None" ]; then
        log_info "Criando Listener HTTPS na porta 443..."
        
        aws elbv2 create-listener \
            --load-balancer-arn $lb_arn \
            --protocol HTTPS \
            --port 443 \
            --certificates CertificateArn=$cert_arn \
            --default-actions Type=forward,TargetGroupArn=$target_group_arn \
            --region $REGION > /dev/null
            
        log_success "Listener HTTPS criado com sucesso."
    else
        log_info "Listener HTTPS já existe."
    fi
}

configure_route53_alias() {
    local lb_arn=$1
    local lb_dns=$(aws elbv2 describe-load-balancers --load-balancer-arns $lb_arn --region $REGION --query "LoadBalancers[0].DNSName" --output text)
    local lb_zone_id=$(aws elbv2 describe-load-balancers --load-balancer-arns $lb_arn --region $REGION --query "LoadBalancers[0].CanonicalHostedZoneId" --output text)
    
    log_info "Configurando Route53 para apontar $DOMAIN -> $lb_dns"
    
    local zone_id=$(get_hosted_zone_id)
    
    cat > alias-record.json << EOF
{
  "Comment": "Alias para Load Balancer",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$lb_zone_id",
          "DNSName": "$lb_dns",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
    aws route53 change-resource-record-sets --hosted-zone-id $zone_id --change-batch file://alias-record.json
    rm alias-record.json
    
    log_success "DNS configurado com sucesso! O domínio deve propagar em alguns minutos."
}

# Fluxo Principal
check_dependencies
CERT_ARN=$(handle_acm_certificate)

if [ -z "$CERT_ARN" ]; then
    log_info "Certificado pendente ou não encontrado. Verifique as mensagens acima."
    exit 0
fi

LB_ARN=$(check_load_balancer)

if [ -n "$LB_ARN" ]; then
    add_https_listener $LB_ARN $CERT_ARN
    configure_route53_alias $LB_ARN
fi

log_success "Configuração concluída!"