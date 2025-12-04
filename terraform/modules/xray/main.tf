terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ============================================
# X-Ray Sampling Rules
# ============================================

# Default sampling rule
resource "aws_xray_sampling_rule" "default" {
  rule_name      = "${var.environment}-default"
  priority       = 9999
  version        = 1
  reservoir_size = var.default_reservoir_size
  fixed_rate     = var.default_fixed_rate
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
  
  attributes = var.tags
}

# High priority sampling for errors
resource "aws_xray_sampling_rule" "errors" {
  rule_name      = "${var.environment}-errors"
  priority       = 1
  version        = 1
  reservoir_size = 10
  fixed_rate     = 1.0  # Sample 100% of errors
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
  
  # Only sample responses with error status codes
  attributes = merge(var.tags, {
    "http.status_code" = "5*"
  })
}

# Sampling rule for critical services
resource "aws_xray_sampling_rule" "critical_services" {
  count = length(var.critical_services)
  
  rule_name      = "${var.environment}-critical-${var.critical_services[count.index]}"
  priority       = 100 + count.index
  version        = 1
  reservoir_size = 5
  fixed_rate     = var.critical_service_sampling_rate
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = var.critical_services[count.index]
  resource_arn   = "*"
  
  attributes = var.tags
}

# ============================================
# X-Ray Groups for Service Organization
# ============================================

# Group for production services
resource "aws_xray_group" "production" {
  count = var.environment == "production" ? 1 : 0
  
  group_name        = "Production-Services"
  filter_expression = "service(\"*.production.*\")"
  
  insights_configuration {
    insights_enabled      = true
    notifications_enabled = var.enable_insights_notifications
  }
  
  tags = var.tags
}

# Group for each microservice
resource "aws_xray_group" "microservices" {
  for_each = toset(var.microservices)
  
  group_name        = "${var.environment}-${each.value}"
  filter_expression = "service(\"${each.value}\")"
  
  insights_configuration {
    insights_enabled      = true
    notifications_enabled = var.enable_insights_notifications
  }
  
  tags = merge(var.tags, {
    Service = each.value
  })
}

# Group for high latency traces
resource "aws_xray_group" "high_latency" {
  group_name        = "${var.environment}-high-latency"
  filter_expression = "duration > ${var.latency_threshold_seconds}"
  
  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }
  
  tags = merge(var.tags, {
    Type = "Performance"
  })
}

# Group for error traces
resource "aws_xray_group" "errors" {
  group_name        = "${var.environment}-errors"
  filter_expression = "error = true OR fault = true"
  
  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }
  
  tags = merge(var.tags, {
    Type = "Errors"
  })
}

# ============================================
# X-Ray Encryption Configuration
# ============================================

resource "aws_xray_encryption_config" "main" {
  count = var.kms_key_id != null ? 1 : 0
  
  type   = "KMS"
  key_id = var.kms_key_id
}

# ============================================
# Service Map Configuration via OTEL
# ============================================

# Note: Service Map is automatically generated from traces
# sent by OTEL Collector. This configuration ensures
# proper trace collection and processing.

locals {
  service_map_config = {
    # Service naming convention
    service_name_prefix = "nebula"
    environment_tag     = var.environment
    
    # Trace processing
    trace_id_ratio_based = var.default_fixed_rate
    
    # Service discovery annotations
    annotations = {
      "service.namespace"  = "nebula"
      "deployment.environment" = var.environment
      "telemetry.sdk.name"    = "opentelemetry"
    }
  }
}

# ============================================
# CloudWatch Dashboard for X-Ray Metrics
# ============================================

resource "aws_cloudwatch_dashboard" "xray_service_map" {
  dashboard_name = "${var.environment}-xray-service-map"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title   = "Service Map Overview"
          region  = data.aws_region.current.name
          metrics = [
            ["AWS/X-Ray", "TracesReceived", { stat = "Sum" }],
            [".", "TracesProcessed", { stat = "Sum" }],
            [".", "LatencyHigh", { stat = "Average" }],
            [".", "ErrorRate", { stat = "Average" }]
          ]
          period = 300
          stat   = "Average"
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title   = "Service Latency Distribution"
          region  = data.aws_region.current.name
          metrics = [
            ["AWS/X-Ray", "Duration", { stat = "p50", label = "P50" }],
            ["...", { stat = "p90", label = "P90" }],
            ["...", { stat = "p95", label = "P95" }],
            ["...", { stat = "p99", label = "P99" }]
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title   = "Service Error Rates"
          region  = data.aws_region.current.name
          metrics = [
            ["AWS/X-Ray", "ErrorRate", { stat = "Average" }],
            [".", "FaultRate", { stat = "Average" }],
            [".", "ThrottleRate", { stat = "Average" }]
          ]
          period = 300
          view   = "timeSeries"
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
        }
      },
      {
        type = "metric"
        properties = {
          title   = "Trace Processing"
          region  = data.aws_region.current.name
          metrics = [
            ["AWS/X-Ray", "TracesReceived", { stat = "Sum" }],
            [".", "TracesProcessed", { stat = "Sum" }],
            [".", "TracesSpillover", { stat = "Sum" }]
          ]
          period = 300
          view   = "singleValue"
        }
      }
    ]
  })
}

# ============================================
# IAM Role for X-Ray Daemon (if needed)
# ============================================

resource "aws_iam_role" "xray_daemon" {
  count = var.create_daemon_role ? 1 : 0
  
  name = "${var.environment}-xray-daemon"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "xray_daemon" {
  count = var.create_daemon_role ? 1 : 0
  
  role       = aws_iam_role.xray_daemon[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "xray_daemon_custom" {
  count = var.create_daemon_role ? 1 : 0
  
  name = "xray-daemon-policy"
  role = aws_iam_role.xray_daemon[0].id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
