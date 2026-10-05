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
  profile = var.aws_profile

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

  repo_root = "${path.module}/../../.."

  # 실제로 모니터링하는 클러스터: terraform_new 연결 시 그 클러스터, 아니면 var.cluster_name
  monitored_cluster_name = local.target_cluster_name != "" ? local.target_cluster_name : var.cluster_name

  # 애플리케이션 로그 그룹은 기존 리소스(main.tf / target-infrastructure.tf)가 관리한다
  application_log_group_name = "/aws/eks/${local.monitored_cluster_name}/application"

  # prometheus/rules/*.rules.yaml → AMP 룰 그룹 네임스페이스 (파일 1개 = 네임스페이스 1개)
  prometheus_rule_files = fileset("${local.repo_root}/prometheus/rules", "*.rules.yaml")
}

# ==========================================================================
# 저장: AMP (메트릭) + 가공: 레코딩 규칙 + 트리거: 알림 규칙 → Alertmanager → SNS
# ==========================================================================
module "amp" {
  source = "../../modules/amp"

  workspace_alias    = "nebula-${var.environment}"
  log_retention_days = var.log_retention_days
  tags               = local.common_tags

  rule_groups = {
    for f in local.prometheus_rule_files :
    "nebula-${trimsuffix(f, ".rules.yaml")}" => file("${local.repo_root}/prometheus/rules/${f}")
  }

  enable_alert_manager = true
  alert_manager_definition = templatefile("${local.repo_root}/prometheus/alertmanager/alertmanager.yaml.tftpl", {
    critical_topic_arn = module.cloudwatch_alarms.critical_sns_topic_arn
    warning_topic_arn  = module.cloudwatch_alarms.sns_topic_arn
    region             = var.region
  })
}

# IAM IRSA for OTEL Collector
# TODO: EKS 클러스터 생성 후 또는 EKS 권한 추가 후 주석 해제
# (terraform_new 클러스터는 target-infrastructure.tf 의 IRSA 역할을 사용)
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

# ==========================================================================
# 로그 가공: 로그 그룹(클래스별 TTL) + 메트릭 필터 + Logs Insights 저장 쿼리
# ==========================================================================
module "log_analytics" {
  source = "../../modules/log-analytics"

  environment         = var.environment
  cluster_name        = local.monitored_cluster_name
  existing_log_groups = ["application"]
  retention_days = {
    application = var.log_retention_days
    audit       = var.audit_log_hot_retention_days
    events      = 14
    metrics     = 1
  }
  tags = local.common_tags

  depends_on = [aws_cloudwatch_log_group.application, aws_cloudwatch_log_group.target_application]
}

# ==========================================================================
# 콜드 데이터: 감사/결제 로그 → S3 7년 보관 (Hot 은 CloudWatch, TTL 경과 후 S3 에서만 조회)
# ==========================================================================
module "log_archive" {
  source = "../../modules/log-archive"
  count  = var.enable_log_archive ? 1 : 0

  environment = var.environment
  log_groups = merge(
    { audit = module.log_analytics.log_group_names["audit"] },
    var.archive_application_logs ? { application = local.application_log_group_name } : {}
  )
  retention_days      = var.archive_retention_days
  object_lock_enabled = var.archive_object_lock
  tags                = local.common_tags
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

output "otel_collector_log_group" {
  description = "CloudWatch Log Group for OTEL Collector"
  value       = aws_cloudwatch_log_group.otel_collector.name
}

output "application_log_group" {
  description = "CloudWatch Log Group for Applications"
  value       = aws_cloudwatch_log_group.application.name
}

output "log_group_names" {
  description = "모니터링 클러스터의 로그 클래스별 로그 그룹"
  value       = module.log_analytics.log_group_names
}

output "log_archive_bucket" {
  description = "콜드 로그 아카이브 S3 버킷"
  value       = var.enable_log_archive ? module.log_archive[0].bucket_name : null
}

# Amazon Managed Grafana
module "amg" {
  source = "../../modules/amg"

  workspace_name            = "nebula-${var.environment}"
  workspace_description     = "Grafana workspace for Nebula monitoring - ${var.environment}"
  authentication_providers  = ["AWS_SSO"]
  data_sources              = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
  notification_destinations = ["SNS"]
  log_retention_days        = var.log_retention_days

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

# ==========================================================================
# CloudWatch Alarms / SNS (Alertmanager 대체): SLA 위반·에러·지연·결제·데이터스토어·파이프라인
# ==========================================================================
data "aws_elasticache_replication_group" "redis" {
  for_each             = toset(var.redis_replication_group_ids)
  replication_group_id = each.value
}

module "cloudwatch_alarms" {
  source = "../../modules/cloudwatch-alarms"

  environment       = var.environment
  amp_workspace_arn = module.amp.workspace_arn

  # SNS Configuration
  email_endpoints = var.alarm_email_endpoints

  # Application SLO / SLA (EMF: Nebula/Application)
  slo_services                 = var.slo_services
  availability_threshold       = 99.9 # 99.9% availability
  error_rate_threshold         = 5    # 5% error rate
  latency_threshold_ms         = 1000 # P95 < 1s ⇔ 1s 초과 요청 < 5%
  slow_request_ratio_threshold = 5

  # Pipeline heartbeat (AMP 와 독립된 감시 경로)
  application_log_group_name = local.application_log_group_name

  # Data stores (terraform_new: Aurora MySQL / ElastiCache Redis)
  aurora_cluster_identifiers = var.aurora_cluster_identifiers
  redis_cache_cluster_ids    = flatten([for rg in data.aws_elasticache_replication_group.redis : tolist(rg.member_clusters)])

  tags = local.common_tags
}

output "alarm_sns_topic" {
  description = "SNS topic ARN for warning alarms"
  value       = module.cloudwatch_alarms.sns_topic_arn
}

output "critical_alarm_sns_topic" {
  description = "SNS topic ARN for critical alarms"
  value       = module.cloudwatch_alarms.critical_sns_topic_arn
}

output "critical_alarms" {
  description = "List of critical alarm ARNs"
  value       = module.cloudwatch_alarms.critical_alarms
}

# X-Ray Service Map Configuration
module "xray" {
  source = "../../modules/xray"

  environment = var.environment

  # Sampling configuration (X-Ray SDK 사용 워크로드용. OTel 워크로드는 gateway tail_sampling 사용)
  default_fixed_rate             = 0.1 # 10% for dev
  critical_services              = ["api", "auth", "payment"]
  critical_service_sampling_rate = 0.5 # 50% for critical services

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
