variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the service account"
  type        = string
  default     = "monitoring"
}

variable "service_account" {
  description = "Name of the Kubernetes service account"
  type        = string
  default     = "otel-collector"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "amp_workspace_arn" {
  description = "ARN of the AMP workspace"
  type        = string
}

variable "enable_s3_export" {
  description = "Enable S3 export for traces/logs"
  type        = bool
  default     = false
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket for exports"
  type        = string
  default     = ""
  
  validation {
    condition = (
      var.s3_bucket_arn == "" ||
      can(regex("^arn:aws:s3:::[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.s3_bucket_arn))
    )
    error_message = "S3 bucket ARN must be a valid ARN format or empty string."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
