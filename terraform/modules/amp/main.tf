# Amazon Managed Prometheus Workspace
resource "aws_prometheus_workspace" "this" {
  alias = var.workspace_alias

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }

  tags = merge(
    var.tags,
    {
      Name      = var.workspace_alias
      ManagedBy = "Terraform"
      Service   = "Monitoring"
    }
  )
}

# CloudWatch Log Group for AMP
resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/prometheus/${var.workspace_alias}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Alert Manager Definition (optional) — 라우팅 대상은 SNS (self-hosted Alertmanager 없음)
resource "aws_prometheus_alert_manager_definition" "this" {
  count = var.enable_alert_manager ? 1 : 0

  workspace_id = aws_prometheus_workspace.this.id
  definition   = var.alert_manager_definition

  lifecycle {
    precondition {
      condition     = length(var.alert_manager_definition) > 0
      error_message = "alert_manager_definition must be set when enable_alert_manager is true."
    }
  }
}

# Rule Groups: prometheus/rules/*.yaml (레코딩 = 가공, 알림 = 트리거)
resource "aws_prometheus_rule_group_namespace" "this" {
  for_each = var.rule_groups

  name         = each.key
  workspace_id = aws_prometheus_workspace.this.id
  data         = each.value
}
