output "sampling_rules" {
  description = "Created X-Ray sampling rules"
  value = {
    default = aws_xray_sampling_rule.default.rule_name
    errors  = aws_xray_sampling_rule.errors.rule_name
    critical = [for rule in aws_xray_sampling_rule.critical_services : rule.rule_name]
  }
}

output "xray_groups" {
  description = "Created X-Ray groups"
  value = {
    production    = try(aws_xray_group.production[0].group_name, null)
    microservices = { for k, v in aws_xray_group.microservices : k => v.group_name }
    high_latency  = aws_xray_group.high_latency.group_name
    errors        = aws_xray_group.errors.group_name
  }
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL for X-Ray metrics"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.xray_service_map.dashboard_name}"
}

output "service_map_url" {
  description = "X-Ray Service Map console URL"
  value       = "https://console.aws.amazon.com/xray/home?region=${data.aws_region.current.name}#/service-map"
}

output "traces_url" {
  description = "X-Ray Traces console URL"
  value       = "https://console.aws.amazon.com/xray/home?region=${data.aws_region.current.name}#/traces"
}

output "service_map_config" {
  description = "Service Map configuration for OTEL Collector"
  value = {
    service_name_prefix = local.service_map_config.service_name_prefix
    environment_tag     = local.service_map_config.environment_tag
    trace_sampling_rate = local.service_map_config.trace_id_ratio_based
    annotations         = local.service_map_config.annotations
  }
}

output "xray_daemon_role_arn" {
  description = "ARN of X-Ray daemon IAM role (if created)"
  value       = try(aws_iam_role.xray_daemon[0].arn, null)
}
