output "log_group_names" {
  description = "로그 클래스 → 로그 그룹 이름 (그룹 생성 이후에 참조되도록 depends_on)"
  value       = local.name
  depends_on  = [aws_cloudwatch_log_group.this]
}

output "query_definition_ids" {
  value = { for k, v in aws_cloudwatch_query_definition.this : k => v.query_definition_id }
}
