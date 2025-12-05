# CloudWatch Alarms 가이드

## 알람 구성

### Application Performance (SLO 기반)

| 알람 | 임계값 | 설명 |
|------|--------|------|
| **High Error Rate** | > 5% | 에러율이 5% 초과 |
| **High Latency P95** | > 1초 | P95 레이턴시 1초 초과 |
| **Low Availability** | < 99.9% | 가용성 99.9% 미달 (SLO 위반) |

### Infrastructure

| 알람 | 임계값 | 설명 |
|------|--------|------|
| **EKS Node CPU** | > 80% | 노드 CPU 사용률 80% 초과 |
| **EKS Node Memory** | > 80% | 노드 메모리 사용률 80% 초과 |
| **Pod Restart Rate** | > 5/분 | Pod 재시작 빈도 과다 |

### OTEL Collector Health

| 알람 | 임계값 | 설명 |
|------|--------|------|
| **Collector Down** | 메트릭 없음 | OTEL Collector 다운 |
| **Collector Memory** | > 80% | Collector 메모리 사용률 과다 |

### Composite Alarm

| 알람 | 조건 | 설명 |
|------|------|------|
| **Service Degradation** | 복합 조건 | 여러 지표가 동시에 악화 |

## 알림 설정

### 1. 이메일 알림 설정

```hcl
# terraform/environments/dev/main.tf
module "cloudwatch_alarms" {
  email_endpoints = [
    "ops-team@company.com",
    "on-call@company.com"
  ]
}
```

배포 후 이메일 확인 필요:
1. AWS SNS에서 확인 이메일 발송
2. 이메일의 "Confirm subscription" 클릭
3. 알림 수신 시작

### 2. Slack 알림 설정 (Lambda 필요)

```python
# Lambda 함수 예시
import json
import urllib3

http = urllib3.PoolManager()

def lambda_handler(event, context):
    url = "YOUR_SLACK_WEBHOOK_URL"
    msg = json.loads(event['Records'][0]['Sns']['Message'])
    
    slack_message = {
        "text": f"🚨 *{msg['AlarmName']}*",
        "attachments": [{
            "color": "danger" if msg['NewStateValue'] == "ALARM" else "good",
            "fields": [
                {"title": "Description", "value": msg['AlarmDescription']},
                {"title": "Reason", "value": msg['NewStateReason']},
                {"title": "Time", "value": msg['StateChangeTime']}
            ]
        }]
    }
    
    http.request('POST', url, 
                body=json.dumps(slack_message),
                headers={'Content-Type': 'application/json'})
```

## 알람 임계값 조정

### 환경별 임계값 설정

```hcl
# Dev 환경 (관대한 임계값)
error_rate_threshold   = 10    # 10%
latency_p95_threshold  = 2000  # 2초
availability_threshold = 99    # 99%

# Production 환경 (엄격한 임계값)
error_rate_threshold   = 1     # 1%
latency_p95_threshold  = 500   # 500ms
availability_threshold = 99.95 # 99.95%
```

## 알람 우선순위

### Critical (즉시 대응)
- **Low Availability**: 서비스 가용성 SLO 위반
- **OTEL Collector Down**: 모니터링 시스템 다운
- **Service Degradation**: 복합 장애 상황

### High (30분 내 대응)
- **High Error Rate**: 에러율 급증
- **Pod Restart Rate High**: 안정성 문제

### Medium (업무시간 내 대응)
- **High Latency P95**: 성능 저하
- **Node CPU/Memory High**: 리소스 부족

## 알람 발생 시 대응

### 1. Low Availability 알람

```bash
# 1. Pod 상태 확인
kubectl get pods -n production --field-selector status.phase!=Running

# 2. 최근 에러 로그 확인
kubectl logs -n production deployment/api --tail=100 | grep ERROR

# 3. 서비스 재시작 (필요시)
kubectl rollout restart deployment/api -n production
```

### 2. High Error Rate 알람

```bash
# 1. 에러 패턴 분석
aws logs insights query \
  --log-group-name /aws/eks/nebula-eks-prod/application \
  --query 'fields @timestamp, @message | filter @message like /ERROR/'

# 2. X-Ray 트레이스 확인
aws xray get-trace-summaries --time-range-type LastHour
```

### 3. OTEL Collector Down 알람

```bash
# 1. Collector Pod 상태 확인
kubectl get pods -n monitoring -l app=otel-collector

# 2. Collector 로그 확인
kubectl logs -n monitoring deployment/otel-collector --tail=50

# 3. Collector 재시작
kubectl rollout restart deployment/otel-collector -n monitoring
```

## 알람 대시보드

Grafana에서 알람 상태 모니터링:

```promql
# 알람 상태 쿼리
ALERTS{alertstate="firing"}

# 알람 히스토리
increase(cloudwatch_alarm_state_changes_total[24h])
```

## 트러블슈팅

### 알람이 발생하지 않을 때

1. **메트릭 확인**
```bash
aws cloudwatch get-metric-statistics \
  --namespace "Nebula/Application" \
  --metric-name "Errors" \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --period 300 \
  --statistics Sum
```

2. **알람 상태 확인**
```bash
aws cloudwatch describe-alarms \
  --alarm-names "prod-high-error-rate"
```

3. **SNS 구독 확인**
```bash
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:region:account:topic-name
```

### 너무 많은 알람이 발생할 때

1. **임계값 조정**
2. **Evaluation Periods 증가**
3. **Composite Alarm 활용**

## 참고 자료

- [CloudWatch Alarms 문서](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html)
- [Composite Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Create_Composite_Alarm.html)
- [SNS 설정 가이드](https://docs.aws.amazon.com/sns/latest/dg/welcome.html)
