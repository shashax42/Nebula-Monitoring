variable "workspace_alias" {
  description = "The alias of the AMP workspace"
  type        = string
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 7
}

variable "enable_alert_manager" {
  description = "Enable Alert Manager for the workspace"
  type        = bool
  default     = false
}

variable "alert_manager_definition" {
  description = "Alert Manager configuration in YAML format"
  type        = string
  default     = ""
}

variable "rule_groups" {
  description = "Map of Prometheus rule groups"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
