locals {
  name = var.project
  tags = {
    project     = var.project
    cost_center = var.cost_center
    managed_by  = "terraform"
  }
  marker_prefix = "raw/ecommerce/_markers/"
  # S3 cobra cada objeto en STANDARD_IA / GLACIER_IR como mínimo 128 KB: mover
  # archivos chicos de partición encarece en vez de ahorrar.
  min_tiering_size = 131072
}

data "aws_caller_identity" "current" {}

# --- Almacenamiento -----------------------------------------------------------

resource "aws_s3_bucket" "lake" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  # Raw solo se relee en backfills: pasa a clases más baratas con el tiempo.
  rule {
    id     = "raw-tiering"
    status = "Enabled"
    filter {
      and {
        prefix                   = "raw/"
        object_size_greater_than = local.min_tiering_size
      }
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }

  rule {
    id     = "bronze-tiering"
    status = "Enabled"
    filter {
      and {
        prefix                   = "bronze/"
        object_size_greater_than = local.min_tiering_size
      }
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- Imagen -------------------------------------------------------------------

resource "aws_ecr_repository" "lakehouse" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "lakehouse" {
  repository = aws_ecr_repository.lakehouse.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar solo las 5 imágenes más recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# --- Permisos -----------------------------------------------------------------

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lee todo el lago, pero solo escribe en las capas que produce (raw es del productor).
data "aws_iam_policy_document" "lake" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.lake.arn}/*"]
  }
  statement {
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = [
      "${aws_s3_bucket.lake.arn}/bronze/*",
      "${aws_s3_bucket.lake.arn}/silver/*",
      "${aws_s3_bucket.lake.arn}/gold/*",
    ]
  }
}

resource "aws_iam_role_policy" "lake" {
  name   = "lake-access"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lake.json
}

# --- Cómputo serverless -------------------------------------------------------

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "pipeline" {
  function_name = local.name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lakehouse.repository_url}:${var.image_tag}"
  architectures = [var.lambda_architecture]
  memory_size   = var.lambda_memory_mb
  timeout       = 900

  ephemeral_storage {
    size = 2048 # MB en /tmp para spill de DuckDB y artefactos de dbt
  }

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      LAKE_ROOT           = "s3://${aws_s3_bucket.lake.bucket}"
      DBT_TARGET          = "aws"
      DUCKDB_MEMORY_LIMIT = "${floor(var.lambda_memory_mb * 0.75)}MB"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [aws_iam_role_policy_attachment.logs, aws_iam_role_policy.lake]
}

resource "aws_lambda_function_event_invoke_config" "pipeline" {
  function_name                = aws_lambda_function.pipeline.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 21600
}

# --- Disparador: marcador _SUCCESS en raw -------------------------------------

resource "aws_lambda_permission" "s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.pipeline.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.lake.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket_notification" "markers" {
  bucket = aws_s3_bucket.lake.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.pipeline.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.marker_prefix
    filter_suffix       = "_SUCCESS"
  }
  depends_on = [aws_lambda_permission.s3]
}

# --- FinOps: presupuesto ------------------------------------------------------

# Filtra por la etiqueta `project`; hay que activarla como cost allocation tag en
# Billing para que el presupuesto la vea (tarda ~24 h).
resource "aws_budgets_budget" "monthly" {
  count        = var.budget_email == "" ? 0 : 1
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:project$%s", var.project)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
