output "bucket" {
  value = aws_s3_bucket.lake.bucket
}

output "lake_root" {
  value = "s3://${aws_s3_bucket.lake.bucket}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.lakehouse.repository_url
}

output "function_name" {
  value = aws_lambda_function.pipeline.function_name
}
