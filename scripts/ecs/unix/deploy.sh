#!/bin/bash

# Script de Deploy ECS - Projeto BIA
# 
# Este script automatiza o processo de build e deploy para ECS
# com versionamento baseado em commit hash para facilitar rollbacks

set -e  # Para o script em caso de erro

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_ECR_REPO="bia"
DEFAULT_CLUSTER="cluster-bia"
DEFAULT_SERVICE="service-bia"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir mensagens coloridas
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Função de ajuda
show_help() {
    cat << EOF
Script de Deploy ECS - Projeto BIA

USAGE:
    ./deploy.sh [COMMAND] [OPTIONS]

COMMANDS:
    deploy          Faz build da imagem e deploy para ECS
    help            Mostra esta ajuda

OPTIONS:
    -r, --region REGION         Região AWS (default: $DEFAULT_REGION)
    -e, --ecr-repo REPO         Nome do repositório ECR (default: $DEFAULT_ECR_REPO)
    -c, --cluster CLUSTER       Nome do cluster ECS (default: $DEFAULT_CLUSTER)
    -s, --service SERVICE       Nome do serviço ECS (default: $DEFAULT_SERVICE)
    -h, --help                  Mostra esta ajuda

EXAMPLES:
    # Deploy normal (usa commit hash atual)
    ./deploy.sh deploy

    # Deploy com configurações customizadas
    ./deploy.sh deploy -r us-west-2 -e meu-repo

WORKFLOW:
    1. O script pega o hash do commit atual (últimos 7 caracteres)
    2. Faz build da imagem Docker com tag: latest e commit-hash
    3. Faz push para ECR
    4. Cria nova task definition apontando para a imagem com commit-hash
    5. Atualiza o serviço ECS com a nova task definition

REQUIREMENTS:
    - aws cli
    - docker
    - git
    - jq
EOF
}

# Função para obter o commit hash atual
get_commit_hash() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse --short=7 HEAD
    else
        log_error "Este diretório não é um repositório Git"
        exit 1
    fi
}

# Função para fazer login no ECR
ecr_login() {
    local region=$1
    local account_id=$2
    log_info "Fazendo login no ECR..."
    aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $account_id.dkr.ecr.$region.amazonaws.com
}

# Função para fazer build e push da imagem
build_and_push() {
    local region=$1
    local repo_name=$2
    local commit_hash=$3
    local account_id=$4
    
    local ecr_uri="$account_id.dkr.ecr.$region.amazonaws.com/$repo_name"
    
    log_info "Iniciando build da imagem Docker..."
    log_info "Tags: latest, $commit_hash"
    
    # Build
    docker build --platform linux/amd64 -t $repo_name:latest -t $repo_name:$commit_hash . >&2
    
    # Tag para ECR
    docker tag $repo_name:latest $ecr_uri:latest >&2
    docker tag $repo_name:$commit_hash $ecr_uri:$commit_hash >&2
    
    log_info "Fazendo push para ECR: $ecr_uri"
    docker push $ecr_uri:latest >&2
    docker push $ecr_uri:$commit_hash >&2
    
    log_success "Build e Push concluídos com sucesso"
    echo "$ecr_uri:$commit_hash"
}

# Função para criar nova task definition e atualizar serviço
update_ecs_service() {
    local region=$1
    local cluster=$2
    local service=$3
    local image_uri=$4
    
    log_info "Atualizando serviço ECS..."
    
    # 1. Obter a task definition atual do serviço
    log_info "Obtendo task definition atual..."
    local task_def_arn=$(aws ecs describe-services --cluster $cluster --services $service --region $region --query "services[0].taskDefinition" --output text)
    
    if [ "$task_def_arn" == "None" ]; then
        log_error "Serviço $service não encontrado ou sem task definition"
        exit 1
    fi
    
    # 2. Baixar a definição JSON
    local current_task_json=$(aws ecs describe-task-definition --task-definition $task_def_arn --region $region --query "taskDefinition" --output json)
    
    # 3. Criar nova definição com a nova imagem
    # Removemos campos que não podem ser enviados no register-task-definition (status, revision, etc)
    log_info "Criando nova revisão da Task Definition..."
    local new_task_json=$(echo $current_task_json | jq --arg image "$image_uri" '
        .containerDefinitions[0].image = $image |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Salvar em arquivo temporário
    echo $new_task_json > new-task-def.json
    
    # 4. Registrar nova task definition
    local new_task_def_arn=$(aws ecs register-task-definition --region $region --cli-input-json file://new-task-def.json --query "taskDefinition.taskDefinitionArn" --output text)
    rm new-task-def.json
    
    if [ -z "$new_task_def_arn" ] || [ "$new_task_def_arn" == "None" ]; then
        log_error "Falha ao registrar nova Task Definition"
        exit 1
    fi

    log_success "Nova Task Definition registrada: $new_task_def_arn"
    
    # 5. Atualizar o serviço
    log_info "Atualizando serviço $service no cluster $cluster..."
    aws ecs update-service --cluster $cluster --service $service --task-definition $new_task_def_arn --force-new-deployment --region $region > /dev/null
    
    log_success "Serviço atualizado! O deployment está em andamento."
}

# Função principal de deploy
deploy() {
    local region=$1
    local ecr_repo=$2
    local cluster=$3
    local service=$4
    
    # Verificar dependências
    for cmd in aws docker git jq; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd não encontrado. Instale primeiro."
            exit 1
        fi
    done
    
    local commit_hash=$(get_commit_hash)
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    
    log_info "Iniciando deploy..."
    log_info "Commit Hash: $commit_hash"
    log_info "Account ID: $account_id"
    log_info "Region: $region"
    
    # Login
    ecr_login $region $account_id
    
    # Build & Push
    local image_uri=$(build_and_push $region $ecr_repo $commit_hash $account_id)
    
    # Deploy ECS
    update_ecs_service $region $cluster $service $image_uri
    
    log_success "Deploy finalizado com sucesso!"
    log_info "Versão deployada: $commit_hash"
}

# Parsing dos argumentos
REGION=$DEFAULT_REGION
ECR_REPO=$DEFAULT_ECR_REPO
CLUSTER=$DEFAULT_CLUSTER
SERVICE=$DEFAULT_SERVICE
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        deploy|help)
            COMMAND=$1
            shift
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se um comando foi especificado
if [ -z "$COMMAND" ]; then
    show_help
    exit 0
fi

# Executar comando
case $COMMAND in
    deploy)
        deploy $REGION $ECR_REPO $CLUSTER $SERVICE
        ;;
    help)
        show_help
        ;;
esac
