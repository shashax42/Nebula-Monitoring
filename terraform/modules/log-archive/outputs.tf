output "bucket_name" {
  value = aws_s3_bucket.archive.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.archive.arn
}

output "firehose_stream_arns" {
  value = { for k, v in aws_kinesis_firehose_delivery_stream.this : k => v.arn }
}
