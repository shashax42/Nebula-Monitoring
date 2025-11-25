variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

# Sampling Configuration
variable "default_reservoir_size" {
  description = "Default reservoir size for sampling"
  type        = number
  default     = 1  # 1 trace per second guaranteed
}

variable "default_fixed_rate" {
  description = "Default fixed sampling rate (0.0 to 1.0)"
  type        = number
  default     = 0.1  # 10% sampling rate
  
  validation {
    condition     = var.default_fixed_rate >= 0 && var.default_fixed_rate <= 1
    error_message = "Fixed rate must be between 0 and 1"
  }
}

variable "critical_services" {
  description = "List of critical services with higher sampling rates"
  type        = list(string)
  default     = ["api-gateway", "payment-service", "auth-service"]
}

variable "critical_service_sampling_rate" {
  description = "Sampling rate for critical services"
  type        = number
  default     = 0.5  # 50% for critical services
  
  validation {
    condition     = var.critical_service_sampling_rate >= 0 && var.critical_service_sampling_rate <= 1
    error_message = "Sampling rate must be between 0 and 1"
  }
}

# Service Configuration
variable "microservices" {
  description = "List of microservices to create X-Ray groups for"
  type        = list(string)
  default     = []
}

# Performance Thresholds
variable "latency_threshold_seconds" {
  description = "Latency threshold in seconds for high latency group"
  type        = number
  default     = 3  # 3 seconds
}

# X-Ray Insights
variable "enable_insights_notifications" {
  description = "Enable X-Ray Insights notifications"
  type        = bool
  default     = true
}

# Encryption
variable "kms_key_id" {
  description = "KMS key ID for X-Ray encryption"
  type        = string
  default     = null
}

# IAM
variable "create_daemon_role" {
  description = "Create IAM role for X-Ray daemon"
  type        = bool
  default     = false
}

# Tags
variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
