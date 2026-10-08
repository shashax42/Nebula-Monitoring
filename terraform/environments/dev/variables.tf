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
  default     = ["core-gateway", "service-order", "service-product", "service-account"]
}

# ---------------- 데이터 스토어 (terraform_new 인프라) ----------------
variable "aurora_cluster_identifiers" {
  description = "감시할 Aurora DBClusterIdentifier 목록. 비우면 Nebula-Platform output(remote state)을 쓴다"
  type        = list(string)
  default     = []
}

variable "redis_replication_group_ids" {
  description = "감시할 ElastiCache Redis replication group ID 목록 (노드는 자동 조회). 비우면 Nebula-Platform output 을 쓴다"
  type        = list(string)
  default     = []
}

variable "rds_instance_identifiers" {
  description = "알람 대상 RDS 인스턴스 ID. 비우면 Nebula-Platform output(rds_instance_identifiers)을 쓴다"
  type        = list(string)
  default     = []
}

variable "sqs_queue_names" {
  description = "알람 대상 SQS 큐. 비우면 Nebula-Platform output(sqs_queue_names)을 쓴다"
  type        = list(string)
  default     = []
}

# ---------------- 로그 보존 / 아카이브 ----------------
variable "audit_log_hot_retention_days" {
  description = "감사 로그의 CloudWatch(Hot) 보존 기간"
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
  description = "S3 아카이브 보존 기간. 법정 최소 5년(전자금융거래법 §22·시행령 §12, 전자상거래법 시행령 §6 대금결제 기록) 위에 분쟁 대응 여유를 둔 7년 정책값"
  type        = number
  default     = 2557
}

variable "archive_object_lock" {
  description = "S3 Object Lock(COMPLIANCE) 로 위·변조 방지. 버킷 생성 시에만 적용 가능"
  type        = bool
  default     = false
}

# ---------------- 확장 ----------------
variable "enable_business_extensions" {
  description = "테넌트·결제·마진 확장 규칙(prometheus/rules/extensions)과 결제 알람 생성. 해당 데이터를 내보내는 서비스가 있을 때만 켠다"
  type        = bool
  default     = false
}

