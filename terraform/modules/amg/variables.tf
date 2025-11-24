variable "workspace_name" {
  description = "Name of the Grafana workspace"
  type        = string
}

variable "workspace_description" {
  description = "Description of the Grafana workspace"
  type        = string
  default     = "Managed Grafana workspace for monitoring"
}

variable "account_access_type" {
  description = "Type of account access for the workspace"
  type        = string
  default     = "CURRENT_ACCOUNT"
  
  validation {
    condition     = contains(["CURRENT_ACCOUNT", "ORGANIZATION"], var.account_access_type)
    error_message = "account_access_type must be either CURRENT_ACCOUNT or ORGANIZATION"
  }
}

variable "authentication_providers" {
  description = "Authentication providers for the workspace"
  type        = list(string)
  default     = ["AWS_SSO"]
  
  validation {
    condition = alltrue([
      for provider in var.authentication_providers : 
      contains(["AWS_SSO", "SAML"], provider)
    ])
    error_message = "authentication_providers must contain only AWS_SSO or SAML"
  }
}

variable "permission_type" {
  description = "Permission type for the workspace"
  type        = string
  default     = "SERVICE_MANAGED"
  
  validation {
    condition     = contains(["CUSTOMER_MANAGED", "SERVICE_MANAGED"], var.permission_type)
    error_message = "permission_type must be either CUSTOMER_MANAGED or SERVICE_MANAGED"
  }
}

variable "data_sources" {
  description = "Data sources to enable in the workspace"
  type        = list(string)
  default     = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
  
  validation {
    condition = alltrue([
      for source in var.data_sources : 
      contains(["AMAZON_OPENSEARCH_SERVICE", "ATHENA", "CLOUDWATCH", "PROMETHEUS", "REDSHIFT", "SITEWISE", "TIMESTREAM", "XRAY"], source)
    ])
    error_message = "Invalid data source specified"
  }
}

variable "notification_destinations" {
  description = "Notification destinations for alerts"
  type        = list(string)
  default     = ["SNS"]
  
  validation {
    condition = alltrue([
      for dest in var.notification_destinations : 
      contains(["SNS"], dest)
    ])
    error_message = "notification_destinations must contain only SNS"
  }
}

variable "grafana_version" {
  description = "Grafana version to use"
  type        = string
  default     = "10.4"
}

variable "vpc_configuration" {
  description = "VPC configuration for private access"
  type = object({
    security_group_ids = list(string)
    subnet_ids         = list(string)
  })
  default = null
}

variable "enable_sso" {
  description = "Enable SSO configuration"
  type        = bool
  default     = false
}

variable "saml_configuration" {
  description = "SAML configuration for the workspace"
  type = object({
    admin_role_values    = list(string)
    editor_role_values   = list(string)
    idp_metadata_url     = string
    idp_metadata_xml     = string
    email_assertion      = string
    name_assertion       = string
    login_assertion      = string
    role_assertion       = string
    org_assertion        = string
  })
  default = null
}

variable "create_api_key" {
  description = "Create an API key for programmatic access"
  type        = bool
  default     = false
}

variable "api_key_seconds_to_live" {
  description = "Seconds until the API key expires"
  type        = number
  default     = 3600
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
