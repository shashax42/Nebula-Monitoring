output "workspace_id" {
  description = "ID of the Grafana workspace"
  value       = aws_grafana_workspace.main.id
}

output "workspace_arn" {
  description = "ARN of the Grafana workspace"
  value       = aws_grafana_workspace.main.arn
}

output "workspace_endpoint" {
  description = "Endpoint URL of the Grafana workspace"
  value       = aws_grafana_workspace.main.endpoint
}

output "workspace_grafana_version" {
  description = "Version of Grafana running in the workspace"
  value       = aws_grafana_workspace.main.grafana_version
}

output "workspace_status" {
  description = "Status of the Grafana workspace"
  value       = aws_grafana_workspace.main.status
}

output "iam_role_arn" {
  description = "ARN of the IAM role for Grafana"
  value       = aws_iam_role.grafana.arn
}

output "api_key_id" {
  description = "ID of the API key (if created)"
  value       = var.create_api_key ? aws_grafana_workspace_api_key.main[0].id : null
}

output "api_key_secret" {
  description = "Secret of the API key (if created)"
  value       = var.create_api_key ? aws_grafana_workspace_api_key.main[0].key : null
  sensitive   = true
}
