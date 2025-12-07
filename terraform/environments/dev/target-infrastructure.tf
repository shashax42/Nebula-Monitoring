# ========================================
# Target Infrastructure Connection
# terraform_new 인프라를 모니터링 타겟으로 연결
# ========================================
# 
# 이 파일은 terraform_new 레포의 코드를 전혀 건드리지 않고
# 모니터링 레포에서만 연결을 설정합니다.
#
# 배포 순서:
# 1. terraform_new에서 EKS 클러스터 생성 (terraform apply)
# 2. 이 모니터링 레포에서 terraform apply
# 3. Helm으로 OTEL Collector 배포 (helm/otel-collector)
# ========================================

# ========================================
# 타겟 인프라 활성화 토글
# terraform_new 클러스터가 생성된 후 true로 변경
# ========================================
variable "enable_target_monitoring" {
  description = "Enable monitoring for terraform_new infrastructure. Set to true after terraform_new cluster is created."
  type        = bool
  default     = false
}

# ========================================
# terraform_new의 state를 data source로 참조
# cluster_name을 자동으로 가져옴
# ========================================
data "terraform_remote_state" "target_infra" {
  count   = var.enable_target_monitoring ? 1 : 0
  backend = "s3"
  
  config = {
    bucket  = "lucia-real-buckets"  # terraform_new의 실제 버킷
    key     = "env/dev/terraform.tfstate"  # terraform_new의 실제 state 경로
    region  = "ap-northeast-2"
    profile = "monitoring-admin"
  }
}

# 타겟 EKS 클러스터 정보 (remote state에서 자동으로 가져옴)
locals {
  # terraform_new의 outputs.cluster_name을 자동으로 읽어옴
  target_cluster_name = var.enable_target_monitoring ? try(
    data.terraform_remote_state.target_infra[0].outputs.cluster_name, 
    ""
  ) : ""
}

# ========================================
# EKS 클러스터 정보 직접 조회
# terraform_new의 outputs에 OIDC 정보가 없어도 동작
# ========================================
data "aws_eks_cluster" "target" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0
  name  = local.target_cluster_name
}

data "aws_caller_identity" "current" {}

# 타겟 EKS 클러스터 상세 정보
locals {
  # EKS 클러스터에서 직접 조회
  target_cluster_endpoint = var.enable_target_monitoring && length(data.aws_eks_cluster.target) > 0 ? data.aws_eks_cluster.target[0].endpoint : ""
  target_oidc_issuer      = var.enable_target_monitoring && length(data.aws_eks_cluster.target) > 0 ? data.aws_eks_cluster.target[0].identity[0].oidc[0].issuer : ""
  target_oidc_provider    = var.enable_target_monitoring && local.target_oidc_issuer != "" ? replace(local.target_oidc_issuer, "https://", "") : ""
}

# ========================================
# IRSA Role for OTEL Collector (타겟 클러스터용)
# terraform_new 클러스터에 배포될 OTEL Collector가 사용
# ========================================
resource "aws_iam_role" "target_otel_collector" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0

  name = "${local.target_cluster_name}-otel-collector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.target_oidc_provider}"
      }
      Condition = {
        StringEquals = {
          "${local.target_oidc_provider}:sub" = "system:serviceaccount:${var.otel_namespace}:${var.otel_service_account}"
          "${local.target_oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name   = "${local.target_cluster_name}-otel-collector-role"
    Target = "terraform-new-infrastructure"
  })
}

# ========================================
# IAM Policies for OTEL Collector
# ========================================

# AMP Write Access
resource "aws_iam_role_policy" "target_amp_write" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0

  name = "AMPWriteAccess"
  role = aws_iam_role.target_otel_collector[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aps:RemoteWrite",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = module.amp.workspace_arn
      }
    ]
  })
}

# CloudWatch Logs Access
resource "aws_iam_role_policy" "target_cloudwatch_logs" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0

  name = "CloudWatchLogsAccess"
  role = aws_iam_role.target_otel_collector[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.target_cluster_name}/*"
        ]
      }
    ]
  })
}

# X-Ray Access
resource "aws_iam_role_policy" "target_xray" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0

  name = "XRayAccess"
  role = aws_iam_role.target_otel_collector[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetSamplingStatisticSummaries"
        ]
        Resource = "*"
      }
    ]
  })
}

# CloudWatch Metrics Access
resource "aws_iam_role_policy" "target_cloudwatch_metrics" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0

  name = "CloudWatchMetricsAccess"
  role = aws_iam_role.target_otel_collector[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics"
        ]
        Resource = "*"
      }
    ]
  })
}

# ========================================
# 타겟 인프라용 CloudWatch Log Groups
# ========================================
resource "aws_cloudwatch_log_group" "target_otel" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0
  
  name              = "/aws/eks/${local.target_cluster_name}/otel-collector"
  retention_in_days = var.log_retention_days
  
  tags = merge(local.common_tags, {
    Target = "terraform-new-infrastructure"
  })
}

resource "aws_cloudwatch_log_group" "target_application" {
  count = var.enable_target_monitoring && local.target_cluster_name != "" ? 1 : 0
  
  name              = "/aws/eks/${local.target_cluster_name}/application"
  retention_in_days = var.log_retention_days
  
  tags = merge(local.common_tags, {
    Target = "terraform-new-infrastructure"
  })
}

# ========================================
# Outputs for target infrastructure
# ========================================
output "target_cluster_name" {
  description = "Target EKS cluster name"
  value       = local.target_cluster_name
}

output "target_cluster_endpoint" {
  description = "Target EKS cluster endpoint"
  value       = local.target_cluster_endpoint
}

output "target_otel_role_arn" {
  description = "OTEL Collector IAM Role ARN for target cluster"
  value       = var.enable_target_monitoring ? try(aws_iam_role.target_otel_collector[0].arn, "") : ""
}

output "target_otel_log_group" {
  description = "CloudWatch Log Group for target OTEL Collector"
  value       = var.enable_target_monitoring ? try(aws_cloudwatch_log_group.target_otel[0].name, "") : ""
}

# ========================================
# Helm 배포에 필요한 설정값 출력
# ========================================
output "target_helm_values" {
  description = "Values to use when deploying OTEL Collector Helm chart to target cluster"
  value = var.enable_target_monitoring && local.target_cluster_name != "" ? {
    service_account_role_arn = try(aws_iam_role.target_otel_collector[0].arn, "")
    amp_remote_write_url     = module.amp.remote_write_url
    log_group_name           = try(aws_cloudwatch_log_group.target_otel[0].name, "")
    region                   = var.region
    cluster_name             = local.target_cluster_name
  } : null
}

# ========================================
# Helm 배포 명령어 출력
# ========================================
output "helm_install_command" {
  description = "Helm command to install OTEL Collector on target cluster"
  value = var.enable_target_monitoring && local.target_cluster_name != "" ? <<-EOT
# 1. kubeconfig 설정 (terraform_new 클러스터)
aws eks update-kubeconfig --name ${local.target_cluster_name} --region ${var.region}

# 2. OTEL Collector Helm 차트 배포
helm upgrade --install otel-collector ../../helm/otel-collector \
  --namespace monitoring --create-namespace \
  -f ../../helm/otel-collector/values-target-infra.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${try(aws_iam_role.target_otel_collector[0].arn, "")}" \
  --set config.exporters.prometheusremotewrite.endpoint="${module.amp.remote_write_url}" \
  --set config.exporters.awscloudwatchlogs.log_group_name="${try(aws_cloudwatch_log_group.target_otel[0].name, "")}" \
  --set config.processors.resource.attributes[0].value="${local.target_cluster_name}"
EOT
  : "Target monitoring not enabled. Set enable_target_monitoring = true and provide target_cluster_name."
}
