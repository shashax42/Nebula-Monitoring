variable "environment" {
  type = string
}

variable "log_groups" {
  description = "아카이브할 로그 클래스 → 로그 그룹 이름 (예: { audit = \"/aws/eks/c1/audit\" })"
  type        = map(string)
}

variable "bucket_name" {
  description = "비우면 nebula-<env>-log-archive-<account_id>"
  type        = string
  default     = ""
}

variable "s3_prefix" {
  type    = string
  default = "logs"
}

variable "retention_days" {
  description = "S3 보관 기간 (기본 7년 = 2,557일, 법정 최소 5년 위의 정책값)"
  type        = number
  default     = 2557
}

variable "object_lock_enabled" {
  description = "감사 로그 WORM(Object Lock COMPLIANCE). 버킷 생성 시에만 설정 가능"
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
