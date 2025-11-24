variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "nebula-eks-dev"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "otel_namespace" {
  description = "Kubernetes namespace for OTEL Collector"
  type        = string
  default     = "monitoring"
}

variable "otel_service_account" {
  description = "Kubernetes service account name for OTEL Collector"
  type        = string
  default     = "otel-collector"
}
