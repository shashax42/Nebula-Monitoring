#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ENVIRONMENT=${1:-dev}
NAMESPACE="monitoring"

echo -e "${GREEN}🚀 Deploying Nebula Monitoring Stack - Environment: ${ENVIRONMENT}${NC}"

# Step 1: Deploy Terraform resources
echo -e "${YELLOW}📦 Step 1: Deploying AWS resources with Terraform...${NC}"
cd terraform/environments/${ENVIRONMENT}

terraform init -upgrade
terraform plan -out=tfplan
terraform apply tfplan

# Capture Terraform outputs
echo -e "${YELLOW}📝 Capturing Terraform outputs...${NC}"
AMP_ENDPOINT=$(terraform output -raw amp_endpoint)
AMP_WORKSPACE_ID=$(terraform output -raw amp_workspace_id)
ROLE_ARN=$(terraform output -raw otel_collector_role_arn)
LOG_GROUP=$(terraform output -raw otel_collector_log_group)

cd ../../../

# Step 2: Create namespace if not exists
echo -e "${YELLOW}🏗️ Step 2: Creating Kubernetes namespace...${NC}"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Deploy OTEL Collector with Helm
echo -e "${YELLOW}⚙️ Step 3: Deploying OTEL Collector with Helm...${NC}"
helm upgrade --install otel-collector ./helm/otel-collector \
  --namespace ${NAMESPACE} \
  --values ./helm/otel-collector/values.yaml \
  --values ./helm/otel-collector/values-${ENVIRONMENT}.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${ROLE_ARN}" \
  --set aws.amp.endpoint="${AMP_ENDPOINT}" \
  --set aws.amp.workspaceId="${AMP_WORKSPACE_ID}" \
  --set aws.cloudwatch.logGroup="${LOG_GROUP}" \
  --wait \
  --timeout 5m

# Step 4: Verify deployment
echo -e "${YELLOW}✅ Step 4: Verifying deployment...${NC}"
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=otel-collector

# Step 5: Show collector logs
echo -e "${YELLOW}📋 Step 5: Showing OTEL Collector logs...${NC}"
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=otel-collector --tail=20

echo -e "${GREEN}✨ Deployment complete!${NC}"
echo -e "${GREEN}📊 AMP Endpoint: ${AMP_ENDPOINT}${NC}"
echo -e "${GREEN}📝 CloudWatch Log Group: ${LOG_GROUP}${NC}"
echo -e "${GREEN}🔐 IAM Role: ${ROLE_ARN}${NC}"
