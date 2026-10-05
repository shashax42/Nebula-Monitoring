# Telemetry Contract — 애플리케이션이 지켜야 할 데이터 규약

모니터링 파이프라인(정제·가공·SLO·대시보드·알림)은 **이 문서의 이름과 속성을 전제로** 동작한다.
여기 없는 이름으로 보내면 수집은 되지만 대시보드/알림에는 나타나지 않는다.

> 검증: `python3 tools/telemetry-simulator/simulate.py` 가 이 계약을 그대로 구현한 예시다.

---

## 1. 전송 방식

| 항목 | 값 |
|---|---|
| OTLP 엔드포인트 | `http://otel-collector.monitoring.svc:4318` (HTTP) / `:4317` (gRPC) — 같은 노드의 agent 로 전달됨 |
| 트레이스 샘플러 | `parentbased_always_on` (**SDK 에서 샘플링하지 않는다**. 보존 여부는 gateway tail sampling 이 결정) |
| 전파 | `tracecontext,baggage` |
| 로그 | **stdout 한 줄 JSON** 권장 (agent 가 수집). OTLP 로그를 쓰면 stdout 로그는 끈다 (중복 저장 방지) |
| 메트릭 temporality | cumulative (기본값). delta 로 보내면 AMP 에 저장되지 않는다 |

자동 계측: `k8s/otel-operator/instrumentation.yaml` 를 쓰면 위 설정이 주입된다.

## 2. 리소스 속성 (모든 신호 공통)

| 속성 | 필수 | 설명 |
|---|---|---|
| `service.name` | ✅ | 서비스 식별자. 없으면 `app.kubernetes.io/name` → `app` 라벨 → 워크로드명 순으로 agent 가 채움 |
| `service.version` | 권장 | 배포 버전 (canary 비교, 배포 직후 이상 탐지) |
| `deployment.environment` | 자동 | collector 가 채움 |
| `k8s.*` | 자동 | agent 의 k8sattributes 가 채움 — 앱이 넣지 않는다 |

## 3. 멀티테넌시 — `tenant.id`

| 위치 | 규약 |
|---|---|
| 인그레스 | 요청 헤더 `x-tenant-id` (SDK 가 `http.request.header.x-tenant-id` 로 캡처 → gateway 가 `tenant.id` 로 정규화, 소문자) |
| 서비스 내부 | 인증 직후 **Baggage** 에 `tenant.id`, `tenant.tier`(`enterprise`/`pro`/`free`) 를 넣는다 |
| 하위 스팬 | Baggage → span 속성 복사 (Java: `OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE=tenant.id,tenant.tier`, 그 외 언어는 `BaggageSpanProcessor`). **DB 스팬에도 `tenant.id` 가 있어야 Noisy Neighbor 분석이 된다** |
| 메트릭/로그 | 속성 `tenant.id` (또는 `tenant_id`, `tenantId` — gateway 가 통일) |

`tenant.id` 는 테넌트 수만큼 시리즈를 만든다. **주문 ID·사용자 ID 를 tenant 로 쓰지 말 것** (gateway 가 `order.id`, `user.id`, `session.id` 메트릭 속성은 제거한다).

## 4. 트레이스 속성

| 스팬 | 속성 | 용도 |
|---|---|---|
| 서버 스팬 | `http.route` (템플릿, 예 `/orders/{id}`), `http.request.method`, `http.response.status_code` | 라우트별 RED, SLO |
| 서버 스팬 | 실패 시 span status = `ERROR` (5xx/예외) | 가용성 SLI |
| DB 스팬 | `db.system`, `tenant.id` | 테넌트별 DB 점유시간 |
| 결제 처리 스팬 | `payment.pg` (`toss`/`kcp`/`inicis`…), `payment.outcome` (`success`/`failure`) | **논리 오류** = HTTP 2xx + `payment.outcome=failure` 를 gateway 가 카운트 |

URL 쿼리의 `token/password/key/secret/code`, `Authorization`/`Cookie` 헤더, SQL 리터럴은 gateway 가 마스킹/삭제한다.

## 5. 비즈니스 메트릭 (OTLP)

| 메트릭 | 타입·단위 | 속성 | 의미 |
|---|---|---|---|
| `nebula.commerce.funnel.events` | Counter `{event}` | `funnel.stage` ∈ `cart_add`, `checkout_start`, `order_created`, `payment_requested`, `payment_succeeded` · `tenant.id` · `channel` | Transactional Event Flow / Drop % / 전환율 |
| `nebula.payment.requests` | Counter `{request}` | `payment.method`, `payment.pg`, `payment.outcome`, `payment.failure.code`(PG 원본 코드), `card.issuer`, `tenant.id` | 결제 성공/실패. gateway 가 `payment.failure.code` → `payment.failure.category` 로 분류 |
| `nebula.payment.pg.duration` | Histogram `s` | `payment.pg`, `payment.outcome` | PG API 지연 |
| `nebula.order.revenue` | Counter `{KRW}` | `tenant.id`, `payment.method` | 매출 (역마진·테넌트 비용효율) |
| `nebula.order.cost` | Counter `{KRW}` | `cost_type` ∈ `cogs`, `pg_fee`, `shipping`, `coupon`, `marketing` · `tenant.id` | 주문 변동비 |

- 단위에 통화를 쓸 때는 반드시 중괄호 `{KRW}` — 그렇지 않으면 Prometheus 이름에 `_KRW` 접미사가 붙는다.
- 메시지 브로커 lag 은 앱이 아니라 collector(cluster) 가 수집한다 (`cluster.messaging.kafka|rabbitmq.enabled`).

### PG 실패 코드 → 카테고리 (gateway `transform/payment-normalize`)

| 카테고리 | 매칭 (대소문자 무시) | 책임 |
|---|---|---|
| `card_limit_exceeded` | LIMIT, EXCEED, 한도 | 고객 |
| `insufficient_funds` | INSUFFICIENT, NOT_ENOUGH, BALANCE, 잔액 | 고객 |
| `pg_timeout` | TIMEOUT, TIMED_OUT, 408, 504 | **시스템** |
| `pg_unavailable` | UNAVAILABLE, SYSTEM_ERROR, MAINTENANCE, 500/502/503, 점검 | **시스템** |
| `fraud_suspected` | FRAUD, RISK, SUSPECT, STOLEN, LOST, 도난, 분실 | 카드사 |
| `invalid_card` | INVALID_CARD, EXPIRED, CARD_NUMBER, 유효기간 | 고객 |
| `card_declined` | DECLIN, REJECT, DENIED, NOT_ALLOWED, 거절 | 카드사 |
| `user_cancelled` | CANCEL, ABORT, 취소 | 고객 |
| `other` | 위에 해당 없음 | 시스템(미분류 → 규칙 보강 대상) |

`other` 비중이 늘면 PG 사 코드표를 보고 `helm/otel-collector/values.yaml` 의 매칭 규칙을 추가한다.

## 6. 로그 형식 (stdout JSON 한 줄)

```json
{"timestamp":"2026-10-05T10:00:00Z","level":"error","message":"payment failed","trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"b7ad6b7169203331","tenant_id":"acme","event.domain":"payment","log.type":"audit"}
```

| 필드 | 규약 |
|---|---|
| `level` / `severity` / `log.level` | `trace/debug/info/warn/error/fatal` (대소문자 무관). 없으면 본문 키워드로 추정 |
| `message` / `msg` | 본문 |
| `trace_id`, `span_id` | 32/16자리 hex → 로그 ↔ 트레이스 연결 |
| `tenant_id` | 테넌트 |
| `log.type: "audit"` 또는 `event.domain: "payment"` | **감사 로그 그룹**(90일 Hot + S3 7년)으로 라우팅 |

마스킹(agent): 이메일, 휴대폰, 주민등록번호, 카드번호(4-4-4-4), JWT, Bearer/Basic 토큰, `password=`/`token=`/`api_key=` 값.
최소 레벨: dev = DEBUG, staging/prod = INFO (`pipeline.logs.minSeverityNumber`).
