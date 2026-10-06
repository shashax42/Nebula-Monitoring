#!/usr/bin/env python3
"""Generate Nebula Grafana dashboards (Amazon Managed Grafana) as JSON.

    python3 grafana/generate_dashboards.py          # writes grafana/dashboards/*.json (+ extensions/)

Dashboards use datasource *variables* (${amp}, ${cloudwatch}, ${xray}) so the same JSON
works in every workspace; scripts/provision-grafana.sh creates the datasources and uploads.

Design rules (kept consistent across dashboards):
  - status colors (green/yellow/red) only on thresholds, never as series identity
  - SLO targets are drawn as dashed threshold lines ("time series with goal line")
  - one unit per panel (no dual axes); single-series panels hide the legend
  - every row ends with actionable links (runbook / X-Ray / Logs Insights)
"""
import json
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")
REPO = "https://github.com/shashax42/Nebula-Monitoring/blob/main"
RUNBOOK = f"{REPO}/docs/RUNBOOK.md"
CONSOLE = "https://${region}.console.aws.amazon.com"

AMP = {"type": "prometheus", "uid": "${amp}"}
CW = {"type": "cloudwatch", "uid": "${cloudwatch}"}
XRAY = {"type": "grafana-x-ray-datasource", "uid": "${xray}"}

GREEN, YELLOW, ORANGE, RED = "green", "#EAB839", "orange", "red"


# --------------------------------------------------------------------------
# builders
# --------------------------------------------------------------------------
class Layout:
    def __init__(self):
        self.y = 0
        self.x = 0
        self.row_h = 0
        self.panels = []
        self.next_id = 1

    def _place(self, w, h):
        if self.x + w > 24:
            self.y += self.row_h
            self.x = 0
            self.row_h = 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        return pos

    def row(self, title):
        if self.x:
            self.y += self.row_h
        self.x, self.row_h = 0, 0
        self.panels.append({"type": "row", "title": title, "collapsed": False, "id": self.next_id,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.next_id += 1
        self.y += 1

    def add(self, panel, w, h):
        panel["id"] = self.next_id
        self.next_id += 1
        panel["gridPos"] = self._place(w, h)
        self.panels.append(panel)


def prom(expr, legend="", instant=False, fmt=None, ref="A"):
    t = {"refId": ref, "datasource": AMP, "expr": expr, "legendFormat": legend or "__auto", "range": not instant, "instant": instant}
    if fmt:
        t["format"] = fmt
    return t


def thresholds(*steps):
    """steps: (color, value) with first value None"""
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in steps]}


def timeseries(title, targets, unit="short", desc="", goal=None, legend=True, stack=False, minv=None, maxv=None, links=None):
    custom = {"lineWidth": 2, "fillOpacity": 10 if stack else 0, "showPoints": "never", "spanNulls": True,
              "axisSoftMin": 0, "gradientMode": "none"}
    defaults = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"}}
    if stack:
        custom["stacking"] = {"mode": "normal", "group": "A"}
    if goal is not None:
        # Time series with goal line: SLO 목표를 점선 임계선으로 그린다
        custom["thresholdsStyle"] = {"mode": "dashed"}
        defaults["thresholds"] = thresholds((GREEN, None), (RED, goal))
        # 값이 모두 0 이어도 목표선이 화면 안에 보이도록 축 상한을 목표 기준으로 잡는다
        custom["axisSoftMax"] = goal * 1.5
    if minv is not None:
        defaults["min"] = minv
    if maxv is not None:
        defaults["max"] = maxv
    p = {"type": "timeseries", "title": title, "description": desc, "datasource": targets[0]["datasource"],
         "targets": targets, "fieldConfig": {"defaults": defaults, "overrides": []},
         "options": {"legend": {"showLegend": legend, "displayMode": "list", "placement": "bottom"},
                     "tooltip": {"mode": "multi", "sort": "desc"}}}
    if links:
        p["links"] = links
    return p


def stat(title, target, unit="short", steps=None, desc="", decimals=None, graph=True, text_mode="auto", links=None):
    defaults = {"unit": unit, "thresholds": steps or thresholds(("text", None)),
                "color": {"mode": "thresholds"}, "noValue": "—"}
    if decimals is not None:
        defaults["decimals"] = decimals
    p = {"type": "stat", "title": title, "description": desc, "datasource": target["datasource"], "targets": [target],
         "fieldConfig": {"defaults": defaults, "overrides": []},
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": "value", "graphMode": "area" if graph else "none", "textMode": text_mode,
                     "justifyMode": "auto", "orientation": "auto"}}
    if links:
        p["links"] = links
    return p


def gauge(title, target, unit, steps, minv, maxv, desc="", decimals=None):
    defaults = {"unit": unit, "min": minv, "max": maxv, "thresholds": steps, "color": {"mode": "thresholds"}, "noValue": "—"}
    if decimals is not None:
        defaults["decimals"] = decimals
    return {"type": "gauge", "title": title, "description": desc, "datasource": target["datasource"], "targets": [target],
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "showThresholdMarkers": True, "showThresholdLabels": False}}


def bargauge(title, targets, unit="short", desc="", steps=None, minv=0, maxv=None):
    defaults = {"unit": unit, "min": minv, "thresholds": steps or thresholds(("blue", None)), "color": {"mode": "thresholds"}}
    if maxv is not None:
        defaults["max"] = maxv
    return {"type": "bargauge", "title": title, "description": desc, "datasource": targets[0]["datasource"], "targets": targets,
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "orientation": "horizontal", "displayMode": "basic", "showUnfilled": True, "valueMode": "text"}}


def table(title, expr, unit="short", desc="", rename=None, sort_col="Value", links=None, steps=None):
    t = prom(expr, instant=True, fmt="table")
    defaults = {"unit": unit, "custom": {"align": "auto", "cellOptions": {"type": "auto"}}}
    overrides = []
    if steps:
        overrides.append({"matcher": {"id": "byName", "options": "Value"},
                          "properties": [{"id": "custom.cellOptions", "value": {"type": "color-text"}},
                                         {"id": "thresholds", "value": steps}]})
    p = {"type": "table", "title": title, "description": desc, "datasource": AMP, "targets": [t],
         "fieldConfig": {"defaults": defaults, "overrides": overrides},
         "options": {"showHeader": True, "sortBy": [{"displayName": (rename or {}).get("Value", sort_col), "desc": True}]},
         "transformations": [{"id": "organize", "options": {
             "excludeByName": {"Time": True, "__name__": True, "job": True, "collector": True, "environment": True, "cluster": True,
                             "otel_scope_name": True, "otel_scope_version": True, "otel_scope_schema_url": True},
             "renameByName": rename or {}}}]}
    if links:
        p["fieldConfig"]["defaults"]["links"] = links
    return p


def text(title, content):
    return {"type": "text", "title": title, "options": {"mode": "markdown", "content": content}}


def cw_metric(namespace, metric, dims, stat_="Average", ref="A", label=""):
    return {"refId": ref, "datasource": CW, "queryMode": "Metrics", "region": "default", "namespace": namespace,
            "metricName": metric, "dimensions": dims, "statistic": stat_, "period": "", "matchExact": True,
            "metricQueryType": 0, "metricEditorMode": 0, "id": "", "expression": "", "label": label}


def cw_logs(title, groups, query, desc=""):
    return {"type": "logs", "title": title, "description": desc, "datasource": CW,
            "targets": [{"refId": "A", "datasource": CW, "queryMode": "Logs", "region": "default",
                         "logGroupNames": groups, "expression": query, "id": "", "statsGroups": []}],
            "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True}}


def link(title, url, icon="external link"):
    return {"title": title, "url": url, "targetBlank": True}


def ds_var(name, label, typ):
    return {"name": name, "label": label, "type": "datasource", "query": typ, "hide": 0, "refresh": 1,
            "current": {}, "options": [], "regex": ""}


def query_var(name, label, query, multi=False, include_all=False, all_value=None, hide=0):
    v = {"name": name, "label": label, "type": "query", "datasource": AMP,
         "definition": query, "query": {"query": query, "refId": f"var-{name}"},
         "refresh": 2, "sort": 1, "multi": multi, "includeAll": include_all, "hide": hide, "current": {}, "options": [], "regex": ""}
    if all_value:
        v["allValue"] = all_value
    return v


def custom_var(name, label, values, default):
    return {"name": name, "label": label, "type": "custom", "query": ",".join(values), "hide": 0,
            "current": {"text": default, "value": default}, "options": [], "multi": False, "includeAll": False}


def dashboard(uid, title, layout, variables, desc, links=None, tags=None, refresh="1m", time_from="now-6h"):
    return {
        "uid": uid, "title": title, "description": desc, "tags": ["nebula"] + (tags or []),
        "timezone": "browser", "editable": True, "graphTooltip": 1, "schemaVersion": 39, "version": 1,
        "refresh": refresh, "time": {"from": time_from, "to": "now"},
        "templating": {"list": variables}, "annotations": {"list": []},
        "links": links or [], "panels": layout.panels,
    }


BASE_VARS = [ds_var("amp", "Metrics (AMP)", "prometheus"),
             query_var("cluster", "Cluster", "label_values(up{job=\"otelcol\"}, cluster)")]
REGION_VAR = custom_var("region", "Region", ["ap-northeast-2", "us-east-1", "eu-west-1"], "ap-northeast-2")

COMMON_LINKS = [
    {"title": "Nebula dashboards", "type": "dashboards", "tags": ["nebula"], "asDropdown": True, "includeVars": True, "keepTime": True},
    link("Runbook", RUNBOOK),
]

C = 'cluster="$cluster"'

# rate() 는 __name__ 을 지우므로 정규식 이름 매칭 대신 신호별로 합산한다
SIGNAL_SUM = ('sum('
              'label_replace(rate({m}_spans_total{{{c}}}[5m]), "signal", "traces", "", "") '
              'or label_replace(rate({m}_metric_points_total{{{c}}}[5m]), "signal", "metrics", "", "") '
              'or label_replace(rate({m}_log_records_total{{{c}}}[5m]), "signal", "logs", "", "")'
              ') or vector(0)')


# --------------------------------------------------------------------------
# 1. Overview (Q1~Q5): 클러스터 건강 → 에러 → 지연 → 리소스 → 시스템 개요
# --------------------------------------------------------------------------
def overview():
    L = Layout()
    L.row("Q1. 클러스터 건강 상태")
    L.add(stat("NotReady 노드", prom(f'count(kube_node_status_condition{{{C},condition="Ready",status="true"}} == 0) or vector(0)'),
               steps=thresholds((GREEN, None), (RED, 1)), graph=False,
               links=[link("Runbook: KubeNodeNotReady", f"{RUNBOOK}#kubenodenotready")]), 4, 4)
    L.add(stat("Pending 파드", prom(f'sum(kube_pod_status_phase{{{C},phase="Pending"}}) or vector(0)'),
               steps=thresholds((GREEN, None), (YELLOW, 1), (RED, 10)), graph=False), 4, 4)
    L.add(stat("Failed 파드", prom(f'sum(kube_pod_status_phase{{{C},phase="Failed"}}) or vector(0)'),
               steps=thresholds((GREEN, None), (RED, 1)), graph=False), 4, 4)
    L.add(stat("CrashLoopBackOff 컨테이너", prom(f'sum(kube_pod_container_status_waiting_reason{{{C},reason="CrashLoopBackOff"}}) or vector(0)'),
               steps=thresholds((GREEN, None), (RED, 1)), graph=False), 4, 4)
    L.add(stat("발화 중인 알림", prom(f'count(ALERTS{{alertstate="firing",{C}}}) or vector(0)'),
               steps=thresholds((GREEN, None), (YELLOW, 1), (RED, 5)), graph=False,
               desc="AMP 알림 규칙 중 현재 firing 상태"), 4, 4)
    L.add(stat("클러스터 CPU", prom(f'cluster:cpu_utilization:ratio{{{C}}}'), unit="percentunit",
               steps=thresholds((GREEN, None), (YELLOW, 0.7), (RED, 0.85)), decimals=1), 4, 4)
    L.add(timeseries("Top 5 재시작 파드 (30분)", [prom(f'topk(5, increase(kube_pod_container_status_restarts_total{{{C}}}[30m]) > 0)', "{{namespace}}/{{pod}}")]), 12, 8)
    L.add(table("네임스페이스별 파드 상태", f'sum by (namespace, phase) (kube_pod_status_phase{{{C}}}) > 0',
                rename={"Value": "파드 수"}), 12, 8)

    L.row("Q2. 서비스 에러율 (Errors = 5xx + 예외, 트레이스 기반)")
    L.add(timeseries("서비스별 에러율", [prom(f'service:error_ratio:rate5m{{{C}}}', "{{service_name}}")],
                     unit="percentunit", goal=0.001, desc="점선 = 가용성 SLO 99.9% 의 에러 허용치(0.1%)",
                     links=[link("Runbook: SLO 번레이트", f"{RUNBOOK}#sloavailabilityburn")]), 12, 8)
    L.add(table("Top 10 에러 라우트", f'topk(10, service_route:error_ratio:rate5m{{{C}}} > 0)', unit="percentunit",
                rename={"Value": "에러율", "service_name": "서비스", "http_route": "라우트", "http_request_method": "메서드"},
                steps=thresholds((GREEN, None), (YELLOW, 0.01), (RED, 0.05))), 12, 8)

    L.row("Q3. 응답 시간 (Latency, 꼬리 지연)")
    L.add(timeseries("서비스별 P95", [prom(f'service:latency_seconds:p95_5m{{{C}}}', "{{service_name}}")], unit="s", goal=1,
                     desc="점선 = 지연 SLO (P95 < 1s)"), 8, 8)
    L.add(timeseries("서비스별 P99", [prom(f'service:latency_seconds:p99_5m{{{C}}}', "{{service_name}}")], unit="s"), 8, 8)
    L.add(table("Top 10 느린 라우트 (P99)", f'topk(10, service_route:latency_seconds:p99_5m{{{C}}})', unit="s",
                rename={"Value": "P99", "service_name": "서비스", "http_route": "라우트", "http_request_method": "메서드"},
                steps=thresholds((GREEN, None), (YELLOW, 0.5), (RED, 1))), 8, 8)

    L.row("Q4. 리소스 사용률 (Saturation & 비용 최적화)")
    L.add(timeseries("네임스페이스 CPU 사용률 (vs Limit)", [prom(f'namespace:cpu_usage_vs_limit:ratio{{{C}}}', "{{namespace}}")],
                     unit="percentunit", goal=0.8), 12, 8)
    L.add(timeseries("네임스페이스 메모리 사용률 (vs Limit)", [prom(f'namespace:memory_usage_vs_limit:ratio{{{C}}}', "{{namespace}}")],
                     unit="percentunit", goal=0.8), 12, 8)
    L.add(table("과소 사용 파드 (1일 평균 CPU/request < 10%) — 다운사이징 후보",
                f'sort(pod:cpu_usage_vs_request:avg1d{{{C}}} < 0.1)', unit="percentunit",
                rename={"Value": "CPU/request (1d)", "namespace": "네임스페이스", "pod": "파드"}), 12, 8)
    L.add(table("과부하 파드 (CPU/limit > 80%) — 스케일업 후보",
                f'sort_desc(pod:cpu_usage_vs_limit:ratio{{{C}}} > 0.8)', unit="percentunit",
                rename={"Value": "CPU/limit", "namespace": "네임스페이스", "pod": "파드"},
                steps=thresholds((YELLOW, None), (RED, 0.95))), 12, 8)
    L.add(timeseries("노드 CPU", [prom(f'node:cpu_utilization:ratio{{{C}}}', "{{node}}")], unit="percentunit", goal=0.8, maxv=1), 12, 7)
    L.add(timeseries("노드 메모리", [prom(f'node:memory_utilization:ratio{{{C}}}', "{{node}}")], unit="percentunit", goal=0.85, maxv=1), 12, 7)

    L.row("Q5. 시스템 개요")
    for title, expr in [("노드", f'count(kube_node_info{{{C}}})'), ("파드", f'count(kube_pod_info{{{C}}})'),
                        ("네임스페이스", f'count(kube_namespace_status_phase{{{C},phase="Active"}} == 1)'),
                        ("Deployment", f'count(kube_deployment_spec_replicas{{{C}}})'),
                        ("활성 scrape 타겟", f'count(up{{{C}}} == 1)')]:
        L.add(stat(title, prom(expr), graph=False), 4, 4)
    L.add(stat("다운 타겟", prom(f'count(up{{{C}}} == 0) or vector(0)'), steps=thresholds((GREEN, None), (RED, 1)), graph=False), 4, 4)
    return dashboard("nebula-overview", "Nebula / Overview (Q1–Q5)", L, BASE_VARS,
                     "클러스터 건강 → 서비스 에러 → 지연 → 리소스 → 시스템 개요 순서로 '어디부터 볼지'를 안내하는 첫 화면",
                     links=COMMON_LINKS, tags=["overview"])


# --------------------------------------------------------------------------
# 2. Service SLO: Gauge with Thresholds / Time Series with Goal Line / Time to Burn Out / Actionable Links
# --------------------------------------------------------------------------
def service_slo():
    L = Layout()
    S = f'{C},service_name="$service"'
    L.row("SLO 현황 — $service")
    L.add(gauge("30일 가용성 (SLO 99.9%)", prom(f'1 - service:sli_error:ratio_rate30d{{{S}}}'), "percentunit",
                thresholds((RED, None), (YELLOW, 0.999), (GREEN, 0.9995)), 0.99, 1, decimals=3,
                desc="Gauge with Thresholds — 빨강: SLO 위반, 노랑: 목표 근접, 초록: 여유"), 6, 7)
    L.add(gauge("남은 에러 버짓 (30일)", prom(f'clamp_min(service:error_budget_remaining:ratio{{{S}}}, 0)'), "percentunit",
                thresholds((RED, None), (YELLOW, 0.25), (GREEN, 0.5)), 0, 1, decimals=1), 6, 7)
    L.add(stat("Time to Burn Out", prom(f'service:error_budget_exhaustion:hours{{{S}}}'), unit="h",
               steps=thresholds((RED, None), (ORANGE, 24), (YELLOW, 72), (GREEN, 168)), graph=False, decimals=1,
               desc="현재 1시간 번레이트가 유지될 때 남은 30일 에러 버짓이 소진되기까지 시간 (최대 8760h)"), 6, 7)
    L.add(stat("현재 번레이트 (1h)", prom(f'service:sli_error:ratio_rate1h{{{S}}} / 0.001'), unit="x",
               steps=thresholds((GREEN, None), (YELLOW, 1), (ORANGE, 6), (RED, 14.4)), decimals=2,
               desc="1 = 정확히 버짓 속도로 소진. 6x/14.4x 는 페이지 알림 기준",
               links=[link("Runbook: SLO 번레이트", f"{RUNBOOK}#sloavailabilityburn")]), 6, 7)

    L.row("Golden Signals")
    L.add(timeseries("Traffic (req/s)", [prom(f'service:requests:rate5m{{{S}}}', "req/s")], unit="reqps", legend=False), 8, 8)
    L.add(timeseries("Errors — 에러율 vs SLO", [prom(f'service:error_ratio:rate5m{{{S}}}', "에러율")], unit="percentunit",
                     goal=0.001, legend=False, desc="Time Series with Goal Line: 점선 = 에러 허용치 0.1%"), 8, 8)
    L.add(timeseries("Latency — P50 / P95 / P99", [
        prom(f'service:latency_seconds:p50_5m{{{S}}}', "P50", ref="A"),
        prom(f'service:latency_seconds:p95_5m{{{S}}}', "P95", ref="B"),
        prom(f'service:latency_seconds:p99_5m{{{S}}}', "P99", ref="C")], unit="s", goal=1,
        desc="점선 = 지연 SLO 1s (P95 기준)"), 8, 8)
    L.add(timeseries("번레이트 (1h / 6h)", [
        prom(f'service:sli_error:ratio_rate1h{{{S}}} / 0.001', "1h", ref="A"),
        prom(f'service:sli_error:ratio_rate6h{{{S}}} / 0.001', "6h", ref="B")], unit="x", goal=6,
        desc="점선 = 6x (페이지 기준). 14.4x 이상이면 1시간 안에 버짓 2% 소진"), 12, 8)
    L.add(timeseries("지연 SLO 위반 비율 (1s 초과)", [
        prom(f'service:sli_latency_bad:ratio_rate1h{{{S}}}', "1h", ref="A"),
        prom(f'service:sli_latency_bad:ratio_rate5m{{{S}}}', "5m", ref="B")], unit="percentunit", goal=0.05), 12, 8)

    L.row("배포 — canary vs stable (Argo Rollouts, nebula-slo-canary 분석과 같은 신호)")
    TR = f'{S},span_kind="SPAN_KIND_SERVER",deployment_track!=""'
    L.add(timeseries("트랙별 에러율", [prom(
        f'sum by (deployment_track) (rate(traces_span_metrics_calls_total{{{TR},status_code="STATUS_CODE_ERROR"}}[2m]))'
        f' / sum by (deployment_track) (rate(traces_span_metrics_calls_total{{{TR}}}[2m]))', "{{deployment_track}}")],
        unit="percentunit", goal=0.01,
        desc="점선 = 분석 절대 기준 1%. canary 가 stable×2+0.5%p 를 넘거나 1% 를 넘으면 롤백. 롤아웃 중에만 canary 선이 생긴다"), 12, 8)
    L.add(timeseries("트랙별 P99", [prom(
        f'histogram_quantile(0.99, sum by (deployment_track, le) (rate(traces_span_metrics_duration_seconds_bucket{{{TR}}}[2m])))',
        "{{deployment_track}}")], unit="s", goal=1.5, desc="점선 = 분석 기준 1.5s"), 12, 8)

    L.row("라우트 / 의존성")
    L.add(table("라우트별 트래픽·에러·P99", f'service_route:requests:rate5m{{{S}}}', unit="reqps",
                rename={"Value": "req/s", "http_route": "라우트", "http_request_method": "메서드", "service_name": "서비스"}), 12, 9)
    L.add(table("의존 서비스 호출 실패율 (client → server)",
                f'service_edge:error_ratio:rate5m{{{C}}} and on (cluster, environment, client, server) (service_edge:requests:rate5m{{{C},client="$service"}} or service_edge:requests:rate5m{{{C},server="$service"}})',
                unit="percentunit", rename={"Value": "실패율", "client": "호출자", "server": "피호출자"},
                steps=thresholds((GREEN, None), (YELLOW, 0.01), (RED, 0.05))), 12, 9)
    L.add({"type": "nodeGraph", "title": "서비스 맵 (X-Ray)", "datasource": XRAY,
           "targets": [{"refId": "A", "datasource": XRAY, "queryType": "getServiceMap", "region": "default", "query": ""}],
           "options": {}}, 24, 10)

    L.row("로그 ↔ 트레이스 (Flow)")
    L.add(cw_logs("$service 에러 로그 (trace_id 로 X-Ray 이동)", ["/aws/eks/$cluster/application"],
                  'fields @timestamp, severity_text, body, trace_id, attributes.logger_name\n'
                  '| filter attributes.service = "$service" and severity_text in ["ERROR", "FATAL"]\n'
                  '| sort @timestamp desc | limit 100'), 16, 10)
    L.add(text("Actionable Links", f"""
**즉시 이동**
- [X-Ray 트레이스: $service 에러]({CONSOLE}/cloudwatch/home?region=${{region}}#xray:traces/query?~(query~(expression~'service(%22$service%22)*20AND*20error*20%3D*20true')))
- [X-Ray 서비스 맵]({CONSOLE}/cloudwatch/home?region=${{region}}#xray:service-map/map)
- [Logs Insights (저장 쿼리: nebula-*)]({CONSOLE}/cloudwatch/home?region=${{region}}#logsV2:logs-insights)
- [CloudWatch 알람 (SLA)]({CONSOLE}/cloudwatch/home?region=${{region}}#alarmsV2:)

**런북**
- [가용성 번레이트]({RUNBOOK}#sloavailabilityburn) · [지연 번레이트]({RUNBOOK}#slolatencyburn)
- [의존성 에러]({RUNBOOK}#servicedependencyerrorshigh) · [배포 직후 이상]({RUNBOOK}#errorratioanomaly)
"""), 8, 10)

    variables = BASE_VARS + [ds_var("cloudwatch", "Logs (CloudWatch)", "cloudwatch"), ds_var("xray", "Traces (X-Ray)", "grafana-x-ray-datasource"),
                             query_var("service", "Service", f'label_values(service:requests:rate5m{{{C}}}, service_name)'), REGION_VAR]
    return dashboard("nebula-service-slo", "Nebula / Service SLO & Golden Signals", L, variables,
                     "서비스별 SLO(가용성 99.9%, P95<1s), 에러 버짓, 번레이트, 라우트/의존성, 로그·트레이스 연결",
                     links=COMMON_LINKS, tags=["slo", "service"])


# --------------------------------------------------------------------------
# 3. Business: 주문 사가 (service-order ↔ Kafka ↔ service-product) + 비동기 처리
# --------------------------------------------------------------------------
SAGA_STAGES = [("order_placed", "1 주문 접수 (order)"), ("purchase_published", "2 purchase 발행 (order)"),
               ("purchase_consumed", "3 재고 처리 (product)"), ("stock_rejected", "└ 재고 부족 거절 (product)"),
               ("order_canceled", "└ 보상: 주문 취소 (order)"), ("purchase_publish_failed", "✕ 발행 실패 (order)")]


def business():
    L = Layout()
    L.row("주문 사가 — HTTP 지표로는 안 보이는 흐름 단절")
    L.add(bargauge("단계별 이벤트 (최근 1시간)", [
        prom(f'sum(saga:events:increase1h{{{C},funnel_stage="{s}"}}) or vector(0)', label, instant=True, ref=chr(65 + i))
        for i, (s, label) in enumerate(SAGA_STAGES)], unit="short",
        desc="거절·취소는 3단계의 부분집합. 거절 수와 취소 수가 다르면 보상 누락"), 10, 9)
    L.add(stat("사가 완료율 (1h)", prom(f'saga:completion:ratio1h{{{C}}}'), unit="percentunit", decimals=1,
               steps=thresholds((RED, None), (YELLOW, 0.9), (GREEN, 0.97)),
               desc="재고 차감까지 끝난 주문 / 접수된 주문. 재고 부족 거절도 완료율을 낮춘다"), 7, 9)
    L.add(stat("발행 실패율 (5m)", prom(f'saga:publish_failure:ratio_rate5m{{{C}}}'), unit="percentunit", decimals=2,
               steps=thresholds((GREEN, None), (YELLOW, 0.001), (RED, 0.01)),
               links=[link("Runbook: 발행 실패", f"{RUNBOOK}#sagapublishfailures")]), 7, 9)
    L.add(timeseries("단계별 처리량 (건/s)", [
        prom(f'sum by (funnel_stage) (saga:events:rate5m{{{C}}})', "{{funnel_stage}}")], unit="suffix: 건/s",
        desc="order_placed ≈ purchase_published ≈ purchase_consumed 가 정상. 아래로 벌어지는 선이 끊긴 구간"), 12, 8)
    L.add(timeseries("단계 사이에 멈춘 건수 (15분 창)", [
        prom(f'saga:consume_gap:increase15m{{{C}}}', "발행 - 재고 처리", ref="A"),
        prom(f'saga:compensation_gap:increase15m{{{C}}}', "재고 거절 - 주문 취소 (보상 누락)", ref="B")], unit="short",
        desc="창 경계의 처리 중 이벤트 때문에 작은 값은 정상. 보상 누락이 쌓이면 SagaCompensationGap",
        links=[link("Runbook: 보상 누락", f"{RUNBOOK}#sagacompensationgap"), link("Runbook: 사가 정지", f"{RUNBOOK}#sagastalled")]), 12, 8)
    L.add(timeseries("재고 부족 거절률", [
        prom(f'saga:stock_rejection:ratio_rate15m{{{C}}}', "15m", ref="A"),
        prom(f'2 * avg_over_time(saga:stock_rejection:ratio_rate15m{{{C}}}[1d])', "알림 기준 (1일 평균 × 2)", ref="B")],
        unit="percentunit", desc="시스템 장애가 아니라 품절/프로모션 신호. SLO 와 분리해서 본다",
        links=[link("Runbook: 재고 거절 급증", f"{RUNBOOK}#stockrejectionspike")]), 12, 8)
    L.add(table("취소·실패 사유 (5m, 건/s)", f'sort_desc(sum by (funnel_stage, reason) (saga:events:rate5m{{{C},reason!="none"}}) > 0)',
                unit="suffix: 건/s", rename={"Value": "건/s", "funnel_stage": "단계", "reason": "사유"}), 12, 8)

    L.row("Kafka — 토픽 구간 (purchase: order → product, refund: product → order)")
    L.add(timeseries("Consumer Lag", [prom(f'messaging:kafka_consumer_lag:sum{{{C}}}', "{{group}} / {{topic}}")],
                     unit="short", links=[link("Runbook: 비동기 적체", f"{RUNBOOK}#asyncbackloggrowing")]), 12, 8)
    L.add(timeseries("Consumer 처리 P95 (트레이스)", [
        prom(f'saga_topic:consumer_latency_seconds:p95_5m{{{C}}}', "{{service_name}} ← {{messaging_destination_name}}")], unit="s"), 12, 8)
    L.add(timeseries("Producer ack P95 (트레이스)", [
        prom(f'saga_topic:producer_latency_seconds:p95_5m{{{C}}}', "{{service_name}} → {{messaging_destination_name}}")], unit="s"), 12, 8)
    L.add(timeseries("Consumer 에러 스팬 (건/s)", [
        prom(f'saga_topic:consumer_errors:rate5m{{{C}}}', "{{service_name}} ← {{messaging_destination_name}}")], unit="suffix: 건/s",
        desc="리스너 예외 (역직렬화 실패, 상품 없음 등). 재시도되면 lag 과 함께 증가"), 12, 8)
    return dashboard("nebula-business", "Nebula / Order Saga & Messaging", L, BASE_VARS,
                     "주문 사가 단계별 흐름·완료율, 발행 실패, 보상(취소) 누락, 재고 거절, Kafka 구간 지연·적체",
                     links=COMMON_LINKS, tags=["business", "saga"])


# --------------------------------------------------------------------------
# 확장: tenant_id 단위 가시화 + Noisy Neighbor + 비용 효율 — extensions/tenant.rules.yaml
# --------------------------------------------------------------------------
def ext_tenant():
    L = Layout()
    T = f'{C},tenant_id=~"$tenant"'
    L.row("테넌트 Golden Signals")
    L.add(timeseries("Traffic by tenant_id (req/s)", [prom(f'topk(10, tenant:requests:rate5m{{{T}}})', "{{tenant_id}} ({{tenant_tier}})")], unit="reqps"), 12, 8)
    L.add(timeseries("에러율 by tenant_id", [prom(f'tenant:error_ratio:rate5m{{{T}}} > 0', "{{tenant_id}}")], unit="percentunit", goal=0.001), 12, 8)
    L.add(timeseries("P99 by tenant_id", [prom(f'topk(10, tenant:latency_seconds:p99_5m{{{T}}})', "{{tenant_id}}")], unit="s", goal=1), 12, 8)
    L.add(table("티어별 SLA 번레이트 (1h, 1 = 버짓 속도)", f'sort_desc(tenant:error_budget_burn:rate1h{{{T}}})', unit="x",
                rename={"Value": "번레이트", "tenant_id": "테넌트", "tenant_tier": "티어"},
                steps=thresholds((GREEN, None), (YELLOW, 1), (RED, 6)),
                links=[link("Runbook: Enterprise SLA", f"{RUNBOOK}#tenantenterprisesloburn")]), 12, 8)

    L.row("Noisy Neighbor — 트래픽 문제인가, 데이터셋/쿼리 문제인가")
    L.add(timeseries("DB 처리시간 점유율 by tenant", [prom(f'tenant:db_time_share:ratio5m{{{T}}}', "{{tenant_id}} ({{db_system}})")],
                     unit="percentunit", goal=0.5, stack=True, maxv=1,
                     desc="점선 50% 초과 + 테넌트 3개 이상 → TenantNoisyNeighbor",
                     links=[link("Runbook: Noisy Neighbor", f"{RUNBOOK}#tenantnoisyneighbor")]), 12, 8)
    L.add(timeseries("DB 호출 수 by tenant (트래픽 신호)", [prom(f'topk(10, tenant:db_calls:rate5m{{{T}}})', "{{tenant_id}}")], unit="reqps"), 12, 8)
    L.add(timeseries("DB 쿼리 P99 by tenant (데이터셋/쿼리 신호)", [prom(f'topk(10, tenant:db_latency_seconds:p99_5m{{{T}}})', "{{tenant_id}}")], unit="s"), 12, 8)
    L.add(timeseries("Aurora Row Lock Wait (ms)", [cw_metric("AWS/RDS", "RowLockTime", {"DBClusterIdentifier": "$aurora", "Role": "WRITER"}, "Average")],
                     unit="ms", legend=False, desc="Aurora MySQL 락 대기. 테넌트 DB P99 와 함께 상승하면 락 경합"), 12, 8)

    L.row("Multi-tenancy & Cost Efficiency")
    L.add(table("테넌트별 배분 인프라 비용 (₩/h, 처리시간 비례)", f'sort_desc(tenant:infra_cost_krw:rate1h{{{T}}})', unit="currencyKRW",
                rename={"Value": "₩/h", "tenant_id": "테넌트"}), 8, 9)
    L.add(table("테넌트별 매출 (₩/h)", f'sort_desc(tenant:revenue_krw:increase1h{{{T}}})', unit="currencyKRW",
                rename={"Value": "₩/h", "tenant_id": "테넌트"}), 8, 9)
    L.add(table("비용 효율 (매출 ÷ 인프라 비용)", f'sort(tenant:cost_efficiency:ratio1h{{{T}}})', unit="x",
                rename={"Value": "효율", "tenant_id": "테넌트"},
                steps=thresholds((RED, None), (YELLOW, 5), (GREEN, 20)),
                desc="낮을수록 SLA/티어 가격 대비 리소스를 많이 쓰는 고객 → 요금제 재검토 후보"), 8, 9)

    variables = BASE_VARS + [ds_var("cloudwatch", "CloudWatch", "cloudwatch"),
                             query_var("tenant", "Tenant", f'label_values(tenant:requests:rate5m{{{C}}}, tenant_id)', multi=True, include_all=True, all_value=".*"),
                             {"name": "aurora", "label": "Aurora cluster", "type": "query", "datasource": CW, "hide": 0, "refresh": 1,
                              "query": {"queryType": "DimensionValues", "region": "default", "namespace": "AWS/RDS",
                                        "metricName": "CPUUtilization", "dimensionKey": "DBClusterIdentifier", "refId": "var-aurora"},
                              "current": {}, "options": [], "multi": False, "includeAll": False}]
    return dashboard("nebula-ext-tenant", "Nebula / Ext / Tenants", L, variables,
                     "[확장] tenant_id 단위 트래픽·에러·지연, 티어별 SLA, Noisy Neighbor 판별, 테넌트 비용 배분/효율",
                     links=COMMON_LINKS, tags=["extension", "tenant"])


# --------------------------------------------------------------------------
# 5. Cost: 인프라 비용 신호 (requests × 단가) + 유휴 리소스
# --------------------------------------------------------------------------
def cost():
    L = Layout()
    L.row("인프라 비용 (requests × 단가, ₩/h)")
    L.add(stat("클러스터 비용 (₩/h)", prom(f'cluster:infra_cost_krw:rate1h{{{C}}}'), unit="currencyKRW",
               desc="단가는 prometheus/rules/05-cost 의 상수 (온디맨드 근사치 — 실제 계약 단가로 교체)"), 6, 8)
    L.add(stat("유휴 비용 (₩/h)", prom(f'sum(namespace:idle_cost_krw:rate1h{{{C}}})'), unit="currencyKRW",
               steps=thresholds((GREEN, None), (YELLOW, 1000), (RED, 5000))), 6, 8)
    L.add(stat("유휴 비율", prom(f'sum(namespace:idle_cost_krw:rate1h{{{C}}}) / cluster:infra_cost_krw:rate1h{{{C}}}'), unit="percentunit",
               steps=thresholds((GREEN, None), (YELLOW, 0.4), (RED, 0.6)), decimals=0,
               desc="requests 로 예약했지만 쓰지 않는 CPU 비중 (비용 기준)"), 6, 8)
    L.add(stat("월 환산 (₩, 현재 속도)", prom(f'cluster:infra_cost_krw:rate1h{{{C}}} * 730'), unit="currencyKRW", graph=False), 6, 8)
    L.add(timeseries("인프라 비용 by 네임스페이스 (₩/h)", [prom(f'topk(10, namespace:infra_cost_krw:rate1h{{{C}}})', "{{namespace}}")],
                     unit="currencyKRW", stack=True, desc="requests × 단가 (prometheus/rules/05-cost 의 단가 상수)"), 12, 8)

    L.row("Predictive & Efficiency — 유휴 리소스")
    L.add(table("유휴 리소스 점수 (1 = 전부 유휴)", f'sort_desc(namespace:idle_resource_score:ratio1d{{{C}}})', unit="percentunit",
                rename={"Value": "Idle score", "namespace": "네임스페이스"},
                steps=thresholds((GREEN, None), (YELLOW, 0.5), (RED, 0.8))), 12, 9)
    L.add(table("유휴로 낭비되는 비용 (₩/h)", f'sort_desc(namespace:idle_cost_krw:rate1h{{{C}}})', unit="currencyKRW",
                rename={"Value": "₩/h", "namespace": "네임스페이스"}), 12, 9)
    return dashboard("nebula-cost", "Nebula / Infra Cost & Efficiency", L, BASE_VARS,
                     "네임스페이스별 인프라 비용(requests × 단가), 유휴 리소스와 낭비 비용 — 다운사이징 근거",
                     links=COMMON_LINKS, tags=["finops", "cost"], time_from="now-24h")


# --------------------------------------------------------------------------
# 6. Data stores (CloudWatch): Aurora / Redis
# --------------------------------------------------------------------------
def datastores():
    L = Layout()
    A = {"DBClusterIdentifier": "$aurora", "Role": "WRITER"}
    L.row("Aurora MySQL — $aurora")
    L.add(timeseries("CPU (Writer)", [cw_metric("AWS/RDS", "CPUUtilization", A)], unit="percent", goal=80, legend=False), 8, 8)
    L.add(timeseries("DB 커넥션", [cw_metric("AWS/RDS", "DatabaseConnections", A)], unit="short", legend=False), 8, 8)
    L.add(timeseries("Deadlocks / s", [cw_metric("AWS/RDS", "Deadlocks", A)], unit="short", legend=False), 8, 8)
    L.add(timeseries("Row Lock Wait (ms)", [cw_metric("AWS/RDS", "RowLockTime", A)], unit="ms", legend=False), 8, 8)
    L.add(timeseries("Blocked Transactions", [cw_metric("AWS/RDS", "BlockedTransactions", A)], unit="short", legend=False), 8, 8)
    L.add(timeseries("Replica Lag (Reader, max)", [cw_metric("AWS/RDS", "AuroraReplicaLag", {"DBClusterIdentifier": "$aurora", "Role": "READER"}, "Maximum")],
                     unit="ms", goal=1000, legend=False), 8, 8)
    R = {"CacheClusterId": "$redis"}
    L.row("ElastiCache Redis — $redis")
    L.add(timeseries("Engine CPU", [cw_metric("AWS/ElastiCache", "EngineCPUUtilization", R)], unit="percent", goal=80, legend=False), 6, 8)
    L.add(timeseries("메모리 사용률", [cw_metric("AWS/ElastiCache", "DatabaseMemoryUsagePercentage", R)], unit="percent", goal=85, legend=False), 6, 8)
    L.add(timeseries("Evictions", [cw_metric("AWS/ElastiCache", "Evictions", R, "Sum")], unit="short", legend=False), 6, 8)
    L.add(timeseries("Cache Hit Rate", [cw_metric("AWS/ElastiCache", "CacheHitRate", R)], unit="percent", legend=False), 6, 8)
    variables = [ds_var("cloudwatch", "CloudWatch", "cloudwatch"),
                 {"name": "aurora", "label": "Aurora cluster", "type": "query", "datasource": CW, "hide": 0, "refresh": 1,
                  "query": {"queryType": "DimensionValues", "region": "default", "namespace": "AWS/RDS", "metricName": "CPUUtilization",
                            "dimensionKey": "DBClusterIdentifier", "refId": "var-aurora"}, "current": {}, "options": [], "multi": False, "includeAll": False},
                 {"name": "redis", "label": "Redis node", "type": "query", "datasource": CW, "hide": 0, "refresh": 1,
                  "query": {"queryType": "DimensionValues", "region": "default", "namespace": "AWS/ElastiCache", "metricName": "EngineCPUUtilization",
                            "dimensionKey": "CacheClusterId", "refId": "var-redis"}, "current": {}, "options": [], "multi": False, "includeAll": False}]
    return dashboard("nebula-datastores", "Nebula / Data Stores (Aurora, Redis)", L, variables,
                     "Aurora 락/데드락/복제 지연, Redis CPU/메모리/축출 — CloudWatch 기본 메트릭",
                     links=COMMON_LINKS, tags=["datastore"])


# --------------------------------------------------------------------------
# 7. Telemetry pipeline (monitoring the monitoring)
# --------------------------------------------------------------------------
def pipeline():
    L = Layout()
    O = f'{C},job="otelcol"'
    L.row("수집 파이프라인 상태")
    L.add(stat("gateway 파드", prom(f'count(up{{{O},component="gateway"}} == 1) or vector(0)'), steps=thresholds((RED, None), (GREEN, 1)), graph=False), 6, 4)
    L.add(stat("agent / 노드", prom(f'count(up{{{O},component="agent"}} == 1) / count(kube_node_info{{{C}}})'), unit="percentunit",
               steps=thresholds((RED, None), (YELLOW, 0.9), (GREEN, 1)), graph=False,
               links=[link("Runbook: agent 누락", f"{RUNBOOK}#telemetryagentmissing")]), 6, 4)
    L.add(stat("export 실패 (/s)", prom(SIGNAL_SUM.format(m="otelcol_exporter_send_failed", c=C)),
               steps=thresholds((GREEN, None), (RED, 0.001)), decimals=2,
               links=[link("Runbook: export 실패", f"{RUNBOOK}#collectorexportfailing")]), 6, 4)
    L.add(stat("거부(백프레셔) (/s)", prom(SIGNAL_SUM.format(m="otelcol_receiver_refused", c=C)),
               steps=thresholds((GREEN, None), (RED, 0.001)), decimals=2), 6, 4)
    L.add(timeseries("수신량 by 신호", [
        prom(f'sum(rate(otelcol_receiver_accepted_spans_total{{{O},component="gateway"}}[5m]))', "spans/s", ref="A"),
        prom(f'sum(rate(otelcol_receiver_accepted_log_records_total{{{O},component="gateway"}}[5m]))', "log records/s", ref="B"),
        prom(f'sum(rate(otelcol_receiver_accepted_metric_points_total{{{O},component="gateway"}}[5m]))', "metric points/s", ref="C")],
        unit="short"), 12, 8)
    L.add(timeseries("정제로 제거된 양 (filter)", [
        prom(f'sum by (component) (rate(otelcol_processor_filter_spans_filtered_total{{{C}}}[5m]))', "spans {{component}}", ref="A"),
        prom(f'sum by (component) (rate(otelcol_processor_filter_logs_filtered_total{{{C}}}[5m]))', "logs {{component}}", ref="B"),
        prom(f'sum by (component) (rate(otelcol_processor_filter_datapoints_filtered_total{{{C}}}[5m]))', "datapoints {{component}}", ref="C")],
        unit="short", desc="헬스체크/디버그 로그/런타임 메트릭 등 노이즈 제거량 — 비용 절감 효과"), 12, 8)
    L.add(timeseries("tail sampling 결정", [prom(f'sum by (decision) (rate(otelcol_processor_tail_sampling_global_count_traces_sampled_total{{{C}}}[5m]))', "{{decision}}")],
                     unit="short", stack=True), 12, 8)
    L.add(timeseries("exporter 큐 사용률", [prom(f'max by (component, exporter) (otelcol_exporter_queue_size{{{C}}} / otelcol_exporter_queue_capacity{{{C}}})', "{{component}}/{{exporter}}")],
                     unit="percentunit", goal=0.8, maxv=1), 12, 8)
    L.add(timeseries("컬렉터 메모리 (RSS)", [prom(f'otelcol_process_memory_rss{{{O}}}', "{{component}} {{instance}}")], unit="bytes"), 12, 8)
    L.add(table("scrape 타겟별 샘플 수 (카디널리티)", f'topk(15, scrape_samples_post_metric_relabeling{{{C}}})',
                rename={"Value": "samples/scrape"}, steps=thresholds((GREEN, None), (YELLOW, 10000), (RED, 20000)),
                links=[link("Runbook: 카디널리티", f"{RUNBOOK}#highcardinalitytarget")]), 12, 8)
    L.add(timeseries("로그량 by 서비스·레벨 (정제 후)", [prom(f'topk(10, sum by (service, level) (service:log_records:rate5m{{{C}}}))', "{{service}} {{level}}")],
                     unit="short", desc="CloudWatch Logs 비용의 선행 지표"), 24, 8)
    return dashboard("nebula-pipeline", "Nebula / Telemetry Pipeline", L, BASE_VARS,
                     "모니터링의 모니터링: 수집량, 정제량, 샘플링, 전송 실패, 큐, 카디널리티",
                     links=COMMON_LINKS, tags=["pipeline"])


# ==========================================================================
# 확장 대시보드 (grafana/dashboards/extensions/, provision-grafana.sh --extensions)
# ==========================================================================
# --------------------------------------------------------------------------
# 확장: 구매 퍼널 + 결제(PG) — extensions/commerce-payment.rules.yaml
# --------------------------------------------------------------------------
def ext_commerce_payment():
    L = Layout()
    L.row("Business Funnel — 장바구니 → 결제 완료")
    L.add(bargauge("퍼널 단계별 이벤트 (최근 1시간)", [
        prom(f'sum(funnel:events:increase1h{{{C},funnel_stage="{s}"}})', label, instant=True, ref=chr(65 + i))
        for i, (s, label) in enumerate([("cart_add", "1 장바구니 담기"), ("checkout_start", "2 결제 시작"),
                                        ("order_created", "3 주문 생성"), ("payment_requested", "4 결제 요청(PG)"),
                                        ("payment_succeeded", "5 결제 완료(DB Commit)")])], unit="short"), 10, 8)
    L.add(bargauge("단계별 Drop (%)", [prom(f'1 - funnel:stage_conversion:ratio1h{{{C}}}', "{{step}}", instant=True)],
                   unit="percentunit", maxv=1, steps=thresholds((GREEN, None), (YELLOW, 0.3), (RED, 0.5))), 7, 8)
    L.add(stat("전체 전환율 (1h)", prom(f'funnel:conversion:ratio1h{{{C}}}'), unit="percentunit", decimals=1,
               steps=thresholds((RED, None), (YELLOW, 0.02), (GREEN, 0.05)),
               links=[link("Runbook: 전환율 하락", f"{RUNBOOK}#checkoutconversiondrop")]), 7, 8)
    L.add(timeseries("전환율 추세 (Conversion Rate Trend)", [prom(f'funnel:conversion:ratio1h{{{C}}}', "전체 전환율")],
                     unit="percentunit", legend=False), 12, 8)
    L.add(timeseries("장바구니 점유 비율 (봇 재고 잠식 지표)", [
        prom(f'funnel:cart_hoarding:ratio15m{{{C}}}', "장바구니/결제시작", ref="A"),
        prom(f'2 * avg_over_time(funnel:cart_hoarding:ratio15m{{{C}}}[1d])', "알림 기준 (1일 평균 × 2)", ref="B")],
        unit="x", desc="결제 없이 장바구니만 점유하는 봇이 늘면 비율이 평소의 2배를 넘는다",
        links=[link("Runbook: 장바구니 점유", f"{RUNBOOK}#carthoardingsuspected")]), 12, 8)

    L.row("결제 — 실패 원인 분리 (카드 한도 초과 vs PG 타임아웃)")
    fail = timeseries("실패 원인별 결제 실패 (건/s)", [prom(f'sum by (payment_failure_category) (payment:failures_by_category:rate5m{{{C}}})', "{{payment_failure_category}}")],
                      unit="suffix: 건/s", stack=True,
                      desc="gateway 가 PG 응답코드를 카테고리로 정규화. 주황/빨강 = 시스템 원인(우리가 대응), 청록/파랑 = 고객·카드사 원인")
    # 색은 '원인의 책임 주체'를 뜻한다: 시스템 원인은 따뜻한 색, 고객/카드사 원인은 차가운 색
    for cat, color in [("pg_timeout", "red"), ("pg_unavailable", "orange"), ("other", "#C4A000"),
                       ("card_limit_exceeded", "#1F78C1"), ("insufficient_funds", "#5794F2"), ("card_declined", "#2C7BB6"),
                       ("invalid_card", "#8AB8FF"), ("fraud_suspected", "#7D5BBE"), ("user_cancelled", "#4E9A9A")]:
        fail["fieldConfig"]["overrides"].append({"matcher": {"id": "byName", "options": cat},
                                                 "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]})
    L.add(fail, 12, 8)
    L.add(timeseries("PG별 시스템 원인 실패율", [prom(f'payment_pg:system_failure_ratio:rate5m{{{C}}}', "{{payment_pg}}")],
                     unit="percentunit", goal=0.02, desc="pg_timeout / pg_unavailable / other. 점선 = 알림 기준 2%",
                     links=[link("Runbook: PG 실패", f"{RUNBOOK}#paymentsystemfailurehigh")]), 12, 8)
    L.add(timeseries("PG 응답 P99", [prom(f'payment:pg_latency_seconds:p99_5m{{{C}}}', "{{payment_pg}}")], unit="s", goal=3), 8, 8)
    L.add(timeseries("Logical Error (HTTP 200 + 결제 실패)", [prom(f'payment:logical_error_ratio:rate5m{{{C}}}', "{{payment_pg}}")],
                     unit="percentunit", goal=0.005, links=[link("Runbook: 논리 오류", f"{RUNBOOK}#paymentlogicalerrors")]), 8, 8)
    L.add(table("결제수단·카드사별 승인 거절률 (15m)", f'sort_desc(payment_method:decline_ratio:rate15m{{{C}}} > 0)', unit="percentunit",
                rename={"Value": "거절률", "payment_method": "결제수단", "card_issuer": "카드사"},
                steps=thresholds((GREEN, None), (YELLOW, 0.05), (RED, 0.1))), 8, 8)

    return dashboard("nebula-ext-payment", "Nebula / Ext / Funnel & Payments", L, BASE_VARS,
                     "[확장] 구매 퍼널(Drop%), 결제 실패 원인 분리, 논리 오류 — 결제 서비스 도입 시 사용",
                     links=COMMON_LINKS, tags=["extension", "payment"])


# --------------------------------------------------------------------------
# 확장: Revenue vs Total OpEx, Net Margin 게이지, Burn Rate, 역마진 예측 — extensions/margin.rules.yaml
# --------------------------------------------------------------------------
def ext_margin():
    L = Layout()
    L.row("역마진(Margin Erosion) 실시간 탐지")
    L.add(gauge("Net Margin (1h)", prom(f'nebula:net_margin:ratio1h{{{C}}}'), "percentunit",
                thresholds((RED, None), (YELLOW, 0), (GREEN, 0.05)), -0.2, 0.3, decimals=1,
                desc="Threshold Gauge — 5% 미만 Warning(노랑) / 0% 미만 Deficit(빨강)"), 6, 8)
    L.add(stat("Burn Rate (적자 ₩/h)", prom(f'nebula:margin_burn_krw:rate1h{{{C}}}'), unit="currencyKRW",
               steps=thresholds((GREEN, None), (RED, 1)),
               links=[link("Runbook: 역마진", f"{RUNBOOK}#netmargindeficit")]), 6, 8)
    L.add(stat("BEP 대비 매출", prom(f'nebula:bep_coverage:ratio1h{{{C}}}'), unit="percentunit",
               steps=thresholds((RED, None), (YELLOW, 1), (GREEN, 1.05)), decimals=0,
               desc="100% 미만이면 손익분기점(BEP) 미달"), 6, 8)
    L.add(stat("6시간 뒤 예상 순마진", prom(f'predict_linear(nebula:net_margin:ratio1h{{{C}}}[6h], 6*3600)'), unit="percentunit",
               steps=thresholds((RED, None), (YELLOW, 0), (GREEN, 0.05)), decimals=1,
               desc="D+? Deficit Entry: 최근 6시간 추세의 선형 외삽 (MarginDeficitPredicted 알림과 동일 식)"), 6, 8)
    L.add(timeseries("Revenue vs Total OpEx (₩/h)", [
        prom(f'nebula:revenue_krw:increase1h{{{C}}}', "Revenue", ref="A"),
        prom(f'nebula:opex_krw:increase1h{{{C}}}', "Total OpEx", ref="B")], unit="currencyKRW",
        desc="두 선이 교차하면 BEP. Total OpEx = 원가·PG수수료·배송비·쿠폰 + 인프라"), 12, 9)
    L.add(timeseries("Net Margin 추세", [prom(f'nebula:net_margin:ratio1h{{{C}}}', "net margin")], unit="percentunit",
                     goal=0.05, legend=False, desc="점선 = 5% 경고선"), 12, 9)
    L.add(timeseries("비용 구성 (COGS Dynamics)", [prom(f'nebula:order_cost_krw:increase1h{{{C}}}', "{{cost_type}}")],
                     unit="currencyKRW", stack=True), 12, 8)
    return dashboard("nebula-ext-margin", "Nebula / Ext / Margin", L, BASE_VARS,
                     "[확장] Revenue vs Total OpEx, Net Margin 게이지(5%/0%), Burn Rate, 역마진 예측 — 매출·원가 계약 구현 시 사용",
                     links=COMMON_LINKS, tags=["extension", "finops"], time_from="now-24h")


def write(out, d):
    path = os.path.join(out, f"{d['uid']}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"wrote {os.path.relpath(path)} ({len(d['panels'])} panels)")


CORE = (overview, service_slo, business, cost, datastores, pipeline)
EXTENSIONS = (ext_commerce_payment, ext_tenant, ext_margin)


def main():
    for out, fns in ((OUT, CORE), (os.path.join(OUT, "extensions"), EXTENSIONS)):
        os.makedirs(out, exist_ok=True)
        for fn in fns:
            write(out, fn())


if __name__ == "__main__":
    main()
