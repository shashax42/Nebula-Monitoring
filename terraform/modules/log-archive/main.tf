terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==========================================================================
# Cold Data: CloudWatch Logs → Kinesis Firehose → S3 (7년 보관)
#
#   Hot  : CloudWatch Logs (log-analytics 모듈 retention, 예: 감사 90일)
#   Warm : S3 Standard-IA (30일 후)
#   Cold : S3 Glacier Instant Retrieval (90일 후) → Deep Archive (365일 후)
#   삭제 : 7년(2,557일) 후 만료 (전자금융/전자상거래 거래기록 보존 기준)
#
# Firehose 가 CloudWatch Logs 구독 데이터(gzip)를 풀고 로그 메시지만 추출해 다시 gzip 으로 저장한다.
# 저장 경로: s3://<bucket>/<prefix>/<log-class>/year=YYYY/month=MM/day=DD/  (Athena 파티션)
# ==========================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "nebula-${var.environment}-log-archive-${data.aws_caller_identity.current.account_id}"
}

# --------------------------------------------------------------------------
# S3 버킷
# --------------------------------------------------------------------------
resource "aws_s3_bucket" "archive" {
  bucket              = local.bucket_name
  object_lock_enabled = var.object_lock_enabled
  force_destroy       = false
  tags                = merge(var.tags, { DataClass = "cold-log-archive" })
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

# 감사 로그 위·변조 방지 (WORM). 활성화 시 보존 기간 동안 삭제 불가
resource "aws_s3_bucket_object_lock_configuration" "archive" {
  count  = var.object_lock_enabled ? 1 : 0
  bucket = aws_s3_bucket.archive.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.retention_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "tiering-and-expiry"
    status = "Enabled"
    filter {
      prefix = "${var.s3_prefix}/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
    expiration {
      days = var.retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "firehose-errors"
    status = "Enabled"
    filter {
      prefix = "${var.s3_prefix}-errors/"
    }
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# --------------------------------------------------------------------------
# Firehose (로그 클래스별 1개: 경로 분리 + 장애 격리)
# --------------------------------------------------------------------------
resource "aws_iam_role" "firehose" {
  name = "nebula-${var.environment}-log-archive-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = data.aws_caller_identity.current.account_id } }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "firehose" {
  name = "s3-write"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"]
        Resource = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
      }],
      var.kms_key_arn != null ? [{
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }] : []
    )
  })
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  for_each = var.log_groups

  name        = "nebula-${var.environment}-archive-${each.key}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.archive.arn
    prefix              = "${var.s3_prefix}/${each.key}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "${var.s3_prefix}-errors/${each.key}/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size      = 64
    buffering_interval  = 300
    compression_format  = "GZIP"

    processing_configuration {
      enabled = true
      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }
      processors {
        type = "CloudWatchLogProcessing"
        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.tags, { LogClass = each.key })
}

# --------------------------------------------------------------------------
# CloudWatch Logs 구독 (로그 그룹 → Firehose)
# --------------------------------------------------------------------------
resource "aws_iam_role" "cwl_to_firehose" {
  name = "nebula-${var.environment}-cwl-to-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringLike = { "aws:SourceArn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "cwl_to_firehose" {
  name = "firehose-put"
  role = aws_iam_role.cwl_to_firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = [for s in aws_kinesis_firehose_delivery_stream.this : s.arn]
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "this" {
  for_each = var.log_groups

  name            = "archive-to-s3"
  log_group_name  = each.value
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.this[each.key].arn
  role_arn        = aws_iam_role.cwl_to_firehose.arn
}
