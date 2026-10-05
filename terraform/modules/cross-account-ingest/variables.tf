variable "role_name" {
  type    = string
  default = "nebula-telemetry-cross-account-ingest"
}

variable "source_role_arns" {
  description = "AssumeRole 을 허용할 워크로드 계정의 collector(IRSA) 역할 ARN 목록"
  type        = list(string)
}

variable "allowed_external_ids" {
  description = "선택: 혼동된 대리인(confused deputy) 방지용 External ID"
  type        = list(string)
  default     = []
}

variable "amp_workspace_arn" {
  type = string
}

variable "log_group_prefixes" {
  description = "쓰기를 허용할 로그 그룹 경로 접두사"
  type        = list(string)
  default     = ["/aws/eks/"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
