# Minimal IAM policies for OTEL Collector
# 블로그 인사이트: 최소 권한 원칙 적용

# AMP Write Policy (메트릭 전송만)
data "aws_iam_policy_document" "amp_write" {
  statement {
    sid    = "AMPRemoteWrite"
    effect = "Allow"
    actions = [
      "aps:RemoteWrite"
    ]
    resources = [var.amp_workspace_arn]
  }

  statement {
    sid    = "AMPQueryForHealthCheck"
    effect = "Allow"
    actions = [
      "aps:QueryMetrics"
    ]
    resources = [var.amp_workspace_arn]
  }
}

# CloudWatch Logs Policy (로그 전송만)
data "aws_iam_policy_document" "cloudwatch_logs" {
  statement {
    sid    = "CloudWatchLogsWrite"
    effect = "Allow"
    actions = [
      "logs:PutLogEvents",
      "logs:CreateLogStream"
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/*"
    ]
  }

  statement {
    sid    = "CloudWatchLogsDescribe"
    effect = "Allow"
    actions = [
      "logs:DescribeLogStreams"
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/*:*"
    ]
  }
}

# X-Ray Policy (트레이스 전송만)
data "aws_iam_policy_document" "xray" {
  statement {
    sid    = "XRayWrite"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords"
    ]
    resources = ["*"]  # X-Ray는 리소스 레벨 권한 미지원
  }
}

# CloudWatch Metrics Policy (선택적)
data "aws_iam_policy_document" "cloudwatch_metrics" {
  statement {
    sid    = "CloudWatchMetricsWrite"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData"
    ]
    resources = ["*"]  # CloudWatch Metrics는 리소스 레벨 권한 미지원
    
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Nebula/Application", "AWS/OTEL"]
    }
  }
}

# S3 Export Policy (선택적)
data "aws_iam_policy_document" "s3_export" {
  count = var.enable_s3_export ? 1 : 0

  statement {
    sid    = "S3Write"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl"
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }

  statement {
    sid    = "S3List"
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [var.s3_bucket_arn]
  }
}

# Combined policy document
data "aws_iam_policy_document" "combined" {
  source_policy_documents = concat(
    [
      data.aws_iam_policy_document.amp_write.json,
      data.aws_iam_policy_document.cloudwatch_logs.json,
      data.aws_iam_policy_document.xray.json,
      data.aws_iam_policy_document.cloudwatch_metrics.json
    ],
    var.enable_s3_export ? [data.aws_iam_policy_document.s3_export[0].json] : []
  )
}

resource "aws_iam_role_policy" "otel_collector" {
  name   = "otel-collector-policy"
  role   = aws_iam_role.otel_collector.id
  policy = data.aws_iam_policy_document.combined.json
}
