# The backstop, OCI edition. Deliberate sibling of terraform/aws/modules/cost-report/budget.tf,
# shaped the same way so the two clouds' cost floors read side by side.
#
# Same premise as the AWS one: every other control in this repo is a design choice, and this
# module assumes those choices were wrong. Both tenancies are built to sit inside Always Free
# and are expected to bill nothing. A budget is the thing that speaks when that stops being
# true and nobody is looking.
#
# ── A budget REPORTS. It cannot CAP. ──────────────────────────────────────────────────────
# Oracle's own word for these is "soft limits". Nothing in OCI hard-stops an account's bill,
# exactly as nothing in AWS does, so the honest job here is to shorten the gap between "spend
# started" and "a human found out" — not to close it. OCI evaluates alert rules every 24
# hours, so a runaway resource still gets up to a day before anything is said. That evaluation
# interval is the reason the FORECAST rule below exists at all.
#
# ── Delivery is EMAIL ONLY. That is the API, not a shortcut. ──────────────────────────────
# Verified against the oracle/oci 8.0.0 provider schema rather than assumed: the only delivery
# argument on oci_budget_alert_rule is `recipients`, a delimited string of email addresses
# (comma, semicolon, space, tab or newline). There is no topic_id on it, and no attribute
# whose name contains "topic" exists on ANY oci_budget_* resource in that provider version.
#
# So the AWS shape — budget notification into an SNS topic, topic fanned out to Slack — has no
# OCI equivalent. Two alternatives were looked at and both fail:
#   - Subscribe an ONS topic and put its address in `recipients`. Impossible: OCI Notifications
#     topics are push-only and have no inbound email address to send to.
#   - oci_budget_cost_alert_subscription, which DOES take a `channels` argument. It belongs to
#     Cost Anomaly Detection, a separate service driven by its own anomaly monitors. It cannot
#     subscribe to these budgets or carry their thresholds.
# The irony is worth writing down so nobody re-derives it: ONS supports a native SLACK
# subscription protocol, and budget alerts are the one thing that cannot reach ONS.
#
# Slack coverage therefore comes from the daily cost report, not from here. Treat that as a
# feature: the report and this budget are fully independent paths, so the report's Lambda,
# schedule or bot token can all break and the budget still mails.
#
# ── Cost of the budgets themselves ────────────────────────────────────────────────────────
# The AWS module has to count them (two free per account, $0.02/budget/day beyond). OCI has no
# equivalent counting problem: Budgets is part of OCI's Cost Management tooling and is not a
# metered line item on the price list. Stated as observed, not as a guarantee — Oracle does not
# publish an explicit "Budgets: free" line, it simply never publishes a price for it.

resource "oci_budget_budget" "tenancy" {
  # A budget OBJECT always lives in the root compartment no matter what it TARGETS. Oracle:
  # "All budgets are created in the root compartment, regardless of the compartment they're
  # targeting". Passing a child compartment here is not a narrower scope, it is an error.
  compartment_id = var.tenancy_ocid

  # `targets` looks like a list and is not one: OCI requires exactly one entry, whether the
  # target is a compartment or a cost-tracking tag. The plural is API surface for a fan-out
  # that does not exist yet.
  #
  # Targeting the ROOT compartment is what makes this cover the whole tenancy: a compartment
  # budget tracks that compartment AND its children. Verified per tenancy rather than assumed,
  # because a budget aimed one level too low is a backstop that quietly misses most of the
  # bill — cloudworkers has no child compartments at all, and firefly's only child is Oracle's
  # own ManagedCompartmentForPaaS, with every real resource (vcn-prod, ff-oci1, ff-oci2, both
  # CHRs) sitting in root.
  target_type = "COMPARTMENT"
  targets     = [var.target_compartment_ocid]

  # MONTHLY is the only value OCI accepts. Anyone reaching for WEEKLY to get faster warning
  # should reach for the FORECAST rule below instead — that is the knob that buys time.
  reset_period = "MONTHLY"

  amount = var.monthly_budget_amount

  display_name = "budget-${var.tenancy_name}-${var.environment}"
  description  = "Monthly spend backstop for the ${var.tenancy_name} tenancy. Reports only; cannot cap spend."

  freeform_tags = {
    "Environment" = var.environment
    "Tenancy"     = var.tenancy_name
    "Managed-By"  = "terraform"
  }
}

# Both rules are set because they answer different questions, which is the same reason the AWS
# module sets both. ACTUAL says money has already gone. FORECAST says the month's trajectory
# says it will — which on a stack that should cost nothing is days of warning rather than none.
#
# Both use threshold_type PERCENTAGE. ABSOLUTE is also accepted and was rejected: it would
# decouple the trip point from `amount`, leaving two numbers to drift apart independently, and
# it would break the line-for-line diff against the AWS module where one variable moves
# everything.

resource "oci_budget_alert_rule" "actual" {
  budget_id      = oci_budget_budget.tenancy.id
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"

  display_name = "actual-100pct"
  description  = "Actual month-to-date spend reached the full budget."

  # The email OCI sends names the budget but not the Oracle account it came from, and this
  # operator runs two tenancies in eu-amsterdam-1. Without the tenancy spelled out in the body,
  # a 3am alert is ambiguous between them.
  message = "OCI ${var.tenancy_name} (${var.environment}): ACTUAL spend has reached the full monthly budget of ${var.monthly_budget_amount}. Expected steady state for this tenancy is zero. Check Cost Analysis in the ${var.tenancy_name} tenancy. This alert reports only; it has not stopped anything."

  recipients = var.alert_recipients
}

resource "oci_budget_alert_rule" "forecast" {
  budget_id = oci_budget_budget.tenancy.id
  type      = "FORECAST"

  # A tenth of the budget, forecast — carried over from the AWS module unchanged. On a tenancy
  # whose expected spend is zero, a forecast of even a fraction of the budget already means
  # something changed, and this fires while there is still most of a month left to act.
  #
  # It is also the only defence against the 24-hour evaluation interval: by the time ACTUAL
  # trips, a full day of whatever went wrong has already been billed.
  #
  # Not lower than 10. OCI forecasts by linear extrapolation from month-to-date spend, so early
  # in the month a trivial accrual extrapolates to a large multiple of itself. Below ~10% this
  # rule fires on rounding noise every month, and a rule that always fires is a rule nobody
  # reads — the same failure the atlantis.yaml autoplan notes are written to avoid.
  threshold      = 10
  threshold_type = "PERCENTAGE"

  display_name = "forecast-10pct"
  description  = "Forecast month-end spend reached a tenth of the budget."

  message = "OCI ${var.tenancy_name} (${var.environment}): FORECAST month-end spend has reached 10% of the monthly budget of ${var.monthly_budget_amount}. Nothing has overrun yet. Expected steady state for this tenancy is zero, so this usually means a resource was created outside the Always Free allowance."

  recipients = var.alert_recipients
}
