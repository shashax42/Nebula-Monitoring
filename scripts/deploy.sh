#!/usr/bin/env bash
# Nebula Monitoring 전체 배포 (Terraform → kube-state-metrics → OTel Collector → Grafana 대시보드)
#
#   ./scripts/deploy.sh [env]        # 기본 dev. terraform_new 클러스터 연결(enable_target_monitoring=true) 기준
set -euo pipefail

ENVIRONMENT="${1:-dev}"
NAMESPACE="monitoring"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Terraform 루트는 하나, 환경은 workspace (dev = default)
TF_DIR="${ROOT_DIR}/terraform/environments/dev"
if [[ "$ENVIRONMENT" != "dev" ]]; then
  export TF_WORKSPACE="$ENVIRONMENT"
fi
REGION="${AWS_REGION:-ap-northeast-2}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "${YELLOW}▶ $*${NC}"; }

step "[1/5] Terraform apply (AMP 규칙/Alertmanager, CloudWatch 알람, 로그 그룹, 아카이브, IRSA)"
terraform -chdir="$TF_DIR" init -upgrade
terraform -chdir="$TF_DIR" apply -var="enable_target_monitoring=true"

tf() { terraform -chdir="$TF_DIR" output -raw "$1"; }
CLUSTER="$(tf target_cluster_name)"
ROLE_ARN="$(tf target_otel_role_arn)"
AMP_URL="$(tf amp_remote_write_url)"
if [[ -z "$CLUSTER" || -z "$ROLE_ARN" ]]; then
  echo -e "${RED}target_cluster_name / target_otel_role_arn 이 비어 있습니다. terraform_new state 연결을 확인하세요.${NC}" >&2
  exit 1
fi

step "[2/5] kubeconfig → ${CLUSTER}"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

step "[3/5] kube-state-metrics"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace "$NAMESPACE" -f "${ROOT_DIR}/helm/kube-state-metrics/values.yaml" --wait --timeout 3m

step "[4/5] OTel Collector (agent / gateway / cluster)"
VALUES_ENV="${ROOT_DIR}/helm/otel-collector/values-${ENVIRONMENT}.yaml"
helm upgrade --install otel-collector "${ROOT_DIR}/helm/otel-collector" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_ENV" \
  -f "${ROOT_DIR}/helm/otel-collector/values-target-infra.yaml" \
  --set global.clusterName="$CLUSTER" \
  --set global.environment="$ENVIRONMENT" \
  --set global.aws.region="$REGION" \
  --set global.aws.ampRemoteWriteUrl="$AMP_URL" \
  --set gateway.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN" \
  --wait --timeout 5m
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-collector

step "[5/5] Grafana 데이터소스 / 대시보드"
"${ROOT_DIR}/scripts/provision-grafana.sh" "$ENVIRONMENT"

echo -e "${GREEN}✓ 배포 완료${NC}"
echo "  앱 OTLP 엔드포인트 : http://otel-collector.${NAMESPACE}.svc:4317 (gRPC) / :4318 (HTTP)"
echo "  Grafana           : https://$(tf grafana_workspace_endpoint)"
echo "  검증              : python3 tools/telemetry-simulator/simulate.py (port-forward 후)"
