# terraform_new 인프라 모니터링 통합 가이드

이 문서는 `terraform_new`로 구축된 Nebula Platform 인프라(EKS, Aurora, Redis)를 기존 `Nebula-Monitoring` 스택(OTEL + AMP/AMG/CloudWatch/X-Ray)에 연결하는 방법을 설명합니다.

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────┐
│  Nebula-Monitoring (모니터링 전용)                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │     AMP      │  │     AMG      │  │  CloudWatch  │      │
│  │ (Prometheus) │  │  (Grafana)   │  │   + X-Ray    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         ▲                ▲                    ▲              │
│         │                │                    │              │
│         └────────────────┴────────────────────┘              │
│                          │                                   │
└──────────────────────────┼───────────────────────────────────┘
                           │
                           │ Remote Write / Logs / Traces
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  terraform_new (실제 인프라)                                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  EKS Cluster                                         │   │
│  │  ┌────────────────┐  ┌────────────────┐            │   │
│  │  │ OTEL Collector │  │  Application   │            │   │
│  │  │  (DaemonSet)   │  │     Pods       │            │   │
│  │  └────────────────┘  └────────────────┘            │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │    Aurora    │  │     Redis    │  │      S3      │     │
│  │   (MySQL)    │  │ (ElastiCache)│  │              │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

## 통합 방식

### 1. **Terraform Remote State 연동**
- `Nebula-Monitoring`의 Terraform이 `terraform_new`의 state를 data source로 참조
- EKS 클러스터 정보(이름, OIDC, VPC 등)를 자동으로 가져옴

### 2. **IAM IRSA 역할 생성**
- `terraform_new` EKS 클러스터용 OTEL Collector IRSA 역할 생성
- 기존 AMP/CloudWatch/X-Ray에 쓰기 권한 부여

### 3. **OTEL Collector 배포**
- Helm Chart로 `terraform_new` EKS에 OTEL Collector DaemonSet 배포
- 모든 메트릭/로그/트레이스를 기존 모니터링 스택으로 전송

---

## 사전 준비

### 1. terraform_new 인프라가 이미 배포되어 있어야 함

```bash
cd terraform_new/environments/dev
terraform apply
```

### 2. terraform_new의 state를 S3 backend로 관리

`terraform_new/environments/dev/terraform.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "nebula-terraform-state"
    key            = "nebula-platform/dev/terraform.tfstate"  # 이 경로 확인!
    region         = "ap-northeast-2"
    dynamodb_table = "nebula-terraform-locks"
    encrypt        = true
    profile        = "monitoring-admin"
  }
}
```

### 3. AWS CLI 프로파일 설정

```bash
aws configure --profile monitoring-admin
```

---

## 배포 단계

### Step 1: terraform_new에 필요한 outputs 추가

`terraform_new/environments/dev/outputs.tf`에 다음 outputs가 있는지 확인:

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
```

없으면 추가 후 `terraform apply`:

```bash
cd terraform_new/environments/dev
terraform apply
```

### Step 2: Nebula-Monitoring Terraform 배포

```bash
cd Nebula-Monitoring/terraform/environments/dev
terraform init
terraform plan
terraform apply
```

이 단계에서:
- ✅ AMP Workspace 생성
- ✅ AMG Workspace 생성
- ✅ `terraform_new` EKS 클러스터 정보 읽기
- ✅ OTEL Collector용 IRSA 역할 생성
- ✅ CloudWatch Log Groups 생성

### Step 3: OTEL Collector Helm 배포 (자동화 스크립트)

```powershell
cd Nebula-Monitoring
.\scripts\deploy-target-monitoring.ps1 -Environment dev -AwsProfile monitoring-admin
```

또는 수동:

```bash
# 1. Terraform outputs 가져오기
cd Nebula-Monitoring/terraform/environments/dev
TARGET_CLUSTER=$(terraform output -raw target_cluster_name)
OTEL_ROLE_ARN=$(terraform output -raw target_otel_role_arn)
AMP_ENDPOINT=$(terraform output -raw amp_remote_write_url)

# 2. kubeconfig 설정
aws eks update-kubeconfig --name $TARGET_CLUSTER --region ap-northeast-2 --profile monitoring-admin

# 3. Helm 배포
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm upgrade --install otel-collector \
  open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --create-namespace \
  --values helm/otel-collector/values-target-infra.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$OTEL_ROLE_ARN \
  --set config.exporters.prometheusremotewrite.endpoint=$AMP_ENDPOINT \
  --set config.exporters.awscloudwatchlogs.region=ap-northeast-2 \
  --set config.exporters.awsxray.region=ap-northeast-2 \
  --set config.extensions.sigv4auth.region=ap-northeast-2 \
  --wait
```

---

## 수집되는 데이터

### 메트릭 (→ AMP)

#### Kubernetes 메트릭
- **API Server**: 요청 수, 레이턴시, 에러율
- **Nodes**: CPU, 메모리, 디스크, 네트워크
- **Pods**: 컨테이너 리소스 사용량, 재시작 횟수
- **cAdvisor**: 컨테이너 세부 메트릭

#### AWS 리소스 메트릭 (CloudWatch → AMP)
- **Aurora**: CPU, 연결 수, Replica Lag, IOPS
- **Redis**: CPU, 메모리, Evictions, Cache Hit Rate
- **EKS Control Plane**: API Server 메트릭

### 로그 (→ CloudWatch Logs)

- **EKS Control Plane Logs**: API, Audit, Authenticator, Controller Manager, Scheduler
- **Application Logs**: OTLP로 전송된 애플리케이션 로그
- **OTEL Collector Logs**: 수집기 자체 로그

### 트레이스 (→ X-Ray)

- **애플리케이션 트레이스**: OTLP gRPC/HTTP로 전송된 분산 트레이싱
- **Service Map**: 마이크로서비스 간 호출 관계
- **Latency Analysis**: 각 서비스별 응답 시간 분석

---

## 검증

### 1. OTEL Collector 상태 확인

```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -f
```

### 2. AMP에 메트릭이 들어오는지 확인

```bash
# Terraform output에서 AMP workspace ID 가져오기
cd Nebula-Monitoring/terraform/environments/dev
AMP_WORKSPACE_ID=$(terraform output -raw amp_workspace_id)

# PromQL 쿼리 테스트
awscurl --service aps --region ap-northeast-2 \
  "https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/$AMP_WORKSPACE_ID/api/v1/query?query=up"
```

### 3. Grafana에서 대시보드 확인

```bash
# Grafana endpoint 가져오기
GRAFANA_ENDPOINT=$(terraform output -raw grafana_workspace_endpoint)
echo "Grafana URL: https://$GRAFANA_ENDPOINT"
```

Grafana에서:
- Data Source → Prometheus (AMP) 연결 확인
- Explore → `up` 쿼리로 타겟 확인
- `container_cpu_usage_seconds_total` 같은 메트릭 조회

### 4. CloudWatch Logs 확인

AWS Console → CloudWatch → Log groups:
- `/aws/eks/<cluster-name>/otel-collector`
- `/aws/eks/<cluster-name>/application`

### 5. X-Ray Service Map 확인

AWS Console → X-Ray → Service map

---

## 트러블슈팅

### OTEL Collector Pod가 CrashLoopBackOff

```bash
kubectl describe pod -n monitoring <pod-name>
kubectl logs -n monitoring <pod-name>
```

**원인 1**: IRSA 역할 권한 부족
- Terraform output `target_otel_role_arn` 확인
- IAM Role에 AMP/CloudWatch/X-Ray 정책이 붙어 있는지 확인

**원인 2**: AMP endpoint 오류
- Helm values에서 `prometheusremotewrite.endpoint` 확인
- 형식: `https://aps-workspaces.<region>.amazonaws.com/workspaces/<ws-id>/api/v1/remote_write`

### 메트릭이 AMP에 안 들어옴

```bash
# OTEL Collector 로그에서 에러 확인
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector | grep -i error

# SigV4 인증 확인
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector | grep sigv4
```

**해결**:
- ServiceAccount에 `eks.amazonaws.com/role-arn` annotation이 제대로 설정되어 있는지 확인
- IRSA 역할의 Trust Policy에서 OIDC Provider가 올바른지 확인

### Aurora/Redis 메트릭이 안 보임

Aurora/Redis는 **CloudWatch 메트릭**으로만 제공됩니다.  
OTEL Collector가 직접 수집하지 않고, Grafana에서 CloudWatch Data Source로 조회해야 합니다.

**Grafana 설정**:
1. Data Sources → Add CloudWatch
2. Region: `ap-northeast-2`
3. Auth: IAM Role (Grafana workspace의 IAM Role에 CloudWatch 읽기 권한 필요)
4. Namespace: `AWS/RDS`, `AWS/ElastiCache` 선택

---

## 다음 단계

### 1. Grafana 대시보드 구성

추천 대시보드:
- **Kubernetes Cluster Monitoring**: Node/Pod 리소스
- **Aurora Performance**: CPU, 연결, Replica Lag
- **Redis Performance**: 메모리, Evictions, Hit Rate
- **Application SLO**: Error Rate, Latency (P95, P99)

### 2. CloudWatch Alarms 설정

`Nebula-Monitoring/terraform/modules/cloudwatch-alarms`에 Aurora/Redis 알람 추가:
- Aurora CPU > 80%
- Redis Memory > 80%
- EKS Node NotReady

### 3. X-Ray Sampling Rules 조정

프로덕션 환경에서는 샘플링 비율 조정:
- 기본: 10%
- 중요 서비스 (auth, payment): 50%

---

## 파일 구조

```
Nebula-Monitoring/
├── terraform/
│   └── environments/
│       └── dev/
│           ├── main.tf                        # 기존 모니터링 스택
│           └── target-infrastructure.tf       # ✨ terraform_new 연결
├── helm/
│   └── otel-collector/
│       └── values-target-infra.yaml          # ✨ 타겟 인프라용 values
└── scripts/
    └── deploy-target-monitoring.ps1          # ✨ 자동 배포 스크립트

terraform_new/
└── environments/
    └── dev/
        ├── main.tf                            # EKS, Aurora, Redis
        └── outputs.tf                         # ✨ 모니터링 연동용 outputs
```

---

## 요약

1. **`terraform_new`**: 실제 인프라 (EKS, Aurora, Redis) 배포
2. **`Nebula-Monitoring`**: 모니터링 스택 (AMP, AMG, CloudWatch, X-Ray) + terraform_new 연결 설정
3. **OTEL Collector**: terraform_new EKS에 DaemonSet으로 배포, 모든 텔레메트리를 중앙 모니터링으로 전송
4. **Grafana**: 통합 대시보드에서 모든 메트릭/로그/트레이스 시각화

**핵심**: 두 레포를 분리 유지하면서, Terraform Remote State + OTEL Collector로 깔끔하게 연결! 🎉
