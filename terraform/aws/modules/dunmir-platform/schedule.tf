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
# through the gateway, and no way to reach the sweep from outside the account at all.

resource "aws_scheduler_schedule" "sweep" {
  # checkov:skip=CKV_AWS_297:No CMK for EventBridge Scheduler. A CMK bills per key per month; the schedule payload is just {"task":"sweep"} with no secrets.
  count = local.creates_schedule ? 1 : 0

  name        = "${local.name}-sweep"
  description = "Dun Mir dead-man heartbeat sweep"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  # ARMED ONLY WHEN THIS ACCOUNT IS THE ONE RUNNING THE APPLICATION.
  #
  # `sweep_http.tf` says the two sweeps are mutually exclusive -- "Exactly one of
  # them should ever be on" -- but both schedules read `var.sweep_enabled`, so
  # that was impossible to express and the comment claiming the HTTP sweep is
  # "independent of sweep_enabled" was simply wrong. Turning the sweep on gave you
  # BOTH, and this one invokes a Lambda that, on a stack pointed at Kubernetes,
  # has no database to sweep: every firing fails, once a minute. (It used to page
  # through the function-error alarm too; that alarm is gone, see the alarms
  # section below, so now it would fail silently.)
  #
  # So `sweep_target_url` now decides WHICH sweep runs and `sweep_enabled` decides
  # WHETHER one does, which is what both comments always described.
  state               = var.sweep_enabled && !local.creates_http_sweep ? "ENABLED" : "DISABLED"
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

# ── alarms ──────────────────────────────────────────────────────────────────────────────────
#
# ONE, AND ONLY WITH RDS. There were three. `api-5xx` and `api-errors` were deleted in 2026-10 to
# bring the organisation inside CloudWatch's 10 free alarms, which are pooled across every
# account (see the alarm-budget note in modules/caldrith-frontdoor/notify.tf): the production
# API carries no traffic, and with `sweep_target_url` set its in-account sweep schedule is
# disabled, so neither alarm had anything to watch.
#
# PUT THEM BACK TOGETHER if this API ever serves the application again, because they see
# different failures. Mangum catches every unhandled exception inside the ASGI app and RETURNS a
# 500 response payload, so the invocation succeeds and Lambda's `Errors` stays at zero while the
# API 500s on every request: only the gateway's `5xx` metric sees that. And a sweep the
# scheduler invokes directly never touches the gateway, so only `Errors` sees it fail.

# CPU credits. RDS runs T4g instances in **Unlimited** mode by default, which means sustained
#    CPU above the baseline is billed per vCPU-hour rather than throttled — an unbounded charge
#    on a stack whose whole premise is a zero bill. A draining credit balance is the early
#    warning, and it arrives days before the invoice does.
resource "aws_cloudwatch_metric_alarm" "database_cpu_credits" {
  count = local.creates_database && var.ops_email != "" ? 1 : 0

  alarm_name        = "${local.name}-db-cpu-credits"
  alarm_description = "Dun Mir database is burning CPU credits — T4g runs in Unlimited mode, so this becomes a bill."

  namespace   = "AWS/RDS"
  metric_name = "CPUCreditBalance"
  dimensions  = { DBInstanceIdentifier = aws_db_instance.this[0].identifier }

  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
}

resource "aws_sns_topic" "alerts" {
  # checkov:skip=CKV_AWS_26:SNS topic not KMS-encrypted. The topic carries email alarm notifications only — no secrets — and a CMK adds a per-key monthly charge this home-lab deployment avoids.
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
