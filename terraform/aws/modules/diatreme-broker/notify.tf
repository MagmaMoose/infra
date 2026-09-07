# Alarms and the budget.
#
# THE THING WORTH UNDERSTANDING ABOUT THIS SERVICE is that it fails SILENTLY. Diatreme's
# `scripts/request-app-token.sh` emits an empty token and exits 0 on every error path, and the
# action falls back to `github-actions[bot]`. A broker that is down, misconfigured, or missing
# its SSM grant produces no red check in any consumer's repository — just PR comments quietly
# losing their byline. These alarms and the weekly smoke workflow are the ONLY signals.
#
# CloudWatch's free allowance is 10 alarm metrics — POOLED ACROSS THE ORGANIZATION, not granted
# per account, because free-tier usage aggregates at the payer. Nievah's front door already uses
# four. This uses two, for six of ten.

# trivy:ignore:AVD-AWS-0095
resource "aws_sns_topic" "ops" {
  # checkov:skip=CKV_AWS_26:No KMS CMK for SNS — home lab; alarm text carries no secrets
  name = "${var.name_prefix}-ops"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.ops_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.ops_email
  # AWS emails a confirmation link; until it is clicked the subscription is pending and delivers
  # nothing, which Terraform reports as "created" either way.
}

# SNS cannot post to a Slack incoming webhook directly — it sends its own envelope and expects a
# subscription-confirmation handshake, neither of which Slack speaks. AWS Chatbot translates, and
# is free. The workspace must be authorised once by hand IN THIS ACCOUNT (an OAuth handshake
# Terraform cannot perform); nievah's account being authorised does nothing here.
resource "aws_chatbot_slack_channel_configuration" "ops" {
  count = var.slack_workspace_id == "" ? 0 : 1

  configuration_name = "${var.name_prefix}-ops"
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.ops.arn]
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

# Read-only, and only the metrics. Chatbot's default managed policy is far wider than posting an
# alarm needs.
resource "aws_iam_role_policy" "chatbot" {
  # checkov:skip=CKV_AWS_355:CloudWatch Describe/Get/List actions do not support resource-level restrictions; "*" is required
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

# --- the one that matters -------------------------------------------------------------------
#
# The broker raising is the only failure a consumer sees from outside, and they see it as a
# red release run — diatreme fails hard on any Lambda error. Everything else is invisible.
resource "aws_cloudwatch_metric_alarm" "broker_errors" {
  alarm_name          = "${var.name_prefix}-broker-erroring"
  alarm_description   = "${aws_lambda_function.broker.function_name} is raising. Every consumer's release goes red — diatreme fails hard. Check CloudWatch Logs; /healthz will look fine regardless, it answers before configuration is read. AND IF RELEASES ARE FAILING WHILE THIS ALARM IS GREEN, CHECK Throttles: Lambda excludes them from the Errors metric, and there is no throttle alarm in this account by design (see notify.tf)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = { FunctionName = aws_lambda_function.broker.function_name }
  # An idle function publishes NO datapoint rather than a zero, so the default treatment leaves
  # this INSUFFICIENT_DATA forever on a healthy stack — which looks broken and trains people to
  # ignore the channel.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]
}

# NO THROTTLE ALARM HERE, ON PURPOSE, AND CHARGATE'S IS NOT A PRECEDENT TO COPY.
#
# The account's total Lambda concurrency is 10, so throttles are possible — but diatreme FAILS
# HARD (see the leaf, and `additional_domain_names` in variables.tf): a throttled invocation is a
# Lambda 429, the gateway turns that into a 5xx, and `request-public-app-token.sh` exits 1 on any
# non-200. So every throttled token request is already a red X on a consumer's release, mailed to
# the same address `aws_sns_topic_subscription.email` delivers this topic to, in the same minute.
# The alarm announced a signal that had already arrived, and it had no `ok_actions`, so it never
# said it cleared either.
#
# `front_door_busy` DOES NOT COVER THIS and it is worth writing down why, because the arithmetic
# is not obvious: a 10-request burst plus 15s of refill is ~40 requests, which is enough to
# exhaust a concurrency cap of 10 and throttle roughly 30 of them, while staying far under
# `busy_alarm_requests_per_15min` (100). That alarm catches a SUSTAINED flood. The burst case is
# caught by the red release run and by nothing else here.
#
# CHARGATE AND BRIMYR KEEP THEIRS, and the reason is the inverse of the reason this one goes.
# Chargate fails SOFT — its client emits an empty token and carries on, so a throttled request is
# a missing byline nobody notices. There the alarm is the only signal that exists. The stakes and
# the detection-value run in opposite directions: diatreme has the worse consequence and the
# lesser need for an alarm.
#
# Reinstate this if a second Lambda ever lands in this account and starts competing for the
# quota, because then a throttle stops being a proxy for "diatreme is being hammered".
# Deleted 2026-09-04; see the alarm-budget note in modules/caldrith-frontdoor/notify.tf.

# --- the cost early-warning -----------------------------------------------------------------
#
# The stage throttle bounds the LAMBDA bill deterministically. It does not bound the GATEWAY
# bill, because AWS does not document whether it charges for the 429s it issues. Cloudflare's
# proxy is what keeps a flood away from the meter; this fires if something arrives anyway.
resource "aws_cloudwatch_metric_alarm" "front_door_busy" {
  alarm_name          = "${var.name_prefix}-front-door-busy"
  alarm_description   = "More than ${var.busy_alarm_requests_per_15min} requests in 15 minutes against ${aws_apigatewayv2_api.broker.name}. Real traffic is a few hundred a MONTH, so this is either a misconfigured consumer or abuse. AWS Budgets will not tell you for another 8-24 hours."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Count"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = var.busy_alarm_requests_per_15min
  comparison_operator = "GreaterThanThreshold"

  dimensions         = { ApiId = aws_apigatewayv2_api.broker.id }
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.ops.arn]
}

# --- the receipt ------------------------------------------------------------------------------
#
# NOT A LIMIT. AWS Budgets cannot stop spend: they refresh at most three times a day, 8-12 hours
# apart, and AWS's own documentation says you "might incur additional costs [...] before AWS
# Budgets can notify you". Any design whose safety depends on this catching something is wrong.
# Two budgets are free per account, so the guard itself costs nothing.
resource "aws_budgets_budget" "guard" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.ops.arn]
  }

  notification {
    # Half the budget, forecast. On a stack whose expected spend is under a cent, a forecast of
    # fifty cents already means something changed — and it arrives days before the bill.
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.ops.arn]
  }
}

# Budgets and CloudWatch publish from service principals, so the topic has to accept them.
# Without this the budget is created, reports healthy, and silently delivers nothing — the exact
# failure mode every alarm in this file exists to avoid.
data "aws_iam_policy_document" "ops_topic" {
  statement {
    sid     = "AllowBudgets"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.ops.arn]
  }

  statement {
    sid     = "AllowCloudWatchAlarms"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.ops.arn]
  }

  # The account keeps everything else it normally has; omitting this replaces the default policy
  # and locks the owner out of their own topic.
  statement {
    sid     = "AllowAccountOwner"
    actions = ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }
    resources = [aws_sns_topic.ops.arn]
  }
}

resource "aws_sns_topic_policy" "ops" {
  arn    = aws_sns_topic.ops.arn
  policy = data.aws_iam_policy_document.ops_topic.json
}
