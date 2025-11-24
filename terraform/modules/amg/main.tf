terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# IAM Role for Grafana Workspace
resource "aws_iam_role" "grafana" {
  name               = "${var.workspace_name}-grafana-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "grafana.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# IAM Policy for Grafana to access data sources
resource "aws_iam_role_policy" "grafana_datasources" {
  name = "${var.workspace_name}-datasources"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadingMetricsFromAMP"
        Effect = "Allow"
        Action = [
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace",
          "aps:QueryMetrics",
          "aps:GetLabels",
          "aps:GetSeries",
          "aps:GetMetricMetadata"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowReadingMetricsFromCloudWatch"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowReadingLogsFromCloudWatch"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowReadingTracesFromXRay"
        Effect = "Allow"
        Action = [
          "xray:BatchGetTraces",
          "xray:GetServiceGraph",
          "xray:GetTraceGraph",
          "xray:GetTraceSummaries",
          "xray:GetGroups",
          "xray:GetGroup",
          "xray:GetSamplingRules"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowReadingTagsAndEC2DescribeInstances"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions"
        ]
        Resource = "*"
      }
    ]
  })
}

# Grafana Workspace
resource "aws_grafana_workspace" "main" {
  name                     = var.workspace_name
  description              = var.workspace_description
  account_access_type      = var.account_access_type
  authentication_providers = var.authentication_providers
  permission_type          = var.permission_type
  role_arn                = aws_iam_role.grafana.arn
  
  # Data sources to enable
  data_sources = var.data_sources
  
  # Notification channels
  notification_destinations = var.notification_destinations
  
  # Organization role mapping (for SAML/SSO)
  dynamic "configuration" {
    for_each = var.enable_sso ? [1] : []
    content {
      plugins = jsonencode({
        # Enable useful plugins
        plugins = [
          "grafana-piechart-panel",
          "grafana-worldmap-panel",
          "grafana-clock-panel",
          "grafana-simple-json-datasource"
        ]
      })
    }
  }
  
  # VPC configuration for private access
  dynamic "vpc_configuration" {
    for_each = var.vpc_configuration != null ? [var.vpc_configuration] : []
    content {
      security_group_ids = vpc_configuration.value.security_group_ids
      subnet_ids         = vpc_configuration.value.subnet_ids
    }
  }
  
  # Grafana version
  grafana_version = var.grafana_version
  
  tags = var.tags
}

# API Key for programmatic access (optional)
resource "aws_grafana_workspace_api_key" "main" {
  count = var.create_api_key ? 1 : 0

  key_name        = "${var.workspace_name}-api-key"
  key_role        = "ADMIN"
  seconds_to_live = var.api_key_seconds_to_live
  workspace_id    = aws_grafana_workspace.main.id
}

# SAML Configuration (if using SAML)
resource "aws_grafana_workspace_saml_configuration" "main" {
  count = var.saml_configuration != null ? 1 : 0

  workspace_id = aws_grafana_workspace.main.id
  editor_role_values = var.saml_configuration.editor_role_values
  admin_role_values  = var.saml_configuration.admin_role_values
  
  idp_metadata {
    url = var.saml_configuration.idp_metadata_url
    xml = var.saml_configuration.idp_metadata_xml
  }
  
  login_assertion_attributes {
    email = var.saml_configuration.email_assertion
    name  = var.saml_configuration.name_assertion
    login = var.saml_configuration.login_assertion
    role  = var.saml_configuration.role_assertion
    org   = var.saml_configuration.org_assertion
  }
}

# CloudWatch Log Group for Grafana audit logs
resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/aws/grafana/${var.workspace_name}"
  retention_in_days = var.log_retention_days
  
  tags = var.tags
}
