###############################################################################
# Weekly AMD IAM policy regeneration - AWS, Terraform alternative.
#
# Same shape as ../cloudformation.yaml: Lambda on a weekly schedule, CCA token
# in Secrets Manager, artifacts versioned in S3, SNS only when a policy really
# changed. Pick one or the other - running both creates two of everything.
#
#   terraform init
#   terraform apply -var cca_secret_arn=arn:aws:secretsmanager:...
#
# The zip is built by ../../package.sh and uploaded by Terraform directly, so
# there is no chicken-and-egg bootstrap bucket to create first.
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "Region to deploy the automation into. Unrelated to which regions the policies cover - the sweep is global either way."
}

variable "name_prefix" {
  type    = string
  default = "amd-iam-policies"
}

variable "cca_secret_arn" {
  type        = string
  description = <<-EOT
    ARN of an existing Secrets Manager secret holding the CCA JWT.
    Create it outside Terraform:
      aws secretsmanager create-secret --name amd/cca-api-key \
        --secret-string file://cca_api_key.txt
    Passing the token as a Terraform variable would write it to state in
    plaintext, which is why this takes an ARN and not the token.
  EOT
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "Optional address subscribed to change notifications."
}

variable "schedule_expression" {
  type        = string
  default     = "cron(0 7 ? * MON *)"
  description = "Weekly, Mondays 07:00 UTC."
}

variable "clouds" {
  type    = string
  default = "AWS,AZURE,GCP,OCI"
}

variable "use_eventbridge_scheduler" {
  type        = bool
  default     = true
  description = "Set false in partitions without EventBridge Scheduler (GovCloud, China, ca-west-1, il-central-1, ap-southeast-5); falls back to a CloudWatch Events rule."
}

variable "lambda_zip_path" {
  type        = string
  default     = "../../build/lambda.zip"
  description = "Built by ../../package.sh."
}

variable "artifact_retention_days" {
  type    = number
  default = 730
}

# ------------------------------------------------------------------ artifacts

resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${var.name_prefix}-"
  # The bucket is the audit trail of what the policy looked like each week.
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket     = aws_s3_bucket.artifacts.id
  depends_on = [aws_s3_bucket_versioning.artifacts]

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.artifact_retention_days
    }
  }

  rule {
    id     = "abort-incomplete"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket     = aws_s3_bucket.artifacts.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# --------------------------------------------------------------- notification

resource "aws_sns_topic" "changes" {
  name         = "${var.name_prefix}-changes"
  display_name = "AMD IAM policy changes"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.changes.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --------------------------------------------------------------------- lambda

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${var.name_prefix}-generate"
  retention_in_days = 90
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "fn" {
  # Scoped to this function's own log group, not logs:* account-wide.
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn.arn}:*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.cca_secret_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.changes.arn]
  }
}

resource "aws_iam_role" "fn" {
  name_prefix        = "${var.name_prefix}-fn-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "fn" {
  name_prefix = "runner-"
  role        = aws_iam_role.fn.id
  policy      = data.aws_iam_policy_document.fn.json
}

resource "aws_lambda_function" "generate" {
  function_name = "${var.name_prefix}-generate"
  description   = "Re-derive AMD IAM policies from the AMD CCA API"
  role          = aws_iam_role.fn.arn
  runtime       = "python3.13"
  handler       = "runner.lambda_handler"
  architectures = ["arm64"]

  # A full four-cloud sweep measured ~48s, nearly all of it waiting on CCA.
  timeout     = 300
  memory_size = 512

  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      CCA_SECRET_ID    = var.cca_secret_arn
      ARTIFACT_BUCKET  = aws_s3_bucket.artifacts.id
      ARTIFACT_PREFIX  = var.name_prefix
      NOTIFY_TOPIC_ARN = aws_sns_topic.changes.arn
      CLOUDS           = var.clouds
    }
  }

  depends_on = [aws_iam_role_policy.fn, aws_cloudwatch_log_group.fn]
}

# ------------------------------------------------------------------- schedule

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.use_eventbridge_scheduler ? 1 : 0
  name_prefix        = "${var.name_prefix}-sched-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  count       = var.use_eventbridge_scheduler ? 1 : 0
  name_prefix = "invoke-"
  role        = aws_iam_role.scheduler[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.generate.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly" {
  count       = var.use_eventbridge_scheduler ? 1 : 0
  name        = "${var.name_prefix}-weekly"
  description = "Weekly AMD CCA policy regeneration"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.generate.arn
    role_arn = aws_iam_role.scheduler[0].arn
    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

# Fallback for partitions without EventBridge Scheduler.
resource "aws_cloudwatch_event_rule" "weekly" {
  count               = var.use_eventbridge_scheduler ? 0 : 1
  name                = "${var.name_prefix}-weekly"
  description         = "Weekly AMD CCA policy regeneration"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "weekly" {
  count     = var.use_eventbridge_scheduler ? 0 : 1
  rule      = aws_cloudwatch_event_rule.weekly[0].name
  target_id = "generate"
  arn       = aws_lambda_function.generate.arn
}

resource "aws_lambda_permission" "events" {
  count         = var.use_eventbridge_scheduler ? 0 : 1
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.generate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly[0].arn
}

# ---------------------------------------------------------------------- alarm
# Without this a failing weekly job is silent, and silence is also what a
# healthy no-change week looks like.

resource "aws_cloudwatch_metric_alarm" "failed" {
  alarm_name          = "${var.name_prefix}-generate-failed"
  alarm_description   = "The weekly AMD policy regeneration raised an error."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.generate.function_name }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.changes.arn]
}

# -------------------------------------------------------------------- outputs

output "artifact_bucket" {
  description = "Where generated policies land (current/ and history/<date>/)"
  value       = aws_s3_bucket.artifacts.id
}

output "function_name" {
  value = aws_lambda_function.generate.function_name
}

output "topic_arn" {
  value = aws_sns_topic.changes.arn
}

output "manual_invoke" {
  description = "Run it now instead of waiting for Monday"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.generate.function_name} /dev/stdout"
}
