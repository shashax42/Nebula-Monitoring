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
# CloudWatch Alarms / SNS  (Alertmanager 대체 계층)
#
#  - SLA 위반 / 에러 / 지연 / 결제 알람: gateway 가 EMF 로 보내는 Nebula/Application 메트릭
#      Requests, Errors, SlowRequests (Environment[, Service])
#      PaymentRequests (Environment, Outcome | FailureCategory | PaymentPg+Outcome)
#      PaymentLogicalErrors (Environment[, PaymentPg])
#  - 데이터 스토어: AWS/RDS (Aurora), AWS/ElastiCache (Redis) 기본 메트릭
#  - 파이프라인 독립 감시: AWS/Logs IncomingLogEvents (AMP 경로가 죽어도 동작)
#  - 모든 알림은 심각도별 SNS 토픽 2개로 수렴 (AMP Alertmanager 도 같은 토픽 사용)
# ==========================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ns = "Nebula/Application"

  # 서비스 단위 SLA 알람을 만들 서비스 (CloudWatch 알람은 서비스 이름을 미리 알아야 한다)
  slo_services = toset(var.slo_services)

  topics = {
    critical = aws_sns_topic.critical.arn
    warning  = aws_sns_topic.warning.arn
  }
}

# --------------------------------------------------------------------------
# SNS
# --------------------------------------------------------------------------
resource "aws_sns_topic" "critical" {
  name              = "${var.environment}-alerts-critical"
  display_name      = "Nebula ${var.environment} CRITICAL"
  kms_master_key_id = var.kms_key_id
  tags              = var.tags
}

resource "aws_sns_topic" "warning" {
  name              = "${var.environment}-alerts-warning"
  display_name      = "Nebula ${var.environment} WARNING"
  kms_master_key_id = var.kms_key_id
  tags              = var.tags
}

# CloudWatch Alarms 와 AMP Alertmanager(aps.amazonaws.com)가 게시할 수 있도록 허용
data "aws_iam_policy_document" "topic" {
  for_each = local.topics

  statement {
    sid       = "AccountOwner"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:ListSubscriptionsByTopic"]
    resources = [each.value]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [each.value]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  dynamic "statement" {
    for_each = var.amp_workspace_arn != "" ? [1] : []
    content {
      sid       = "AMPAlertManager"
      actions   = ["sns:Publish", "sns:GetTopicAttributes"]
      resources = [each.value]
      principals {
        type        = "Service"
        identifiers = ["aps.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
      condition {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [var.amp_workspace_arn]
      }
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  for_each = local.topics

  arn    = each.value
  policy = data.aws_iam_policy_document.topic[each.key].json
}

resource "aws_sns_topic_subscription" "critical_email" {
  for_each = toset(var.email_endpoints)

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "warning_email" {
  for_each = toset(var.warning_email_endpoints != null ? var.warning_email_endpoints : var.email_endpoints)

  topic_arn = aws_sns_topic.warning.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "chat_lambda" {
  for_each = var.chat_lambda_arn != "" ? local.topics : {}

  topic_arn = each.value
  protocol  = "lambda"
  endpoint  = var.chat_lambda_arn
}

# --------------------------------------------------------------------------
# SLA / Golden Signals (환경 전체)
# 트래픽이 없을 때(missing)는 정상으로 간주한다. 파이프라인 단절은 아래 heartbeat 알람이 잡는다.
# --------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "availability_sla" {
  alarm_name          = "${var.environment}-sla-availability"
  alarm_description   = "SLA 위반: 서버 요청 가용성 < ${var.availability_threshold}% (${var.metric_period / 60}분 × ${var.evaluation_periods}회). 런북: docs/RUNBOOK.md#sla-availability"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.evaluation_periods
  threshold           = var.availability_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "availability"
    expression  = "IF(requests >= ${var.min_requests_per_period}, 100 * (1 - FILL(errors, 0) / requests))"
    label       = "Availability %"
    return_data = true
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = local.ns
      metric_name = "Requests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = local.ns
      metric_name = "Errors"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
  tags          = merge(var.tags, { Severity = "Critical", Type = "SLA" })
}

resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.environment}-error-rate"
  alarm_description   = "서버 에러율 > ${var.error_rate_threshold}%. 런북: docs/RUNBOOK.md#sla-availability"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  threshold           = var.error_rate_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests >= ${var.min_requests_per_period}, 100 * FILL(errors, 0) / requests)"
    label       = "Error rate %"
    return_data = true
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = local.ns
      metric_name = "Requests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = local.ns
      metric_name = "Errors"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "High", Type = "Application" })
}

# "P95 < 임계" SLO ⇔ "임계 초과 요청 비율 < 5%". EMF 는 백분위수를 직접 못 주므로 비율로 평가한다.
resource "aws_cloudwatch_metric_alarm" "latency_slo" {
  alarm_name          = "${var.environment}-latency-slo"
  alarm_description   = "지연 SLO 위반: ${var.latency_threshold_ms}ms 초과 요청 > ${var.slow_request_ratio_threshold}% (= P${100 - var.slow_request_ratio_threshold} > ${var.latency_threshold_ms}ms). 런북: docs/RUNBOOK.md#slolatencyburn"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  threshold           = var.slow_request_ratio_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "slow_ratio"
    expression  = "IF(requests >= ${var.min_requests_per_period}, 100 * FILL(slow, 0) / requests)"
    label       = "Slow request %"
    return_data = true
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = local.ns
      metric_name = "Requests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }
  metric_query {
    id = "slow"
    metric {
      namespace   = local.ns
      metric_name = "SlowRequests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Performance" })
}

# 핵심 서비스별 가용성 SLA
resource "aws_cloudwatch_metric_alarm" "service_availability" {
  for_each = local.slo_services

  alarm_name          = "${var.environment}-sla-availability-${each.value}"
  alarm_description   = "${each.value} 가용성 < ${var.availability_threshold}%. 런북: docs/RUNBOOK.md#sla-availability"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.evaluation_periods
  threshold           = var.availability_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "availability"
    expression  = "IF(requests >= ${var.min_requests_per_period}, 100 * (1 - FILL(errors, 0) / requests))"
    return_data = true
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = local.ns
      metric_name = "Requests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment, Service = each.value }
    }
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = local.ns
      metric_name = "Errors"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment, Service = each.value }
    }
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
  tags          = merge(var.tags, { Severity = "Critical", Type = "SLA", Service = each.value })
}

# --------------------------------------------------------------------------
# 결제 (비즈니스 완결성)
# --------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "payment_pg_timeout" {
  alarm_name          = "${var.environment}-payment-pg-timeout"
  alarm_description   = "PG 타임아웃 실패 비율 > ${var.payment_pg_timeout_threshold}%. 카드 한도 초과 등 고객 원인 실패와 분리된 시스템 원인. 런북: docs/RUNBOOK.md#paymentsystemfailurehigh"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.payment_pg_timeout_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "timeout_ratio"
    expression  = "IF(total >= ${var.min_requests_per_period}, 100 * FILL(timeouts, 0) / total)"
    label       = "PG timeout %"
    return_data = true
  }
  metric_query {
    id = "total"
    metric {
      namespace   = local.ns
      metric_name = "PaymentRequests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }
  metric_query {
    id = "timeouts"
    metric {
      namespace   = local.ns
      metric_name = "PaymentRequests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment, FailureCategory = "pg_timeout" }
    }
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
  tags          = merge(var.tags, { Severity = "Critical", Type = "Business" })
}

resource "aws_cloudwatch_metric_alarm" "payment_failure_rate" {
  alarm_name          = "${var.environment}-payment-failure-rate"
  alarm_description   = "전체 결제 실패율 > ${var.payment_failure_threshold}% (고객 원인 포함). 카테고리별 분해는 Grafana 'Nebula / Business' 대시보드. 런북: docs/RUNBOOK.md#paymentsystemfailurehigh"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.payment_failure_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "failure_ratio"
    expression  = "IF(total >= ${var.min_requests_per_period}, 100 * FILL(failures, 0) / total)"
    return_data = true
  }
  metric_query {
    id = "total"
    metric {
      namespace   = local.ns
      metric_name = "PaymentRequests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment }
    }
  }
  metric_query {
    id = "failures"
    metric {
      namespace   = local.ns
      metric_name = "PaymentRequests"
      stat        = "Sum"
      period      = var.metric_period
      dimensions  = { Environment = var.environment, Outcome = "failure" }
    }
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "High", Type = "Business" })
}

# HTTP 200 인데 결제 실패 — HTTP 지표로는 보이지 않는 조용한 실패
resource "aws_cloudwatch_metric_alarm" "payment_logical_errors" {
  alarm_name          = "${var.environment}-payment-logical-errors"
  alarm_description   = "결제 논리 오류(HTTP 2xx + 결제 실패) ${var.payment_logical_error_threshold}건 초과 / ${var.metric_period / 60}분. 런북: docs/RUNBOOK.md#paymentlogicalerrors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "PaymentLogicalErrors"
  namespace           = local.ns
  period              = var.metric_period
  statistic           = "Sum"
  threshold           = var.payment_logical_error_threshold
  treat_missing_data  = "notBreaching"
  dimensions          = { Environment = var.environment }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
  tags          = merge(var.tags, { Severity = "Critical", Type = "Business" })
}

# --------------------------------------------------------------------------
# 파이프라인 독립 감시 (AMP 경로와 무관)
# 애플리케이션 로그가 일정 시간 0건이면 수집 파이프라인 단절로 판단 → missing 도 breaching
# --------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "log_ingestion_stopped" {
  count = var.application_log_group_name != "" ? 1 : 0

  alarm_name          = "${var.environment}-telemetry-log-ingestion-stopped"
  alarm_description   = "${var.application_log_group_name} 에 ${var.log_heartbeat_minutes}분간 로그 유입 0건 → OTel agent/gateway 또는 IRSA 점검. 런북: docs/RUNBOOK.md#telemetrygatewayabsent"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.log_heartbeat_minutes / 5
  metric_name         = "IncomingLogEvents"
  namespace           = "AWS/Logs"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { LogGroupName = var.application_log_group_name }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
  tags          = merge(var.tags, { Severity = "Critical", Type = "Monitoring" })
}

# --------------------------------------------------------------------------
# Aurora (MySQL)
# --------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  for_each = toset(var.aurora_cluster_identifiers)

  alarm_name          = "${var.environment}-aurora-${each.value}-cpu-high"
  alarm_description   = "Aurora ${each.value} CPU > ${var.aurora_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.aurora_cpu_threshold
  treat_missing_data  = "notBreaching"
  dimensions          = { DBClusterIdentifier = each.value, Role = "WRITER" }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Datastore" })
}

# 락 경합: Noisy Neighbor / 특정 고객 대용량 쿼리의 DB 측 증상
resource "aws_cloudwatch_metric_alarm" "aurora_deadlocks" {
  for_each = toset(var.aurora_cluster_identifiers)

  alarm_name          = "${var.environment}-aurora-${each.value}-deadlocks"
  alarm_description   = "Aurora ${each.value} 데드락 발생 (초당 평균 > ${var.aurora_deadlock_threshold}). 테넌트별 DB 점유율(tenant:db_time_share:ratio5m)과 함께 확인. 런북: docs/RUNBOOK.md#tenantnoisyneighbor"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Deadlocks"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.aurora_deadlock_threshold
  treat_missing_data  = "notBreaching"
  dimensions          = { DBClusterIdentifier = each.value, Role = "WRITER" }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Datastore" })
}

resource "aws_cloudwatch_metric_alarm" "aurora_replica_lag" {
  for_each = toset(var.aurora_cluster_identifiers)

  alarm_name          = "${var.environment}-aurora-${each.value}-replica-lag"
  alarm_description   = "Aurora ${each.value} 리더 복제 지연 > ${var.aurora_replica_lag_ms}ms (읽기 일관성 저하)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.aurora_replica_lag_ms
  treat_missing_data  = "notBreaching"
  dimensions          = { DBClusterIdentifier = each.value, Role = "READER" }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Datastore" })
}

# --------------------------------------------------------------------------
# ElastiCache (Redis) — 노드(CacheClusterId) 단위
# --------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  for_each = toset(var.redis_cache_cluster_ids)

  alarm_name          = "${var.environment}-redis-${each.value}-engine-cpu-high"
  alarm_description   = "Redis ${each.value} EngineCPU > ${var.redis_cpu_threshold}% (단일 스레드 포화)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = var.redis_cpu_threshold
  treat_missing_data  = "notBreaching"
  dimensions          = { CacheClusterId = each.value }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Datastore" })
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  for_each = toset(var.redis_cache_cluster_ids)

  alarm_name          = "${var.environment}-redis-${each.value}-memory-high"
  alarm_description   = "Redis ${each.value} 메모리 사용률 > ${var.redis_memory_threshold}% (eviction 임박)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = var.redis_memory_threshold
  treat_missing_data  = "notBreaching"
  dimensions          = { CacheClusterId = each.value }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Datastore" })
}

resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  for_each = toset(var.redis_cache_cluster_ids)

  alarm_name          = "${var.environment}-redis-${each.value}-evictions"
  alarm_description   = "Redis ${each.value} 키 축출 발생 (캐시 적중률 하락 → DB 부하 전이)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = var.redis_evictions_threshold
  treat_missing_data  = "notBreaching"
  dimensions          = { CacheClusterId = each.value }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
  tags          = merge(var.tags, { Severity = "Medium", Type = "Datastore" })
}

# --------------------------------------------------------------------------
# Composite: 고객 영향이 확정된 서비스 저하 (한 번만 호출)
# --------------------------------------------------------------------------
resource "aws_cloudwatch_composite_alarm" "service_degradation" {
  alarm_name        = "${var.environment}-service-degradation"
  alarm_description = "SLA 위반 또는 (에러율 + 지연 SLO 동시 위반) 또는 결제 PG 타임아웃 → 고객 영향 확정"
  actions_enabled   = true

  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.availability_sla.alarm_name})",
    "(ALARM(${aws_cloudwatch_metric_alarm.error_rate.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.latency_slo.alarm_name}))",
    "ALARM(${aws_cloudwatch_metric_alarm.payment_pg_timeout.alarm_name})",
  ])

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
  tags          = merge(var.tags, { Severity = "Critical", Type = "Composite" })
}
