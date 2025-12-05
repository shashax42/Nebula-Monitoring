# 환경별 변수 설정 가이드

## 📊 환경별 변수 매핑표

| 변수명 | Dev | Staging | Production | 설명 |
|--------|-----|---------|------------|------|
| **environment** | `dev` | `staging` | `production` | 환경 식별자 |
| **cluster_name** | `nebula-eks-dev` | `nebula-eks-staging` | `nebula-eks-prod` | EKS 클러스터 이름 |
| **region** | `ap-northeast-2` | `ap-northeast-2` | `ap-northeast-2` | AWS 리전 |
| **log_retention_days** | `7` | `14` | `30` | CloudWatch 로그 보관 기간 |
| **otel_namespace** | `monitoring` | `monitoring` | `monitoring` | OTEL Collector 네임스페이스 |
| **otel_service_account** | `otel-collector` | `otel-collector` | `otel-collector` | 서비스 계정 이름 |
| **replica_count** | `1` | `2` | `3` | OTEL Collector 레플리카 수 |
| **sampling_percentage** | `50` | `25` | `10` | 트레이스 샘플링 비율 (%) |

## 🚀 배포 순서 체크리스트

### 1단계: Terraform 인프라 배포

```bash
# 환경 선택 (dev/staging/prod)
export ENV=dev

# Terraform 배포
cd terraform/environments/${ENV}
terraform init
terraform plan -var-file="${ENV}.tfvars"
terraform apply -var-file="${ENV}.tfvars"

# Output 값 저장
terraform output -json > outputs.json
```

### 2단계: Terraform Output → Helm Values 매핑

```bash
# Terraform outputs 추출
export AMP_ENDPOINT=$(terraform output -raw amp_endpoint)
export AMP_WORKSPACE_ID=$(terraform output -raw amp_workspace_id)
export ROLE_ARN=$(terraform output -raw otel_collector_role_arn)
export LOG_GROUP=$(terraform output -raw otel_collector_log_group)
```

### 3단계: Helm 배포

```bash
# Helm 배포 (환경별 values 파일 사용)
helm upgrade --install otel-collector ./helm/otel-collector \
  --namespace monitoring \
  --create-namespace \
  --values ./helm/otel-collector/values.yaml \
  --values ./helm/otel-collector/values-${ENV}.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${ROLE_ARN}" \
  --set aws.amp.endpoint="${AMP_ENDPOINT}" \
  --set aws.amp.workspaceId="${AMP_WORKSPACE_ID}" \
  --set aws.cloudwatch.logGroup="${LOG_GROUP}" \
  --wait
```

## 🔄 자동화 스크립트 사용

```bash
# 전체 배포 자동화
./scripts/deploy.sh ${ENV}
```

## 📝 환경별 설정 파일 위치

### Terraform
- **공통 모듈**: `terraform/modules/`
- **환경별 설정**: `terraform/environments/${ENV}/`
  - `main.tf`: 메인 구성
  - `variables.tf`: 변수 정의
  - `${ENV}.tfvars`: 환경별 값 (선택사항)

### Helm
- **기본 values**: `helm/otel-collector/values.yaml`
- **환경별 override**: 
  - `helm/otel-collector/values-dev.yaml`
  - `helm/otel-collector/values-staging.yaml`
  - `helm/otel-collector/values-prod.yaml`

## 🔐 민감 정보 관리

### AWS Secrets Manager 사용 (권장)

```hcl
# Terraform에서 Secrets Manager 참조
data "aws_secretsmanager_secret_version" "api_key" {
  secret_id = "nebula/${var.environment}/api-keys"
}

locals {
  api_keys = jsondecode(data.aws_secretsmanager_secret_version.api_key.secret_string)
}
```

### Kubernetes Secrets 사용

```yaml
# External Secrets Operator 사용 예시
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: otel-secrets
spec:
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: otel-collector-secrets
  data:
  - secretKey: api-key
    remoteRef:
      key: nebula/monitoring/api-keys
```

## ⚙️ 환경별 리소스 권장 사항

### Development
- **목적**: 개발 및 테스트
- **리소스**: 최소 (CPU: 100m-500m, Memory: 256Mi-1Gi)
- **샘플링**: 50-100%
- **레플리카**: 1개

### Staging
- **목적**: 프로덕션 전 검증
- **리소스**: 중간 (CPU: 200m-1000m, Memory: 512Mi-2Gi)
- **샘플링**: 25-50%
- **레플리카**: 2개

### Production
- **목적**: 실제 서비스
- **리소스**: 충분 (CPU: 500m-2000m, Memory: 1Gi-4Gi)
- **샘플링**: 10% (또는 adaptive)
- **레플리카**: 3개 이상
- **HPA**: 활성화 (min: 3, max: 10)

## 🔍 검증 방법

```bash
# 1. 환경 변수 확인
kubectl get deployment otel-collector -n monitoring -o yaml | grep -A5 env:

# 2. Resource attributes 확인
kubectl logs -n monitoring deployment/otel-collector | grep "cluster.name\|deployment.environment"

# 3. 메트릭 확인
curl -s http://localhost:8888/metrics | grep otelcol_processor
```
