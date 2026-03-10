#!/bin/bash
set -e

INSTANCE_ID="i-0468687d753fd33c1"

echo "Triggering remote database setup (create & migrate) on instance $INSTANCE_ID..."

# We use a single command string with proper escaping to ensure variable persistence
# 1. Find the container exposing port 8080
# 2. Run db:create to create the 'bia' database
# 3. Run db:migrate to create tables
COMMAND="
CONTAINER_ID=\$(docker ps -q --filter publish=8080 | head -n 1)
if [ -z \"\$CONTAINER_ID\" ]; then
  echo \"Error: Application container not found. Is the task running?\"
  exit 1
fi
echo \"Found container: \$CONTAINER_ID\"

echo \"Running db:create...\"
docker exec \$CONTAINER_ID npx sequelize db:create

echo \"Running db:migrate...\"
docker exec \$CONTAINER_ID npx sequelize db:migrate
"

# Send command and capture ID
COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceids,Values=$INSTANCE_ID" \
    --parameters "commands=[\"$COMMAND\"]" \
    --query "Command.CommandId" \
    --output text)

echo "Command sent! ID: $COMMAND_ID"
echo "Waiting for execution to complete..."

# Wait for the command to finish
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"

# Get output
echo "Command finished. Fetching output..."
aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" \
    --output text

echo "
Check the output above for any errors.
If successful, try accessing the API again."
