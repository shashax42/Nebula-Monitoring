variable "environment" {
  type = string
}

variable "cluster_name" {
  description = "로그 그룹 경로 /aws/eks/<cluster_name>/<class> 에 사용"
  type        = string
}

variable "retention_days" {
  description = "로그 클래스별 Hot 보존 기간(일)"
  type = object({
    application = number
    audit       = number
    events      = number
    metrics     = number
  })
  default = {
    application = 30
    audit       = 90
    events      = 14
    metrics     = 1
  }
}

variable "existing_log_groups" {
  description = "이미 다른 곳에서 관리 중이라 이 모듈이 만들지 않을 로그 클래스 (예: [\"application\"])"
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
