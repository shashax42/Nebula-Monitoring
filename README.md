# Nebula Monitoring Stack

OTEL Collector + AWS Managed Services를 활용한 통합 모니터링 솔루션

##  아키텍처

```
Application → OTEL SDK → OTEL Collector → AWS Services
                                        ├→ AMP (메트릭)
                                        ├→ CloudWatch Logs (로그)
                                        └→ X-Ray (트레이스)
```

##  프로젝트 구조

```
Nebula-Monitoring/
├── terraform/              # AWS 리소스 (Terraform)
│   ├── environments/       # 환경별 설정
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   └── modules/           # 재사용 가능한 모듈
│       ├── amp/           # Amazon Managed Prometheus
│       ├── amg/           # Amazon Managed Grafana
│       ├── iam-irsa/      # IAM IRSA
│       └── cloudwatch/    # CloudWatch
└── helm/                  # K8s 리소스 (Helm)
    └── otel-collector/    # OTEL Collector Chart
```

##  배포 가이드

### 1. AWS 리소스 배포 (Terraform)

```bash
# 1. Terraform 초기화
cd terraform/environments/dev
terraform init

# 2. 계획 확인
terraform plan

# 3. 리소스 생성
terraform apply

# 4. Output 값 확인 (Helm에서 사용)
terraform output -json > terraform-outputs.json
```

### 2. OTEL Collector 배포 (Helm)

```bash
# 1. Namespace 생성
kubectl create namespace monitoring

# 2. Terraform Output을 Helm values로 변환
export AMP_ENDPOINT=$(terraform output -raw amp_endpoint)
export ROLE_ARN=$(terraform output -raw otel_collector_role_arn)

# 3. Helm 배포
helm install otel-collector ./helm/otel-collector \
  --namespace monitoring \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ROLE_ARN \
  --set aws.amp.endpoint=$AMP_ENDPOINT \
  --values ./helm/otel-collector/values.yaml

# 4. 배포 확인
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=otel-collector
```

##  모니터링 대시보드 접속

### Amazon Managed Grafana
1. AWS Console → Amazon Managed Grafana
2. Workspace 선택
3. Grafana URL 클릭
4. SSO 로그인

### CloudWatch Logs Insights
```sql
fields @timestamp, @message
| filter @logStream like /otel-collector/
| sort @timestamp desc
| limit 100
```

### X-Ray Service Map
1. AWS Console → X-Ray
2. Service Map 선택
3. 시간 범위 설정

##  설정 커스터마이징

### OTEL Collector 설정 변경
```bash
# values.yaml 수정 후
helm upgrade otel-collector ./helm/otel-collector \
  --namespace monitoring \
  --values ./helm/otel-collector/values.yaml
```

### 새로운 환경 추가
```bash
# 1. 환경 디렉토리 복사
cp -r terraform/environments/dev terraform/environments/prod

# 2. variables.tf 수정
vim terraform/environments/prod/variables.tf

# 3. 배포
cd terraform/environments/prod
terraform init && terraform apply
```

##  주요 설정 파일

### Terraform Variables
- `terraform/environments/{env}/variables.tf`: 환경별 변수
- `terraform/environments/{env}/terraform.tfvars`: 실제 값 (gitignore 권장)

### Helm Values
- `helm/otel-collector/values.yaml`: 기본 설정
- `helm/otel-collector/values-{env}.yaml`: 환경별 오버라이드

##  보안 고려사항

1. **IRSA (IAM Roles for Service Accounts)**
   - OTEL Collector는 IRSA를 통해 AWS 서비스 접근
   - 최소 권한 원칙 적용

2. **네트워크 보안**
   - OTEL Collector는 ClusterIP 서비스로 내부 통신만 허용
   - AWS PrivateLink 사용 권장

3. **데이터 암호화**
   - 전송 중: TLS 1.2+
   - 저장 시: AWS KMS 암호화

##  비용 최적화

1. **샘플링 설정**
   ```yaml
   processors:
     probabilistic_sampler:
       sampling_percentage: 10  # 10% 샘플링
   ```

2. **로그 보존 기간**
   ```hcl
   log_retention_days = 7  # 개발: 7일, 운영: 30일
   ```

3. **메트릭 필터링**
   ```yaml
   processors:
     filter:
       metrics:
         exclude:
           match_type: regexp
           metric_names: [".*_bucket", ".*_created"]
   ```

## 🗺️ X-Ray Service Map

마이크로서비스 간 의존성과 성능을 시각화합니다.

### 주요 기능
- **서비스 의존성 맵**: 호출 관계 시각화
- **성능 분석**: P50/P90/P95/P99 레이턴시
- **오류 추적**: 오류 발생 지점 파악
- **트레이스 분석**: 상세 호출 체인 확인

자세한 내용은 [X-Ray Service Map 가이드](docs/XRAY_SERVICE_MAP_GUIDE.md)를 참고하세요.

## 🤖 Auto-Instrumentation (블로그 인사이트 적용)

애플리케이션 코드 수정 없이 자동 계측하는 방법은 [Auto-Instrumentation 가이드](docs/AUTO_INSTRUMENTATION.md)를 참고하세요.

### Quick Start
```yaml
# Deployment에 annotation 추가만 하면 자동 계측!
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-java: "true"  # Java
    instrumentation.opentelemetry.io/inject-python: "true"  # Python
    instrumentation.opentelemetry.io/inject-nodejs: "true"  # Node.js
```

##  트러블슈팅

### OTEL Collector 로그 확인
```bash
kubectl logs -n monitoring deployment/otel-collector -f
```

### IRSA 권한 확인
```bash
kubectl describe sa otel-collector -n monitoring
aws sts assume-role-with-web-identity --role-arn $ROLE_ARN --role-session-name test
```

### AMP 연결 테스트
```bash
kubectl exec -n monitoring deployment/otel-collector -- \
  curl -X POST ${AMP_ENDPOINT}/api/v1/query \
  -d 'query=up'
```

##  참고 문서

- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Amazon Managed Prometheus](https://docs.aws.amazon.com/prometheus/)
- [AWS X-Ray](https://docs.aws.amazon.com/xray/)
- [CloudWatch Logs](https://docs.aws.amazon.com/cloudwatch/)
