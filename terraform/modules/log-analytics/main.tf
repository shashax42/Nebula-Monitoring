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
# CloudWatch Logs 가공: 로그 그룹(보존=TTL), 메트릭 필터, Logs Insights 저장 쿼리
#
# gateway 가 남기는 로그 이벤트 형식 (awscloudwatchlogs exporter):
#   {"body": "...", "severity_text": "ERROR", "trace_id": "...", "span_id": "...",
#    "attributes": {"service": "...", "namespace": "...", "pod": "...", "level": "ERROR", "tenant_id": "...", ...},
#    "resource": {"k8s.cluster.name": "...", "deployment.environment": "...", ...}}
# ==========================================================================

locals {
  prefix = "/aws/eks/${var.cluster_name}"

  # 로그 클래스별 Hot 보존 기간(TTL). 장기 보관은 log-archive 모듈(S3, 7년)이 담당
  log_groups = {
    application = { retention = var.retention_days.application, desc = "앱 stdout/OTLP 로그 (정제·마스킹 후)" }
    audit       = { retention = var.retention_days.audit, desc = "감사/결제 로그 (S3 7년 아카이브 대상)" }
    events      = { retention = var.retention_days.events, desc = "Kubernetes Warning 이벤트" }
    metrics     = { retention = var.retention_days.metrics, desc = "EMF 원본 (CloudWatch 메트릭 추출용)" }
  }
  managed = { for k, v in local.log_groups : k => v if !contains(var.existing_log_groups, k) }

  name = { for k in keys(local.log_groups) : k => "${local.prefix}/${k}" }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.managed

  name              = local.name[each.key]
  retention_in_days = each.value.retention
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { LogClass = each.key })
}

# --------------------------------------------------------------------------
# 메트릭 필터: 로그 → CloudWatch 메트릭 (AMP 와 독립된 경로의 에러 신호)
# --------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "error_logs" {
  name           = "${var.environment}-error-logs"
  log_group_name = local.name["application"]
  pattern        = "{ ($.severity_text = \"ERROR\") || ($.severity_text = \"FATAL\") }"

  metric_transformation {
    name          = "ErrorLogs"
    namespace     = "Nebula/Logs"
    value         = "1"
    default_value = "0"
    dimensions = {
      Service = "$.attributes.service"
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_cloudwatch_log_metric_filter" "oom_events" {
  name           = "${var.environment}-k8s-oomkilled"
  log_group_name = local.name["events"]
  pattern        = "OOMKilled"

  metric_transformation {
    name          = "OOMKilledEvents"
    namespace     = "Nebula/Logs"
    value         = "1"
    default_value = "0"
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

# --------------------------------------------------------------------------
# Logs Insights 저장 쿼리 (Actionable Links: 대시보드/런북에서 바로 실행)
# --------------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "this" {
  for_each = {
    "01-errors-by-service" = {
      groups = ["application"]
      query  = <<-Q
        fields @timestamp, attributes.service as service, attributes.tenant_id as tenant, body, trace_id
        | filter severity_text in ["ERROR", "FATAL"]
        | stats count(*) as errors by service, bin(5m)
        | sort errors desc
      Q
    }
    "02-top-error-messages" = {
      groups = ["application"]
      query  = <<-Q
        fields @timestamp, attributes.service as service, body
        | filter severity_text in ["ERROR", "FATAL"]
        | parse body /(?<signature>^.{0,120})/
        | stats count(*) as occurrences, latest(trace_id) as sample_trace by service, signature
        | sort occurrences desc
        | limit 50
      Q
    }
    "03-logs-by-trace-id" = {
      groups = ["application", "audit"]
      query  = <<-Q
        fields @timestamp, attributes.service as service, severity_text, body, span_id
        | filter trace_id = "REPLACE_WITH_TRACE_ID"
        | sort @timestamp asc
      Q
    }
    "04-tenant-errors" = {
      groups = ["application"]
      query  = <<-Q
        fields @timestamp, attributes.tenant_id as tenant, attributes.service as service, body, trace_id
        | filter ispresent(attributes.tenant_id) and severity_text in ["ERROR", "FATAL"]
        | stats count(*) as errors by tenant, service
        | sort errors desc
      Q
    }
    "05-payment-audit-trail" = {
      groups = ["audit"]
      query  = <<-Q
        fields @timestamp, attributes.tenant_id as tenant, attributes.service as service, body, trace_id
        | sort @timestamp desc
        | limit 200
      Q
    }
    "06-k8s-warning-events" = {
      groups = ["events"]
      query  = <<-Q
        fields @timestamp, attributes.`k8s.event.reason` as reason, attributes.`k8s.object.kind` as kind,
               attributes.`k8s.object.name` as object, body
        | stats count(*) as events, latest(body) as last_message by reason, kind, object
        | sort events desc
      Q
    }
    "07-log-volume-by-service" = {
      groups = ["application"]
      query  = <<-Q
        fields attributes.service as service, severity_text
        | stats count(*) as records, sum(strlen(body)) as body_bytes by service, severity_text
        | sort body_bytes desc
      Q
    }
  }

  name            = "nebula-${var.environment}/${each.key}"
  log_group_names = [for g in each.value.groups : local.name[g]]
  query_string    = each.value.query

  depends_on = [aws_cloudwatch_log_group.this]
}
