# CloudWatch Alarms 가이드

## 알람 구성

CloudWatch Alarms 는 **Alertmanager 대체 계층**으로, "고객 영향이 확정된" SLA/비즈니스 경보를 담당한다.
조기 경보(번레이트, 주문 사가, 이상탐지, 쿠버네티스)는 AMP 알림 규칙 → AMP Alertmanager → **같은 SNS 토픽**으로 온다.

데이터 출처: gateway 가 트레이스에서 직접 센 SLI 를 EMF 로 `Nebula/Application` 에 보낸다
(`Requests`, `Errors`, `SlowRequests` — 차원 `Environment`[, `Service`]). 확장 오버레이를 켜면 `PaymentRequests`, `PaymentLogicalErrors` 가 추가된다.

### SLA / Golden Signals

| 알람 | 조건 (기본값) | 토픽 |
|------|------|------|
| `<env>-sla-availability` | 가용성 < 99.9% (5분 × 3회 연속, 기간당 요청 50건 이상) | critical |
| `<env>-sla-availability-<service>` | 핵심 서비스(`slo_services`)별 동일 조건 | critical |
| `<env>-error-rate` | 에러율 > 5% | warning |
| `<env>-latency-slo` | 1s 초과 요청 > 5% (= P95 > 1s) | warning |
| `<env>-service-degradation` (Composite) | SLA 위반 OR (에러율 AND 지연) [OR PG 타임아웃 — 확장] | critical |

### 결제 (확장 — `enable_business_extensions = true` 일 때만 생성)

결제 서비스와 collector 오버레이(`values-extension-business.yaml`)가 있어야 데이터가 생긴다. 기본 배포에서는 만들지 않는다.

| 알람 | 조건 | 토픽 |
|------|------|------|
| `<env>-payment-pg-timeout` | `FailureCategory=pg_timeout` 비율 > 1% | critical |
| `<env>-payment-failure-rate` | 전체 결제 실패율 > 10% (고객 원인 포함) | warning |
| `<env>-payment-logical-errors` | HTTP 2xx + 결제 실패 > 0건 | critical |

### 데이터 스토어 / 파이프라인

| 알람 | 조건 | 토픽 |
|------|------|------|
| `<env>-aurora-<id>-cpu-high` / `-deadlocks` / `-replica-lag` | Writer CPU > 80%, 데드락 > 0.1/s, Reader 복제 지연 > 1s | warning |
| `<env>-redis-<node>-engine-cpu-high` / `-memory-high` / `-evictions` | EngineCPU > 80%, 메모리 > 85%, 축출 > 100/5분 | warning |
| `<env>-telemetry-log-ingestion-stopped` | 애플리케이션 로그 그룹 유입 0건 15분 (missing = breaching) | critical |

Aurora/Redis 대상은 `aurora_cluster_identifiers`, `redis_replication_group_ids` 변수로 지정한다 (Redis 노드는 자동 조회).

> 이전 버전의 알람(AWS/Lambda Errors, 설치되지 않은 ContainerInsights, 아무도 보내지 않던 `OpenTelemetryCollector` 네임스페이스)은
> 실제 데이터가 없어 동작하지 않거나(`treat_missing_data=breaching` 인 경우) 항상 ALARM 상태였으므로 제거했다.
> 노드/파드 경보는 AMP 규칙(`prometheus/rules/01-kubernetes.rules.yaml`)이 담당한다.

## 알림 설정

### 1. 이메일 알림 설정

```hcl
# terraform/environments/dev/main.tf
module "cloudwatch_alarms" {
  email_endpoints = [   # dev 는 variables.tf 의 alarm_email_endpoints
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

| 토픽 | 대상 | 기대 대응 |
|---|---|---|
| `<env>-alerts-critical` | SLA 위반, Composite, 로그 유입 중단 + AMP critical 규칙(사가 발행 실패·정지·보상 누락 등) [확장: PG 타임아웃, 결제 논리 오류] | 즉시 |
| `<env>-alerts-warning` | 에러율, 지연 SLO, Aurora/Redis + AMP warning/info 규칙 [확장: 결제 실패율] | 업무 시간 내 (info 는 하루 1회 묶음) |

## 알람 발생 시 대응

알람 설명(`alarm_description`)과 AMP 알림의 `runbook_url` 은 모두 [RUNBOOK.md](RUNBOOK.md) 의 해당 항목을 가리킨다.

```bash
# 에러 패턴 (저장 쿼리 nebula-<env>/02-top-error-messages 와 동일)
aws logs start-query --log-group-name /aws/eks/<cluster>/application \
  --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) \
  --query-string 'fields attributes.service as service, body | filter severity_text in ["ERROR","FATAL"] | stats count(*) by service | sort count(*) desc'

# 수집 파이프라인 상태
kubectl get pods -n monitoring -l app.kubernetes.io/name=otel-collector
kubectl logs -n monitoring -l app.kubernetes.io/component=gateway --tail=100
```

## 알람 대시보드

Grafana에서 알람 상태 모니터링:

```promql
# 알람 상태 쿼리
ALERTS{alertstate="firing"}

# 알림별 발화 시간(최근 24h, AMP 규칙)
sum by (alertname) (count_over_time(ALERTS{alertstate="firing"}[24h]))
```

## 트러블슈팅

### 알람이 발생하지 않을 때

1. **메트릭 확인** — EMF 원본은 `/aws/eks/<cluster>/metrics` 로그 그룹에 있다 (gateway `awsemf` 가 쓰는지 확인)
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
  --alarm-names "production-error-rate"
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
