terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# SNS Topic for Alarms
resource "aws_sns_topic" "alarms" {
  name              = "${var.environment}-monitoring-alarms"
  display_name      = "Monitoring Alarms for ${var.environment}"
  kms_master_key_id = var.kms_key_id
  
  tags = var.tags
}

# SNS Topic Subscription (Email)
resource "aws_sns_topic_subscription" "email" {
  count = length(var.email_endpoints)
  
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.email_endpoints[count.index]
}

# SNS Topic Subscription (Slack via Lambda)
resource "aws_sns_topic_subscription" "slack" {
  count = var.slack_webhook_url != "" ? 1 : 0
  
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "lambda"
  endpoint  = var.slack_lambda_arn
}

# ============================================
# Application Performance Alarms (SLO-based)
# ============================================

# High Error Rate Alarm
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.environment}-high-error-rate"
  alarm_description   = "Error rate exceeds ${var.error_rate_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"  # Or custom namespace
  period              = var.metric_period
  statistic           = "Average"
  threshold           = var.error_rate_threshold
  treat_missing_data  = "notBreaching"
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "High"
    Type     = "Application"
  })
}

# High Latency Alarm (P95)
resource "aws_cloudwatch_metric_alarm" "high_latency_p95" {
  alarm_name          = "${var.environment}-high-latency-p95"
  alarm_description   = "P95 latency exceeds ${var.latency_p95_threshold}ms"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  threshold           = var.latency_p95_threshold
  treat_missing_data  = "notBreaching"
  
  metric_query {
    id          = "p95"
    return_data = true
    
    metric {
      namespace   = "Nebula/Application"
      metric_name = "RequestDuration"
      stat        = "p95"
      period      = var.metric_period
      
      dimensions = {
        Environment = var.environment
      }
    }
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Medium"
    Type     = "Performance"
  })
}

# Low Availability Alarm (SLO)
resource "aws_cloudwatch_metric_alarm" "low_availability" {
  alarm_name          = "${var.environment}-low-availability"
  alarm_description   = "Availability below ${var.availability_threshold}%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.evaluation_periods
  threshold           = var.availability_threshold
  treat_missing_data  = "breaching"
  
  metric_query {
    id          = "availability"
    expression  = "100 - (errors / requests * 100)"
    return_data = true
  }
  
  metric_query {
    id = "errors"
    
    metric {
      namespace   = "Nebula/Application"
      metric_name = "Errors"
      stat        = "Sum"
      period      = var.metric_period
      
      dimensions = {
        Environment = var.environment
      }
    }
  }
  
  metric_query {
    id = "requests"
    
    metric {
      namespace   = "Nebula/Application"
      metric_name = "Requests"
      stat        = "Sum"
      period      = var.metric_period
      
      dimensions = {
        Environment = var.environment
      }
    }
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Critical"
    Type     = "SLO"
  })
}

# ============================================
# Infrastructure Alarms
# ============================================

# EKS Node CPU Utilization
resource "aws_cloudwatch_metric_alarm" "eks_node_cpu_high" {
  alarm_name          = "${var.environment}-eks-node-cpu-high"
  alarm_description   = "EKS node CPU utilization exceeds ${var.cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = var.metric_period
  statistic           = "Average"
  threshold           = var.cpu_threshold
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    ClusterName = var.cluster_name
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Medium"
    Type     = "Infrastructure"
  })
}

# EKS Node Memory Utilization
resource "aws_cloudwatch_metric_alarm" "eks_node_memory_high" {
  alarm_name          = "${var.environment}-eks-node-memory-high"
  alarm_description   = "EKS node memory utilization exceeds ${var.memory_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = var.metric_period
  statistic           = "Average"
  threshold           = var.memory_threshold
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    ClusterName = var.cluster_name
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Medium"
    Type     = "Infrastructure"
  })
}

# Pod Restart Rate
resource "aws_cloudwatch_metric_alarm" "pod_restart_rate_high" {
  alarm_name          = "${var.environment}-pod-restart-rate-high"
  alarm_description   = "Pod restart rate exceeds ${var.pod_restart_threshold} per minute"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = var.metric_period
  statistic           = "Sum"
  threshold           = var.pod_restart_threshold
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    ClusterName = var.cluster_name
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "High"
    Type     = "Stability"
  })
}

# ============================================
# OTEL Collector Health Alarms
# ============================================

# OTEL Collector Down
resource "aws_cloudwatch_metric_alarm" "otel_collector_down" {
  alarm_name          = "${var.environment}-otel-collector-down"
  alarm_description   = "OTEL Collector is not sending metrics"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "otelcol_process_uptime"
  namespace           = "OpenTelemetryCollector"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "breaching"
  
  dimensions = {
    service_name = "otel-collector"
    environment  = var.environment
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Critical"
    Type     = "Monitoring"
  })
}

# OTEL Collector Memory Usage
resource "aws_cloudwatch_metric_alarm" "otel_collector_memory_high" {
  alarm_name          = "${var.environment}-otel-collector-memory-high"
  alarm_description   = "OTEL Collector memory usage exceeds 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "otelcol_process_memory_rss"
  namespace           = "OpenTelemetryCollector"
  period              = var.metric_period
  statistic           = "Average"
  threshold           = 1717986918  # 80% of 2Gi in bytes
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    service_name = "otel-collector"
    environment  = var.environment
  }
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Medium"
    Type     = "Monitoring"
  })
}

# ============================================
# Composite Alarms (Multiple conditions)
# ============================================

# Critical Service Degradation (Composite)
resource "aws_cloudwatch_composite_alarm" "service_degradation" {
  alarm_name          = "${var.environment}-service-degradation"
  alarm_description   = "Multiple indicators show service degradation"
  actions_enabled     = true
  
  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.high_error_rate.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.low_availability.alarm_name})",
    "(ALARM(${aws_cloudwatch_metric_alarm.high_latency_p95.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.pod_restart_rate_high.alarm_name}))"
  ])
  
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  
  tags = merge(var.tags, {
    Severity = "Critical"
    Type     = "Composite"
  })
}
