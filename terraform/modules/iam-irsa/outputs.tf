output "role_arn" {
  description = "ARN of the IAM role for OTEL Collector"
  value       = aws_iam_role.otel_collector.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.otel_collector.name
}

output "service_account_annotations" {
  description = "Map of annotations to add to the Kubernetes service account"
  value = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.otel_collector.arn
  }
}
