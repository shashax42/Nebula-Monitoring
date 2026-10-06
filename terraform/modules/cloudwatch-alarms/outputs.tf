output "sns_topic_arn" {
  description = "Warning SNS topic ARN (기본 알림 채널)"
  value       = aws_sns_topic.warning.arn
}

output "critical_sns_topic_arn" {
  description = "Critical SNS topic ARN (즉시 대응)"
  value       = aws_sns_topic.critical.arn
}

output "sns_topic_name" {
  description = "Warning SNS topic name"
  value       = aws_sns_topic.warning.name
}

output "alarm_arns" {
  description = "ARNs of the SLA / business / pipeline alarms"
  value = merge(
    {
      availability_sla    = aws_cloudwatch_metric_alarm.availability_sla.arn
      error_rate          = aws_cloudwatch_metric_alarm.error_rate.arn
      latency_slo         = aws_cloudwatch_metric_alarm.latency_slo.arn
      service_degradation = aws_cloudwatch_composite_alarm.service_degradation.arn
    },
    { for a in aws_cloudwatch_metric_alarm.payment_pg_timeout : "payment_pg_timeout" => a.arn },
    { for a in aws_cloudwatch_metric_alarm.payment_failure_rate : "payment_failure_rate" => a.arn },
    { for a in aws_cloudwatch_metric_alarm.payment_logical_errors : "payment_logical_errors" => a.arn },
    { for k, v in aws_cloudwatch_metric_alarm.log_ingestion_stopped : "log_ingestion_stopped" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.service_availability : "availability_${k}" => v.arn },
  )
}

output "critical_alarms" {
  description = "List of critical alarm ARNs"
  value = concat(
    [
      aws_cloudwatch_metric_alarm.availability_sla.arn,
      aws_cloudwatch_composite_alarm.service_degradation.arn,
    ],
    [for a in aws_cloudwatch_metric_alarm.payment_pg_timeout : a.arn],
    [for a in aws_cloudwatch_metric_alarm.payment_logical_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.log_ingestion_stopped : a.arn],
    [for a in aws_cloudwatch_metric_alarm.service_availability : a.arn],
  )
}
