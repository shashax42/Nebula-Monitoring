#!/usr/bin/env python3
"""Nebula telemetry simulator — 클러스터 없이 파이프라인/규칙/대시보드/카나리 판정을 검증·시연한다.

nebula-services 가 실제로 내보내는 모양 그대로 OTLP/HTTP(JSON) 로 보낸다. 표준 라이브러리만 사용.
  - 트레이스: Micrometer Tracing(OTel bridge) 스팬 — 속성이 Observation 키(uri, method, status) 그대로이고,
    예외 없이 5xx 를 응답하면 스팬 상태가 UNSET 이다 (gateway 의 transform/micrometer-semconv 가 표준화)
    core-gateway → service-order → Kafka purchase → service-product (→ Kafka refund → service-order)
  - 메트릭: nebula.commerce.funnel.events{funnel.stage, reason} (service-order / service-product 의 FunnelMetrics)
            kafka.consumer_group.lag (클러스터 collector 의 kafka_metrics 수신기가 만드는 지표를 흉내)
  - 로그: --log-dir 를 주면 Spring logstash JSON 을 CRI 포맷 컨테이너 로그로 기록 (agent 의 file_log 가 수집)
  - 리소스: service-order 파드는 deployment.track=stable|canary (클러스터에서는 k8sattributes 가 파드 라벨에서 붙임)

    python3 tools/telemetry-simulator/simulate.py --endpoint http://localhost:4318 --duration 600
    # 클러스터 안에서:  kubectl port-forward -n monitoring ds/otel-collector-agent 4318:4318

시나리오(--scenario):
    normal             평상시 (재고 부족 거절 ~2%, 알림 없음)
    canary-bad         service-order canary 파드가 6% 를 500 으로 응답 → nebula-slo-canary 분석 실패(롤백)
    kafka-down         purchase 발행 실패 20% → SagaPublishFailures
    consumer-stall     service-product 가 purchase 를 처리하지 못함 → SagaStalled, AsyncBacklogGrowing
    compensation-gap   재고 거절 후 주문 취소가 누락 → SagaCompensationGap
    stock-out          재고 부족 거절 30% → StockRejectionSpike (1일 기준선이 쌓여야 발화)
확장 시나리오(--extensions 필요, 결제·테넌트·마진): pg-timeout, noisy, deficit, bot  → extensions.py
"""
import argparse
import json
import os
import random
import time
import urllib.request
import zlib

from extensions import ExtensionSim, attr, rid

CORE_SCENARIOS = ["normal", "canary-bad", "kafka-down", "consumer-stall", "compensation-gap", "stock-out"]
EXT_SCENARIOS = ["pg-timeout", "noisy", "deficit", "bot"]
SERVER, CLIENT, PRODUCER, CONSUMER = 2, 3, 4, 5
CANARY_WEIGHT = 0.5  # rollout.yaml: setWeight 50


class Sim:
    def __init__(self, endpoint, scenario, log_dir=None):
        self.ep = endpoint.rstrip("/")
        self.scenario = scenario
        self.start = time.time_ns()
        self.counters = {}  # (service, name, attrs) → cumulative value (OTLP cumulative temporality)
        self.lag = 0
        self.log_dir = log_dir
        self.spans = {}

    def post(self, path, body):
        req = urllib.request.Request(self.ep + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status

    @staticmethod
    def res(svc, track=None):
        a = [attr("service.name", svc), attr("service.version", "0.0.1-SNAPSHOT"), attr("k8s.namespace.name", "backend"),
             attr("k8s.pod.name", f"{svc}-{track or 'stable'}-0"), attr("deployment.environment", "dev"),
             attr("telemetry.sdk.name", "io.micrometer")]
        if track:
            a.append(attr("deployment.track", track))
        return {"attributes": a}

    def count(self, svc, stage, reason="none", n=1):
        k = (svc, "nebula.commerce.funnel.events", (("funnel.stage", stage), ("reason", reason)))
        self.counters[k] = self.counters.get(k, 0) + n

    # ------------------------------------------------------------------
    def span(self, key, trace, name, kind, start, dur_ms, attrs, parent=None, error=False):
        sid = rid(64)
        s = {"traceId": trace, "spanId": sid, "name": name, "kind": kind, "startTimeUnixNano": str(start),
             "endTimeUnixNano": str(start + int(dur_ms * 1e6)), "attributes": [attr(k, v) for k, v in attrs.items()],
             "status": {"code": 2} if error else {}}
        if parent:
            s["parentSpanId"] = parent
        self.spans.setdefault(key, []).append(s)
        return sid

    @staticmethod
    def http(method, uri, status):
        # Micrometer Observation 키 (DefaultServerRequestObservationConvention)
        return {"method": method, "uri": uri, "status": str(status),
                "outcome": "SUCCESS" if status < 400 else ("CLIENT_ERROR" if status < 500 else "SERVER_ERROR"),
                "exception": "none", "http.url": uri.replace("{id}", str(random.randint(1, 5000)))}

    def order_saga(self, now):
        t = rid(128)
        st = now - random.randint(200_000_000, 3_000_000_000)
        track = "canary" if random.random() < CANARY_WEIGHT else "stable"
        bad = self.scenario == "canary-bad" and track == "canary" and random.random() < 0.06
        status = 500 if bad or random.random() < 0.0003 else 201
        order_ms = random.expovariate(1 / 60) + 15

        gw = self.span(("core-gateway", None), t, "http post /api/orders", SERVER, st, order_ms + 8, self.http("POST", "/api/orders", status))
        cl = self.span(("core-gateway", None), t, "http post", CLIENT, st + 2_000_000, order_ms + 4,
                       {**self.http("POST", "/orders", status), "client.name": "service-order"}, parent=gw)
        so = self.span(("service-order", track), t, "http post /orders", SERVER, st + 3_000_000, order_ms,
                       self.http("POST", "/orders", status), parent=cl)
        self.span(("service-order", track), t, "INSERT market.orders", CLIENT, st + 4_000_000, random.expovariate(1 / 6) + 1,
                  {"db.system": "mysql", "db.statement": "insert into orders (account_id, email, quantity) values (7, 'kim@example.com', 2)"},
                  parent=so)
        if status >= 500:
            return
        self.count("service-order", "order_placed")

        # AFTER_COMMIT → Kafka purchase (producer 스팬: 브로커 ack 까지)
        p_start = st + int(order_ms * 1e6)
        failed = self.scenario == "kafka-down" and random.random() < 0.2
        prod = self.span(("service-order", track), t, "purchase send", PRODUCER, p_start, 120_000 if failed else random.expovariate(1 / 5) + 1,
                         {"messaging.system": "kafka", "messaging.operation": "publish", "messaging.destination.name": "purchase",
                          "spring.kafka.template.name": "kafkaTemplate"}, parent=so, error=failed)
        if failed:
            self.count("service-order", "purchase_publish_failed", "publish_error")
            self.log("service-order", "ERROR", f"주문 이벤트 전송 실패: {random.randint(1000, 9999)}", t,
                     stack="org.apache.kafka.common.errors.TimeoutException: Expiring 1 record(s) for purchase-0")
            return
        self.count("service-order", "purchase_published")
        self.log("service-order", "INFO", f"주문 접수: {random.randint(1000, 9999)}", t)

        if self.scenario == "consumer-stall":
            self.lag += 1
            return
        c_start = p_start + random.randint(5_000_000, 40_000_000)
        cons = self.span(("service-product", None), t, "purchase receive", CONSUMER, c_start, random.expovariate(1 / 12) + 3,
                         {"messaging.system": "kafka", "messaging.operation": "process", "messaging.destination.name": "purchase",
                          "messaging.kafka.consumer.group": "order", "spring.kafka.listener.id": "org.springframework.kafka.KafkaListenerEndpointContainer#0-0"},
                         parent=prod)
        self.span(("service-product", None), t, "UPDATE market.product", CLIENT, c_start + 1_000_000, random.expovariate(1 / 4) + 1,
                  {"db.system": "mysql", "db.statement": "update product set stock=stock-2 where id=31"}, parent=cons)
        self.count("service-product", "purchase_consumed")
        reject_p = 0.30 if self.scenario == "stock-out" else 0.02
        if random.random() >= reject_p:
            return
        # 재고 부족 → refund 발행 → service-order 가 주문 취소 (보상 트랜잭션)
        self.count("service-product", "stock_rejected", "out_of_stock")
        r_start = c_start + 4_000_000
        rp = self.span(("service-product", None), t, "refund send", PRODUCER, r_start, random.expovariate(1 / 5) + 1,
                       {"messaging.system": "kafka", "messaging.operation": "publish", "messaging.destination.name": "refund"}, parent=cons)
        if self.scenario == "compensation-gap" and random.random() < 0.7:
            return
        rc = self.span(("service-order", track), t, "refund receive", CONSUMER, r_start + 15_000_000, random.expovariate(1 / 8) + 2,
                       {"messaging.system": "kafka", "messaging.operation": "process", "messaging.destination.name": "refund",
                        "messaging.kafka.consumer.group": "order"}, parent=rp)
        self.span(("service-order", track), t, "UPDATE market.orders", CLIENT, r_start + 16_000_000, 3,
                  {"db.system": "mysql", "db.statement": "update orders set state='CANCELED' where id=1042"}, parent=rc)
        self.count("service-order", "order_canceled", "out_of_stock")

    def browse(self, now):
        # 조회 트래픽: 상품 상세 / 계정 조회 (Golden Signals 의 대부분)
        t = rid(128)
        st = now - random.randint(100_000_000, 3_000_000_000)
        svc, uri = random.choice([("service-product", "/products/{id}"), ("service-product", "/products"), ("service-account", "/accounts/{id}")])
        status = 500 if random.random() < 0.0003 else (404 if random.random() < 0.01 else 200)
        ms = random.expovariate(1 / 25) + 5
        gw = self.span(("core-gateway", None), t, f"http get /api{uri}", SERVER, st, ms + 6, self.http("GET", f"/api{uri}", status))
        cl = self.span(("core-gateway", None), t, "http get", CLIENT, st + 1_000_000, ms + 2,
                       {**self.http("GET", uri, status), "client.name": svc}, parent=gw)
        s = self.span((svc, None), t, f"http get {uri}", SERVER, st + 2_000_000, ms, self.http("GET", uri, status), parent=cl)
        self.span((svc, None), t, "SELECT market." + ("product" if "product" in uri else "account"), CLIENT, st + 3_000_000,
                  random.expovariate(1 / 4) + 1, {"db.system": "mysql", "db.statement": "select * from product where id=31"}, parent=s)
        # actuator 프로브 (gateway 의 filter/traces-noise 가 버려야 한다)
        if random.random() < 0.2:
            self.span((svc, None), rid(128), "http get /actuator/health/{*path}", SERVER, st, 1, self.http("GET", "/actuator/health/{*path}", 200))

    def traces(self, now, orders, views):
        self.spans = {}
        for _ in range(orders):
            self.order_saga(now)
        for _ in range(views):
            self.browse(now)
        body = {"resourceSpans": [{"resource": self.res(svc, track or ("stable" if svc == "service-order" else None)),
                                   "scopeSpans": [{"scope": {"name": "io.micrometer.tracing"}, "spans": sp}]}
                                  for (svc, track), sp in self.spans.items()]}
        return self.post("/v1/traces", body)

    def metrics(self, now):
        by_svc = {}
        for (svc, name, key), v in self.counters.items():
            m = by_svc.setdefault(svc, {}).setdefault(name, {
                "name": name, "description": "Order saga events by stage", "unit": "",
                "sum": {"aggregationTemporality": 2, "isMonotonic": True, "dataPoints": []}})
            m["sum"]["dataPoints"].append({"asDouble": float(v), "startTimeUnixNano": str(self.start), "timeUnixNano": str(now),
                                           "attributes": [attr(k, x) for k, x in key]})
        rms = [{"resource": self.res(svc), "scopeMetrics": [{"scope": {"name": "io.micrometer"}, "metrics": list(ms.values())}]}
               for svc, ms in by_svc.items()]
        # Strimzi market-message 의 consumer group lag (kafka_metrics 수신기와 같은 이름·속성)
        lag = {"name": "kafka.consumer_group.lag", "unit": "{messages}", "gauge": {"dataPoints": [
            {"asInt": str(self.lag if topic == "purchase" else 0), "timeUnixNano": str(now),
             "attributes": [attr("group", "order"), attr("topic", topic), attr("partition", 0)]} for topic in ("purchase", "refund")]}}
        rms.append({"resource": {"attributes": [attr("service.name", "otel-collector-cluster")]},
                    "scopeMetrics": [{"scope": {"name": "kafkametricsreceiver"}, "metrics": [lag]}]})
        return self.post("/v1/metrics", {"resourceMetrics": rms})

    # ------------------------------------------------------------------
    def log(self, svc, level, msg, trace=None, stack=None):
        if not self.log_dir:
            return
        d = os.path.join(self.log_dir, f"backend_{svc}-6c9f7d8b5-sim01_00000000-0000-4000-8000-{zlib.crc32(svc.encode()):012d}", svc)
        os.makedirs(d, exist_ok=True)
        rec = {"@timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), "@version": "1", "message": msg,
               "logger_name": f"io.nebula.market.{svc.split('-')[-1]}.Sim", "thread_name": "sim", "level": level,
               "level_value": {"DEBUG": 10000, "INFO": 20000, "WARN": 30000, "ERROR": 40000}[level]}
        if trace:
            rec["traceId"], rec["spanId"] = trace, rid(64)
        if stack:
            rec["stack_trace"] = stack
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + f".{time.time_ns() % 10**9:09d}Z"
        with open(os.path.join(d, "0.log"), "a", encoding="utf-8") as f:
            f.write(f"{ts} stdout F {json.dumps(rec, ensure_ascii=False)}\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_logs = os.path.join(here, "..", "local-stack", "pod-logs")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--endpoint", default="http://localhost:4318")
    ap.add_argument("--interval", type=float, default=5)
    ap.add_argument("--duration", type=float, default=300, help="seconds (0 = forever)")
    ap.add_argument("--scenario", default="normal", choices=CORE_SCENARIOS + EXT_SCENARIOS)
    ap.add_argument("--orders", type=int, default=25, help="orders per interval")
    ap.add_argument("--views", type=int, default=60, help="read requests per interval")
    ap.add_argument("--extensions", action="store_true", help="결제·테넌트·마진 확장 텔레메트리도 보낸다 (collector 오버레이 필요)")
    ap.add_argument("--log-dir", default=default_logs if os.path.isdir(default_logs) else None,
                    help="CRI 컨테이너 로그를 쓸 디렉터리 (local-stack 의 pod-logs)")
    a = ap.parse_args()
    if a.scenario in EXT_SCENARIOS:
        a.extensions = True
    sim = Sim(a.endpoint, a.scenario if a.scenario in CORE_SCENARIOS else "normal", a.log_dir)
    ext = ExtensionSim(a.endpoint, a.scenario if a.scenario in EXT_SCENARIOS else "normal") if a.extensions else None
    end = time.time() + a.duration if a.duration else float("inf")
    n = 0
    while time.time() < end:
        now = time.time_ns()
        try:
            sim.traces(now, a.orders, a.views)
            sim.metrics(now)
            if ext:
                ext.traces(now)
                ext.metrics(now)
                ext.logs(now)
            n += 1
            if n % 12 == 1:
                print(f"[{time.strftime('%H:%M:%S')}] sent batch #{n} ({a.scenario}{', +extensions' if ext else ''})", flush=True)
        except Exception as e:  # keep going on transient collector restarts
            print("send failed:", e, flush=True)
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
