#!/bin/bash
set -e

INSTANCE_ID="i-0468687d753fd33c1"

echo "Running deep cleanup on instance $INSTANCE_ID..."

COMMAND="
echo 'Stopping all containers...'
docker stop \$(docker ps -aq) || true
echo 'Removing all containers...'
docker rm \$(docker ps -aq) || true
echo 'Pruning system (images, volumes, networks)...'
docker system prune -a -f --volumes
echo 'Cleanup complete.'
"

# Send command and capture ID
COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceids,Values=$INSTANCE_ID" \
    --parameters "commands=[\"$COMMAND\"]" \
    --query "Command.CommandId" \
    --output text)

echo "Cleanup command sent! ID: $COMMAND_ID"
echo "Waiting for execution..."
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"

echo "Cleanup finished. The ECS Agent should automatically start a new fresh task soon."
