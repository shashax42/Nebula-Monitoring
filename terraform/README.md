# Nebula Observability Infrastructure (Terraform)

AWS 관리형 모니터링 서비스를 위한 Terraform 코드입니다.

##  디렉토리 구조

```
terraform/
├── environments/          # 환경별 설정
│   ├── dev/
│   ├── staging/
│   └── prod/
├── modules/              # 재사용 가능한 모듈
│   ├── amp/             # Amazon Managed Prometheus
│   ├── amg/             # Amazon Managed Grafana
│   ├── iam-irsa/        # IAM IRSA for OTEL Collector
│   ├── cloudwatch/      # CloudWatch Logs & Alarms
│   └── cross-account/   # Cross-Account 설정
└── backend/             # Terraform Backend 설정
```

##  관리 리소스

### AWS Services
- **AMP (Amazon Managed Prometheus)**: 메트릭 저장소
- **AMG (Amazon Managed Grafana)**: 시각화 대시보드
- **CloudWatch Logs**: 로그 수집 및 저장
- **CloudWatch Alarms**: 알람 및 알림
- **IAM Roles (IRSA)**: OTEL Collector 권한
- **X-Ray**: 분산 트레이싱

### Cross-Account
- ResourceLens 설정
- IAM Trust Relationships

##  사용법

### 1. Backend 초기화
```bash
cd terraform/backend
terraform init
terraform apply
```

### 2. 환경별 배포
```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply
```

##  환경 변수

각 환경별로 `terraform.tfvars` 파일 생성:

```hcl
region           = "ap-northeast-2"
environment      = "dev"
cluster_name     = "nebula-eks-dev"
retention_days   = 7
```

##  모듈 사용 예시

```hcl
module "amp" {
  source = "../../modules/amp"
  
  workspace_alias = "nebula-${var.environment}"
  tags = local.common_tags
}

module "otel_collector_irsa" {
  source = "../../modules/iam-irsa"
  
  cluster_name      = var.cluster_name
  namespace         = "monitoring"
  service_account   = "otel-collector"
  amp_workspace_arn = module.amp.workspace_arn
}
```

##  필요 권한

Terraform 실행을 위한 최소 IAM 권한:
- AMP 관리
- AMG 관리
- IAM Role/Policy 관리
- CloudWatch 관리
- X-Ray 관리

##  주의사항

1. **State 관리**: S3 Backend 사용 권장
2. **Lock 관리**: DynamoDB Table 사용
3. **환경 분리**: 각 환경별 독립적인 State 파일
4. **비용 관리**: 특히 AMG 워크스페이스 비용 주의
