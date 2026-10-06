# Amazon Managed Grafana (AMG) 사용 가이드

## 개요

Amazon Managed Grafana는 완전 관리형 Grafana 서비스로, 별도의 서버 관리 없이 대시보드를 구성할 수 있습니다.

## 배포 방법

### 1. Terraform으로 AMG 배포

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply

# AMG 엔드포인트 확인
terraform output grafana_workspace_endpoint
```

### 2. Grafana 접속

```bash
# 출력된 엔드포인트로 브라우저 접속
https://g-xxxxxxxxxx.grafana-workspace.ap-northeast-2.amazonaws.com
```

## 접근 권한 설정

### AWS SSO 사용 시

1. AWS SSO 콘솔에서 사용자/그룹 생성
2. Grafana 워크스페이스에 권한 할당:
   - **Admin**: 모든 권한
   - **Editor**: 대시보드 생성/수정
   - **Viewer**: 읽기 전용

### API Key 사용 시

```bash
# Terraform에서 API Key 생성 활성화
create_api_key = true

# API Key 확인
terraform output -raw api_key_secret
```

## 데이터 소스 설정

### 1. Amazon Managed Prometheus (AMP)

자동으로 연결됩니다. 추가 설정:

```
Configuration → Data Sources → Prometheus
- URL: AMP workspace endpoint
- Auth: SigV4
- Default Region: ap-northeast-2
```

### 2. CloudWatch

자동으로 연결됩니다. 사용 가능한 네임스페이스:
- `AWS/RDS`, `AWS/ElastiCache` (Data Stores 대시보드)
- `Nebula/Application` — gateway 가 EMF 로 보내는 SLI 지표 (CloudWatch Alarms 대상, 확장 시 결제 지표 추가)
- `Nebula/Logs` — 로그 메트릭 필터 (ErrorLogs, OOMKilledEvents)

### 3. X-Ray

자동으로 연결됩니다. Service Map 확인:

```
Explore → X-Ray → Service Map
```

## 대시보드 구성

### 프로비저닝 (권장)

```bash
./scripts/provision-grafana.sh dev                 # 기본 대시보드
./scripts/provision-grafana.sh dev --extensions    # + 확장(테넌트·결제·마진)
```

- 데이터소스 3개를 uid 고정(`amp`, `cloudwatch`, `xray`)으로 만들고 워크스페이스 IAM 역할로 인증한다.
- `grafana/dashboards/*.json` 을 `Nebula` 폴더에 덮어쓴다. 대시보드는 `grafana/generate_dashboards.py` 로 생성한다 (JSON 직접 수정 금지).

| 대시보드 | 내용 |
|---|---|
| Nebula / Overview (Q1–Q5) | 클러스터 건강 → 서비스 에러 → 지연 → 리소스 → 시스템 개요 |
| Nebula / Service SLO & Golden Signals | 30일 가용성 게이지, 남은 버짓, Time to Burn Out, 번레이트, 목표선, 라우트/의존성, 서비스 맵, 에러 로그 |
| Nebula / Order Saga & Messaging | 주문 사가 단계·완료율, 발행 실패, 보상(취소) 누락, 재고 거절률, Kafka lag·토픽별 지연·에러 |
| Nebula / Infra Cost & Efficiency | 네임스페이스 비용(₩/h), 유휴 비용·비율, 다운사이징 후보 |
| Nebula / Ext / Funnel & Payments · Tenants · Margin | (확장) 퍼널·PG 실패 원인, 테넌트 Noisy Neighbor·비용, Net Margin |
| Nebula / Data Stores | Aurora / Redis (CloudWatch) |
| Nebula / Telemetry Pipeline | 수집량, 정제량, 샘플링, 전송 실패, 카디널리티 |

### 커스텀 대시보드 생성

1. **Create → Dashboard**
2. **Add Panel** 클릭
3. Query 작성:

```promql
# 예시: 서비스별 요청률 (트레이스에서 만든 레코딩 규칙)
service:requests:rate5m

# 예시: 에러율
service:error_ratio:rate5m{service_name="service-order"}

# 예시: P95 레이턴시 (원천 히스토그램에서 직접)
histogram_quantile(0.95, sum by (le) (rate(traces_span_metrics_duration_seconds_bucket{service_name="service-order", span_kind="SPAN_KIND_SERVER"}[5m])))
```

## 알림 설정

### 1. Contact Point 생성

```
Alerting → Contact points → New contact point
- Name: slack-alerts
- Type: Slack
- Webhook URL: https://hooks.slack.com/services/XXX
```

### 2. Alert Rule 생성

```
Alerting → Alert rules → New alert rule
- Condition: 에러율 > 5%
- Evaluation: Every 1m for 5m
- Actions: Send to slack-alerts
```

## 📱 모바일 접근

### Grafana 모바일 앱

1. iOS/Android에서 Grafana 앱 설치
2. URL 입력: AMG 엔드포인트
3. API Key로 인증

## Best Practices

### 1. 대시보드 구성

- **Golden Signals 중심**: Latency, Traffic, Errors, Saturation
- **드릴다운 구조**: Overview → Service → Pod
- **시간 범위**: 실시간 + 히스토리컬

### 2. 쿼리 최적화

```promql
# Bad: 모든 메트릭 조회
{__name__=~".*"}

# Good: 레코딩 규칙(사전 가공) 사용
service:requests:rate5m{service_name="api-gateway"}
```

### 3. 변수 활용

```
Dashboard Settings → Variables
- $namespace: 네임스페이스 선택
- $service: 서비스 선택
- $interval: 시간 간격
```

## 트러블슈팅

### 데이터가 보이지 않을 때

1. 데이터 소스 연결 확인
2. IAM 권한 확인
3. 시간 범위 조정
4. 쿼리 문법 확인

### 성능 이슈

1. 쿼리 시간 범위 축소
2. Recording Rules 활용
3. 대시보드 새로고침 주기 조정

## 참고 자료

- [AWS Grafana 문서](https://docs.aws.amazon.com/grafana/)
- [Grafana 공식 문서](https://grafana.com/docs/)
- [PromQL 가이드](https://prometheus.io/docs/prometheus/latest/querying/basics/)
