# Alarms, and the one that matters.
#
# THE POINT OF ALARMING FROM AWS is that it keeps working when the cluster does not. Every
# instrument Nievah had before this lived inside the failure domain it was watching: the
# planner's missed-window record is in Valkey, the tick's alarms come from a pod, the Grafana
# dashboard reads Prometheus on the same node. All of them go quiet together, and quiet is
# indistinguishable from healthy. `jobs_stale` below is the first monitor Nievah has that is
# not subject to that.
#
# CloudWatch's always-free tier covers 10 alarms. This uses four.

resource "aws_sns_topic" "ops" {
  name = "${var.name_prefix}-ops"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.ops_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.ops_email
  # AWS emails a confirmation link; until it is clicked the subscription is pending and
  # delivers nothing. Terraform reports it as created either way.
}

# SNS cannot post to a Slack incoming webhook directly — it sends its own envelope and
# expects a subscription-confirmation handshake, neither of which Slack speaks. AWS Chatbot
# does the translation, and is free. The workspace must be authorized once by hand in the
# Chatbot console (an OAuth handshake Terraform cannot perform).
resource "aws_chatbot_slack_channel_configuration" "ops" {
  count = var.slack_workspace_id == "" || var.localstack ? 0 : 1

  configuration_name = "${var.name_prefix}-ops"
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.ops.arn]
  logging_level      = "ERROR"
}

resource "aws_iam_role" "chatbot" {
  count = var.slack_workspace_id == "" || var.localstack ? 0 : 1
  name  = "${var.name_prefix}-chatbot"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "chatbot.amazonaws.com" }
    }]
  })
}

# Read-only, and only the metrics. Chatbot's default managed policy is far wider than posting
# an alarm needs.
resource "aws_iam_role_policy" "chatbot" {
  count = var.slack_workspace_id == "" || var.localstack ? 0 : 1
  name  = "${var.name_prefix}-chatbot"
  role  = aws_iam_role.chatbot[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*"]
      Resource = "*"
    }]
  })
}

# --- THE ONE THAT MATTERS ------------------------------------------------------------------
#
# The oldest job nobody has taken. This is "the cluster has stopped consuming", observed from
# outside the cluster, and it is the alarm that would have caught the 15 hours of planner
# silence, the 7 hours of split-brain review queueing, and every ingress outage that lost a
# delivery — none of which had a symptom anything was watching.
#
# It is also why the scheduled ticks moved to EventBridge. A CronJob that stops firing leaves
# NOTHING behind; a schedule that fires into a queue leaves an unconsumed message, and that
# message ages. Absence became a positive signal.
resource "aws_cloudwatch_metric_alarm" "jobs_stale" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-jobs-not-being-consumed"
  alarm_description   = "Oldest job on ${aws_sqs_queue.jobs.name} is older than ${var.stale_jobs_alarm_seconds}s — nievah-worker is not draining. Webhooks are safe (14-day retention) but nothing is being reviewed."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.stale_jobs_alarm_seconds
  comparison_operator = "GreaterThanThreshold"

  dimensions = { QueueName = aws_sqs_queue.jobs.name }

  # An empty queue publishes NO datapoint rather than a zero, so the default treatment leaves
  # the alarm INSUFFICIENT_DATA forever on a healthy fleet — which looks broken and trains
  # people to ignore it. notBreaching makes idle read as OK.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]
}

# Anything here is a genuine bug: nothing the cluster does can make an events-queue message
# fail, so a redrive means the consumer itself rejected it five times.
resource "aws_cloudwatch_metric_alarm" "events_dlq" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-events-dlq-not-empty"
  alarm_description   = "A delivery could not be processed by ${aws_lambda_function.consumer.function_name} and was redriven. This is a code bug, not an outage."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions         = { QueueName = aws_sqs_queue.events_dlq.name }
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.ops.arn]
}

# Reaching this DLQ takes ~50 failed receives, so it means an outage that outlasted the
# redrive budget. These are deliveries that are about to be lost unless someone redrives them.
resource "aws_cloudwatch_metric_alarm" "jobs_dlq" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-jobs-dlq-not-empty"
  alarm_description   = "Deliveries exhausted the jobs-queue redrive budget. Fix the cluster, then redrive ${aws_sqs_queue.jobs_dlq.name} from the console."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions         = { QueueName = aws_sqs_queue.jobs_dlq.name }
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.ops.arn]
}

# The producer failing is the only failure in this stack that GitHub sees. Everything else
# degrades into a queue; this one returns a 5xx to a caller that will never retry.
resource "aws_cloudwatch_metric_alarm" "producer_errors" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-producer-erroring"
  alarm_description   = "${aws_lambda_function.producer.function_name} is raising. Deliveries are being REFUSED at the edge and GitHub will not re-send them."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions         = { FunctionName = aws_lambda_function.producer.function_name }
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.ops.arn]
}
