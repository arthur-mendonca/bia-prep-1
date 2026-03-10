#!/bin/bash
set -e

INSTANCE_ID="i-0468687d753fd33c1"

echo "Installing Kiro CLI on instance $INSTANCE_ID for ec2-user..."

# We need to use a directory on disk because /tmp (tmpfs) is full
COMMAND="
# Install unzip if missing
yum install -y unzip

# Switch to ec2-user context
su - ec2-user -c '
  # Create a temp directory on disk (not in /tmp)
  mkdir -p ~/kiro-temp
  cd ~/kiro-temp
  
  echo \"Downloading Kiro CLI to disk...\"
  curl --proto \"=https\" --tlsv1.2 -sSf \"https://desktop-release.q.us-east-1.amazonaws.com/latest/kirocli-x86_64-linux.zip\" -o \"kirocli.zip\"

  echo \"Unzipping...\"
  unzip -o kirocli.zip

  echo \"Installing...\"
  cd kirocli
  ./install.sh --no-confirm
  
  echo \"Kiro CLI installed successfully.\"
  
  # Cleanup
  cd ~
  rm -rf ~/kiro-temp
'
"

# Escape double quotes for JSON (replace " with \")
COMMAND_ESCAPED=$(echo "$COMMAND" | sed 's/"/\\"/g')

# Send command and capture ID
COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceids,Values=$INSTANCE_ID" \
    --parameters "commands=[\"$COMMAND_ESCAPED\"]" \
    --query "Command.CommandId" \
    --output text)

echo "Install command sent! ID: $COMMAND_ID"
echo "Waiting for execution..."
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"

echo "Installation complete. You may need to restart your shell or run 'source ~/.bashrc' to use kiro-cli."
