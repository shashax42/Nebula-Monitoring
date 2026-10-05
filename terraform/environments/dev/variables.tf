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

variable "aws_profile" {
  description = "AWS CLI profile used by the provider"
  type        = string
  default     = "monitoring-admin"
}

# ---------------- 알림 ----------------
variable "alarm_email_endpoints" {
  description = "알림 이메일 수신자 (critical/warning SNS 토픽 구독)"
  type        = list(string)
  default     = ["shinsia1649@gmail.com"]
}

variable "slo_services" {
  description = "서비스별 가용성 SLA CloudWatch 알람을 만들 핵심 서비스(OTel service.name)"
  type        = list(string)
  default     = ["api-gateway", "payment-service", "auth-service"]
}

# ---------------- 데이터 스토어 (terraform_new 인프라) ----------------
variable "aurora_cluster_identifiers" {
  description = "감시할 Aurora DBClusterIdentifier 목록 (terraform_new 출력값)"
  type        = list(string)
  default     = []
}

variable "redis_replication_group_ids" {
  description = "감시할 ElastiCache Redis replication group ID 목록 (노드는 자동 조회)"
  type        = list(string)
  default     = []
}

# ---------------- 로그 보존 / 아카이브 ----------------
variable "audit_log_hot_retention_days" {
  description = "감사/결제 로그의 CloudWatch(Hot) 보존 기간"
  type        = number
  default     = 90
}

variable "enable_log_archive" {
  description = "감사 로그를 S3 로 7년 아카이브 (Firehose)"
  type        = bool
  default     = true
}

variable "archive_application_logs" {
  description = "애플리케이션 로그 전체도 S3 로 아카이브 (비용 증가)"
  type        = bool
  default     = false
}

variable "archive_retention_days" {
  description = "S3 아카이브 보존 기간 (기본 7년)"
  type        = number
  default     = 2557
}

variable "archive_object_lock" {
  description = "S3 Object Lock(COMPLIANCE) 로 위·변조 방지. 버킷 생성 시에만 적용 가능"
  type        = bool
  default     = false
}
