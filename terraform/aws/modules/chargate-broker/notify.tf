# Alarms and the budget.
#
# THE THING WORTH UNDERSTANDING ABOUT THIS SERVICE is that it fails SILENTLY. Chargate's
# `scripts/request-app-token.sh` emits an empty token and exits 0 on every error path, and the
# action falls back to `github-actions[bot]`. A broker that is down, misconfigured, or missing
# its SSM grant produces no red check in any consumer's repository — just PR comments quietly
# losing their byline. This alarm and the weekly smoke workflow are the ONLY signals.
#
# CloudWatch's free allowance is 10 alarm metrics, POOLED ACROSS THE ORGANIZATION rather than
# granted per account, because free-tier usage aggregates at the payer. This module has one,
# and it is deployed twice (chargate and brimyr). See the alarm-budget note in
# modules/caldrith-frontdoor/notify.tf before adding another.

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
# The broker raising is the only failure a consumer half-sees, and they see it as a missing
# byline rather than an error. Everything else about this service is invisible from outside.
resource "aws_cloudwatch_metric_alarm" "broker_errors" {
  alarm_name          = "${var.name_prefix}-broker-erroring"
  alarm_description   = "${aws_lambda_function.broker.function_name} is raising. PR comments across every consumer are silently falling back to github-actions[bot]. Check CloudWatch Logs — /healthz will look fine regardless, it answers before configuration is read. If bylines go missing while this alarm is green, check Throttles: Lambda excludes them from the Errors metric, and there is no throttle alarm in this account by design (see notify.tf)."
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

# NO THROTTLE OR FRONT-DOOR-BUSY ALARM, since 2026-10, to bring the organisation inside its 10
# free alarms (see the alarm-budget note in modules/caldrith-frontdoor/notify.tf).
#
# A FLOOD is still bounded and still reported. The stage throttle caps what reaches Lambda, so
# it bounds the compute bill exactly, and the budget's FORECASTED notification reports what a
# sustained flood costs, 8-24 hours late, as AWS Budgets always is. Cloudflare's proxy is what
# keeps a flood away from the gateway meter in the first place.
#
# WHAT IS GIVEN UP is the throttle signal itself. Chargate fails SOFT: a throttled token request
# fails, the client turns any failure into an empty token, and the PR comment loses its byline
# without anything going red. The account's total Lambda concurrency is 10, so a burst at the
# stage limit can throttle a few requests, and that now shows up only as missing bylines.
# Lambda excludes throttles from `Errors`, which is why the description above says to check
# Throttles by hand.

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
