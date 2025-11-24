output "workspace_id" {
  description = "The ID of the AMP workspace"
  value       = aws_prometheus_workspace.this.id
}

output "workspace_arn" {
  description = "The ARN of the AMP workspace"
  value       = aws_prometheus_workspace.this.arn
}

output "workspace_endpoint" {
  description = "The endpoint URL of the AMP workspace"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "remote_write_url" {
  description = "The remote write URL for the AMP workspace"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

output "query_url" {
  description = "The query URL for the AMP workspace"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/query"
}
