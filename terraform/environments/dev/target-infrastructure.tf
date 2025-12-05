# ========================================
# Target Infrastructure Connection
# terraform_new 인프라를 모니터링 타겟으로 연결
# ========================================

# terraform_new의 state를 data source로 참조
# (같은 AWS 계정/리전에 있다고 가정)
data "terraform_remote_state" "target_infra" {
  backend = "s3"
  
  config = {
    bucket  = "nebula-terraform-state"
    key     = "nebula-platform/dev/terraform.tfstate"  # terraform_new의 state 경로
    region  = "ap-northeast-2"
    profile = "monitoring-admin"
  }
}

# 타겟 EKS 클러스터 정보
locals {
  target_cluster_name     = try(data.terraform_remote_state.target_infra.outputs.cluster_name, "")
  target_cluster_endpoint = try(data.terraform_remote_state.target_infra.outputs.cluster_endpoint, "")
  target_oidc_issuer      = try(data.terraform_remote_state.target_infra.outputs.cluster_oidc_issuer_url, "")
  target_vpc_id           = try(data.terraform_remote_state.target_infra.outputs.vpc_id, "")
}

# 타겟 EKS 클러스터에 OTEL Collector 배포를 위한 IRSA 역할
module "target_otel_irsa" {
  source = "../../modules/iam-irsa"
  
  count = local.target_cluster_name != "" ? 1 : 0

  cluster_name      = local.target_cluster_name
  namespace         = var.otel_namespace
  service_account   = var.otel_service_account
  region            = var.region
  amp_workspace_arn = module.amp.workspace_arn  # 기존 모니터링 스택의 AMP 사용

  tags = {
    Environment = var.environment
    Target      = "terraform-new-infrastructure"
    ManagedBy   = "Terraform"
  }
}

# 타겟 인프라용 CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "target_eks" {
  count = local.target_cluster_name != "" ? 1 : 0
  
  name              = "/aws/eks/${local.target_cluster_name}/otel-collector"
  retention_in_days = var.log_retention_days
  
  tags = merge(local.common_tags, {
    Target = "terraform-new-infrastructure"
  })
}

resource "aws_cloudwatch_log_group" "target_application" {
  count = local.target_cluster_name != "" ? 1 : 0
  
  name              = "/aws/eks/${local.target_cluster_name}/application"
  retention_in_days = var.log_retention_days
  
  tags = merge(local.common_tags, {
    Target = "terraform-new-infrastructure"
  })
}

# Outputs for target infrastructure
output "target_cluster_name" {
  description = "Target EKS cluster name"
  value       = local.target_cluster_name
}

output "target_otel_role_arn" {
  description = "OTEL Collector IAM Role ARN for target cluster"
  value       = try(module.target_otel_irsa[0].role_arn, "")
}
