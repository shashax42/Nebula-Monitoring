variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

# SNS Configuration
variable "email_endpoints" {
  description = "List of email addresses for alarm notifications"
  type        = list(string)
  default     = []
}

variable "slack_webhook_url" {
  description = "Slack webhook URL for notifications"
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_lambda_arn" {
  description = "ARN of Lambda function for Slack notifications"
  type        = string
  default     = ""
}

variable "kms_key_id" {
  description = "KMS key ID for SNS encryption"
  type        = string
  default     = null
}

# Alarm Thresholds - Application
variable "error_rate_threshold" {
  description = "Error rate threshold in percentage"
  type        = number
  default     = 5  # 5% error rate
}

variable "latency_p95_threshold" {
  description = "P95 latency threshold in milliseconds"
  type        = number
  default     = 1000  # 1 second
}

variable "availability_threshold" {
  description = "Availability threshold in percentage"
  type        = number
  default     = 99.9  # 99.9% availability (SLO)
}

# Alarm Thresholds - Infrastructure
variable "cpu_threshold" {
  description = "CPU utilization threshold in percentage"
  type        = number
  default     = 80
}

variable "memory_threshold" {
  description = "Memory utilization threshold in percentage"
  type        = number
  default     = 80
}

variable "pod_restart_threshold" {
  description = "Pod restart threshold per minute"
  type        = number
  default     = 5
}

# Alarm Configuration
variable "evaluation_periods" {
  description = "Number of periods to evaluate before triggering alarm"
  type        = number
  default     = 2
}

variable "metric_period" {
  description = "Period in seconds for metric evaluation"
  type        = number
  default     = 300  # 5 minutes
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
