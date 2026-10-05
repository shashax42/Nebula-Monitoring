terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==========================================================================
# 계정 분리 운영 (Operability: prod-us ↔ prod-eu, customer-A ↔ prod-eu)
#
# 워크로드 계정마다 수집 파이프라인은 그대로 두고, 저장/조회 계층만 모니터링 계정으로 모은다.
#   워크로드 계정 gateway(IRSA 역할) ──AssumeRole──▶ 이 역할 ──▶ 모니터링 계정 AMP / CloudWatch Logs / X-Ray
#
# gateway 설정 (Helm values 오버라이드):
#   gateway.config.extensions.sigv4auth.assume_role.arn = <이 모듈 output role_arn>
#   gateway.config.exporters.awscloudwatchlogs/*.role_arn = <role_arn>
#   gateway.config.exporters.awsxray.role_arn            = <role_arn>
# 테넌트 전용 계정(customer-A)은 routing/logs 에 tenant_id 조건 + 전용 exporter 를 추가해 분리한다.
# ==========================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "ingest" {
  name                 = var.role_name
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "WorkloadCollectors"
      Effect    = "Allow"
      Principal = { AWS = var.source_role_arns }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = length(var.allowed_external_ids) > 0 ? {
        StringEquals = { "sts:ExternalId" = var.allowed_external_ids }
      } : null
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ingest" {
  name = "telemetry-ingest"
  role = aws_iam_role.ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AMPRemoteWrite"
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = var.amp_workspace_arn
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
        Resource = [
          for p in var.log_group_prefixes :
          "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${p}*"
        ]
      },
      {
        Sid      = "XRayWrite"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      }
    ]
  })
}
