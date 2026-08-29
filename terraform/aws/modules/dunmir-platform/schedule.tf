# The dead-man heartbeat sweep, on a timer.
#
# Every agent reports in on an interval; the sweep is what notices when one stops. It is the
# whole point of the product's alerting, and it is invisible when broken — a fleet with no
# sweep looks exactly like a fleet where nothing has gone wrong.
#
# EventBridge Scheduler rather than an EventBridge rule: one-minute granularity, a free
# allowance of 14 million invocations a month (this uses ~44,000), and a flexible time window
# that would let the schedule spread load if it ever mattered.
#
# The payload invokes the function DIRECTLY with `{"task": "sweep"}` rather than making an HTTP
# request to `POST /internal/sweep`. That means no shared admin token to hold, no round trip
# through CloudFront, and no way to reach the sweep from outside the account at all.

resource "aws_scheduler_schedule" "sweep" {
  count = local.creates_schedule ? 1 : 0

  name        = "${local.name}-sweep"
  description = "Dun Mir dead-man heartbeat sweep"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = var.sweep_schedule_expression
  # Explicit rather than the account default. A `cron()` expression written for a European
  # operator and silently interpreted as UTC is the kind of off-by-an-hour that only shows up
  # twice a year, at the clock change.
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.api.arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ task = "sweep" })

    retry_policy {
      # One retry. The sweep is idempotent and runs again in sixty seconds anyway, so a long
      # retry ladder would only pile concurrent sweeps on top of whatever made the first fail.
      maximum_retry_attempts       = 1
      maximum_event_age_in_seconds = 60
    }
  }
}

# ── cost tripwire ───────────────────────────────────────────────────────────────────────────
#
# One dollar. Not a sensible operating budget — the entire premise of this stack is that it is
# free, so ANY charge is news and the alert should fire on the first one. Without it the first
# signal that something slipped off the free tier is next month's invoice.
#
# Budgets themselves are free for the first two per account, and they email directly rather than
# through SNS, so there is no subscription confirmation to be silently pending.
resource "aws_budgets_budget" "guardrail" {
  count = var.enable_budget_alarm && !var.localstack && var.ops_email != "" ? 1 : 0

  name         = "${local.name}-free-tier-guardrail"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.ops_email]
  }

  notification {
    # FORECASTED as well as ACTUAL. A forecast crossing the line is the early warning; by the
    # time actual spend has crossed it, whatever is billing has been billing for days.
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.ops_email]
  }
}

# ── the alarm that matters operationally ────────────────────────────────────────────────────
#
# Function errors, not latency and not throttles. An error here means either the API is
# 500-ing or the sweep is not running, and both are invisible from outside: the console shows
# stale data and the fleet shows no alerts, which is indistinguishable from a quiet week.
#
# CloudWatch's free tier includes 10 alarms.
resource "aws_cloudwatch_metric_alarm" "function_errors" {
  count = !var.localstack && var.ops_email != "" ? 1 : 0

  alarm_name        = "${local.name}-api-errors"
  alarm_description = "Dun Mir API function is erroring — the console, the agents or the sweep are affected."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions  = { FunctionName = aws_lambda_function.api.function_name }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  # Missing data is GOOD here: Lambda publishes no Errors datapoint when there are no errors, so
  # `missing` would otherwise flap the alarm into INSUFFICIENT_DATA every quiet five minutes.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
}

resource "aws_sns_topic" "alerts" {
  count = !var.localstack && var.ops_email != "" ? 1 : 0

  name = "${local.name}-alerts"

  tags = { Name = "${local.name}-alerts" }
}

# AWS sends the confirmation link exactly ONCE, and until it is clicked the subscription is
# pending and delivers nothing — which Terraform reports as "created" either way. Check the
# inbox after the first apply; an unconfirmed subscription is an alarm nobody receives.
resource "aws_sns_topic_subscription" "alerts_email" {
  count = !var.localstack && var.ops_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.ops_email
}
