variable "environment" {
  description = "Environment name (dev, staging, production). EMF 메트릭의 Environment 차원 값과 같아야 한다 (Helm global.environment)."
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

# ---------------- SNS ----------------
variable "email_endpoints" {
  description = "Critical 토픽 이메일 구독자 (warning_email_endpoints 가 null 이면 warning 토픽에도 구독)"
  type        = list(string)
  default     = []
}

variable "warning_email_endpoints" {
  description = "Warning 토픽 이메일 구독자. null 이면 email_endpoints 사용"
  type        = list(string)
  default     = null
}

variable "chat_lambda_arn" {
  description = "Slack/Teams 전달용 Lambda ARN (선택)"
  type        = string
  default     = ""
}

variable "kms_key_id" {
  description = "KMS key ID for SNS encryption"
  type        = string
  default     = null
}

variable "amp_workspace_arn" {
  description = "AMP 워크스페이스 ARN. 지정 시 AMP Alertmanager 가 SNS 에 게시하도록 토픽 정책에 허용"
  type        = string
  default     = ""
}

# ---------------- SLA / Golden Signals ----------------
variable "slo_services" {
  description = "서비스 단위 가용성 SLA 알람을 만들 서비스 이름(OTel service.name) 목록"
  type        = list(string)
  default     = []
}

variable "availability_threshold" {
  description = "가용성 SLA (%)"
  type        = number
  default     = 99.9
}

variable "error_rate_threshold" {
  description = "에러율 임계 (%)"
  type        = number
  default     = 5
}

variable "latency_threshold_ms" {
  description = "SlowRequests 판정 기준(ms). Helm pipeline.sli.latencyThresholdMs 와 같아야 한다 (설명용)"
  type        = number
  default     = 1000
}

variable "slow_request_ratio_threshold" {
  description = "임계 초과 요청 비율 상한 (%). 5 = P95 기준"
  type        = number
  default     = 5
}

variable "min_requests_per_period" {
  description = "비율 알람을 평가할 최소 요청 수 (저트래픽 오탐 방지)"
  type        = number
  default     = 50
}

variable "evaluation_periods" {
  description = "Number of periods to evaluate before triggering alarm"
  type        = number
  default     = 3
}

variable "metric_period" {
  description = "Period in seconds for metric evaluation"
  type        = number
  default     = 300
}

# ---------------- 결제 ----------------
variable "payment_pg_timeout_threshold" {
  description = "PG 타임아웃 실패 비율 임계 (%)"
  type        = number
  default     = 1
}

variable "payment_failure_threshold" {
  description = "전체 결제 실패율 임계 (%)"
  type        = number
  default     = 10
}

variable "payment_logical_error_threshold" {
  description = "기간당 결제 논리 오류 허용 건수"
  type        = number
  default     = 0
}

# ---------------- 파이프라인 ----------------
variable "application_log_group_name" {
  description = "로그 유입 heartbeat 를 감시할 애플리케이션 로그 그룹 이름 (빈 값이면 알람 미생성)"
  type        = string
  default     = ""
}

variable "log_heartbeat_minutes" {
  description = "로그 유입이 이 시간(분, 5의 배수) 동안 0건이면 알람"
  type        = number
  default     = 15

  validation {
    condition     = var.log_heartbeat_minutes % 5 == 0 && var.log_heartbeat_minutes >= 5
    error_message = "log_heartbeat_minutes must be a multiple of 5"
  }
}

# ---------------- 데이터 스토어 ----------------
variable "aurora_cluster_identifiers" {
  description = "감시할 Aurora DBClusterIdentifier 목록"
  type        = list(string)
  default     = []
}

variable "aurora_cpu_threshold" {
  type    = number
  default = 80
}

variable "aurora_deadlock_threshold" {
  description = "초당 평균 데드락 수 임계"
  type        = number
  default     = 0.1
}

variable "aurora_replica_lag_ms" {
  type    = number
  default = 1000
}

variable "redis_cache_cluster_ids" {
  description = "감시할 ElastiCache CacheClusterId(노드) 목록"
  type        = list(string)
  default     = []
}

variable "redis_cpu_threshold" {
  type    = number
  default = 80
}

variable "redis_memory_threshold" {
  type    = number
  default = 85
}

variable "redis_evictions_threshold" {
  description = "5분당 축출 키 수 임계"
  type        = number
  default     = 100
}
