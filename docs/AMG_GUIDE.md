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
- `AWS/EKS`
- `AWS/Lambda`
- `AWS/RDS`
- `Nebula/Application` (커스텀)

### 3. X-Ray

자동으로 연결됩니다. Service Map 확인:

```
Explore → X-Ray → Service Map
```

## 대시보드 구성

### 사전 구성된 대시보드

1. **Cluster Overview**
   - CPU/Memory 사용률
   - 네트워크 I/O
   - Pod 상태

2. **Application Performance**
   - Request Rate
   - Error Rate
   - P95 Latency
   - Availability (SLO)

### 대시보드 임포트

```json
# terraform/modules/amg/dashboards/ 폴더의 JSON 파일 사용
1. Dashboards → Import
2. Upload JSON file 선택
3. 데이터 소스 매핑
4. Import 클릭
```

### 커스텀 대시보드 생성

1. **Create → Dashboard**
2. **Add Panel** 클릭
3. Query 작성:

```promql
# 예시: 서비스별 요청률
sum(rate(http_requests_total[5m])) by (service)

# 예시: 에러율
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# 예시: P95 레이턴시
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
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

# Good: 필요한 메트릭만
http_requests_total{service="api"}
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
