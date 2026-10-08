# Telemetry Contract — 애플리케이션이 지켜야 할 데이터 규약

모니터링 파이프라인(정제·가공·SLO·대시보드·알림)은 **이 문서의 이름과 속성을 전제로** 동작한다.
여기 없는 이름으로 보내면 수집은 되지만 대시보드/알림에는 나타나지 않는다.

1~6장은 **nebula-services 가 지금 내보내는 것**(기본 배포)이고, 7장은 해당 기능이 생길 때 켜는 **확장**이다.

> 검증: `python3 tools/telemetry-simulator/simulate.py` 가 1~6장을 그대로 흉내 낸다 (`--extensions` 는 7장).

---

## 1. 전송 방식 (nebula-services 구현)

| 항목 | 값 |
|---|---|
| 계측 | Spring Boot 3 Micrometer Observation → `micrometer-tracing-bridge-otel` (트레이스) + `micrometer-registry-otlp` (메트릭) |
| OTLP 엔드포인트 | `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://otel-collector.monitoring.svc:4318` (nebula-gitops `config-common/observability.yaml`). Service 가 `internalTrafficPolicy: Local` 이라 같은 노드의 agent 로 간다 |
| 트레이스 샘플링 | `management.tracing.sampling.probability: 1.0` (**앱에서 샘플링하지 않는다**. 보존 여부는 gateway tail sampling 이 결정) |
| 전파 | W3C `traceparent` (HTTP, Kafka 헤더) — KafkaTemplate / listener factory 에 `observationEnabled=true` |
| 메트릭 | OTLP push 30s, cumulative (Micrometer 기본). delta 로 보내면 AMP 에 저장되지 않는다 |
| 로그 | kubernetes 프로필에서 **stdout 한 줄 JSON** (logstash 포맷). agent 가 컨테이너 로그 파일로 수집 — OTLP 로그는 쓰지 않는다 |

## 2. 리소스 속성 (모든 신호 공통)

| 속성 | 필수 | 설명 |
|---|---|---|
| `service.name` | ✅ | `spring.application.name` (core-gateway, service-account, service-order, service-product). 없으면 `app.kubernetes.io/name` → `app` 라벨 → 워크로드명 순으로 agent 가 채움 |
| `deployment.track` | 자동 | Argo Rollouts 파드 라벨 `nebula.io/track`(canary/stable) → agent k8sattributes. **카나리 분석의 비교 축** |
| `deployment.environment` | 자동 | collector 가 채움 |
| `k8s.*` | 자동 | agent 의 k8sattributes 가 채움 — 앱이 넣지 않는다 |

## 3. 트레이스 속성

Micrometer 는 Observation 키를 그대로 스팬 속성으로 쓴다. gateway 의 `transform/micrometer-semconv` 가 OTel 표준으로 옮기고,
그 뒤의 span metrics·SLO 규칙·X-Ray 는 표준 이름만 본다.

| 스팬 | Micrometer 속성 | gateway 가 만드는 표준 속성 | 용도 |
|---|---|---|---|
| HTTP 서버 | `uri` (템플릿, 예 `/orders/{id}`), `method`, `status`, `outcome`, `exception` | `http.route`, `http.request.method`, `http.response.status_code`(int) | 라우트별 RED, SLO |
| HTTP 서버 | (예외 없이 5xx 를 응답하면 상태 UNSET) | **5xx → span status `ERROR`** | 가용성 SLI 가 `@ControllerAdvice` 로 처리된 5xx 도 센다 |
| Kafka producer | `messaging.system=kafka`, `messaging.destination.name` (purchase / refund) | 그대로 | 토픽별 발행 지연·실패 |
| Kafka consumer | 위 + `messaging.kafka.consumer.group` | 그대로 | 토픽별 처리 지연·에러, 사가 구간 |
| DB 클라이언트 | `db.system`, `db.statement` | SQL 리터럴 `'…'` → `'?'` | 의존성 지연 |

- `/actuator/**` 스팬과 kube-probe 는 gateway 가 버린다.
- URL 쿼리의 `token/password/key/secret/code`, `Authorization`/`Cookie` 헤더는 gateway 가 마스킹/삭제한다.
- 주문 → 재고 → (취소) 가 Kafka 헤더로 이어져 **하나의 트레이스**가 된다 (X-Ray 에서 `messaging.destination.name` 인덱스로 검색).

## 4. 비즈니스 메트릭 — 주문 사가 (OTLP)

| 메트릭 | 타입 | 속성 | 의미 |
|---|---|---|---|
| `nebula.commerce.funnel.events` | Counter | `funnel.stage`, `reason` | 주문 사가 단계 이벤트 |

| `funnel.stage` | 기록 위치 | 시점 | `reason` |
|---|---|---|---|
| `order_placed` | service-order `OrderEventProducer` | 주문 트랜잭션 커밋 후 (AFTER_COMMIT) | `none` |
| `purchase_published` | service-order | Kafka `purchase` send 성공 (future 결과) | `none` |
| `purchase_publish_failed` | service-order | send 실패 | `publish_error` |
| `purchase_consumed` | service-product `OrderEventConsumer` | 재고 처리 완료 (성공·거절 모두) | `none` |
| `stock_rejected` | service-product `ProductEventProducer` | 재고 부족으로 거절, `refund` 발행 | `out_of_stock` |
| `order_canceled` | service-order `ProductEventConsumer` | 보상 트랜잭션(주문 취소) 완료 | `out_of_stock` / `other` |

- `reason` 은 고정 값만 쓴다 (`FunnelMetrics.normalizeReason`). 자유 텍스트("재고 부족>3")를 넣으면 시리즈가 폭증한다.
- 규칙: `prometheus/rules/04-business.rules.yaml` (발행 실패율, 사가 정지, 보상 누락, 재고 거절률, 완료율).
- 메시지 브로커 lag 은 앱이 아니라 collector(cluster) 가 수집한다 (`cluster.messaging.kafka.enabled`, Strimzi `market-message`).

### 4.1 배치 (batch-order CronJob)

짧게 살다 끝나는 프로세스라 스크레이프로는 놓친다. 기존 구조의 Push Gateway 대신, 종료할 때 OTLP 로 마지막 값을 push 한다
(`SpringApplication.exit` 로 컨텍스트를 정상 종료해야 OTLP 레지스트리가 마지막 전송을 한다).

| 메트릭 | 타입 | 속성 | 의미 |
|---|---|---|---|
| `nebula.batch.job.last.run` | Gauge (epoch s) | `job.name`, `status`=completed\|failed | 마지막으로 끝난 시각 |
| `nebula.batch.job.duration` | Gauge (s) | `job.name`, `status` | 실행 시간 |
| `nebula.batch.order.rows` | Gauge | `job.name` | 마지막 성공 실행이 취소·삭제한 주문 수 (Step write count 합) |

- 매 실행이 새 프로세스라 카운터는 0 에서 다시 시작해 증가량을 계산할 수 없다. 그래서 게이지로 "마지막 값"을 보낸다.
- collector 는 Job 파드(`k8s.job.name` 있음)에 `pod` 라벨을 붙이지 않고 `cronjob` 라벨을 붙인다. 실행마다 바뀌는 파드 이름이 새 시리즈를 만들지 않게 하기 위해서다.
- 실패한 실행은 종료 코드가 0 이 아니다 → CronJob 실패 기록, kube-state-metrics `kube_job_status_failed` 와 함께 본다.
- 규칙: `prometheus/rules/08-batch.rules.yaml` (BatchJobStale, BatchJobFailing, StaleOrdersAutoCanceled).

## 5. 로그 형식 (stdout JSON 한 줄, Spring logstash)

```json
{"@timestamp":"2026-10-05T10:00:02.000Z","message":"주문 이벤트 전송 실패: 1043","logger_name":"io.nebula.market.order…OrderEventProducer","thread_name":"kafka-producer-network-thread | producer-1","level":"ERROR","stack_trace":"org.apache.kafka…","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"00f067aa0ba902b7"}
```

| 필드 | 처리 (agent) |
|---|---|
| `level` / `severity` / `log.level` | severity 로 승격 (대소문자 무관). 없으면 본문 키워드로 추정 |
| `message` / `msg` | 본문 |
| `traceId`/`spanId` (Micrometer MDC), `trace_id`/`span_id` | 32/16자리 hex → 로그 ↔ 트레이스 연결 |
| `@timestamp`, `@version`, `level_value` | 삭제 (시각은 CRI 타임스탬프, 레벨은 severity 와 중복) |
| `logger_name`, `thread_name`, `stack_trace` | attributes 로 유지 (Logs Insights 필터) |
| `log.type: "audit"` | **감사 로그 그룹**(90일 Hot + S3 아카이브)으로 라우팅 |

마스킹(agent): 이메일, 휴대폰, 주민등록번호, 카드번호(4-4-4-4), JWT, Bearer/Basic 토큰, `password=`/`token=`/`api_key=` 값.
최소 레벨: dev = DEBUG, staging/prod = INFO (`pipeline.logs.minSeverityNumber`).

## 6. 카디널리티 규칙

- span metrics 차원: `http.route`, `http.request.method`, `http.response.status_code`, `k8s.namespace.name`, `messaging.destination.name`, `deployment.track`
  (서비스당 수십 개 라우트 × 토픽 2개 × 트랙 2개 규모). `aggregation_cardinality_limit: 5000`.
- gateway 는 메트릭 속성 `order.id`, `user.id`, `session.id`, 클라이언트 IP 를 제거한다. **ID 를 라벨로 쓰지 말 것**.

---

## 7. 확장 (기본 비활성) — 멀티테넌시 · 결제(PG) · 매출/원가

현재 서비스에는 테넌트·결제 연동·매출 이벤트가 없다. 해당 기능을 만들 때 아래 계약을 지키고 다음을 함께 켠다
(배경: [ADR 0001](adr/0001-core-vs-extension-telemetry.md)).

| 구성 | 켜는 방법 |
|---|---|
| collector | `-f helm/otel-collector/values-extension-business.yaml` |
| 규칙 | `terraform apply -var enable_business_extensions=true` (`prometheus/rules/extensions/*` + 결제 CloudWatch 알람) |
| 대시보드 | `scripts/provision-grafana.sh <env> --extensions` |

### 7.1 `tenant.id`

| 위치 | 규약 |
|---|---|
| 인그레스 | 요청 헤더 `x-tenant-id` (`http.request.header.x-tenant-id` 로 캡처 → gateway 가 `tenant.id` 로 정규화, 소문자) |
| 서비스 내부 | 인증 직후 Baggage 에 `tenant.id`, `tenant.tier`(`enterprise`/`pro`/`free`) → 하위 스팬 속성으로 복사. **DB 스팬에도 `tenant.id` 가 있어야 Noisy Neighbor 분석이 된다** |
| 메트릭/로그 | 속성 `tenant.id` (또는 `tenant_id`, `tenantId` — gateway 가 통일) |

### 7.2 결제·매출 메트릭

| 메트릭 | 타입·단위 | 속성 | 의미 |
|---|---|---|---|
| `nebula.commerce.funnel.events` | Counter | `funnel.stage` ∈ `cart_add`, `checkout_start`, `order_created`, `payment_requested`, `payment_succeeded` · `tenant.id` | 구매 퍼널 Drop % (사가 단계와 이름이 겹치지 않는다) |
| `nebula.payment.requests` | Counter `{request}` | `payment.method`, `payment.pg`, `payment.outcome`, `payment.failure.code`(PG 원본 코드), `card.issuer`, `tenant.id` | 결제 성공/실패. gateway 가 `payment.failure.code` → `payment.failure.category` 로 분류 |
| `nebula.payment.pg.duration` | Histogram `s` | `payment.pg`, `payment.outcome` | PG API 지연 |
| `nebula.order.revenue` | Counter `{KRW}` | `tenant.id`, `payment.method` | 매출 (역마진·테넌트 비용효율) |
| `nebula.order.cost` | Counter `{KRW}` | `cost_type` ∈ `cogs`, `pg_fee`, `shipping`, `coupon`, `marketing` · `tenant.id` | 주문 변동비 |

결제 처리 스팬에는 `payment.pg`, `payment.outcome` 을 넣는다 → **논리 오류**(HTTP 2xx + `payment.outcome=failure`)를 gateway 가 센다.
통화 단위는 반드시 중괄호 `{KRW}` — 그렇지 않으면 Prometheus 이름에 `_KRW` 접미사가 붙는다.

### 7.3 PG 실패 코드 → 카테고리 (`transform/payment-normalize`)

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

결제 도메인 로그(`event.domain: "payment"`)는 오버레이가 감사 로그 그룹으로 라우팅한다.
