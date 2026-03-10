ECR_REGISTRY="388976124018.dkr.ecr.us-east-1.amazonaws.com"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build --platform linux/amd64 -t bia .
docker tag bia:latest $ECR_REGISTRY/bia:latest
docker push $ECR_REGISTRY/bia:latest
