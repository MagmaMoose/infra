# kics-scan disable=CKV_AWS_26,CKV_AWS_355
# Delivery, and the one alarm that makes the report trustworthy.

# checkov:skip=CKV_AWS_26:No KMS CMK for SNS — home lab; AES256 default encryption is sufficient
# trivy:ignore:AVD-AWS-0095
resource "aws_sns_topic" "cost" {
  name = var.name_prefix
}

# THE HANDSHAKE IS NOT OPTIONAL AND NOT AUTOMATABLE. Chatbot authorises a Slack workspace per
# AWS account through an OAuth flow in the console. The front door's authorisation lives in
# 666802049426 and grants nothing here — this is a different account, so the same workspace
# has to be authorised again in 857256953358 before this resource can be created. Applying
# without it fails on this resource with an invalid-workspace error, which is the intended
# outcome: a cost report that reports to nobody should not apply clean.
resource "aws_chatbot_slack_channel_configuration" "cost" {
  count = var.slack_workspace_id == "" ? 0 : 1

  configuration_name = var.name_prefix
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.cost.arn]
  logging_level      = "ERROR"
}

resource "aws_iam_role" "chatbot" {
  count = var.slack_workspace_id == "" ? 0 : 1
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

# Chatbot's own managed policy is far wider than relaying a message needs. The report arrives
# pre-rendered in the SNS payload, so Chatbot needs to read nothing at all to deliver it; the
# CloudWatch reads below exist only so the error alarm renders with its metric graph.
# checkov:skip=CKV_AWS_355:CloudWatch Describe/Get/List actions do not support resource-level restrictions
resource "aws_iam_role_policy" "chatbot" {
  count = var.slack_workspace_id == "" ? 0 : 1
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

# CloudWatch publishes alarm state from a service principal, so the topic has to accept it.
# Without this the alarm is created, reports healthy, and silently delivers nothing.
data "aws_iam_policy_document" "cost_topic" {
  # Budgets publishes from a service principal. Without this the budget is created, reports
  # healthy, and silently delivers nothing — which on the one control that exists to catch a
  # surprise bill is the worst possible failure.
  statement {
    sid     = "AllowBudgets"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.cost.arn]
  }

  statement {
    sid     = "AllowCloudWatchAlarms"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.cost.arn]
  }

  # The account keeps everything it normally has; omitting this replaces the default policy
  # and locks the owner out of their own topic.
  statement {
    sid     = "AllowAccountOwner"
    actions = ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }
    resources = [aws_sns_topic.cost.arn]
  }
}

resource "aws_sns_topic_policy" "cost" {
  arn    = aws_sns_topic.cost.arn
  policy = data.aws_iam_policy_document.cost_topic.json
}

# --- THE ONE THAT MATTERS -------------------------------------------------------------------
#
# A DAILY REPORT THAT STOPS ARRIVING LOOKS EXACTLY LIKE A QUIET MONTH. That is the failure
# mode of every scheduled report, and it is worse here than usual: the whole point of this
# stack is to make sub-cent spend visible, so "no message today" is indistinguishable from
# the good news it is supposed to deliver. This alarm is what separates the two — it fires
# from CloudWatch, not from the function, so it still speaks when the function does not.
resource "aws_cloudwatch_metric_alarm" "report_errors" {
  alarm_name        = "${var.name_prefix}-failing"
  alarm_description = "${aws_lambda_function.report.function_name} raised instead of publishing the daily cost report. Until this clears, silence in this channel means the report is broken, not that spend is zero."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"
  # A full day, because the function only runs once a day. A five-minute period would sit in
  # INSUFFICIENT_DATA for 287 of every 288 periods and train everyone to ignore it.
  period              = 86400
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = { FunctionName = aws_lambda_function.report.function_name }

  # A day with no invocation publishes no datapoint rather than a zero, so the default
  # treatment would leave this INSUFFICIENT_DATA forever on a healthy stack.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.cost.arn]
  ok_actions    = [aws_sns_topic.cost.arn]
}
