# Alarms, the flood detector, and the cost guard.
#
# THE POINT OF ALARMING FROM AWS is that it keeps working when the thing it watches does not.
# Caldrith's own instrumentation is structlog inside the very functions that break; when the
# reconcile function is throttled to a standstill or its event source mapping is disabled,
# there are no log lines to notice, and quiet is indistinguishable from healthy. Everything
# below observes from outside the failure domain.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE ALARM BUDGET, WHICH IS TIGHT AND IS THE REASON THIS FILE HAS FOUR ALARMS AND NOT NINE.
#
# CloudWatch's always-free tier is 10 alarms, and — like every other allowance in this design —
# it is shared across the ORGANISATION rather than per account.
#
# THE BUDGET IS ALREADY BLOWN, AND NOT BY THIS FILE. An earlier version of this note said
# "nievah uses 4, the five here take the organisation to 9, ONE SPARE". That counted two
# accounts. On 2026-09-03 seven hold alarms — caldrith, nievah, brimyr, chargate, diatreme,
# dunmir and the Root account — forecasting 13.42 against the free 10, or about $0.34/month.
# Deleting the events DLQ alarm below took this file from five to four and the organisation to
# ~12.4; it did not fix the overage, and nothing in THIS module can. Getting back under 10 is a
# decision across those seven accounts, not a caldrith one.
#
# So the spare is not to be spent casually, and two alarms that would otherwise be obvious were
# deliberately NOT created:
#
#   reconcile-erroring   `jobs_stale` already covers it and covers it FASTER. A job that raises
#                        goes back on the queue and keeps ageing, so a persistent reconcile
#                        failure trips the 15-minute age alarm long before an Errors alarm
#                        would add anything — and much sooner than the DLQ fills (~5 hours).
#   producer-routing     `producer_errors` covers it. Since the fold the producer does its own
#                        claiming and routing, so a routing bug raises there and is already
#                        alarmed — and it is a 5xx to GitHub, which is the louder signal anyway.
# ─────────────────────────────────────────────────────────────────────────────────────────────

# trivy:ignore:AVD-AWS-0095
resource "aws_sns_topic" "ops" {
  #checkov:skip=CKV_AWS_26:No KMS CMK for SNS — home lab; AES256 default encryption is sufficient
  name = "${var.name_prefix}-ops"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.ops_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.ops_email
  # AWS emails a confirmation link; until it is clicked the subscription is pending and
  # delivers nothing. Terraform reports it as created either way — so "the alarm resource
  # exists" and "somebody will hear the alarm" are two different facts, and only one of them is
  # in state.
}

# SNS cannot post to a Slack incoming webhook directly — it sends its own envelope and expects
# a subscription-confirmation handshake, neither of which Slack speaks. AWS Chatbot does the
# translation, and is free.
#
# THE WORKSPACE MUST BE AUTHORISED IN *THIS* ACCOUNT FIRST. Chatbot's OAuth handshake is
# per-AWS-account and Terraform cannot perform it. The authorisation nievah's front door uses
# lives in 666802049426 and the cost report's in 857256953358; neither grants anything in
# prd-caldrith. Applying with `slack_workspace_id` set before doing the handshake in Caldrith's
# own account fails here — correctly, since alarms configured to reach a workspace that has not
# authorised the account would otherwise apply clean and deliver nothing.
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
  #checkov:skip=CKV_AWS_355:CloudWatch Describe/Get/List actions do not support resource-level restrictions; "*" is required
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
# The oldest job nobody has taken. This is "reconciles have stopped happening", observed from
# outside the function that would be doing them — which is what makes it fire in the cases an
# in-process monitor cannot report: the event source mapping disabled, the account's Lambda
# concurrency exhausted by something else, every invocation timing out, or the function's role
# losing its SSM grant so it cannot mint a token.
#
# It is ALSO the de facto reconcile-errors alarm, and doing two jobs is how this file stays
# inside its alarm budget. A job that raises is returned to the queue and keeps ageing, so a
# persistent failure trips this in 15 minutes rather than in the ~5 hours the jobs DLQ takes to
# fill. Webhooks are safe throughout — the jobs queue holds 14 days — but nothing is being
# enforced, which on a config-as-code tool means drift is accumulating unseen.
resource "aws_cloudwatch_metric_alarm" "jobs_stale" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-jobs-not-being-reconciled"
  alarm_description   = "Oldest job on ${aws_sqs_queue.jobs.name} is older than ${var.stale_jobs_alarm_seconds}s — ${var.name_prefix}-reconcile is not draining, or is failing every attempt. Deliveries are safe (14-day retention) but no configuration is being enforced and drift is accumulating."
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

# Reaching this DLQ takes ten failed receives at a 30-minute visibility timeout — roughly five
# hours of sustained failure. So it means either a GitHub incident that outlasted the redrive
# budget, or a job that fails deterministically (a revoked installation, a repo deleted between
# the fan-out and the job, a config that no longer validates).
resource "aws_cloudwatch_metric_alarm" "jobs_dlq" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-jobs-dlq-not-empty"
  alarm_description   = "Reconcile jobs exhausted the redrive budget on ${aws_sqs_queue.jobs.name}. Fix the cause, then either redrive ${aws_sqs_queue.jobs_dlq.name} from the console or — usually better — POST /reconcile, which re-derives the work from the current config instead of replaying stale jobs."
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
# degrades into a queue; this one returns a 5xx to a caller that POSTs each delivery exactly
# once and will never re-send it.
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

# --- THE FLOOD DETECTOR -----------------------------------------------------------------------
#
# THE ALARM THIS STACK WAS MISSING, and the only one that watches the front door itself rather
# than what the front door lets through. Every other alarm here observes a consequence — a
# queue ageing, a DLQ filling, a function raising. A flood produces none of those: the throttle
# absorbs it, the queues drain, nothing errors, and the only trace is a request count and,
# possibly, a bill.
#
# IT CATCHES CALDRITH BEFORE IT CATCHES AN ATTACKER, which is the better reason to have it.
# Caldrith's own writes echo back to it as webhooks — a repo edit is a `repository` event, a
# label write is a `label` event — and that terminates only because the next reconcile finds no
# drift and issues no write. A tier that re-drifts every pass turns it into a self-sustaining
# loop: the exact bug recorded in COMMON_MISTAKES under "the deep diff is desired-driven at
# EVERY level", where a partial `security_and_analysis` object never compared equal and the
# repository tier re-PATCHed on every single reconcile. That shipped. Nothing else in this file
# would have said a word about it.
#
# THE THRESHOLD ARITHMETIC IS IN `var.api_flood_alarm_hourly_count` AND IS WORTH READING before
# changing either number: 10,000/hour — the value first proposed — can never be reached if the
# `Count` metric excludes throttled requests, because a 1 req/s stage throttle caps an hour at
# 3,600. A validation rule ties the two variables together so that property cannot rot.
#
# Sum over one hour rather than a rate over five minutes, deliberately: a five-minute window on
# a service whose normal traffic is ~40 requests an hour is mostly noise, and this alarm is
# about a sustained condition — an attacker with a script, or a loop — not a spike.
resource "aws_cloudwatch_metric_alarm" "api_flood" {
  count = var.localstack ? 0 : 1

  alarm_name          = "${var.name_prefix}-front-door-flooded"
  alarm_description   = "More than ${var.api_flood_alarm_hourly_count} requests reached ${var.name_prefix}-front-door in an hour, against a normal of ~40. Either something is flooding the endpoint, or Caldrith is in a write/drift-event loop and is flooding itself — check whether a tier is re-applying the same change on every reconcile before assuming it is external."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Count"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.api_flood_alarm_hourly_count
  comparison_operator = "GreaterThanThreshold"

  # `ApiId` alone. HTTP APIs publish these metrics per API by default; a `Stage` dimension
  # would need detailed metrics turned on, which is itself billed — a monitoring feature that
  # costs money to watch for money being spent is not the trade to make here.
  dimensions = { ApiId = aws_apigatewayv2_api.producer[0].id }

  # A quiet hour publishes no datapoint at all on a low-traffic API, so without this the alarm
  # sits in INSUFFICIENT_DATA on a perfectly healthy Sunday.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]
}

# --- THE COST GUARD -------------------------------------------------------------------------
#
# The brief for this stack was "free", and everything in it is inside a permanent always-free
# allowance except the API Gateway requests. This is what turns that
# from an estimate into something monitored.
#
# TWO BUDGETS ARE FREE PER ACCOUNT and prd-caldrith had none, so this one costs nothing. Do not
# add a third without meaning to: beyond two, AWS charges $0.02/budget/day, which would be its
# own small surprise bill on a stack designed around not having one.
#
# It is deliberately not a limit. AWS BUDGETS CANNOT STOP SPEND — nothing in AWS can — and they
# can lag several hours to a day. The real-time controls are the API Gateway throttle (api.tf)
# and the flood alarm above; this is the backstop that notices whatever both of them missed,
# including the categories they cannot see at all, such as a service being switched on by hand
# in the console.
#
# Both thresholds matter. ACTUAL fires once real money has been spent; FORECASTED fires when
# the month's trajectory says it will be — which on a stack that should cost pennies is the one
# that gives useful warning, days ahead of the bill.
resource "aws_budgets_budget" "guard" {
  count = var.localstack ? 0 : 1

  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # GROSS USAGE, NOT NET, AND WITHOUT THIS BLOCK THE GUARD IS BLIND FOR ABOUT A YEAR. AWS's
  # defaults are include_credit = true and include_refund = true, so a budget with no cost_types
  # tracks spend AFTER credits are applied. This organisation signed up 2025-09-18, under the
  # post-2025-07-15 free-tier model, which hands a new account $100-$200 in credits that expire
  # twelve months from the sign-up date. Until they are gone, a net-cost budget reads roughly $0
  # no matter what this stack actually consumes — so neither the ACTUAL 100% nor the FORECASTED
  # 50% notification below can fire. The one resource whose entire job is to prevent a surprise
  # would be blind for exactly the window in which a misconfiguration is cheapest to catch, and
  # then spend would appear at full rate on the day the credits expire, with no history to
  # calibrate against. Measuring gross usage charges makes the $1 guard mean what it says, and
  # starts it reporting now.
  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.ops.arn]
  }

  notification {
    # Half the budget, forecast. On a stack whose expected spend is a few cents, a forecast of
    # fifty cents already means something changed.
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.ops.arn]
  }

  # THE TOPIC POLICY IS A PRECONDITION, NOT A SIBLING, and nothing else in the config says so.
  # AWS Budgets validates SNS publish permission at CreateBudget time, so on a fresh apply
  # Terraform creating this before `aws_sns_topic_policy.ops` fails with a validation error
  # naming the topic — and with no edge between them that ordering is roughly a coin flip. The
  # natural reaction to an apply that fails on the budget resource is to drop the notification,
  # which lands exactly on the silent-delivery failure the policy's own comment warns about.
  depends_on = [aws_sns_topic_policy.ops]
}

# Budgets publishes from a service principal, so the ops topic has to accept it. WITHOUT THIS
# THE BUDGET IS CREATED, REPORTS HEALTHY, AND SILENTLY DELIVERS NOTHING — the failure mode every
# alarm in this file exists to avoid, arriving through the one resource whose whole job is to
# tell you something went wrong. It is easy to omit because nothing errors when you do.
data "aws_iam_policy_document" "ops_topic" {
  statement {
    sid     = "AllowBudgets"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.ops.arn]

    # The confused-deputy guard AWS documents for this exact statement. `budgets.amazonaws.com`
    # is a SHARED service principal: unqualified, the grant says "any budget in any account may
    # publish here", and someone else's budget could drive this topic — which on a topic whose
    # subscriber is a human inbox is a notification-spoofing surface, not just untidiness.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
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

  # The account keeps everything else it normally has; omitting this replaces the default
  # policy and locks the owner out of their own topic.
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
