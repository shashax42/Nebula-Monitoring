#!/usr/bin/env bash
# Amazon Managed Grafana 에 Nebula 데이터소스(AMP / CloudWatch / X-Ray)와 대시보드를 올린다.
#
#   ./scripts/provision-grafana.sh [env]                 # 기본 env=dev, 기본 대시보드만
#   ./scripts/provision-grafana.sh dev --extensions      # 확장(테넌트·결제·마진) 대시보드도 업로드
#
# 필요: aws CLI, terraform, curl, jq / Terraform apply 완료 상태
# 동작:
#   1) 워크스페이스 서비스 계정(nebula-provisioner, ADMIN) 확보 → 15분짜리 토큰 발급
#   2) 데이터소스 upsert (uid 고정: amp / cloudwatch / xray, 인증 = 워크스페이스 IAM 역할)
#   3) grafana/dashboards/*.json 을 "Nebula" 폴더에 overwrite 업로드 (--extensions: extensions/*.json 도)
#   4) 토큰 삭제
set -euo pipefail

ENVIRONMENT="${1:-dev}"
WITH_EXTENSIONS="${2:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Terraform 루트는 하나, 환경은 workspace (dev = default)
TF_DIR="${ROOT_DIR}/terraform/environments/dev"
if [[ "$ENVIRONMENT" != "dev" ]]; then
  export TF_WORKSPACE="$ENVIRONMENT"
fi
REGION="${AWS_REGION:-ap-northeast-2}"
SA_NAME="nebula-provisioner"

for bin in aws terraform curl jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

tf() { terraform -chdir="$TF_DIR" output -raw "$1"; }
WS_ID="$(tf grafana_workspace_id)"
GRAFANA_URL="https://$(tf grafana_workspace_endpoint)"
AMP_URL="$(tf amp_endpoint)"
AMP_URL="${AMP_URL%/}"

echo "▶ workspace ${WS_ID} (${GRAFANA_URL})"

SA_ID="$(aws grafana list-workspace-service-accounts --workspace-id "$WS_ID" --region "$REGION" \
  --query "serviceAccounts[?name=='${SA_NAME}'].id | [0]" --output text)"
if [[ -z "$SA_ID" || "$SA_ID" == "None" ]]; then
  SA_ID="$(aws grafana create-workspace-service-account --workspace-id "$WS_ID" --region "$REGION" \
    --name "$SA_NAME" --grafana-role ADMIN --query id --output text)"
fi

TOKEN_JSON="$(aws grafana create-workspace-service-account-token --workspace-id "$WS_ID" --region "$REGION" \
  --service-account-id "$SA_ID" --name "provision-$(date +%s)" --seconds-to-live 900 --output json)"
TOKEN="$(jq -r '.serviceAccountToken.key' <<<"$TOKEN_JSON")"
TOKEN_ID="$(jq -r '.serviceAccountToken.id' <<<"$TOKEN_JSON")"
cleanup() {
  aws grafana delete-workspace-service-account-token --workspace-id "$WS_ID" --region "$REGION" \
    --service-account-id "$SA_ID" --token-id "$TOKEN_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

api() {
  curl -sS --fail-with-body -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"
}

upsert_datasource() {
  local uid="$1" body="$2"
  if api "${GRAFANA_URL}/api/datasources/uid/${uid}" >/dev/null 2>&1; then
    api -X PUT "${GRAFANA_URL}/api/datasources/uid/${uid}" -d "$body" >/dev/null
  else
    api -X POST "${GRAFANA_URL}/api/datasources" -d "$body" >/dev/null
  fi
  echo "  ✓ datasource ${uid}"
}

echo "▶ datasources"
upsert_datasource amp "$(jq -n --arg url "$AMP_URL" --arg region "$REGION" '{
  uid: "amp", name: "AMP", type: "prometheus", access: "proxy", url: $url, isDefault: true,
  jsonData: {httpMethod: "POST", sigV4Auth: true, sigV4AuthType: "ec2", sigV4Region: $region, timeInterval: "30s"}}')"
upsert_datasource cloudwatch "$(jq -n --arg region "$REGION" '{
  uid: "cloudwatch", name: "CloudWatch", type: "cloudwatch", access: "proxy",
  jsonData: {authType: "ec2", defaultRegion: $region}}')"
upsert_datasource xray "$(jq -n --arg region "$REGION" '{
  uid: "xray", name: "X-Ray", type: "grafana-x-ray-datasource", access: "proxy",
  jsonData: {authType: "ec2", defaultRegion: $region}}')"

echo "▶ folder"
api -X POST "${GRAFANA_URL}/api/folders" -d '{"uid":"nebula","title":"Nebula"}' >/dev/null 2>&1 || true

echo "▶ dashboards"
DASHBOARDS=("${ROOT_DIR}"/grafana/dashboards/*.json)
[[ "$WITH_EXTENSIONS" == "--extensions" ]] && DASHBOARDS+=("${ROOT_DIR}"/grafana/dashboards/extensions/*.json)
for f in "${DASHBOARDS[@]}"; do
  jq '{dashboard: (. + {id: null}), folderUid: "nebula", overwrite: true, message: "provisioned by scripts/provision-grafana.sh"}' "$f" \
    | api -X POST "${GRAFANA_URL}/api/dashboards/db" -d @- >/dev/null
  echo "  ✓ $(jq -r .title "$f")"
done

echo "✓ done → ${GRAFANA_URL}/dashboards/f/nebula"
