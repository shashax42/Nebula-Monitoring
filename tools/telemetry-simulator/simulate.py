#!/usr/bin/env python3
"""Nebula telemetry simulator — 앱 계측 없이 파이프라인/규칙/대시보드를 검증·시연한다.

docs/TELEMETRY_CONTRACT.md 의 계약대로 OTLP/HTTP(JSON) 로 트레이스·메트릭·로그를 보낸다.
표준 라이브러리만 사용.

    python3 tools/telemetry-simulator/simulate.py --endpoint http://localhost:4318 --duration 600
    # 클러스터 안에서:  kubectl port-forward -n monitoring ds/otel-collector-agent 4318:4318

시나리오(--scenario):
    normal       평상시
    pg-timeout   특정 PG(kcp) 타임아웃 급증 → PaymentSystemFailureHigh / CloudWatch payment-pg-timeout
    noisy        한 테넌트(acme)가 DB 시간을 독점 → TenantNoisyNeighbor
    deficit      쿠폰 남발로 원가 > 매출 → NetMarginDeficit
    bot          한 테넌트(hooli)의 장바구니만 3배 → CartHoardingSuspected
"""
import argparse
import json
import random
import time
import urllib.request

SERVICES = {
    "api-gateway": {"routes": ["/api/cart", "/api/checkout", "/api/orders/{id}"], "base_ms": 40},
    "checkout": {"routes": ["/checkout", "/checkout/{id}/confirm"], "base_ms": 80},
    "payment-service": {"routes": ["/api/payments", "/api/payments/{id}"], "base_ms": 150},
    "inventory": {"routes": ["/inventory/{sku}"], "base_ms": 25},
}
TENANTS = [("acme", "enterprise"), ("globex", "enterprise"), ("initech", "pro"), ("umbrella", "pro"), ("hooli", "free")]
PGS = ["toss", "kcp", "inicis"]
METHODS = ["card", "kakaopay", "naverpay"]
ISSUERS = ["hyundai", "shinhan", "kb", "samsung"]
FAIL_CODES = {
    "customer": ["EXCEED_MAX_CARD_LIMIT", "NOT_ENOUGH_BALANCE", "REJECT_CARD_COMPANY", "INVALID_CARD_EXPIRATION", "USER_CANCEL"],
    "system": ["PG_TIMEOUT", "PROVIDER_SYSTEM_ERROR", "503"],
}


def attr(k, v):
    if isinstance(v, bool):
        return {"key": k, "value": {"boolValue": v}}
    if isinstance(v, int):
        return {"key": k, "value": {"intValue": str(v)}}
    if isinstance(v, float):
        return {"key": k, "value": {"doubleValue": v}}
    if isinstance(v, list):
        return {"key": k, "value": {"arrayValue": {"values": [{"stringValue": x} for x in v]}}}
    return {"key": k, "value": {"stringValue": str(v)}}


def rid(bits):
    return "%0*x" % (bits // 4, random.getrandbits(bits))


class Sim:
    def __init__(self, endpoint, scenario):
        self.ep = endpoint.rstrip("/")
        self.scenario = scenario
        self.start = time.time_ns()
        # cumulative counters (OTLP cumulative temporality)
        self.counters = {}
        self.hist = {}

    def post(self, path, body):
        req = urllib.request.Request(self.ep + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status

    def res(self, svc):
        return {"attributes": [attr("service.name", svc), attr("service.version", "1.4.2"),
                               attr("k8s.namespace.name", "shop"), attr("k8s.pod.name", f"{svc}-7d9f-{random.randint(1, 2)}"),
                               attr("deployment.environment", "dev")]}

    def inc(self, name, key, v):
        k = (name, tuple(sorted(key.items())))
        self.counters[k] = self.counters.get(k, 0) + v

    # ------------------------------------------------------------------
    def traces(self, now):
        by_svc = {s: [] for s in SERVICES}
        for _ in range(random.randint(40, 70)):
            tenant, tier = random.choice(TENANTS)
            svc = random.choice(list(SERVICES))
            route = random.choice(SERVICES[svc]["routes"])
            t, root = rid(128), rid(64)
            dur_ms = random.expovariate(1 / SERVICES[svc]["base_ms"])
            err = random.random() < 0.0005  # SLO(99.9%) 이내
            if svc == "payment-service" and self.scenario == "pg-timeout" and random.random() < 0.15:
                dur_ms, err = 5000 + random.random() * 2000, True
            dur = int(dur_ms * 1e6)
            st = now - dur - random.randint(0, 3_000_000_000)
            attrs = [attr("http.route", route), attr("http.request.method", "POST" if "payments" in route else "GET"),
                     attr("http.response.status_code", 500 if err else 200),
                     attr("http.request.header.x-tenant-id", [tenant]), attr("tenant.tier", tier),
                     attr("url.full", f"https://shop.example.com{route}?token=abc123&page=1")]
            if svc == "payment-service":
                pay_fail = err or random.random() < 0.01
                attrs += [attr("payment.pg", random.choice(PGS)), attr("payment.outcome", "failure" if pay_fail else "success")]
            by_svc[svc].append({"traceId": t, "spanId": root, "name": f"{'POST' if 'payments' in route else 'GET'} {route}", "kind": 2,
                                "startTimeUnixNano": str(st), "endTimeUnixNano": str(st + dur), "attributes": attrs,
                                "status": {"code": 2 if err else 1}})
            # DB client span (tenant 전파: baggage → span attribute)
            db_ms = random.expovariate(1 / 8)
            if self.scenario == "noisy" and tenant == "acme":
                db_ms *= 25
            by_svc[svc].append({"traceId": t, "spanId": rid(64), "parentSpanId": root, "name": "SELECT shop.orders", "kind": 3,
                                "startTimeUnixNano": str(st), "endTimeUnixNano": str(st + int(db_ms * 1e6)),
                                "attributes": [attr("db.system", "mysql"), attr("tenant.id", tenant),
                                               attr("db.statement", "select * from orders where email='kim@example.com'")],
                                "status": {}})
            # api-gateway → downstream client span (service graph edge)
            if svc == "api-gateway":
                down = random.choice(["checkout", "inventory"])
                cs = rid(64)
                by_svc[svc].append({"traceId": t, "spanId": cs, "parentSpanId": root, "name": f"GET {down}", "kind": 3,
                                    "startTimeUnixNano": str(st), "endTimeUnixNano": str(st + dur // 2),
                                    "attributes": [attr("server.address", down), attr("http.request.method", "GET")], "status": {"code": 1}})
                by_svc[down].append({"traceId": t, "spanId": rid(64), "parentSpanId": cs, "name": f"GET {SERVICES[down]['routes'][0]}", "kind": 2,
                                     "startTimeUnixNano": str(st), "endTimeUnixNano": str(st + dur // 3),
                                     "attributes": [attr("http.route", SERVICES[down]["routes"][0]), attr("http.request.method", "GET"),
                                                    attr("http.response.status_code", 200), attr("http.request.header.x-tenant-id", [tenant]),
                                                    attr("tenant.tier", tier)], "status": {"code": 1}})
        body = {"resourceSpans": [{"resource": self.res(s), "scopeSpans": [{"scope": {"name": "simulator"}, "spans": sp}]}
                                  for s, sp in by_svc.items() if sp]}
        return self.post("/v1/traces", body)

    # ------------------------------------------------------------------
    def business(self):
        for tenant, _ in TENANTS:
            carts = random.randint(30, 60)
            hoard = 3 if self.scenario == "bot" and tenant == "hooli" else 1
            checkout = int(carts * random.uniform(0.55, 0.65))
            orders = int(checkout * random.uniform(0.88, 0.95))
            requested = int(orders * random.uniform(0.97, 1.0))
            for stage, v in [("cart_add", carts * hoard), ("checkout_start", checkout), ("order_created", orders), ("payment_requested", requested)]:
                self.inc("nebula.commerce.funnel.events", {"funnel.stage": stage, "tenant.id": tenant, "channel": "web"}, v)
            succeeded = 0
            for _ in range(requested):
                pg, method, issuer = random.choice(PGS), random.choice(METHODS), random.choice(ISSUERS)
                fail_p_sys = 0.25 if (self.scenario == "pg-timeout" and pg == "kcp") else 0.003
                r = random.random()
                if r < fail_p_sys:
                    code = "PG_TIMEOUT" if self.scenario == "pg-timeout" else random.choice(FAIL_CODES["system"])
                    key = {"payment.outcome": "failure", "payment.failure.code": code}
                elif r < fail_p_sys + 0.04:
                    key = {"payment.outcome": "failure", "payment.failure.code": random.choice(FAIL_CODES["customer"])}
                else:
                    key = {"payment.outcome": "success"}
                    succeeded += 1
                key.update({"payment.pg": pg, "payment.method": method, "card.issuer": issuer if method == "card" else "none", "tenant.id": tenant})
                self.inc("nebula.payment.requests", key, 1)
            self.inc("nebula.commerce.funnel.events", {"funnel.stage": "payment_succeeded", "tenant.id": tenant, "channel": "web"}, succeeded)
            aov = random.randint(35000, 60000)
            revenue = succeeded * aov
            self.inc("nebula.order.revenue", {"tenant.id": tenant}, revenue)
            coupon = 0.55 if self.scenario == "deficit" else 0.05
            for cost_type, ratio in [("cogs", 0.62), ("pg_fee", 0.028), ("shipping", 0.06), ("coupon", coupon)]:
                self.inc("nebula.order.cost", {"cost_type": cost_type, "tenant.id": tenant}, int(revenue * ratio))

    def metrics(self, now):
        self.business()
        metrics = {}
        for (name, key), v in self.counters.items():
            unit = "{KRW}" if name.startswith("nebula.order") else "{event}"
            metrics.setdefault(name, {"name": name, "unit": unit, "sum": {"aggregationTemporality": 2, "isMonotonic": True, "dataPoints": []}})
            metrics[name]["sum"]["dataPoints"].append({"asInt": str(v), "startTimeUnixNano": str(self.start), "timeUnixNano": str(now),
                                                       "attributes": [attr(k, x) for k, x in key]})
        # PG 응답 시간 히스토그램 (누적 temporality: PRW 는 delta 를 받지 않는다)
        buckets = [0.1, 0.25, 0.5, 1, 2.5, 5]
        dps = []
        for pg in PGS:
            st = self.hist.setdefault(pg, {"count": 0, "sum": 0.0, "b": [0] * (len(buckets) + 1)})
            for _ in range(30):
                x = random.lognormvariate(-1.6, 0.6)
                if self.scenario == "pg-timeout" and pg == "kcp" and random.random() < 0.25:
                    x = 5 + random.random() * 2
                st["count"] += 1
                st["sum"] += x
                st["b"][next((i for i, b in enumerate(buckets) if x <= b), len(buckets))] += 1
            dps.append({"startTimeUnixNano": str(self.start), "timeUnixNano": str(now), "count": str(st["count"]), "sum": st["sum"],
                        "bucketCounts": [str(c) for c in st["b"]], "explicitBounds": buckets,
                        "attributes": [attr("payment.pg", pg), attr("payment.outcome", "success")]})
        hist = {"name": "nebula.payment.pg.duration", "unit": "s", "histogram": {"aggregationTemporality": 2, "dataPoints": dps}}
        body = {"resourceMetrics": [{"resource": self.res("payment-service"),
                                     "scopeMetrics": [{"scope": {"name": "simulator"}, "metrics": list(metrics.values()) + [hist]}]}]}
        return self.post("/v1/metrics", body)

    def logs(self, now):
        recs = []
        for _ in range(random.randint(10, 20)):
            tenant, _ = random.choice(TENANTS)
            lvl = random.choices(["INFO", "WARN", "ERROR", "DEBUG"], [80, 8, 2, 10])[0]
            msg = {"INFO": f"order created for kim{random.randint(1, 99)}@example.com",
                   "WARN": "slow query detected",
                   "ERROR": "payment failed Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig card 1234-5678-9012-3456",
                   "DEBUG": "cache miss"}[lvl]
            sev = {"DEBUG": 5, "INFO": 9, "WARN": 13, "ERROR": 17}[lvl]
            a = [attr("tenant_id", tenant)]
            if lvl == "INFO" and random.random() < 0.3:
                a.append(attr("log.type", "audit"))
            recs.append({"timeUnixNano": str(now), "severityNumber": sev, "severityText": lvl, "body": {"stringValue": msg},
                         "traceId": rid(128), "attributes": a})
        body = {"resourceLogs": [{"resource": self.res("payment-service"), "scopeLogs": [{"scope": {"name": "simulator"}, "logRecords": recs}]}]}
        return self.post("/v1/logs", body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="http://localhost:4318")
    ap.add_argument("--interval", type=float, default=5)
    ap.add_argument("--duration", type=float, default=300, help="seconds (0 = forever)")
    ap.add_argument("--scenario", default="normal", choices=["normal", "pg-timeout", "noisy", "deficit", "bot"])
    a = ap.parse_args()
    sim = Sim(a.endpoint, a.scenario)
    end = time.time() + a.duration if a.duration else float("inf")
    n = 0
    while time.time() < end:
        now = time.time_ns()
        try:
            sim.traces(now)
            sim.metrics(now)
            sim.logs(now)
            n += 1
            if n % 12 == 1:
                print(f"[{time.strftime('%H:%M:%S')}] sent batch #{n} ({a.scenario})", flush=True)
        except Exception as e:  # keep going on transient collector restarts
            print("send failed:", e, flush=True)
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
