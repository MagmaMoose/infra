# kics-scan disable=CKV_AWS_297
# The daily fire.
#
# EventBridge Scheduler rather than a classic EventBridge rule, for the same reason the front
# door uses it: 14 million invocations a month free permanently, a retry policy per target,
# and a timezone field — which a rule does not have, so a rule would force the schedule to be
# written in UTC and silently mean something different to whoever reads it next.
resource "aws_scheduler_schedule" "daily" {
  # checkov:skip=CKV_AWS_297:No KMS CMK for EventBridge Scheduler — home lab; AWS managed key is sufficient
  name                         = var.name_prefix
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    # A cost report has no reason to fire at an exact second, but OFF keeps the delivery time
    # predictable for the humans reading it, which is worth more than the scheduling slack.
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.report.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      # The report is idempotent — it derives its own dates and publishes a fresh message —
      # so a retry costs one extra Slack post at worst, against a silently missing report.
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.name_prefix}-scheduler"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.report.arn
    }]
  })
}
