output "role_arn" {
  description = "워크로드 계정 gateway 가 assume 할 역할 ARN"
  value       = aws_iam_role.ingest.arn
}
