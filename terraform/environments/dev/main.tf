terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  # Backend configuration for state management
  # TODO: S3 버킷 권한 설정 후 주석 해제
  # backend "s3" {
  #   bucket         = "nebula-terraform-state"
  #   key            = "monitoring/dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "nebula-terraform-locks"
  #   encrypt        = true
  #   profile        = "monitoring-admin"
  # }
}

provider "aws" {
  region  = var.region
  profile = "monitoring-admin"
  
  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Environment = var.environment
    Project     = "Nebula"
    ManagedBy   = "Terraform"
    Team        = "Platform"
  }
}

# AMP (Amazon Managed Prometheus)
module "amp" {
  source = "../../modules/amp"
  
  workspace_alias    = "nebula-${var.environment}"
  log_retention_days = var.log_retention_days
  tags              = local.common_tags
}

# IAM IRSA for OTEL Collector
# TODO: EKS 클러스터 생성 후 또는 EKS 권한 추가 후 주석 해제
# module "otel_collector_irsa" {
#   source = "../../modules/iam-irsa"
#   
#   cluster_name      = var.cluster_name
#   namespace         = var.otel_namespace
#   service_account   = var.otel_service_account
#   region           = var.region
#   amp_workspace_arn = module.amp.workspace_arn
#   tags             = local.common_tags
# }

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "otel_collector" {
  name              = "/aws/eks/${var.cluster_name}/otel-collector"
  retention_in_days = var.log_retention_days
  
  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "application" {
  name              = "/aws/eks/${var.cluster_name}/application"
  retention_in_days = var.log_retention_days
  
  tags = local.common_tags
}

# Output values for Helm chart
output "amp_workspace_id" {
  description = "AMP Workspace ID"
  value       = module.amp.workspace_id
}

output "amp_endpoint" {
  description = "AMP Endpoint URL"
  value       = module.amp.workspace_endpoint
}

output "amp_remote_write_url" {
  description = "AMP Remote Write URL"
  value       = module.amp.remote_write_url
}

# TODO: IRSA 모듈 활성화 후 주석 해제
# output "otel_collector_role_arn" {
#   description = "IAM Role ARN for OTEL Collector"
#   value       = module.otel_collector_irsa.role_arn
# }

# output "service_account_annotations" {
#   description = "Service Account annotations for IRSA"
#   value       = module.otel_collector_irsa.service_account_annotations
# }

output "otel_collector_log_group" {
  description = "CloudWatch Log Group for OTEL Collector"
  value       = aws_cloudwatch_log_group.otel_collector.name
}

output "application_log_group" {
  description = "CloudWatch Log Group for Applications"
  value       = aws_cloudwatch_log_group.application.name
}

# Amazon Managed Grafana
module "amg" {
  source = "../../modules/amg"
  
  workspace_name            = "nebula-${var.environment}"
  workspace_description     = "Grafana workspace for Nebula monitoring - ${var.environment}"
  authentication_providers  = ["SAML"]
  data_sources             = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
  notification_destinations = ["SNS"]
  log_retention_days       = var.log_retention_days
  
  tags = local.common_tags
}

output "grafana_workspace_endpoint" {
  description = "Grafana workspace endpoint URL"
  value       = module.amg.workspace_endpoint
}

output "grafana_workspace_id" {
  description = "Grafana workspace ID"
  value       = module.amg.workspace_id
}

# CloudWatch Alarms
module "cloudwatch_alarms" {
  source = "../../modules/cloudwatch-alarms"
  
  environment  = var.environment
  cluster_name = var.cluster_name
  
  # SNS Configuration
  email_endpoints = ["ops-team@nebula.com"]  # 실제 이메일로 변경 필요
  
  # Application SLO Thresholds
  error_rate_threshold   = 5      # 5% error rate
  latency_p95_threshold  = 1000   # 1 second
  availability_threshold = 99.9   # 99.9% availability
  
  # Infrastructure Thresholds
  cpu_threshold         = 80
  memory_threshold      = 80
  pod_restart_threshold = 5
  
  tags = local.common_tags
}

output "alarm_sns_topic" {
  description = "SNS topic ARN for alarms"
  value       = module.cloudwatch_alarms.sns_topic_arn
}

output "critical_alarms" {
  description = "List of critical alarm ARNs"
  value       = module.cloudwatch_alarms.critical_alarms
}

# X-Ray Service Map Configuration
module "xray" {
  source = "../../modules/xray"
  
  environment = var.environment
  
  # Sampling configuration
  default_fixed_rate      = 0.1  # 10% for dev
  critical_services       = ["api", "auth", "payment"]
  critical_service_sampling_rate = 0.5  # 50% for critical services
  
  # Microservices to track
  microservices = [
    "api-gateway",
    "auth-service",
    "user-service",
    "payment-service",
    "notification-service",
    "inventory-service"
  ]
  
  # Performance thresholds
  latency_threshold_seconds = 3
  
  # X-Ray Insights
  enable_insights_notifications = true
  
  tags = local.common_tags
}

output "xray_service_map_url" {
  description = "X-Ray Service Map URL"
  value       = module.xray.service_map_url
}

output "xray_traces_url" {
  description = "X-Ray Traces URL"
  value       = module.xray.traces_url
}
