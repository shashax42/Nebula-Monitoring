# Nebula Monitoring Stack

OpenTelemetry + AWS 관리형 서비스(AMP · AMG · CloudWatch · X-Ray)로 만든 Nebula Platform 관측성 스택.
**"무엇을 수집하고, 어떻게 정제하고, 어떻게 가공해서, 언제 개입할 것인가"** 를 코드로 구현했다.

- 설계 문서: [docs/OBSERVABILITY_DATA_PIPELINE.md](docs/OBSERVABILITY_DATA_PIPELINE.md) — 질문 → 데이터 → 정제 → 가공 → 판단
- 앱 계측 규약: [docs/TELEMETRY_CONTRACT.md](docs/TELEMETRY_CONTRACT.md)
- 알림 대응: [docs/RUNBOOK.md](docs/RUNBOOK.md)
- 무엇을 기본으로 두고 무엇을 확장으로 뺐는지: [docs/adr/0001-core-vs-extension-telemetry.md](docs/adr/0001-core-vs-extension-telemetry.md)
- 모니터링 비용 산정: [docs/COST_ESTIMATE.md](docs/COST_ESTIMATE.md)

## 연결된 레포

| 레포 | 이 스택과의 연결 |
|---|---|
| nebula-services | Micrometer → OTLP(트레이스·메트릭), logstash JSON 로그, 주문 사가 단계 카운터 `nebula.commerce.funnel.events` |
| nebula-gitops | `observability-env`(OTLP 엔드포인트), service-order Argo Rollouts canary + `nebula-slo-canary` 분석(AMP), `platform/aws/envs/<env>` 모니터링 앱(ArgoCD) |
| Nebula-Platform | dev·staging·prod EKS, 서비스 DB(dev·staging RDS / prod Aurora)·Redis·Strimzi·SQS(staging), Argo Rollouts IRSA(AMP 조회), `enable_aws_platform_apps`, 이 스택이 remote state 로 읽는 output |
| nebula-ci-templates | 서비스 이미지 빌드·서명 → nebula-gitops 태그 갱신. 배포된 서비스의 텔레메트리가 이 스택으로 들어온다 |

## 아키텍처

```
nebula-services (Micrometer → OTLP, stdout JSON)
   │ OTLP  ─────────────►  agent (DaemonSet)      로그·kubelet·cAdvisor 수집, k8s 메타(+canary/stable), 파싱, PII 마스킹
   │                          │ traceID load-balancing
KSM / API server / Events ─► cluster (Deployment) 클러스터 범위 단일 수집, Kafka(Strimzi) Consumer Lag
Kafka(market-message)         ▼
                         gateway (Deployment, HPA, IRSA)
                           Micrometer 속성 → OTel 표준(+5xx=ERROR) · span_metrics(라우트·토픽·canary/stable RED)
                           service_graph · 로그 카운트 · tail sampling(에러/지연 100%)
        ┌──────────────┬───────────────┬──────────────────────────┬──────────────────────┐
        ▼              ▼               ▼                          ▼                      ▼
   AMP(메트릭)     X-Ray(트레이스)   CloudWatch Logs              CloudWatch Metrics     S3 (감사 로그, 7년 정책)
   + 레코딩/알림 규칙                 app / audit / events         (EMF SLI)              ← Firehose
        │   └──► Argo Rollouts 분석 (service-order canary vs stable → 자동 롤백)
        └── AMP Alertmanager ──► SNS (critical / warning) ◄── CloudWatch Alarms (SLA·DB·파이프라인)
                                         │
                               AMG 대시보드 6종 (Overview · Service SLO · Order Saga · Infra Cost · Data Stores · Pipeline)
```

기본 배포는 **지금 서비스가 실제로 내보내는 데이터만** 처리한다. 멀티테넌시·결제(PG)·매출/마진은 해당 기능이 생길 때 켜는 확장이다:
`-f helm/otel-collector/values-extension-business.yaml` · `terraform -var enable_business_extensions=true` · `provision-grafana.sh <env> --extensions`.

## 저장소 구조

```
helm/
  otel-collector/            # agent / gateway / cluster 3-tier 차트 (수집·정제·가공 설정이 values.yaml 에 있음)
    values-extension-business.yaml   # 확장 오버레이: 테넌트 라벨링·테넌트 RED, 결제 논리 오류·PG 코드 분류
  kube-state-metrics/        # KSM values (메트릭 allowlist, 네임스페이스 라벨)
prometheus/
  rules/                     # AMP 레코딩·알림 규칙 (k8s, 서비스 SLO, 주문 사가·Kafka, 인프라 비용, 이상탐지, 파이프라인)
    extensions/              # 확장 규칙 (테넌트, 구매 퍼널·결제, 마진) — 기본 미로드
  tests/                     # promtool 단위 테스트 (rules.test.yaml: 기본 + 카나리 쿼리, extensions.test.yaml)
  alertmanager/              # AMP Alertmanager → SNS 라우팅 템플릿
grafana/
  generate_dashboards.py     # 대시보드 생성기 (JSON 직접 수정 금지)
  dashboards/*.json          # 기본 6종, extensions/ 확장 3종
terraform/
  environments/dev/          # AMP·AMG·알람·로그·아카이브·X-Ray·Nebula-Platform 연결(remote state, IRSA). 환경은 workspace 로 나눈다
  modules/
    amp/ amg/ xray/ iam-irsa/
    cloudwatch-alarms/       # SNS 2토픽 + SLA/Aurora/Redis/파이프라인 알람 (결제 알람은 확장)
    log-analytics/           # 로그 그룹(클래스별 TTL), 메트릭 필터, Logs Insights 저장 쿼리
    log-archive/             # CloudWatch → Firehose → S3 (Glacier, 7년 정책값)
    cross-account-ingest/    # 계정 분리 운영용 수집 역할
k8s/
  otel-operator/             # (대안) Micrometer 를 못 쓰는 워크로드용 자동 계측
scripts/
  deploy.sh / deploy-target-monitoring.ps1   # 수동 배포
  render-gitops-values.sh    # Terraform output → nebula-gitops platform/aws/envs/<env> 값 (ArgoCD 배포)
  provision-grafana.sh       # AMG 데이터소스·대시보드 업로드
  validate.sh                # 전체 검증 (CI 와 동일)
tools/
  telemetry-simulator/       # 서비스와 같은 모양의 OTLP 시뮬레이터 (canary-bad, kafka-down, consumer-stall, compensation-gap, stock-out)
  local-stack/               # 로컬 E2E: simulator → agent → gateway → Prometheus → Grafana
```

## 배포 (GitOps)

환경(dev / staging / prod)마다 같은 순서. Terraform 루트는 `terraform/environments/dev` 하나이고 **환경 = workspace** 다
(dev 는 default workspace, 그 외에는 workspace 이름 = environment. 다르면 plan 단계에서 막는다).

```bash
ENV=prod
# 1) Nebula-Platform: environments/$ENV terraform apply  (EKS, ArgoCD, Argo Rollouts + AMP 조회 IRSA, 서비스 ConfigMap/Secret)
# 2) 이 레포: AMP·AMG·알람·collector IRSA (Platform output 의 클러스터·Aurora/RDS·Redis·SQS 를 자동으로 읽는다)
cd terraform/environments/dev
[ "$ENV" = dev ] || terraform workspace select -or-create "$ENV"
terraform apply -var environment="$ENV" -var enable_target_monitoring=true \
  -var target_state_bucket=<Nebula-Platform state 버킷>        # state 경로는 env/$ENV/terraform.tfstate
# 3) Terraform output → nebula-gitops platform/aws/envs/$ENV 값 기록 → PR → main
./scripts/render-gitops-values.sh "$ENV" ../nebula-gitops
# 4) Nebula-Platform: enable_aws_platform_apps = true → ArgoCD 가 kube-state-metrics + otel-collector + 카나리 분석 동기화
# 5) 대시보드
./scripts/provision-grafana.sh "$ENV"
```

Platform output 에 따라 만들어지는 데이터 스토어 알람: Aurora(prod: CPU·데드락·복제 지연), RDS(dev·staging: CPU·스토리지),
Redis(노드별 CPU·메모리·eviction), SQS(staging: 적체 나이, DLQ 비어 있지 않음).

ArgoCD 없이 바로 설치하려면 `./scripts/deploy.sh dev` (Windows: `.\scripts\deploy-target-monitoring.ps1 -Environment dev`).
Terraform 변수(알림 수신자, 핵심 서비스, 보존 기간, 확장)는 `terraform/environments/dev/variables.tf`.

서비스 연결은 nebula-gitops 가 한다 (`config-common/observability.yaml` → `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc:4318`).

## 로컬에서 확인하기 (AWS 불필요)

```bash
cd tools/local-stack && python3 render.py && docker compose up -d
python3 ../telemetry-simulator/simulate.py --scenario canary-bad     # 카나리 판정, kafka-down / compensation-gap …
# Grafana http://localhost:3000 → Nebula 폴더,  Prometheus http://localhost:9090/alerts
```

## 검증

```bash
./scripts/validate.sh
```
- Helm 4개 환경 + 확장 오버레이 렌더링 → **렌더링된 컬렉터 설정을 실제 otelcol-contrib 로 validate**
- `promtool check rules` + 규칙 단위 테스트 (SLO 번레이트, 사가 발행 실패·정지·보상 누락, **카나리 분석 쿼리**, 비용, 파이프라인 / 확장: 퍼널·PG·테넌트·마진)
- 대시보드 생성물 최신 여부 + 모든 PromQL 파싱, 런북 앵커 존재
- Terraform fmt / validate

PR 마다 `.github/workflows/validate.yml` 이 같은 검사를 실행한다.

## 기타 문서

- [docs/AMG_GUIDE.md](docs/AMG_GUIDE.md) · [docs/CLOUDWATCH_ALARMS_GUIDE.md](docs/CLOUDWATCH_ALARMS_GUIDE.md) · [docs/XRAY_SERVICE_MAP_GUIDE.md](docs/XRAY_SERVICE_MAP_GUIDE.md)
- [docs/AUTO_INSTRUMENTATION.md](docs/AUTO_INSTRUMENTATION.md) · [docs/ENVIRONMENT_VARIABLES.md](docs/ENVIRONMENT_VARIABLES.md)
