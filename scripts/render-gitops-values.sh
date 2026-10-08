#!/usr/bin/env bash
# Terraform output → nebula-gitops platform/aws/envs/<env> 의 계정 고유 값 기록
#
#   ./scripts/render-gitops-values.sh [env] <nebula-gitops 경로>      # 예: prod ../nebula-gitops
#
# Terraform 루트는 terraform/environments/dev 하나이고 환경은 workspace 로 나뉜다 (dev = default workspace).
#
# 채우는 값
#   platform/aws/envs/<env>/values-monitoring.yaml  global.clusterName, global.environment, global.aws.region,
#                                                   global.aws.ampRemoteWriteUrl, gateway.serviceAccount.annotations[role-arn]
#   platform/aws/envs/<env>/analysis-args.yaml      args[amp-endpoint], args[region]  (service-order 카나리 분석이 조회할 AMP)
#
# 결과는 gitops 레포 작업 트리에만 쓴다. 커밋/PR 은 사람이 확인 후 진행 (ArgoCD 가 main 을 동기화).
# 필요: terraform, yq(v4) / Nebula-Monitoring terraform apply -var enable_target_monitoring=true 완료 상태
set -euo pipefail

ENVIRONMENT="${1:-dev}"
GITOPS_DIR="${2:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform/environments/dev"
if [[ "$ENVIRONMENT" != "dev" ]]; then
  export TF_WORKSPACE="$ENVIRONMENT"
fi

if [[ -z "$GITOPS_DIR" || ! -d "$GITOPS_DIR/platform/aws/envs/${ENVIRONMENT}" ]]; then
  echo "usage: $0 [env] <nebula-gitops 경로>   (platform/aws/envs/${ENVIRONMENT} 디렉터리가 있어야 함)" >&2
  exit 1
fi
for bin in terraform yq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
yq --version 2>&1 | grep -q 'version v4' || { echo "yq v4 (mikefarah) 가 필요합니다" >&2; exit 1; }

tf() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }
CLUSTER="$(tf target_cluster_name)"
REMOTE_WRITE="$(tf amp_remote_write_url)"
AMP_ENDPOINT="$(tf amp_endpoint)"
ROLE_ARN="$(tf target_otel_role_arn)"
REGION="$(terraform -chdir="$TF_DIR" console <<<'var.region' 2>/dev/null | tr -d '"' || true)"
REGION="${REGION:-ap-northeast-2}"

missing=()
[[ -n "$CLUSTER" ]] || missing+=(target_cluster_name)
[[ -n "$REMOTE_WRITE" ]] || missing+=(amp_remote_write_url)
[[ -n "$AMP_ENDPOINT" ]] || missing+=(amp_endpoint)
[[ -n "$ROLE_ARN" && "$ROLE_ARN" != "null" ]] || missing+=(target_otel_role_arn)
if (( ${#missing[@]} )); then
  echo "Terraform output 이 비어 있습니다: ${missing[*]}" >&2
  echo "→ ${TF_DIR} 에서 (workspace ${TF_WORKSPACE:-default}) terraform apply -var environment=${ENVIRONMENT} -var enable_target_monitoring=true 후 다시 실행" >&2
  exit 1
fi

VALUES="${GITOPS_DIR}/platform/aws/envs/${ENVIRONMENT}/values-monitoring.yaml"
ANALYSIS="${GITOPS_DIR}/platform/aws/envs/${ENVIRONMENT}/analysis-args.yaml"

CLUSTER="$CLUSTER" REGION="$REGION" REMOTE_WRITE="$REMOTE_WRITE" ROLE_ARN="$ROLE_ARN" ENVIRONMENT="$ENVIRONMENT" yq -i '
  .global.clusterName = strenv(CLUSTER) |
  .global.environment = strenv(ENVIRONMENT) |
  .global.aws.region = strenv(REGION) |
  .global.aws.ampRemoteWriteUrl = strenv(REMOTE_WRITE) |
  .gateway.serviceAccount.annotations["eks.amazonaws.com/role-arn"] = strenv(ROLE_ARN)
' "$VALUES"

# Argo Rollouts prometheus provider 는 .../workspaces/ws-xxx/ 까지를 address 로 받고 /api/v1/query 를 붙인다
AMP_ENDPOINT="${AMP_ENDPOINT%/}/" REGION="$REGION" yq -i '
  (.spec.args[] | select(.name == "amp-endpoint")).value = strenv(AMP_ENDPOINT) |
  (.spec.args[] | select(.name == "region")).value = strenv(REGION)
' "$ANALYSIS"

echo "✓ ${VALUES#"$GITOPS_DIR"/}"
echo "    clusterName=${CLUSTER} region=${REGION}"
echo "    ampRemoteWriteUrl=${REMOTE_WRITE}"
echo "    role-arn=${ROLE_ARN}"
echo "✓ ${ANALYSIS#"$GITOPS_DIR"/}  amp-endpoint=${AMP_ENDPOINT%/}/"
echo
echo "다음: cd ${GITOPS_DIR} && git diff → 브랜치/PR → main 머지"
echo "      → Nebula-Platform environments/${ENVIRONMENT}: enable_aws_platform_apps = true 로 apply (ArgoCD 가 envs/${ENVIRONMENT} 동기화)"
