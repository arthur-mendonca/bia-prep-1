#!/bin/bash
set -e

# Configuration
INSTANCE_ID="i-0468687d753fd33c1"
SG_DEFAULT="sg-03e933792139213df"
SG_BIA_DEV="sg-0c535157d72e216b3"
RDS_ENDPOINT="bia.cursmugyih4x.us-east-1.rds.amazonaws.com"
SERVICE_NAME="service-bia"
CLUSTER_NAME="cluster-bia"

echo "1. Updating EC2 Security Groups..."
aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --groups $SG_DEFAULT $SG_BIA_DEV
echo "Security Groups updated."

echo "2. Fetching current Task Definition..."
# Get the task definition ARN from the service
TASK_DEF_ARN=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query "services[0].taskDefinition" --output text)
aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --query "taskDefinition" > current-task.json

echo "3. Creating new Task Definition revision with correct DB_HOST..."
# Update DB_HOST and clean up read-only fields
jq --arg HOST "$RDS_ENDPOINT" '
  .containerDefinitions[0].environment |= map(if .name == "DB_HOST" then .value = $HOST else . end) |
  {
    family: .family,
    taskRoleArn: .taskRoleArn,
    executionRoleArn: .executionRoleArn,
    networkMode: .networkMode,
    containerDefinitions: .containerDefinitions,
    volumes: .volumes,
    placementConstraints: .placementConstraints,
    requiresCompatibilities: .requiresCompatibilities,
    cpu: .cpu,
    memory: .memory
  } | del(.[] | select(. == null))
' current-task.json > new-task.json

echo "4. Registering new Task Definition..."
NEW_TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://new-task.json --query "taskDefinition.taskDefinitionArn" --output text)
echo "Registered: $NEW_TASK_ARN"

echo "5. Updating Service to use new Task Definition..."
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_ARN --force-new-deployment

echo "Done! The service is updating. Please wait a few minutes for the new task to start."
