output "sns_topic_arn" {
  description = "ARN of the SNS topic for alarms"
  value       = aws_sns_topic.alarms.arn
}

output "sns_topic_name" {
  description = "Name of the SNS topic for alarms"
  value       = aws_sns_topic.alarms.name
}

output "alarm_arns" {
  description = "ARNs of all created alarms"
  value = {
    # Application alarms
    high_error_rate    = aws_cloudwatch_metric_alarm.high_error_rate.arn
    high_latency_p95   = aws_cloudwatch_metric_alarm.high_latency_p95.arn
    low_availability   = aws_cloudwatch_metric_alarm.low_availability.arn
    
    # Infrastructure alarms
    eks_node_cpu_high     = aws_cloudwatch_metric_alarm.eks_node_cpu_high.arn
    eks_node_memory_high  = aws_cloudwatch_metric_alarm.eks_node_memory_high.arn
    pod_restart_rate_high = aws_cloudwatch_metric_alarm.pod_restart_rate_high.arn
    
    # OTEL Collector alarms
    otel_collector_down        = aws_cloudwatch_metric_alarm.otel_collector_down.arn
    otel_collector_memory_high = aws_cloudwatch_metric_alarm.otel_collector_memory_high.arn
    
    # Composite alarms
    service_degradation = aws_cloudwatch_composite_alarm.service_degradation.arn
  }
}

output "critical_alarms" {
  description = "List of critical alarm ARNs"
  value = [
    aws_cloudwatch_metric_alarm.low_availability.arn,
    aws_cloudwatch_metric_alarm.otel_collector_down.arn,
    aws_cloudwatch_composite_alarm.service_degradation.arn
  ]
}
