# Nebula Observability — 데이터 수집 · 정제 · 가공 설계

> 출발점은 "무엇을 수집할 수 있나"가 아니라 **"어떤 문제를 언제 개입해서 해결할 것인가"** 다 (Top-down).
> 그래서 이 문서는 질문 → 데이터 → 정제 → 가공 → 판단(대시보드·알림) 순서로 쓴다.
> 각 단계는 저장소의 실제 파일과 1:1 로 연결되며, 모든 설정은 실제 바이너리로 검증된다(10장).
>
> **기본 배포 = 지금 nebula-services 가 내보내는 데이터**(HTTP/Kafka 스팬, 주문 사가 카운터, 컨테이너 로그, 인프라).
> 테넌트·결제(PG)·매출/마진은 해당 기능이 없으므로 **확장**(기본 비활성)으로 분리했다 → [ADR 0001](adr/0001-core-vs-extension-telemetry.md).
> 아래 표의 `[확장]` 표시는 오버레이·확장 규칙을 켰을 때만 동작한다.

---

## 0. 참고 설계(Nebula Platform / Observability) ↔ 구현 대응표

| 참고 설계 항목 | 구현 위치 |
|---|---|
| Phase 2: OTel Collector (Metrics scrape, Logs collection, Tenant labeling/routing, **Sampling + filtering**) | `helm/otel-collector` agent·gateway·cluster (테넌트 라벨링은 `[확장]` `values-extension-business.yaml`) |
| OTel Collector Sidecar **or DaemonSet** | agent = DaemonSet (노드 로컬 수집) |
| AMP = Prometheus 대체 (메트릭 저장) | gateway `prometheus_remote_write/amp`, `terraform/modules/amp` |
| CloudWatch Logs = Loki 대체 (로그 저장, Logs Insights) | gateway `awscloudwatchlogs/*`, `terraform/modules/log-analytics` (저장 쿼리 7종) |
| X-Ray = Zipkin 대체 (분산 추적, 서비스 맵) | gateway `awsxray` (tail sampling 후) |
| AMG = Grafana 대체 (대시보드, Alerting) | `grafana/dashboards/*.json`, `scripts/provision-grafana.sh` |
| **CloudWatch Alarms/SNS = Alertmanager 대체** (SLA breach, Error/Latency alerts) | `terraform/modules/cloudwatch-alarms` (EMF SLI 기반) + AMP 관리형 Alertmanager → 같은 SNS |
| Golden Signals: Latency P99 / Traffic / Errors 5xx+Business / Saturation | `02-service-slo`, `04-business`, `01-kubernetes` 규칙 (Traffic by tenant_id 는 `[확장]` `extensions/tenant`) |
| Transactional Event Flow: 단계별 흐름, Drop %, Logical Error | **주문 사가**: `04-business` (발행 실패·사가 정지·보상 누락·재고 거절·완료율) + Kafka 스팬 지연 |
| (장바구니 → 결제요청(PG) → 결제완료, PG 실패 코드 분류) | `[확장]` `extensions/commerce-payment` + `transform/payment-normalize` |
| Consumer Lag (Kafka): API 정상인데 후행 로직 밀림 | cluster `kafka_metrics`(Strimzi market-message) + `SagaStalled`, `AsyncLagWhileAPIHealthy` |
| tenant_id 트레이싱 + DB Lock Wait: Noisy Neighbor vs 고객 데이터셋 문제 | `[확장]` `span_metrics/tenant` + `TenantNoisyNeighbor`. 기본: Aurora RowLockTime/Deadlocks 알람 |
| Multi-tenancy & Cost Efficiency (tenant_id 비용, SLA/Tiered pricing) | 기본: `05-cost`(네임스페이스 비용·유휴) / `[확장]` 테넌트 배분·효율, 티어별 SLO |
| Anomaly Alert / Idle Resource Score | `06-anomaly` |
| Cold Data (S3), TTL Data | `terraform/modules/log-archive` (법정 최소 5년, 정책값 7년), 로그 클래스별 retention |
| 역마진: Revenue vs Total OpEx, BEP, Net Margin 게이지(5%/0%), Burn Rate ₩/hr, D+? 예측 | `[확장]` `extensions/margin` + `Ext / Margin` 대시보드 (매출·원가 이벤트 필요) |
| Reliability & GitOps: 배포 직후 이상 → 메트릭 기반 Auto-Rollback | service-order Argo Rollouts canary + nebula-gitops `platform/aws/base/analysis-slo-canary.yaml` (AMP span metrics, `deployment_track`) |
| 위젯: Gauge with Thresholds / Time Series with Goal Line / Time to Burn Out / Actionable Links | `Nebula / Service SLO` 대시보드 상단 |
| Operability: 계정 분리 (prod-us ↔ prod-eu, customer-A) | `terraform/modules/cross-account-ingest`, `routing/logs` |

---

## 1. 아키텍처

```
 App Pods (Micrometer→OTLP, stdout JSON)            kube-state-metrics   API server   k8s Events   Kafka(Strimzi)
        │ OTLP :4317/4318 (Service otel-collector, internalTrafficPolicy=Local)       │            │             │
        ▼                                                                             ▼            ▼             ▼
 ┌──────────────── agent (DaemonSet, 노드당 1) ────────────────┐      ┌──────── cluster (Deployment ×1) ────────┐
 │ 수집: filelog(/var/log/pods), kubelet·cAdvisor·파드 scrape   │      │ 수집: KSM, apiserver, events, 브로커 lag │
 │      (자기 노드만 → DaemonSet 이어도 중복 없음), OTLP 수신    │      │ 정제: Normal 이벤트 제거, 필드 정규화    │
 │ 정제: k8s 메타 부착, service.name 표준화, JSON/레벨/trace_id │      └───────────────────┬──────────────────────┘
 │      파싱, 헬스체크·DEBUG 제거, PII 마스킹, 크기 제한         │                          │ OTLP
 └──────────┬───────────────────────────────┬───────────────────┘                          │
   traces: traceID 기준 load_balancing   logs/metrics: OTLP                                  │
            ▼                               ▼                                               ▼
 ┌──────────────────────────── gateway (Deployment, HPA 2~10, IRSA) ────────────────────────────────────┐
 │ 정제: Micrometer 속성 → OTel 표준(+5xx=ERROR), 헬스체크·actuator 스팬 제거, 민감 속성 삭제/SQL·URL 마스킹 │
 │ 가공: span_metrics(서비스·라우트·토픽·canary/stable RED) · service_graph · count/logs · count/sli        │
 │       [확장] span_metrics/tenant · count/business(논리 오류) · PG 실패코드 분류                          │
 │ 샘플링: tail_sampling (에러·지연 100%, 핵심 서비스 50%, 나머지 baseline)                                │
 └──────┬──────────────────┬───────────────────┬──────────────────────┬──────────────────────┬──────────┘
        ▼                  ▼                   ▼                      ▼                      ▼
   AMP (메트릭)        X-Ray (트레이스)   CloudWatch Logs           CloudWatch Metrics      (계정 분리 시
   + 레코딩 규칙        서비스 맵          app / audit / events      Nebula/Application      cross-account
   + 알림 규칙                             └ audit → Firehose → S3   (EMF: SLI)               역할 assume)
        │                                        (7년 정책, Glacier)       │
        ▼                                                                  ▼
   AMP Alertmanager ─────────────► SNS (critical / warning) ◄──── CloudWatch Alarms (SLA·DB·파이프라인)
        │      └──────────────► Argo Rollouts 분석(nebula-slo-canary): canary vs stable → 자동 롤백
        ▼
   AMG (Grafana): Overview · Service SLO · Order Saga · Infra Cost · Data Stores · Pipeline  (+ 확장 3종)
```

**왜 3계층인가 (Structure: 감당 가능한 최소 조합)**
- agent 는 노드 로컬 일(파일 읽기, kubelet)만 하고 AWS 자격증명이 없다 → 노드 침해 시 영향 최소화.
- gateway 만 IRSA 를 갖고 내보낸다 → 권한·엔드포인트·비용 통제 지점이 하나.
- tail sampling 과 service_graph 는 "한 트레이스의 모든 스팬이 같은 곳"에 있어야 정확하다 → agent 가 traceID 로 gateway 를 고른다.
- KSM·apiserver·Events 는 클러스터에 하나뿐이므로 한 번만 수집해야 한다 → cluster (replicas=1, Recreate).

**벤더 종속 경계 (Portability)**: 앱은 Micrometer + OTLP 표준만 안다. AWS 종속은 gateway exporter 와 Terraform 에만 있다.
다른 백엔드로 옮길 때 바꾸는 것은 gateway `exporters:` 블록뿐이다.

---

## 2. 무엇을 수집하나 — 질문에서 데이터로

### 2.1 Top-Down 질문 → 데이터 → 인사이트

| 질문 (언제 개입해야 하나?) | 수집 데이터 | 얻는 인사이트 |
|---|---|---|
| 사용자가 체감하는 품질은? | 서버 스팬(전량) → Latency P99, Traffic, Errors(5xx — Micrometer 가 놓치는 예외 없는 5xx 포함) | SLO / 에러 버짓 / 번레이트 |
| 주문이 끝까지 처리됐나? (API 는 200 인데) | 사가 단계 카운터(주문 접수 → purchase 발행 → 재고 처리 → 거절 시 취소) | 발행 실패, 사가 정지, **보상(취소) 누락** = 데이터 정합성 문제 |
| API 는 정상인데 왜 주문 처리가 늦나? | Kafka **Consumer Lag** + consumer 스팬 지연·에러 | 후행 비즈니스 로직 적체 (HTTP 지표로는 안 보이는 장애) |
| 방금 배포한 버전이 나쁜가? | canary/stable 파드 라벨이 붙은 span metrics | 외부 장애와 배포 결함 구분(상대 비교) → 자동 롤백 |
| 재고 부족이 늘었나? (장애가 아닌 비즈니스 신호) | `stock_rejected` / `purchase_consumed` | 품절·프로모션 과열 — SLO 알림과 분리 |
| 자원을 낭비하고 있나? | requests vs 실제 사용량 × 단가 | 네임스페이스 비용, 유휴 비용, 다운사이징 후보 |
| `[확장]` 결제가 왜 실패하나? | 결제 이벤트 + **PG 원본 응답 코드** | 카드 한도 초과(고객) vs PG 타임아웃(시스템) |
| `[확장]` 특정 고객 때문에 전체가 느린가? | tenant_id 가 박힌 트레이스 + DB 스팬 시간 + Aurora Lock Wait | Noisy Neighbor vs 고객 데이터셋/쿼리 문제 |
| `[확장]` 팔수록 손해인가? | 매출·변동비 + 인프라 비용 신호 | Net Margin, Burn Rate, BEP, 역마진 예측 |

### 2.2 신호 카탈로그

| 신호 | 출처 | 수집기 | 주요 데이터 | 저장 |
|---|---|---|---|---|
| 컨테이너 로그 | `/var/log/pods` (Spring logstash JSON) | agent `file_log` | 메시지, 레벨, traceId, logger, stack_trace | CW Logs `application` |
| 감사 로그 | 앱 로그 중 `log.type=audit` (`[확장]` + `event.domain=payment`) | agent → gateway 라우팅 | 감사 이력 | CW Logs `audit` (90일) → S3 (7년 정책) |
| K8s 이벤트 | events.k8s.io watch | cluster `k8sobjects` | OOMKilled, FailedScheduling, BackOff, Evicted | CW Logs `events` (14일) |
| 트레이스 | Micrometer Tracing (OTel bridge) | agent → gateway | HTTP 서버/클라이언트, Kafka producer/consumer, DB 스팬 | X-Ray (샘플링 후) |
| 앱 메트릭 | micrometer-registry-otlp / `prometheus.io/scrape` | agent | JVM·HTTP, **사가 단계 카운터** (`[확장]` 결제·매출·원가) | AMP |
| 노드/파드 자원 | kubelet `/metrics/resource`, cAdvisor | agent (노드 로컬) | CPU/메모리/네트워크/스로틀링/OOM | AMP |
| PVC | kubelet `/metrics` | agent | 볼륨 사용량 | AMP |
| 클러스터 상태 | kube-state-metrics | cluster | 노드/파드 phase, requests/limits, 재시작, 네임스페이스 테넌트 라벨 | AMP |
| 컨트롤 플레인 | API server | cluster | 요청 수/inflight | AMP |
| 메시지 브로커 | Kafka(Strimzi `market-message`) / RabbitMQ API | cluster | consumer lag (group `order`, topic purchase·refund) | AMP |
| 데이터 스토어 | AWS/RDS, AWS/ElastiCache | (CloudWatch 기본) | Aurora CPU·Deadlocks·RowLockTime·ReplicaLag, Redis CPU·메모리·Evictions | CloudWatch |
| 파이프라인 자체 | 각 컬렉터 `:8888` | 자기 자신 scrape | 수신/거부/전송실패/큐/샘플링 | AMP |

### 2.3 메트릭 계층 (Tier) — 무엇을 어디에, 얼마나

| Tier | 대상 | 저장 | 해상도/보존 | 비용 통제 |
|---|---|---|---|---|
| **T0 — 알림 근거 (SLA)** | SLI 3종 `Requests/Errors/SlowRequests` (서비스별) | CloudWatch EMF + AMP | 1분 / 15개월(CW) | 차원 고정 (`Environment`, `Service`) — 커스텀 메트릭 = 서비스 수 × 3 × 2 |
| **T1 — 판단 지표** | 레코딩 규칙 결과: SLO·번레이트, 사가 비율, lag, 비용 | AMP | 30s~5m / 150일 | 규칙 파일로 고정된 시리즈 수 |
| **T2 — 진단 원천** | span metrics(라우트·토픽·트랙), KSM·kubelet·cAdvisor 허용 목록, 앱 OTLP | AMP | 15~30s / 150일 | `aggregation_cardinality_limit`, allowlist, 고카디널리티 속성 삭제 |
| **T3 — 사건 증거** | 샘플링된 트레이스, 로그 | X-Ray / CloudWatch Logs → S3 | 원본 / 30일 · 클래스별 TTL | tail sampling, 로그 레벨·노이즈 필터, PII 마스킹 |
| `[확장]` | 테넌트 span metrics, 결제·매출 메트릭, 결제 EMF | AMP / CW | T1·T2 와 같음 | 오버레이를 켜기 전에는 시리즈 0 |

**수집하지 않기로 한 것**: secrets/configmaps 메타(보안·무용), apiserver 지연 히스토그램(시리즈 폭증, EKS 관리형), cAdvisor 의 파일시스템/프로세스 세부, 파드 라벨 전체(`pod-template-hash` 등 카디널리티 폭증).

앱이 지켜야 할 이름·속성 규약: [`docs/TELEMETRY_CONTRACT.md`](TELEMETRY_CONTRACT.md)

---

## 3. 정제 (Refinement) — 버릴 것은 버리고, 같은 것은 같게, 위험한 것은 가리고

정제는 **가능한 한 원천 가까이(agent)** 에서 한다. 늦게 버릴수록 네트워크·CPU·저장 비용을 이미 쓴 뒤다.

### 3.1 로그 (agent `transform/logs-parse` → `filter/logs-noise` → `transform/logs-redact`)

| 단계 | 규칙 | 이유 |
|---|---|---|
| 포맷 정규화 | containerd/CRI-O/docker 포맷 자동 판별, 경로에서 namespace/pod/container 추출 | 런타임 무관 |
| 구조화 | `{` 로 시작하면 JSON 파싱 → attributes. `message`/`msg` → body | Logs Insights 필드 질의 |
| 레벨 통일 | `level`/`severity`/`log.level` → 대문자 + OTel severity_number. WARNING→WARN, ERR→ERROR, CRITICAL/PANIC→FATAL. 레벨 없으면 본문 키워드(error/exception/warn)로 추정, 그래도 없으면 INFO | 서비스 간 비교 가능 |
| 트레이스 연결 | `trace_id`/`traceId` (32 hex), `span_id` (16 hex) → OTel 필드 | 로그 ↔ 트레이스 |
| service.name | SDK 값 > `app.kubernetes.io/name` > `app` > Deployment/StatefulSet/DaemonSet > 컨테이너명. `unknown_service*` 는 무시 | 신호 간 조인 키 통일 |
| 노이즈 제거 | 최소 레벨 미만(dev=DEBUG, prod=INFO), 빈 본문, `kube-probe`/`ELB-HealthChecker`, `GET /health|ready|live|metrics` 액세스 로그 | 저장량의 큰 비중, 정보 가치 0 |
| PII/비밀 마스킹 | 이메일 `<email>`, 휴대폰 `<phone>`, 주민번호 `<rrn>`, 카드번호 `<card>`, JWT `<jwt>`, Bearer/Basic 토큰, `password=`/`token=`/`api_key=` 값. 같은 키 이름의 속성은 삭제 | 개인정보보호법·PCI, 로그 유출 시 피해 차단 |
| 크기 제한 | 본문 16KB, 속성값 4KB, 속성 64개 | 비정상 로그 폭주 차단 |
| Spring 필드 정리 | logstash JSON 의 `@timestamp`/`@version`/`level_value` 삭제, `traceId`/`spanId`(MDC) → OTel 필드 | 중복 제거, 로그 ↔ 트레이스 |
| 저장 전 평탄화(gateway) | service/namespace/pod/container/level 을 attributes 로 (`[확장]` tenant_id), 중복 리소스 속성은 제거 | Insights 쿼리 단순화, 이벤트당 저장 바이트 절감 |

### 3.2 트레이스 (gateway `transform/micrometer-semconv` → `filter/traces-noise` → `transform/traces-redact`)

| 규칙 | 이유 |
|---|---|
| Micrometer `uri`/`method`/`status` → `http.route`/`http.request.method`/`http.response.status_code`(int) | 계측 라이브러리와 무관하게 같은 이름 → span metrics·규칙·X-Ray 가 한 계약만 본다 |
| 서버 스팬 5xx → status `ERROR` | Micrometer 는 예외 없이 5xx 를 응답하면 상태를 UNSET 으로 둔다 → 가용성 SLI 누락 방지 |
| 헬스체크/메트릭/`/actuator/**` 스팬, kube-probe UA 스팬 제거 | SLO 왜곡 방지 (항상 성공하는 대량 요청) |
| `[확장]` `tenant.id` 확정: span 속성 > `x-tenant-id` 캡처 헤더 > 리소스 속성, 소문자 통일 | 테넌트 라벨링 |
| Authorization/Cookie/x-api-key 헤더, User-Agent 삭제 | 비밀값·고카디널리티 |
| `db.statement` 문자열 리터럴 → `'?'` | 쿼리 형태는 유지, 값(개인정보) 제거 |
| URL 쿼리의 token/password/key/secret/code 값 마스킹 | |

### 3.3 메트릭

| 위치 | 규칙 |
|---|---|
| agent scrape | **허용 목록** 방식: kubelet(볼륨·실행 파드), resource(노드 CPU/메모리), cAdvisor(CPU·메모리·네트워크·스로틀링·OOM)만 keep. pause 컨테이너/집계 cgroup 시리즈 drop. `id`/`name`/`image` 라벨 drop |
| agent scrape | 파드 라벨은 `app`/`app.kubernetes.io/name`→`service`, `version` 만 (labelmap 전체 금지) |
| agent scrape | 앱 메트릭의 `go_*`, `process_*`, `promhttp_*`, `*_created` drop |
| KSM | 메트릭 allowlist 35종, 네임스페이스 라벨은 `tenant-id`/`tenant-tier`/`team`/`cost-center` 만 |
| gateway | OTLP 메트릭에 `namespace`/`pod` 라벨 부여 (파드 간 시리즈 충돌 방지). `[확장]` `tenant_id`/`tenantId` → `tenant.id` 통일 |
| gateway | `client.address`, `network.peer.*`, `user_agent.original`, `order.id`, `user.id`, `session.id` 등 무한 카디널리티 속성 삭제 |
| gateway | PRW `external_labels` 로 모든 시리즈에 `cluster`, `environment` |
| KSM scrape | `honor_labels: true` — KSM 이 내보내는 `namespace`/`pod` 를 scrape 타겟 라벨이 덮어쓰지 않게 |

### 3.4 `[확장]` 결제 실패 코드 정규화 (gateway `transform/payment-normalize`)

PG 사마다 다른 원본 코드를 9개 카테고리로 분류한다 (표: TELEMETRY_CONTRACT 7.3).
원본 코드는 AMP 에 남기고(드릴다운), CloudWatch 에는 카테고리만 보낸다(차원 비용).

---

## 4. 가공 (Processing) — 원천 데이터를 판단 가능한 지표로

### 4.1 컬렉터 안에서의 가공 (gateway connectors)

| 커넥터 | 입력 → 출력 | 만드는 지표 |
|---|---|---|
| `span_metrics` | 전체 스팬(샘플링 **전**) → 메트릭 | `traces_span_metrics_calls_total`, `..._duration_seconds_bucket` — 서비스×라우트×메서드×상태코드×**토픽**×**canary/stable** RED. 카나리 분석과 사가 구간 지연의 원천 |
| `service_graph` | client/server 스팬 쌍 → 메트릭 | `traces_service_graph_request_total{client,server,failed}` — 의존성 에러율 |
| `count/logs` | 정제된 로그 → 메트릭 | `nebula_log_records_total{service,namespace,level}` — 로그량·에러 로그 추세 (CloudWatch 비용 선행 지표) |
| `[확장]` `span_metrics/tenant` | 테넌트 식별 서버/컨슈머 스팬 + DB 스팬 → 메트릭 | `traces_tenant_metrics_*` — 테넌트×티어×상태×db.system |
| `[확장]` `count/business` | 스팬 → 메트릭 | `nebula_payment_logical_errors_total` — **HTTP 2xx 인데 결제 실패** |
| `count/sli` | 서버 스팬 → CloudWatch EMF | `Requests`, `Errors`, `SlowRequests(>1s)` — CloudWatch Alarms 용 SLI |
| `delta_to_cumulative` | count 커넥터의 delta → cumulative | PRW 는 delta 를 받지 않는다 (없으면 조용히 유실) |

> span_metrics 는 tail sampling 이전에 있으므로 **샘플링 비율과 무관하게 100% 트래픽 기준**이다.
> gateway replica 간 같은 시리즈 충돌은 `collector=<pod>` 라벨로 구분하고 규칙에서 `sum` 한다.

### 4.2 AMP 레코딩 규칙 (`prometheus/rules/`)

| 파일 | 가공 결과 (대표) |
|---|---|
| `01-kubernetes` | `node:cpu_utilization:ratio`, `namespace:cpu_usage_vs_limit:ratio`, `pod:cpu_usage_vs_request:ratio` (Saturation, Q4) |
| `02-service-slo` | `service:requests/errors/error_ratio:rate5m`, `service:latency_seconds:p50/p95/p99_5m`, 라우트·의존성 지표, `service:sli_error:ratio_rate{5m..3d,30d}`, `service:sli_latency_bad:ratio_rate*`, `service:error_budget_remaining:ratio`, **`service:error_budget_exhaustion:hours`(Time to Burn Out)** |
| `04-business` | **주문 사가**: `saga:publish_failure:ratio_rate5m`, `saga:stock_rejection:ratio_rate15m`, `saga:completion:ratio1h`, `saga:consume_gap/compensation_gap:increase15m`, `saga_topic:consumer/producer_latency_seconds:p95_5m`, `messaging:kafka_consumer_lag:sum` |
| `05-cost` | 단가 상수 → `namespace/cluster:infra_cost_krw:rate1h`, `namespace:idle_cost_krw:rate1h` |
| `06-anomaly` | z-score(트래픽·에러율·CPU·에러 로그), `namespace:idle_resource_score:ratio1d` |
| `[확장]` `extensions/tenant` | `tenant:requests/error_ratio/latency`, `tenant:db_time_share:ratio5m`, `tenant:error_budget_burn:rate1h`(티어별 목표), `tenant:infra_cost_krw:rate1h` |
| `[확장]` `extensions/commerce-payment` | `funnel:stage_conversion:ratio1h{step}`, `payment_pg:system_failure_ratio:rate5m`, `payment_method:decline_ratio:rate15m`, `payment:logical_error_ratio:rate5m` |
| `[확장]` `extensions/margin` | `nebula:revenue/opex/margin_krw:increase1h`, `nebula:net_margin:ratio1h`, `nebula:margin_burn_krw:rate1h`, `nebula:bep_coverage:ratio1h`, `tenant:cost_efficiency:ratio1h` |

### 4.3 SLO 정의

| SLO | SLI | 목표 | 버짓(30일) |
|---|---|---|---|
| 가용성 | 서버 스팬 중 status≠ERROR 비율 | 99.9% | 0.1% |
| 지연 | 서버 스팬 중 1s 이하 비율 (= P95 < 1s) | 95% | 5% |
| 카나리 (배포 게이트) | canary 서버 스팬 에러율·P99 vs stable | 에러율 < 1% 이고 ≤ stable×2+0.5%p, P99 < 1.5s | 롤아웃당 5회 측정, 2회 실패 시 롤백 |
| `[확장]` 테넌트 SLA | 테넌트별 가용성 | enterprise 99.95 / pro 99.9 / free 99.5 | 티어별 |

번레이트 = 현재 에러율 ÷ 버짓. 멀티 윈도우 알림(14.4x@1h&5m, 6x@6h&30m → critical / 3x@1d&2h, 1x@3d&6h → warning).
Time to Burn Out = 남은 버짓 × 720h ÷ 현재(1h) 번레이트.

### 4.4 비용 모델

- 인프라 비용 = Σ(실행 중 파드 CPU requests × ₩/core·h + 메모리 requests × ₩/GiB·h). 단가는 규칙 파일 상수(데이터로 관리).
- 유휴 비용 = 네임스페이스 비용 × (1 − CPU 사용/requests).
- `[확장]` 테넌트 배분(공유 풀) = 테넌트 서버 처리시간 점유율 × 클러스터 비용.
- `[확장]` Total OpEx = 주문 변동비(원가·PG 수수료·배송비·쿠폰·마케팅) + 인프라.
- 모니터링 자체 비용 산정: [`docs/COST_ESTIMATE.md`](COST_ESTIMATE.md) (입력값은 실측으로 채운다).

---

## 5. 저장과 보존 (Hot / Cold / TTL)

| 데이터 | Hot (조회·알림) | Cold | 근거 |
|---|---|---|---|
| 메트릭 | AMP (기본 150일) | — | 추세/SLO 30일 + 분기 비교 |
| 애플리케이션 로그 | CloudWatch 30일 (dev 7일) | 선택: S3 (`archive_application_logs`) | 장애 분석 기간 |
| 감사 로그 | CloudWatch 90일 | **S3 7년(정책값)**: 30일 IA → 90일 Glacier IR → 365일 Deep Archive → 2,557일 만료, 선택적 Object Lock(WORM) | 법정 최소 5년(전자금융거래법 §22·시행령 §12, 전자상거래법 시행령 §6 대금결제 기록) + 분쟁 대응 여유. 실제 보존 대상·기간은 법무 확인 후 `archive_retention_days` 로 조정 |
| K8s 이벤트 | CloudWatch 14일 | — | 최근 장애 원인 추적 |
| EMF 원본 | CloudWatch 1일 | — | 메트릭 추출용 중간 산출물 |
| 트레이스 | X-Ray 30일 (AWS 고정) | — | 샘플링으로 양 제한 |

S3 경로: `logs/<class>/year=YYYY/month=MM/day=DD/` (Athena 파티션 프로젝션으로 바로 질의 가능).

---

## 6. 시각화 — 대시보드와 위젯 패턴

| 대시보드 | 질문 |
|---|---|
| Overview (Q1–Q5) | 클러스터 건강 → 서비스 에러 → 지연 → 리소스 → 시스템 개요 (어디부터 볼지) |
| Service SLO & Golden Signals | **Gauge with Thresholds**(30일 가용성·남은 버짓), **Time to Burn Out**, 번레이트, **Time Series with Goal Line**(SLO 점선), 라우트·의존성, X-Ray 서비스 맵, 에러 로그, **Actionable Links** |
| Order Saga & Messaging | 사가 단계별 이벤트·완료율, 발행 실패율, 단계 사이에 멈춘 건수(보상 누락), 재고 거절률, 취소 사유, Kafka lag·토픽별 consumer/producer 지연·에러 |
| Infra Cost & Efficiency | 클러스터/네임스페이스 비용(₩/h), 유휴 비용·비율, 월 환산, 유휴 점수 |
| (Service SLO 안) 배포 — canary vs stable | 트랙별 에러율·P99 + 분석 기준선(1%, 1.5s) |
| `[확장]` Ext / Funnel & Payments · Tenants · Margin | 퍼널 Drop %, PG 실패 원인 분리, 테넌트 Noisy Neighbor·비용, Net Margin 게이지 |
| Data Stores | Aurora(CPU·커넥션·Deadlock·Row Lock·Blocked Tx·Replica Lag), Redis(CPU·메모리·Evictions·Hit Rate) |
| Telemetry Pipeline | 수신량, **정제로 제거된 양**, tail sampling 결정, 전송 실패, 큐, 카디널리티, 로그량 |

규칙: 상태색(초록/노랑/빨강)은 임계값에만, 한 패널에 한 단위(이중 축 금지), 목표는 점선, 단일 시리즈는 범례 생략.
대시보드는 `grafana/generate_dashboards.py` 가 생성한다 (JSON 직접 수정 금지).

---

## 7. 경보 — 무엇이 트리거인가 (Trigger)

**두 경로, 하나의 수신 채널**
1. **CloudWatch Alarms (Alertmanager 대체, SLA 확정 경보)** — EMF 로 보낸 SLI(`Requests/Errors/SlowRequests`)와 AWS 기본 메트릭(Aurora/Redis), 로그 유입 heartbeat. AMP 경로가 죽어도 독립적으로 동작한다. `[확장]` 결제 알람(`enable_business_extensions`).
2. **AMP 알림 규칙 (조기 경보)** — 번레이트, 주문 사가, 이상탐지, 쿠버네티스, 파이프라인 (`[확장]` 테넌트·결제·마진). 관리형 Alertmanager 가 SNS 로만 전달 (self-hosted Alertmanager 없음).

| 심각도 | SNS 토픽 | 반복 | 예 |
|---|---|---|---|
| critical | `<env>-alerts-critical` | 1h | SLA 위반, 14.4x/6x 번레이트, 사가 발행 실패·정지·보상 누락, 파이프라인 단절 (`[확장]` PG 타임아웃, 논리 오류, 역마진) |
| warning | `<env>-alerts-warning` | 4h | 지속 번레이트, 노드 압박, CrashLoop, Kafka 적체, 재고 거절 급증 (`[확장]` Noisy Neighbor, 카드 거절률) |
| info | warning 토픽, 하루 1회 묶음 | 24h | 유휴 리소스, 트래픽 이상, CPU 스로틀링 |

억제: 같은 서비스에 critical 이 있으면 warning/info 억제, gateway 부재 시 '데이터 없음' 계열 억제.
모든 알림은 런북 링크를 가진다 → [`docs/RUNBOOK.md`](RUNBOOK.md).

**배포 안전장치**: service-order 는 Argo Rollouts canary(50% → 3분 → 분석). `nebula-slo-canary` 가 AMP 에서 canary 의 절대 에러율·P99 + stable 대비 상대 에러율을 1분마다 5회 측정, 2회 실패 시 자동 롤백.
상대 기준은 외부 장애(둘 다 나쁨)와 배포 결함(canary 만 나쁨)을 구분하기 위한 것이다. 컨트롤러는 IRSA(`aps:QueryMetrics`)로 SigV4 질의한다 (Nebula-Platform).

---

## 8. Incident Decision Flow — 설계 판단 기록

| Key | 질문 | 이 저장소의 답 |
|---|---|---|
| Cost | 진짜로 줄여야 하는 비용은? | 저장 비용의 대부분은 로그·고카디널리티 메트릭 → agent 단계 정제·허용 목록, tail sampling, CloudWatch 커스텀 메트릭은 SLI 3종만. 없는 기능의 지표(테넌트·결제)는 기본에서 제외. 관리형 서비스로 운영 인력 비용 제거 |
| Portability | 벤더에 종속되면 안 되는 계층은? | 계측(Micrometer·OTLP)과 정제/가공(컬렉터 설정) — AWS 종속은 exporter 와 Terraform 에만 |
| Structure | 감당 가능한 구조인가? | agent/gateway/cluster 3역할 + 관리형 백엔드. 자체 운영하는 상태 저장 컴포넌트 0개 |
| Trigger | 모니터링 시작점에 따라 어떻게 설계할까? | 지표를 다 모은 뒤 경보를 고르는 대신, SLO/비즈니스 질문에서 SLI 를 정하고 필요한 데이터만 수집 |
| Flow | 연결된 흐름인가? | 공통 키 `service.name`·`trace_id`·`messaging.destination.name` 으로 메트릭 → 트레이스 → 로그 이동. 주문 → Kafka → 재고 → 취소가 한 트레이스 |
| Operability | 계정 분리 시 유지되는가? | 워크로드 계정마다 같은 차트, 저장은 `cross-account-ingest` 역할로 모니터링 계정에 집약. 특정 고객 전용 라우팅은 `routing/logs` 에 tenant 조건 추가 |

---

## 9. 비용·카디널리티 예산 (가이드)

| 항목 | 상한 | 장치 |
|---|---|---|
| span_metrics 시리즈 | 5,000 / gateway | `aggregation_cardinality_limit` |
| `[확장]` 테넌트 span_metrics | 10,000 / gateway | 라우트 차원 제외 |
| scrape 타겟당 샘플 | 20,000 | `HighCardinalityTarget` 알림 |
| CloudWatch 커스텀 메트릭 | 3 × (서비스 수 + 1) (`[확장]` + 결제 차원 조합) | EMF `metric_declarations` 로 고정 |
| 트레이스 저장 | baseline dev 50% / staging 20% / prod 5% + 에러·지연 100% | tail sampling |
| 로그 | prod INFO 이상, 헬스체크 제거 | `pipeline.logs.minSeverityNumber` |

`Nebula / Telemetry Pipeline` 대시보드의 "정제로 제거된 양"이 절감 효과를 보여준다.

---

## 10. 검증

| 대상 | 방법 | 명령 |
|---|---|---|
| Helm 차트 | lint + 렌더링 | `scripts/validate.sh` |
| 컬렉터 설정 | **렌더링된 ConfigMap 을 실제 otelcol-contrib 0.162.0 으로 `validate`** (기본 + 확장 오버레이) | `helm template … \| python3 scripts/validate_collector.py` |
| 레코딩/알림 규칙 | `promtool check rules` + **단위 테스트** — 기본: SLO 번레이트, 사가(발행 실패·정지·보상 누락), **카나리 분석 쿼리**, 비용, 파이프라인 / 확장: 퍼널·PG 분류·Noisy Neighbor·테넌트 SLA·역마진 | `promtool test rules rules.test.yaml extensions.test.yaml` |
| Terraform | fmt + validate | `scripts/validate.sh` |
| 대시보드 | 생성물 최신 여부 + 모든 PromQL 파싱 | `scripts/validate.sh` |
| 전체 흐름 | 로컬 E2E: 시뮬레이터(Micrometer 모양 스팬·사가·canary) → agent → gateway → Prometheus(같은 규칙) → Grafana(같은 대시보드) | `tools/local-stack/README.md` |

CI: `.github/workflows/validate.yml` 이 PR 마다 위 검사를 실행한다.

---

## 11. 한계와 다음 단계 (Phase 3)

- **확장 지표 활성화**: 테넌트·결제(PG)·매출 이벤트가 서비스에 생기면 오버레이·확장 규칙을 켠다 (계약: TELEMETRY_CONTRACT 7장).
- **사가 단건 추적**: 지금은 집계 카운터(단계 간 건수 차이)로 누락을 감지한다. 어떤 주문이 멈췄는지는 트레이스/로그로 찾는다 — 주문 상태 테이블 기반 대사(reconciliation) 잡이 다음 단계.
- **Kafka 발행 실패 재처리**: 감지까지 구현. 아웃박스 패턴은 서비스 코드 변경 사항.

- **유령 셀러/이탈 예측, 외부 요인(커뮤니티 유입) 결합 예측**: 현재는 규칙 기반 신호(Queue Lag × Error Spike, 거절률 z-score)까지. 예측 모델은 S3 아카이브 + Athena/SageMaker 로 학습 후 점수를 메트릭으로 되돌리는 구조가 필요하다.
- **봇 Think Time 분석**: 세션 단위 이벤트가 필요하다(현재는 집계 카운터). 세션 이벤트 스트림(Kinesis) 설계 필요.
- **역마진 서킷 브레이커 자동 실행**: 알림까지 구현. SNS → Lambda → 기능 플래그(쿠폰 발급 제한) 연결은 앱 측 플래그 시스템 확정 후.
- **z-score 계절성**: 1일 창 기준. 요일 패턴이 강하면 `offset 1w` 비교로 교체.
- **AMP 보존 기간 연장**이 필요하면 워크스페이스 retention 설정 또는 장기 집계 메트릭을 S3 로 내보내는 작업 추가.
