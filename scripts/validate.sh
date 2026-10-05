#!/usr/bin/env bash
# 저장소 전체 정적/동작 검증 (CI: .github/workflows/validate.yml)
#   필요: helm, terraform, docker, python3(PyYAML)
#   SKIP_TERRAFORM=1 로 terraform 단계 생략 가능 (provider 다운로드가 막힌 환경)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OTEL_IMAGE="otel/opentelemetry-collector-contrib:$(sed -n 's/^appVersion: "\(.*\)"/\1/p' helm/otel-collector/Chart.yaml)"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v2.54.1}"
fail=0
step() { printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }

step "Helm lint / template (all environments)"
CHART=helm/otel-collector
REQ=(--set global.aws.ampRemoteWriteUrl=https://example/api/v1/remote_write --set global.clusterName=ci)
helm lint "$CHART" "${REQ[@]}"
for env in dev staging prod target-infra; do
  helm template otel-collector "$CHART" -n monitoring -f "$CHART/values-$env.yaml" "${REQ[@]}" > "/tmp/otel-$env.yaml"
  echo "  rendered $env"
done
# 선택 수집기(Kafka/RabbitMQ)까지 켠 렌더링
helm template otel-collector "$CHART" -n monitoring -f "$CHART/values-prod.yaml" "${REQ[@]}" \
  --set cluster.messaging.kafka.enabled=true --set 'cluster.messaging.kafka.brokers={b-1:9092}' \
  --set cluster.messaging.rabbitmq.enabled=true > /tmp/otel-full.yaml

step "Collector configs validated by otelcol-contrib (${OTEL_IMAGE})"
for f in /tmp/otel-dev.yaml /tmp/otel-prod.yaml /tmp/otel-full.yaml; do
  python3 scripts/validate_collector.py --image "$OTEL_IMAGE" < "$f" || fail=1
done

step "Prometheus rules: check + unit tests"
docker run --rm -v "$ROOT/prometheus:/p:ro" -w /p/tests --entrypoint sh "$PROM_IMAGE" -c \
  'promtool check rules /p/rules/*.rules.yaml && promtool test rules rules.test.yaml' || fail=1

step "Dashboards are up to date and every PromQL parses"
python3 grafana/generate_dashboards.py >/dev/null
if ! git diff --quiet -- grafana/dashboards; then
  echo "grafana/dashboards/*.json is stale — run: python3 grafana/generate_dashboards.py"; git --no-pager diff --stat -- grafana/dashboards; fail=1
fi
TMP_RULES="$(mktemp -d)"; chmod 755 "$TMP_RULES"
python3 - "$TMP_RULES/dash.yaml" <<'PY'
import glob, json, sys, yaml
rules = []
for f in sorted(glob.glob("grafana/dashboards/*.json")):
    for p in json.load(open(f))["panels"]:
        for t in p.get("targets", []):
            if "expr" in t:
                e = t["expr"]
                for v in ("cluster", "service", "tenant", "aurora", "redis", "region"):
                    e = e.replace("$" + v, "x")
                rules.append({"record": f"dash:check_{len(rules)}", "expr": e})
yaml.safe_dump({"groups": [{"name": "dashboards", "rules": rules}]}, open(sys.argv[1], "w"))
print(f"  {len(rules)} dashboard queries")
PY
chmod 644 "$TMP_RULES/dash.yaml"
docker run --rm -v "$TMP_RULES:/t:ro" --entrypoint promtool "$PROM_IMAGE" check rules --lint=none /t/dash.yaml || fail=1

step "Runbook anchors referenced by alerts/dashboards exist"
python3 - <<'PY' || fail=1
import re, subprocess, sys
heads = {re.sub(r"[^\w\- ]", "", l[3:].strip().lower()).replace(" ", "-") for l in open("docs/RUNBOOK.md") if l.startswith("## ")}
used = set(subprocess.check_output("grep -rhoE 'RUNBOOK.md#[a-z0-9-]+' prometheus grafana/dashboards terraform | sed 's/RUNBOOK.md#//'", shell=True, text=True).split())
missing = sorted(used - heads)
print("  missing:", missing) if missing else print(f"  {len(used)} anchors ok")
sys.exit(1 if missing else 0)
PY

if [[ "${SKIP_TERRAFORM:-0}" != "1" ]]; then
  step "Terraform fmt / validate"
  terraform fmt -check -recursive terraform/modules/cloudwatch-alarms terraform/modules/log-analytics \
    terraform/modules/log-archive terraform/modules/cross-account-ingest terraform/environments/dev || fail=1
  (cd terraform/environments/dev && terraform init -backend=false -input=false >/dev/null && terraform validate) || fail=1
fi

if [[ $fail -ne 0 ]]; then echo -e "\n\033[0;31m✗ validation failed\033[0m"; exit 1; fi
echo -e "\n\033[0;32m✓ all checks passed\033[0m"
