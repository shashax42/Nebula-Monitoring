# Nebula Observability — 데이터 수집 · 정제 · 가공 설계

> 출발점은 "무엇을 수집할 수 있나"가 아니라 **"어떤 문제를 언제 개입해서 해결할 것인가"** 다 (Top-down).
> 그래서 이 문서는 질문 → 데이터 → 정제 → 가공 → 판단(대시보드·알림) 순서로 쓴다.
> 각 단계는 저장소의 실제 파일과 1:1 로 연결되며, 모든 설정은 실제 바이너리로 검증된다(10장).

---

## 0. 참고 설계(Nebula Platform / Observability) ↔ 구현 대응표

| 참고 설계 항목 | 구현 위치 |
|---|---|
| Phase 2: OTel Collector (Metrics scrape, Logs collection, **Tenant labeling/routing**, **Sampling + filtering**) | `helm/otel-collector` agent·gateway·cluster |
| OTel Collector Sidecar **or DaemonSet** | agent = DaemonSet (노드 로컬 수집) |
| AMP = Prometheus 대체 (메트릭 저장) | gateway `prometheus_remote_write/amp`, `terraform/modules/amp` |
| CloudWatch Logs = Loki 대체 (로그 저장, Logs Insights) | gateway `awscloudwatchlogs/*`, `terraform/modules/log-analytics` (저장 쿼리 7종) |
| X-Ray = Zipkin 대체 (분산 추적, 서비스 맵) | gateway `awsxray` (tail sampling 후) |
| AMG = Grafana 대체 (대시보드, Alerting) | `grafana/dashboards/*.json`, `scripts/provision-grafana.sh` |
| **CloudWatch Alarms/SNS = Alertmanager 대체** (SLA breach, Error/Latency alerts) | `terraform/modules/cloudwatch-alarms` (EMF SLI 기반) + AMP 관리형 Alertmanager → 같은 SNS |
| Golden Signals: Latency P99 / Traffic by tenant_id / Errors 5xx+Business / Saturation | `02-service-slo`, `03-tenant`, `01-kubernetes` 규칙 |
| Transactional Event Flow: 장바구니 → 주문 → 결제요청(PG) → 결제완료(DB Commit), Drop %, Logical Error | `04-business` 규칙 + `count/business` 커넥터 |
| 결제 실패 코드(PG 응답): 카드 한도 초과 vs PG 타임아웃 | gateway `transform/payment-normalize` |
| Consumer Lag (Kafka/RabbitMQ): API 정상인데 후행 로직 밀림 | cluster `kafka_metrics`/`rabbitmq` + `AsyncLagWhileAPIHealthy` |
| tenant_id 트레이싱 + DB Lock Wait: Noisy Neighbor vs 고객 데이터셋 문제 | `span_metrics/tenant` + `TenantNoisyNeighbor` + Aurora RowLockTime |
| Multi-tenancy & Cost Efficiency (tenant_id 비용, SLA/Tiered pricing) | `05-finops` 테넌트 비용 배분·효율, 티어별 SLO |
| Anomaly Alert / Idle Resource Score | `06-anomaly` |
| Cold Data (7 year / S3), TTL Data | `terraform/modules/log-archive`, 로그 클래스별 retention |
| 역마진: Revenue vs Total OpEx, BEP, Net Margin 게이지(5%/0%), Burn Rate ₩/hr, D+? 예측 | `05-finops` + `Nebula / FinOps & Margin` 대시보드 |
| Reliability & GitOps: 배포 직후 이상 → 확률 기반 Auto-Rollback | `k8s/argo-rollouts/analysis-template.yaml` |
| 위젯: Gauge with Thresholds / Time Series with Goal Line / Time to Burn Out / Actionable Links | `Nebula / Service SLO` 대시보드 상단 |
| Operability: 계정 분리 (prod-us ↔ prod-eu, customer-A) | `terraform/modules/cross-account-ingest`, `routing/logs` |

---

## 1. 아키텍처

```
 App Pods (OTel SDK, stdout JSON)                   kube-state-metrics   API server   k8s Events   Kafka/RabbitMQ
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
 │ 정제: 헬스체크 스팬 제거, 민감 속성 삭제/SQL·URL 마스킹, 테넌트 라벨링(tenant.id), 고카디널리티 속성 제거 │
 │ 가공: span_metrics(서비스·라우트 RED) · span_metrics/tenant(테넌트 RED + DB 시간) · service_graph      │
 │       count/logs(로그량) · count/business(논리 오류) · count/sli(CloudWatch SLI) · PG 실패코드 분류     │
 │ 샘플링: tail_sampling (에러·지연·결제실패 100%, 핵심 서비스 50%, 나머지 10%)                             │
 └──────┬──────────────────┬───────────────────┬──────────────────────┬──────────────────────┬──────────┘
        ▼                  ▼                   ▼                      ▼                      ▼
   AMP (메트릭)        X-Ray (트레이스)   CloudWatch Logs           CloudWatch Metrics      (계정 분리 시
   + 레코딩 규칙        서비스 맵          app / audit / events      Nebula/Application      cross-account
   + 알림 규칙                             └ audit → Firehose → S3   (EMF: SLI·결제)          역할 assume)
        │                                        (7년, Glacier)            │
        ▼                                                                  ▼
   AMP Alertmanager ─────────────► SNS (critical / warning) ◄──── CloudWatch Alarms (SLA·결제·DB·파이프라인)
        │
        ▼
   AMG (Grafana): Overview · Service SLO · Business · Tenants · FinOps · Data Stores · Pipeline
```

**왜 3계층인가 (Structure: 감당 가능한 최소 조합)**
- agent 는 노드 로컬 일(파일 읽기, kubelet)만 하고 AWS 자격증명이 없다 → 노드 침해 시 영향 최소화.
- gateway 만 IRSA 를 갖고 내보낸다 → 권한·엔드포인트·비용 통제 지점이 하나.
- tail sampling 과 service_graph 는 "한 트레이스의 모든 스팬이 같은 곳"에 있어야 정확하다 → agent 가 traceID 로 gateway 를 고른다.
- KSM·apiserver·Events 는 클러스터에 하나뿐이므로 한 번만 수집해야 한다 → cluster (replicas=1, Recreate).

**벤더 종속 경계 (Portability)**: 앱은 OTLP 표준만 안다. AWS 종속은 gateway exporter 와 Terraform 에만 있다.
다른 백엔드로 옮길 때 바꾸는 것은 gateway `exporters:` 블록뿐이다.

---

## 2. 무엇을 수집하나 — 질문에서 데이터로

### 2.1 Top-Down 질문 → 데이터 → 인사이트

| 질문 (언제 개입해야 하나?) | 수집 데이터 | 얻는 인사이트 |
|---|---|---|
| 결제가 왜 실패하나? | 결제 성공/실패 이벤트 + **PG 원본 응답 코드** | 카드 한도 초과(고객) vs PG 타임아웃(시스템) 구분 → 대응 주체가 다르다 |
| API 는 정상인데 왜 주문 처리가 늦나? | 브로커 **Consumer Lag** | 후행 비즈니스 로직 적체 (HTTP 지표로는 안 보이는 장애) |
| 특정 고객 때문에 전체가 느린가? | **tenant_id 가 박힌 트레이스** + DB 스팬 시간 + Aurora Lock Wait | Noisy Neighbor(트래픽) vs 고객 데이터셋/쿼리 문제 |
| 사용자가 체감하는 품질은? | 서버 스팬(전량) → Latency P99, Traffic(tenant 별), Errors(5xx + 비즈니스 오류) | SLO / 에러 버짓 / 번레이트 |
| 퍼널 어디서 이탈하나? | 단계별 이벤트 카운터 | 단계별 Drop %, 전환율 추세, 봇 재고 잠식 |
| 팔수록 손해인가? | 매출·변동비(쿠폰/배송/PG 수수료) + 인프라 비용 신호 | Net Margin, Burn Rate, BEP, 역마진 예측 |
| 자원을 낭비하고 있나? | requests vs 실제 사용량 | 유휴 점수, 낭비 비용, 다운사이징 후보 |

### 2.2 신호 카탈로그

| 신호 | 출처 | 수집기 | 주요 데이터 | 저장 |
|---|---|---|---|---|
| 컨테이너 로그 | `/var/log/pods` (stdout/stderr) | agent `file_log` | 메시지, 레벨, trace_id, tenant_id | CW Logs `application` |
| 감사/결제 로그 | 앱 로그 중 `log.type=audit` / `event.domain=payment` | agent → gateway 라우팅 | 결제 처리 이력 | CW Logs `audit` (90일) → S3 7년 |
| K8s 이벤트 | events.k8s.io watch | cluster `k8sobjects` | OOMKilled, FailedScheduling, BackOff, Evicted | CW Logs `events` (14일) |
| 트레이스 | 앱 OTel SDK | agent → gateway | 서버/클라이언트/DB 스팬, tenant.id, payment.* | X-Ray (샘플링 후) |
| 앱 메트릭 | 앱 OTel SDK / `prometheus.io/scrape` | agent | 런타임, 비즈니스 카운터(퍼널·결제·매출·원가) | AMP |
| 노드/파드 자원 | kubelet `/metrics/resource`, cAdvisor | agent (노드 로컬) | CPU/메모리/네트워크/스로틀링/OOM | AMP |
| PVC | kubelet `/metrics` | agent | 볼륨 사용량 | AMP |
| 클러스터 상태 | kube-state-metrics | cluster | 노드/파드 phase, requests/limits, 재시작, 네임스페이스 테넌트 라벨 | AMP |
| 컨트롤 플레인 | API server | cluster | 요청 수/inflight | AMP |
| 메시지 브로커 | Kafka / RabbitMQ API | cluster (선택) | consumer lag, ready 메시지 | AMP |
| 데이터 스토어 | AWS/RDS, AWS/ElastiCache | (CloudWatch 기본) | Aurora CPU·Deadlocks·RowLockTime·ReplicaLag, Redis CPU·메모리·Evictions | CloudWatch |
| 파이프라인 자체 | 각 컬렉터 `:8888` | 자기 자신 scrape | 수신/거부/전송실패/큐/샘플링 | AMP |

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
| 저장 전 평탄화(gateway) | service/namespace/pod/container/level/tenant_id 를 attributes 로, 중복 리소스 속성은 제거 | Insights 쿼리 단순화, 이벤트당 저장 바이트 절감 |

### 3.2 트레이스 (gateway `filter/traces-noise` → `transform/tenant` → `transform/traces-redact`)

| 규칙 | 이유 |
|---|---|
| 헬스체크/메트릭 엔드포인트 스팬, kube-probe UA 스팬 제거 | SLO 왜곡 방지 (항상 성공하는 대량 요청) |
| `tenant.id` 확정: span 속성 > `x-tenant-id` 캡처 헤더 > 리소스 속성, 소문자 통일 | 테넌트 라벨링 |
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
| gateway | OTLP 메트릭에 `namespace`/`pod` 라벨 부여 (파드 간 시리즈 충돌 방지), `tenant_id`/`tenantId` → `tenant.id` 통일 |
| gateway | `client.address`, `network.peer.*`, `user_agent.original`, `order.id`, `user.id`, `session.id` 등 무한 카디널리티 속성 삭제 |
| gateway | PRW `external_labels` 로 모든 시리즈에 `cluster`, `environment` |
| KSM scrape | `honor_labels: true` — KSM 이 내보내는 `namespace`/`pod` 를 scrape 타겟 라벨이 덮어쓰지 않게 |

### 3.4 결제 실패 코드 정규화 (gateway `transform/payment-normalize`)

PG 사마다 다른 원본 코드를 9개 카테고리로 분류한다 (표: TELEMETRY_CONTRACT 5장).
원본 코드는 AMP 에 남기고(드릴다운), CloudWatch 에는 카테고리만 보낸다(차원 비용).

---

## 4. 가공 (Processing) — 원천 데이터를 판단 가능한 지표로

### 4.1 컬렉터 안에서의 가공 (gateway connectors)

| 커넥터 | 입력 → 출력 | 만드는 지표 |
|---|---|---|
| `span_metrics` | 전체 스팬(샘플링 **전**) → 메트릭 | `traces_span_metrics_calls_total`, `..._duration_seconds_bucket` — 서비스×라우트×메서드×상태코드 RED. 앱 계측 없이도 Golden Signals |
| `span_metrics/tenant` | 테넌트 식별 서버/컨슈머 스팬 + DB 스팬 → 메트릭 | `traces_tenant_metrics_*` — 테넌트×티어×상태×db.system. 라우트 차원을 빼서 카디널리티 분리 |
| `service_graph` | client/server 스팬 쌍 → 메트릭 | `traces_service_graph_request_total{client,server,failed}` — 의존성 에러율 |
| `count/logs` | 정제된 로그 → 메트릭 | `nebula_log_records_total{service,namespace,level,tenant_id}` — 로그량·에러 로그 추세 (CloudWatch 비용 선행 지표) |
| `count/business` | 스팬 → 메트릭 | `nebula_payment_logical_errors_total` — **HTTP 2xx 인데 결제 실패** |
| `count/sli` | 서버 스팬 → CloudWatch EMF | `Requests`, `Errors`, `SlowRequests(>1s)` — CloudWatch Alarms 용 SLI |
| `delta_to_cumulative` | count 커넥터의 delta → cumulative | PRW 는 delta 를 받지 않는다 (없으면 조용히 유실) |

> span_metrics 는 tail sampling 이전에 있으므로 **샘플링 비율과 무관하게 100% 트래픽 기준**이다.
> gateway replica 간 같은 시리즈 충돌은 `collector=<pod>` 라벨로 구분하고 규칙에서 `sum` 한다.

### 4.2 AMP 레코딩 규칙 (`prometheus/rules/`)

| 파일 | 가공 결과 (대표) |
|---|---|
| `01-kubernetes` | `node:cpu_utilization:ratio`, `namespace:cpu_usage_vs_limit:ratio`, `pod:cpu_usage_vs_request:ratio` (Saturation, Q4) |
| `02-service-slo` | `service:requests/errors/error_ratio:rate5m`, `service:latency_seconds:p50/p95/p99_5m`, 라우트·의존성 지표, `service:sli_error:ratio_rate{5m..3d,30d}`, `service:sli_latency_bad:ratio_rate*`, `service:error_budget_remaining:ratio`, **`service:error_budget_exhaustion:hours`(Time to Burn Out)** |
| `03-tenant` | `tenant:requests/error_ratio/latency`, `tenant:db_time_share:ratio5m`, `tenant:db_latency_seconds:p99_5m`, `tenant:server_time_share:ratio1h`, `tenant:error_budget_burn:rate1h`(티어별 목표) |
| `04-business` | `funnel:stage_conversion:ratio1h{step}`, `funnel:conversion:ratio1h`, `funnel:cart_hoarding:ratio15m`, `payment_pg:system_failure_ratio:rate5m`, `payment_method:decline_ratio:rate15m`, `payment:pg_latency_seconds:p99_5m`, `payment:logical_error_ratio:rate5m`, `messaging:*_lag` |
| `05-finops` | 단가 상수 → `namespace/cluster:infra_cost_krw:rate1h`, `tenant:infra_cost_krw:rate1h`, `nebula:revenue/opex/margin_krw:increase1h`, `nebula:net_margin:ratio1h`, `nebula:margin_burn_krw:rate1h`, `nebula:bep_coverage:ratio1h`, `tenant:cost_efficiency:ratio1h` |
| `06-anomaly` | z-score(트래픽·에러율·CPU·에러 로그), `namespace:idle_resource_score:ratio1d` |

### 4.3 SLO 정의

| SLO | SLI | 목표 | 버짓(30일) |
|---|---|---|---|
| 가용성 | 서버 스팬 중 status≠ERROR 비율 | 99.9% | 0.1% |
| 지연 | 서버 스팬 중 1s 이하 비율 (= P95 < 1s) | 95% | 5% |
| 테넌트 SLA | 테넌트별 가용성 | enterprise 99.95 / pro 99.9 / free 99.5 | 티어별 |

번레이트 = 현재 에러율 ÷ 버짓. 멀티 윈도우 알림(14.4x@1h&5m, 6x@6h&30m → critical / 3x@1d&2h, 1x@3d&6h → warning).
Time to Burn Out = 남은 버짓 × 720h ÷ 현재(1h) 번레이트.

### 4.4 비용 모델

- 인프라 비용 = Σ(실행 중 파드 CPU requests × ₩/core·h + 메모리 requests × ₩/GiB·h). 단가는 규칙 파일 상수(데이터로 관리).
- 테넌트 배분(공유 풀) = 테넌트 서버 처리시간 점유율 × 클러스터 비용. (전용 네임스페이스 모델은 `tenant-id` 네임스페이스 라벨로 직접 합산)
- Total OpEx = 주문 변동비(원가·PG 수수료·배송비·쿠폰·마케팅) + 인프라. 인프라 신호가 없어도 변동비만으로 마진이 계산되도록 대체값 0 사용.

---

## 5. 저장과 보존 (Hot / Cold / TTL)

| 데이터 | Hot (조회·알림) | Cold | 근거 |
|---|---|---|---|
| 메트릭 | AMP (기본 150일) | — | 추세/SLO 30일 + 분기 비교 |
| 애플리케이션 로그 | CloudWatch 30일 (dev 7일) | 선택: S3 (`archive_application_logs`) | 장애 분석 기간 |
| 감사/결제 로그 | CloudWatch 90일 | **S3 7년**: 30일 IA → 90일 Glacier IR → 365일 Deep Archive → 2,557일 만료, 선택적 Object Lock(WORM) | 전자금융/전자상거래 거래기록 보존 |
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
| Business Flow & Payments | 퍼널 Drop %, 전환율 추세, 실패 원인 분리(색 = 책임 주체), PG 지연, 논리 오류, 카드사별 거절률, Consumer Lag |
| Tenants | tenant_id 별 트래픽·에러·P99, 티어별 SLA 번레이트, Noisy Neighbor 판별(점유율/호출수/P99/Row Lock), 테넌트 비용·효율 |
| FinOps & Margin | Net Margin 게이지(5%/0%), Burn Rate ₩/h, BEP, 6시간 뒤 예상 마진, Revenue vs Total OpEx, 비용 구성, 유휴 비용 |
| Data Stores | Aurora(CPU·커넥션·Deadlock·Row Lock·Blocked Tx·Replica Lag), Redis(CPU·메모리·Evictions·Hit Rate) |
| Telemetry Pipeline | 수신량, **정제로 제거된 양**, tail sampling 결정, 전송 실패, 큐, 카디널리티, 로그량 |

규칙: 상태색(초록/노랑/빨강)은 임계값에만, 한 패널에 한 단위(이중 축 금지), 목표는 점선, 단일 시리즈는 범례 생략.
대시보드는 `grafana/generate_dashboards.py` 가 생성한다 (JSON 직접 수정 금지).

---

## 7. 경보 — 무엇이 트리거인가 (Trigger)

**두 경로, 하나의 수신 채널**
1. **CloudWatch Alarms (Alertmanager 대체, SLA 확정 경보)** — EMF 로 보낸 SLI(`Requests/Errors/SlowRequests`, `PaymentRequests`, `PaymentLogicalErrors`)와 AWS 기본 메트릭(Aurora/Redis), 로그 유입 heartbeat. AMP 경로가 죽어도 독립적으로 동작한다.
2. **AMP 알림 규칙 (조기 경보)** — 번레이트, 테넌트, 비즈니스, FinOps, 이상탐지, 쿠버네티스, 파이프라인. 관리형 Alertmanager 가 SNS 로만 전달 (self-hosted Alertmanager 없음).

| 심각도 | SNS 토픽 | 반복 | 예 |
|---|---|---|---|
| critical | `<env>-alerts-critical` | 1h | SLA 위반, 14.4x/6x 번레이트, PG 타임아웃, 논리 오류, 역마진, 파이프라인 단절 |
| warning | `<env>-alerts-warning` | 4h | 지속 번레이트, 노드 압박, CrashLoop, Noisy Neighbor, 거절률 급증 |
| info | warning 토픽, 하루 1회 묶음 | 24h | 유휴 리소스, 트래픽 이상, CPU 스로틀링 |

억제: 같은 서비스에 critical 이 있으면 warning/info 억제, gateway 부재 시 '데이터 없음' 계열 억제.
모든 알림은 런북 링크를 가진다 → [`docs/RUNBOOK.md`](RUNBOOK.md).

**배포 안전장치**: Argo Rollouts `nebula-slo-canary` — canary 의 절대 에러율·P99 + stable 대비 상대 에러율을 1분마다 5회 측정, 2회 실패 시 자동 롤백.

---

## 8. Incident Decision Flow — 설계 판단 기록

| Key | 질문 | 이 저장소의 답 |
|---|---|---|
| Cost | 진짜로 줄여야 하는 비용은? | 저장 비용의 대부분은 로그·고카디널리티 메트릭 → agent 단계 정제·허용 목록, tail sampling, CloudWatch 커스텀 메트릭은 SLI 5종만. 관리형 서비스로 운영 인력 비용 제거 |
| Portability | 벤더에 종속되면 안 되는 계층은? | 계측(OTel SDK·OTLP)과 정제/가공(컬렉터 설정) — AWS 종속은 exporter 와 Terraform 에만 |
| Structure | 감당 가능한 구조인가? | agent/gateway/cluster 3역할 + 관리형 백엔드. 자체 운영하는 상태 저장 컴포넌트 0개 |
| Trigger | 모니터링 시작점에 따라 어떻게 설계할까? | 지표를 다 모은 뒤 경보를 고르는 대신, SLO/비즈니스 질문에서 SLI 를 정하고 필요한 데이터만 수집 |
| Flow | 연결된 흐름인가? | 공통 키 `service.name`·`tenant.id`·`trace_id` 로 메트릭 → 트레이스 → 로그 이동 (대시보드 링크, 로그 trace_id, X-Ray 인덱스) |
| Operability | 계정 분리 시 유지되는가? | 워크로드 계정마다 같은 차트, 저장은 `cross-account-ingest` 역할로 모니터링 계정에 집약. 특정 고객 전용 라우팅은 `routing/logs` 에 tenant 조건 추가 |

---

## 9. 비용·카디널리티 예산 (가이드)

| 항목 | 상한 | 장치 |
|---|---|---|
| span_metrics 시리즈 | 5,000 / gateway | `aggregation_cardinality_limit` |
| 테넌트 span_metrics | 10,000 / gateway | 라우트 차원 제외 |
| scrape 타겟당 샘플 | 20,000 | `HighCardinalityTarget` 알림 |
| CloudWatch 커스텀 메트릭 | ~ (서비스 수 × 3) + 결제 차원 조합 | EMF `metric_declarations` 로 고정 |
| 트레이스 저장 | baseline dev 50% / staging 20% / prod 5% + 에러·지연·결제실패 100% | tail sampling |
| 로그 | prod INFO 이상, 헬스체크 제거 | `pipeline.logs.minSeverityNumber` |

`Nebula / Telemetry Pipeline` 대시보드의 "정제로 제거된 양"이 절감 효과를 보여준다.

---

## 10. 검증

| 대상 | 방법 | 명령 |
|---|---|---|
| Helm 차트 | lint + 렌더링 | `scripts/validate.sh` |
| 컬렉터 설정 | **렌더링된 ConfigMap 을 실제 otelcol-contrib 0.162.0 으로 `validate`** | `helm template … \| python3 scripts/validate_collector.py` |
| 레코딩/알림 규칙 | `promtool check rules` + **단위 테스트**(SLO 번레이트, 퍼널, PG 분류, Noisy Neighbor, 테넌트 SLA, 비용·역마진, 파이프라인) | `promtool test rules prometheus/tests/rules.test.yaml` |
| Terraform | fmt + validate | `scripts/validate.sh` |
| 대시보드 | 생성물 최신 여부 + 모든 PromQL 파싱 | `scripts/validate.sh` |
| 전체 흐름 | 로컬 E2E: 시뮬레이터 → agent → gateway → Prometheus(같은 규칙) → Grafana(같은 대시보드) | `tools/local-stack/README.md` |

CI: `.github/workflows/validate.yml` 이 PR 마다 위 검사를 실행한다.

---

## 11. 한계와 다음 단계 (Phase 3)

- **유령 셀러/이탈 예측, 외부 요인(커뮤니티 유입) 결합 예측**: 현재는 규칙 기반 신호(Queue Lag × Error Spike, 거절률 z-score)까지. 예측 모델은 S3 아카이브 + Athena/SageMaker 로 학습 후 점수를 메트릭으로 되돌리는 구조가 필요하다.
- **봇 Think Time 분석**: 세션 단위 이벤트가 필요하다(현재는 집계 카운터). 세션 이벤트 스트림(Kinesis) 설계 필요.
- **역마진 서킷 브레이커 자동 실행**: 알림까지 구현. SNS → Lambda → 기능 플래그(쿠폰 발급 제한) 연결은 앱 측 플래그 시스템 확정 후.
- **z-score 계절성**: 1일 창 기준. 요일 패턴이 강하면 `offset 1w` 비교로 교체.
- **AMP 보존 기간 연장**이 필요하면 워크스페이스 retention 설정 또는 장기 집계 메트릭을 S3 로 내보내는 작업 추가.
