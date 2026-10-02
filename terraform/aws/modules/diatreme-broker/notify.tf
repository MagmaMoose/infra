# The ops topic and the budget. No alarms.
#
# THE THING WORTH UNDERSTANDING ABOUT THIS SERVICE is that it fails HARD. Diatreme's
# `scripts/request-public-app-token.sh` exits 1 on any non-200, so a broker that is down,
# misconfigured, throttled or missing its SSM grant is a red release run in every consumer
# repository. That, and the weekly smoke workflow, are the signals.
#
# CloudWatch's free allowance is 10 alarm metrics, POOLED ACROSS THE ORGANIZATION rather than
# granted per account, because free-tier usage aggregates at the payer. This module used two
# until 2026-10; see the note where they were, below.

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

# --- no alarms, on purpose -------------------------------------------------------------------
#
# This module had three and has none. `broker-throttled` went on 2026-09-04;
# `broker-erroring` and `front-door-busy` went in 2026-10, to bring the organisation inside its
# 10 free alarms (see the alarm-budget note in modules/caldrith-frontdoor/notify.tf).
#
# ALL THREE ANNOUNCED A SIGNAL THAT HAD ALREADY ARRIVED. Diatreme FAILS HARD (see the leaf, and
# `additional_domain_names` in variables.tf): a broker that raises, and a throttled invocation
# (a Lambda 429 the gateway turns into a 5xx), both make `request-public-app-token.sh` exit 1,
# which is a red X on a consumer's release, mailed to the same address
# `aws_sns_topic_subscription.email` delivers this topic to, in the same minute. Between
# releases, the weekly smoke workflow calls it.
#
# A FLOOD is bounded by the stage throttle, which caps what reaches Lambda and so the compute
# bill, and reported by the budget's FORECASTED notification, 8-24 hours late as AWS Budgets
# always is. Cloudflare's proxy keeps a flood away from the gateway meter in the first place.
#
# Chargate fails SOFT and keeps its `broker-erroring` alarm for that reason; it is not a
# precedent to copy here. Reinstate a throttle alarm if a second Lambda ever lands in this
# account and competes for its concurrency quota (10): throttles could then come from the
# neighbour, and a red release would no longer say why.

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
