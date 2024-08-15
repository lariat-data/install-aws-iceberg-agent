terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }

    time = {
      source  = "hashicorp/time"
    }
    null = {
      source  = "hashicorp/null"
    }
  }
  backend "s3" {}
}

locals {
    today  = timestamp()
    lambda_heartbeat_time   = timeadd(local.today, "5m")
    lambda_heartbeat_minute = formatdate("m", local.lambda_heartbeat_time)
    lambda_heartbeat_hour = formatdate("h", local.lambda_heartbeat_time)
    lambda_heartbeat_day = formatdate("D", local.lambda_heartbeat_time)
    lambda_heartbeat_month = formatdate("M", local.lambda_heartbeat_time)
    lambda_heartbeat_year = formatdate("YYYY", local.lambda_heartbeat_time)
    lariat_vendor_tag_aws = var.lariat_vendor_tag_aws != "" ? var.lariat_vendor_tag_aws : "lariat-${var.aws_region}"

    s3_bucket_stubs = [for s in var.target_s3_buckets : element(split("/", s),2)]
}

# Configure default the AWS Provider
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      VendorLariat = local.lariat_vendor_tag_aws
    }
  }
}

data "aws_caller_identity" "current" {}

// Create object for agent configuration file in s3
resource "aws_s3_bucket" "lariat_iceberg_agent_config_bucket" {
  bucket_prefix = var.iceberg_agent_config_bucket
  force_destroy = true
}

resource "aws_s3_object" "lariat_iceberg_agent_config" {
  bucket = aws_s3_bucket.lariat_iceberg_agent_config_bucket.bucket
  key    = "iceberg_agent.yaml"
  source = "iceberg_agent.yaml"

  etag = filemd5("iceberg_agent.yaml")
}

resource "aws_cloudwatch_event_rule" "lariat_iceberg_lambda_trigger_daily" {
  name_prefix = "lariat-iceberg-lambda-trigger"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "lariat_iceberg_lambda_trigger_daily_target" {
  rule = aws_cloudwatch_event_rule.lariat_iceberg_lambda_trigger_daily.name
  arn = aws_lambda_function.lariat_iceberg_monitoring_lambda.arn
  input = jsonencode({"run_type"="raw_schema"})
}

resource "aws_cloudwatch_event_rule" "lariat_iceberg_lambda_trigger_heartbeat" {
  name_prefix = "lariat-iceberg-lambda-trigger"
  schedule_expression ="cron(${local.lambda_heartbeat_minute} ${local.lambda_heartbeat_hour} ${local.lambda_heartbeat_day} ${local.lambda_heartbeat_month} ? ${local.lambda_heartbeat_year})"
}

resource "aws_cloudwatch_event_target" "lariat_iceberg_lambda_trigger_heartbeat_target" {
  rule = aws_cloudwatch_event_rule.lariat_iceberg_lambda_trigger_heartbeat.name
  arn = aws_lambda_function.lariat_iceberg_monitoring_lambda.arn
  input = jsonencode({"run_type"="raw_schema"})
}

resource "aws_cloudwatch_event_rule" "lariat_iceberg_lambda_trigger_5_minutely" {
  name_prefix = "lariat-iceberg-lambda-trigger"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "lariat_iceberg_lambda_trigger_5_minutely_target" {
  rule = aws_cloudwatch_event_rule.lariat_iceberg_lambda_trigger_5_minutely.name
  arn = aws_lambda_function.lariat_iceberg_monitoring_lambda.arn
  input = jsonencode({"run_type"="batch_agent_query_dispatch"})
}

resource "aws_lambda_permission" "allow_cloudwatch_5_minutely" {
  statement_id  = "AllowExecutionFromCloudWatch5Minutely"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lariat_iceberg_monitoring_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lariat_iceberg_lambda_trigger_5_minutely.arn
}

resource "aws_lambda_permission" "allow_cloudwatch_daily" {
  statement_id  = "AllowExecutionFromCloudWatchDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lariat_iceberg_monitoring_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lariat_iceberg_lambda_trigger_daily.arn
}


resource "aws_lambda_permission" "allow_cloudwatch_heartbeat" {
  statement_id  = "AllowExecutionFromCloudWatchHeartbeat"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lariat_iceberg_monitoring_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lariat_iceberg_lambda_trigger_heartbeat.arn
}

// Policy document for iceberg agent lambda to access its execution image
data "aws_iam_policy_document" "lariat_iceberg_agent_repository_policy" {
  statement {
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:GetRepositoryPolicy",
      "ecr:ListImages",
      "ecr:DeleteRepository",
      "ecr:BatchDeleteImage",
      "ecr:SetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy"
    ]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "lariat_iceberg_monitoring_policy" {
  name_prefix = "lariat-iceberg-monitoring-policy"
  policy = templatefile("iam/lariat-iceberg-monitoring-policy.json.tftpl", { s3_bucket_stubs = local.s3_bucket_stubs, s3_buckets = var.target_s3_buckets, target_glue_database_tables = var.target_glue_database_tables, glue_region=var.aws_region, aws_account_id=data.aws_caller_identity.current.account_id, iceberg_agent_config_bucket = aws_s3_bucket.lariat_iceberg_agent_config_bucket.bucket })
}

resource "aws_iam_role" "lariat_iceberg_monitoring_lambda_role" {
  name_prefix = "lariat-s3-monitoring-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda-assume-role-policy.json
  managed_policy_arns = [aws_iam_policy.lariat_iceberg_monitoring_policy.arn, "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
}

resource "aws_lambda_function" "lariat_iceberg_monitoring_lambda" {
  function_name = "lariat-iceberg-monitoring-lambda"
  image_uri = "358681817243.dkr.ecr.${var.aws_region}.amazonaws.com/lariat-iceberg-agent:latest"
  role = aws_iam_role.lariat_iceberg_monitoring_lambda_role.arn
  package_type = "Image"
  memory_size = 10240
  timeout = 900

  environment {
    variables = {
      LARIAT_API_KEY = var.lariat_api_key
      LARIAT_APPLICATION_KEY = var.lariat_application_key
      CLOUD_AGENT_CONFIG_PATH = "${aws_s3_bucket.lariat_iceberg_agent_config_bucket.bucket}/iceberg_agent.yaml"
      LARIAT_ENDPOINT = "http://ingest.lariatdata.com/api"
      LARIAT_OUTPUT_BUCKET = "lariat-batch-agent-sink"
      LARIAT_SINK_AWS_ACCESS_KEY_ID = "${var.lariat_sink_aws_access_key_id}"
      LARIAT_SINK_AWS_SECRET_ACCESS_KEY = "${var.lariat_sink_aws_secret_access_key}"
      LARIAT_CLOUD_ACCOUNT_ID = "${data.aws_caller_identity.current.account_id}"
      LARIAT_EVENT_NAME = "iceberg_agent"
      LARIAT_GLUE_REGION = "${var.aws_region}"
    }
  }
}

data "aws_iam_policy_document" "allow_config_access_from_lariat_account" {
  statement {
    principals {
      type        = "AWS"
      identifiers = ["358681817243",
      "arn:aws:sts::358681817243:assumed-role/lariat-iam-terraform-cross-account-access-role-${data.aws_caller_identity.current.account_id}/s3-session-${data.aws_caller_identity.current.account_id}"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.lariat_iceberg_agent_config_bucket.arn,
      "${aws_s3_bucket.lariat_iceberg_agent_config_bucket.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "allow_config_access_from_lariat_account_policy" {
  bucket = aws_s3_bucket.lariat_iceberg_agent_config_bucket.id
  policy = data.aws_iam_policy_document.allow_config_access_from_lariat_account.json
}

resource "aws_iam_policy" "allow_user_lambda_to_invoke_monitoring_policy" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "lambda:InvokeFunction",
        ]
        Effect   = "Allow"
        Resource = aws_lambda_function.lariat_iceberg_monitoring_lambda.arn
      },
    ]
  })
}

