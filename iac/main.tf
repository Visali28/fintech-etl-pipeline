provider "aws" {
  region = "ap-south-1"
}

##############################
# 1. S3 Bucket (Raw Layer)
##############################
resource "aws_s3_bucket" "raw_bucket" {
  bucket = "fintech-etl-raw-yourname"

  versioning { enabled = true }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    }
  }

  lifecycle_rule {
    enabled = true
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }

  public_access_block_configuration {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}

##############################
# 2. DynamoDB Table
##############################
resource "aws_dynamodb_table" "transactions" {
  name         = "fintech-etl-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "txn_id"
  range_key    = "customer_id"

  attribute { name = "txn_id" type = "S" }
  attribute { name = "customer_id" type = "S" }
}

##############################
# 3. SQS Dead Letter Queue
##############################
resource "aws_sqs_queue" "dlq" {
  name = "fintech-etl-dlq"
}

##############################
# 4. SNS Topic for Alerts
##############################
resource "aws_sns_topic" "alerts" {
  name = "fintech-etl-alerts"
}

##############################
# 5. IAM Role for Lambda
##############################
resource "aws_iam_role" "lambda_role" {
  name = "etl_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "etl_lambda_policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.raw_bucket.arn}/*" },
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.transactions.arn },
      { Effect = "Allow", Action = ["sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage"], Resource = aws_sqs_queue.dlq.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], Resource = "*" }
    ]
  })
}

##############################
# 6. Lambda Function
##############################
resource "aws_lambda_function" "etl_lambda" {
  function_name = "fintech-etl-processor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "etl_processor.lambda_handler"
  runtime       = "python3.9"
  timeout       = 30

  filename         = "../etl.zip"
  source_code_hash = filebase64sha256("../etl.zip")

  environment {
    variables = {
      DLQ_URL    = aws_sqs_queue.dlq.id
      TABLE_NAME = aws_dynamodb_table.transactions.name
    }
  }
}

##############################
# 7. S3 Trigger for Lambda
##############################
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.etl_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_bucket.arn
}

resource "aws_s3_bucket_notification" "s3_trigger" {
  bucket = aws_s3_bucket.raw_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.etl_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_lambda_permission.s3_invoke]
}

##############################
# 8. Logging & Compliance
##############################
# CloudTrail for logging S3, Lambda, IAM actions
resource "aws_cloudtrail" "etl_trail" {
  name                          = "fintech-etl-trail"
  s3_bucket_name                = aws_s3_bucket.raw_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
}

# Separate bucket for access logs
resource "aws_s3_bucket" "log_bucket" {
  bucket = "fintech-etl-logs-yourname"
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_logging" "raw_bucket_logs" {
  bucket        = aws_s3_bucket.raw_bucket.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "s3-access-logs/"
}

##############################
# 9. Monitoring & Alerting
##############################
# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "etl-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  dimensions = { FunctionName = aws_lambda_function.etl_lambda.function_name }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "etl-lambda-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Average"
  threshold           = 5000
  dimensions = { FunctionName = aws_lambda_function.etl_lambda.function_name }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "etl-dlq-messages"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  dimensions = { QueueName = aws_sqs_queue.dlq.name }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "etl_dashboard" {
  dashboard_name = "fintech-etl-dashboard"
  dashboard_body = <<EOF
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          [ "AWS/Lambda", "Invocations", "FunctionName", "${aws_lambda_function.etl_lambda.function_name}" ],
          [ "AWS/Lambda", "Duration", "FunctionName", "${aws_lambda_function.etl_lambda.function_name}" ],
          [ "AWS/Lambda", "Errors", "FunctionName", "${aws_lambda_function.etl_lambda.function_name}" ],
          [ "AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${aws_sqs_queue.dlq.name}" ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "ap-south-1",
        "title": "ETL Pipeline Metrics"
      }
    }
  ]
}
EOF
}

