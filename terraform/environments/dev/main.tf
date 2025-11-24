terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  # Backend configuration for state management
  backend "s3" {
    bucket         = "nebula-terraform-state"
    key            = "monitoring/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "nebula-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  
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
module "otel_collector_irsa" {
  source = "../../modules/iam-irsa"
  
  cluster_name      = var.cluster_name
  namespace         = var.otel_namespace
  service_account   = var.otel_service_account
  region           = var.region
  amp_workspace_arn = module.amp.workspace_arn
  tags             = local.common_tags
}

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

output "otel_collector_role_arn" {
  description = "IAM Role ARN for OTEL Collector"
  value       = module.otel_collector_irsa.role_arn
}

output "service_account_annotations" {
  description = "Service Account annotations for IRSA"
  value       = module.otel_collector_irsa.service_account_annotations
}

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
  authentication_providers  = ["AWS_SSO"]
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
