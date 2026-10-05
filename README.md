# Nebula Monitoring Stack

OpenTelemetry + AWS 관리형 서비스(AMP · AMG · CloudWatch · X-Ray)로 만든 Nebula Platform 관측성 스택.
**"무엇을 수집하고, 어떻게 정제하고, 어떻게 가공해서, 언제 개입할 것인가"** 를 코드로 구현했다.

- 설계 문서: [docs/OBSERVABILITY_DATA_PIPELINE.md](docs/OBSERVABILITY_DATA_PIPELINE.md) — 질문 → 데이터 → 정제 → 가공 → 판단
- 앱 계측 규약: [docs/TELEMETRY_CONTRACT.md](docs/TELEMETRY_CONTRACT.md)
- 알림 대응: [docs/RUNBOOK.md](docs/RUNBOOK.md)

## 아키텍처

```
App (OTel SDK / stdout JSON)
   │ OTLP  ─────────────►  agent (DaemonSet)      로그·kubelet·cAdvisor 수집, k8s 메타, 파싱, PII 마스킹, 노이즈 제거
   │                          │ traceID load-balancing
KSM / API server / Events ─► cluster (Deployment) 클러스터 범위 단일 수집, 브로커 Consumer Lag
                              ▼
                         gateway (Deployment, HPA, IRSA)
                           테넌트 라벨링 · span_metrics(RED/테넌트) · service_graph · 로그/결제 카운트
                           PG 실패코드 분류 · tail sampling(에러/지연/결제실패 100%)
        ┌──────────────┬───────────────┬──────────────────────────┬──────────────────────┐
        ▼              ▼               ▼                          ▼                      ▼
   AMP(메트릭)     X-Ray(트레이스)   CloudWatch Logs              CloudWatch Metrics     S3 (감사 로그 7년)
   + 레코딩/알림 규칙                 app / audit / events         (EMF SLI·결제)         ← Firehose
        │                                                         │
        └── AMP Alertmanager ──► SNS (critical / warning) ◄── CloudWatch Alarms (SLA·결제·DB·파이프라인)
                                         │
                               AMG 대시보드 7종 (Overview · SLO · Business · Tenants · FinOps · Data Stores · Pipeline)
```

## 저장소 구조

```
helm/
  otel-collector/            # agent / gateway / cluster 3-tier 차트 (수집·정제·가공 설정이 values.yaml 에 있음)
  kube-state-metrics/        # KSM values (메트릭 allowlist, 테넌트 네임스페이스 라벨)
prometheus/
  rules/                     # AMP 레코딩·알림 규칙 (k8s, 서비스 SLO, 테넌트, 비즈니스, FinOps, 이상탐지, 파이프라인)
  tests/rules.test.yaml      # promtool 단위 테스트
  alertmanager/              # AMP Alertmanager → SNS 라우팅 템플릿
grafana/
  generate_dashboards.py     # 대시보드 생성기 (JSON 직접 수정 금지)
  dashboards/*.json
terraform/
  environments/dev/          # AMP·AMG·알람·로그·아카이브·X-Ray·terraform_new 연결(IRSA)
  modules/
    amp/ amg/ xray/ iam-irsa/
    cloudwatch-alarms/       # SNS 2토픽 + SLA/결제/Aurora/Redis/파이프라인 알람
    log-analytics/           # 로그 그룹(클래스별 TTL), 메트릭 필터, Logs Insights 저장 쿼리
    log-archive/             # CloudWatch → Firehose → S3 (7년, Glacier)
    cross-account-ingest/    # 계정 분리 운영용 수집 역할
k8s/
  otel-operator/             # 자동 계측 Instrumentation (tail sampling 전제 설정)
  argo-rollouts/             # SLO 기반 canary 자동 롤백 분석 템플릿
scripts/
  deploy.sh / deploy-target-monitoring.ps1   # 전체 배포
  provision-grafana.sh       # AMG 데이터소스·대시보드 업로드
  validate.sh                # 전체 검증 (CI 와 동일)
tools/
  telemetry-simulator/       # 계약대로 OTLP 데이터를 만드는 시뮬레이터 (시나리오: pg-timeout, noisy, deficit, bot)
  local-stack/               # 로컬 E2E: simulator → agent → gateway → Prometheus → Grafana
```

## 배포

```bash
# 0) terraform_new 인프라(EKS, Aurora, Redis)가 먼저 배포되어 있어야 한다
# 1) 전체 배포: Terraform → kube-state-metrics → OTel Collector → Grafana
./scripts/deploy.sh dev            # Windows: .\scripts\deploy-target-monitoring.ps1 -Environment dev
```

수동 배포 / 값 설명은 [TARGET_INFRASTRUCTURE_INTEGRATION.md](TARGET_INFRASTRUCTURE_INTEGRATION.md),
Terraform 변수(알림 수신자, 핵심 서비스, Aurora/Redis 대상, 보존 기간)는 `terraform/environments/dev/variables.tf`.

앱 연결:
```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://otel-collector.monitoring.svc:4318   # 같은 노드의 agent 로 전달됨
  - name: OTEL_TRACES_SAMPLER
    value: parentbased_always_on                       # 샘플링은 gateway 가 결정
```
또는 `k8s/otel-operator/instrumentation.yaml` + `instrumentation.opentelemetry.io/inject-<lang>` 어노테이션.

## 로컬에서 확인하기 (AWS 불필요)

```bash
cd tools/local-stack && python3 render.py && docker compose up -d
python3 ../telemetry-simulator/simulate.py --endpoint http://localhost:4318 --scenario pg-timeout
# Grafana http://localhost:3000 → Nebula 폴더,  Prometheus http://localhost:9090/alerts
```

## 검증

```bash
./scripts/validate.sh
```
- Helm 4개 환경 렌더링 → **렌더링된 컬렉터 설정을 실제 otelcol-contrib 로 validate**
- `promtool check rules` + 규칙 단위 테스트 (SLO 번레이트, 퍼널, PG 분류, Noisy Neighbor, 비용·역마진, 파이프라인)
- 대시보드 생성물 최신 여부 + 모든 PromQL 파싱, 런북 앵커 존재
- Terraform fmt / validate

PR 마다 `.github/workflows/validate.yml` 이 같은 검사를 실행한다.

## 기타 문서

- [docs/AMG_GUIDE.md](docs/AMG_GUIDE.md) · [docs/CLOUDWATCH_ALARMS_GUIDE.md](docs/CLOUDWATCH_ALARMS_GUIDE.md) · [docs/XRAY_SERVICE_MAP_GUIDE.md](docs/XRAY_SERVICE_MAP_GUIDE.md)
- [docs/AUTO_INSTRUMENTATION.md](docs/AUTO_INSTRUMENTATION.md) · [docs/ENVIRONMENT_VARIABLES.md](docs/ENVIRONMENT_VARIABLES.md)
