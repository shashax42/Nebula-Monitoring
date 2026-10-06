#!/usr/bin/env python3
"""helm/otel-collector/values.yaml 의 agent/gateway 설정을 로컬(무 AWS)용으로 변환한다.

AWS exporter 를 로컬 대체물로 바꾸는 것 외에는 정제/가공 설정을 그대로 쓴다
(→ 로컬에서 본 결과 = 클러스터에서의 결과).
  prometheus_remote_write/amp → prometheus exporter (:9464, Prometheus 가 scrape)
  awsxray / awsemf / awscloudwatchlogs → file exporter (./out/*.json)

    python3 render.py               # 기본 배포와 같은 구성
    python3 render.py --extensions  # + values-extension-business.yaml, 확장 규칙·대시보드
"""
import glob
import os
import shutil
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
CHART = os.path.join(ROOT, "helm", "otel-collector")
GEN = os.path.join(HERE, "generated")
EXT = "--extensions" in sys.argv[1:]


def merge(base, over):
    """Helm 과 같은 규칙: map 은 재귀 병합, 그 외(list 포함)는 덮어쓴다."""
    for k, val in over.items():
        if isinstance(val, dict) and isinstance(base.get(k), dict):
            merge(base[k], val)
        else:
            base[k] = val
    return base


v = yaml.safe_load(open(os.path.join(CHART, "values.yaml")))
if EXT:
    merge(v, yaml.safe_load(open(os.path.join(CHART, "values-extension-business.yaml"))))
gw, ag = v["gateway"]["config"], v["agent"]["config"]

gw["exporters"] = {
    "prometheus": {"endpoint": "0.0.0.0:9464", "add_metric_suffixes": True,
                   "resource_to_telemetry_conversion": {"enabled": False}},
    "file/xray": {"path": "/out/xray-traces.json"},
    "file/emf": {"path": "/out/cloudwatch-emf.json"},
    "file/logs-app": {"path": "/out/logs-application.json"},
    "file/logs-audit": {"path": "/out/logs-audit.json"},
    "file/logs-events": {"path": "/out/logs-events.json"},
}
del gw["extensions"]["sigv4auth"]
gw["service"]["extensions"] = ["health_check"]
p = gw["service"]["pipelines"]
p["traces/out"]["exporters"] = ["file/xray"]
p["metrics"]["exporters"] = ["prometheus"]
p["metrics/derived"]["exporters"] = ["prometheus"]
p["metrics/cloudwatch"]["exporters"] = ["file/emf"]
p["logs/app"]["exporters"] = ["file/logs-app"]
p["logs/audit"]["exporters"] = ["file/logs-audit"]
p["logs/events"]["exporters"] = ["file/logs-events"]
# prometheus exporter 는 delta 를 스스로 누적하므로 PRW 용 변환은 그대로 둬도 무방

# agent: k8s API / kubelet 이 없으므로 해당 수집기만 제외 (filelog 는 ./sample-logs 를 읽음)
del ag["receivers"]["prometheus"]
ag["receivers"]["file_log"]["start_at"] = "beginning"
del ag["processors"]["k8sattributes"]
for pl in ag["service"]["pipelines"].values():
    pl["processors"] = [x for x in pl["processors"] if x != "k8sattributes"]
del ag["service"]["pipelines"]["metrics/scrape"]

os.makedirs(GEN, exist_ok=True)
for name, cfg in (("gateway", gw), ("agent", ag)):
    with open(os.path.join(GEN, f"{name}.yaml"), "w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)

# Prometheus: AMP 와 같은 규칙 세트 (확장은 --extensions 일 때만)
prom = yaml.safe_load(open(os.path.join(HERE, "prometheus.yml")))
prom["rule_files"] = ["/etc/prometheus/rules/*.rules.yaml"] + (["/etc/prometheus/rules/extensions/*.rules.yaml"] if EXT else [])
with open(os.path.join(GEN, "prometheus.yml"), "w") as f:
    yaml.safe_dump(prom, f, sort_keys=False)

# Grafana: 기본 대시보드 (+ 확장)
dash = os.path.join(GEN, "dashboards")
shutil.rmtree(dash, ignore_errors=True)
os.makedirs(dash)
for src in glob.glob(os.path.join(ROOT, "grafana", "dashboards", "*.json")) + \
        (glob.glob(os.path.join(ROOT, "grafana", "dashboards", "extensions", "*.json")) if EXT else []):
    shutil.copy(src, dash)

# 컨테이너 로그: 샘플을 복사해 두고 simulator(--log-dir pod-logs)가 이어서 기록한다
logs = os.path.join(HERE, "pod-logs")
if not os.path.isdir(logs):
    shutil.copytree(os.path.join(HERE, "sample-logs"), logs)

os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
os.chmod(os.path.join(HERE, "out"), 0o777)
print("rendered", GEN, "(+extensions)" if EXT else "")
