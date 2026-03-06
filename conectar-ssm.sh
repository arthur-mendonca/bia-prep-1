# 1. Obter o ID da instância rodando com o nome 'bia-dev'
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=bia-dev" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

# 2. Exibir o ID (para conferência)
echo "Conectando à instância: $INSTANCE_ID"

# 3. Iniciar a sessão SSM
aws ssm start-session --target $INSTANCE_ID