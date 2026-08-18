# The scheduled ticks that replace the two Kubernetes CronJobs.
#
# THIS IS NOT A LIKE-FOR-LIKE MOVE, and the difference is the reason to make it. A CronJob
# runs INSIDE the cluster, so a wedged cluster silently stops ticking, and the only thing
# positioned to notice is the thing that is wedged — the exact shape of the 15 hours of
# unexplained planner silence recorded in src/nievah/worker/tick.py. A schedule that fires
# into a queue leaves an unconsumed message behind instead, and the age of that message is a
# CloudWatch alarm that pages from OUTSIDE the failure domain. See notify.tf.
#
# The tick still only ENQUEUES; the work still runs in the worker under its existing budgets
# and locks. What moved is when the work starts, never where it happens — the same contract
# tick.py has always described, one hop further out.

locals {
  # Names must match nievah.worker.tick.CRONJOB_TICKS. An unknown name is refused by
  # enqueue_tick with a log line, which is the right failure but a silent-looking one.
  ticks = {
    # Every two hours across the working day, matching the schedule in k8s/base/cronjob.yaml
    # that this replaces. PLANNER_HOURS in the ConfigMap does not schedule anything — it
    # feeds the catch-up interval — so this is the single thing deciding when a run starts.
    planner = "cron(7 6,8,10,12,14 * * ? *)"
    # 06:30 UTC, matching k8s/base/cronjob.yaml. This read `12` until 2026-08-18, which
    # would have moved the standup 18 minutes earlier the moment ticks were enabled and cut
    # the planner-to-standup gap from 23 minutes to 5 — the exact margin that file's own
    # comment says to WIDEN, not shrink, since the standup reports on what the planner just
    # did. A schedule copied between two systems has to be diffed, not eyeballed.
    standup = "cron(30 6 * * ? *)"
  }
}

# EventBridge Scheduler: 14 million invocations a month free, permanently, not for twelve
# months. This stack uses about 180. It supersedes the legacy scheduled RULE and is the
# service to reach for on anything new — one-off schedules, flexible time windows, and a
# retry policy per target, none of which a rule has.
#
# NOT CREATED UNDER LOCALSTACK, which mocks the Scheduler API and never fires a schedule.
# An earlier draft substituted a classic EventBridge rule locally, which LocalStack DOES
# fire — and it was deleted, for two reasons. It raced aws/localstack/smoke.py's own tick
# (both landed in the same minute, so the second was correctly deduplicated and the test
# went red for the right reason at the wrong time); and all it ever proved was that
# EventBridge can invoke a Lambda, which is AWS's job. The part that is OURS — tick ->
# producer -> events -> consumer -> jobs — is covered by invoking the function directly.
resource "aws_scheduler_schedule" "tick" {
  for_each = var.localstack || !var.enable_ticks ? {} : local.ticks

  name                         = "${var.name_prefix}-${each.key}"
  schedule_expression          = each.value
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    # Fire at the stated minute. The planner's catch-up arithmetic reasons about windows, and
    # a flexible window would let a fire drift into the next one.
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.producer.arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ nievah_tick = each.key })

    retry_policy {
      # A tick that cannot be enqueued is a missed window. Retrying costs nothing and the
      # producer is idempotent for a tick — the delivery id is derived from the minute, so a
      # retry inside the same minute dedups against itself.
      maximum_retry_attempts       = 5
      maximum_event_age_in_seconds = 300
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = var.localstack || !var.enable_ticks ? 0 : 1
  name  = "${var.name_prefix}-scheduler"

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
  count = var.localstack || !var.enable_ticks ? 0 : 1
  name  = "${var.name_prefix}-scheduler"
  role  = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.producer.arn
    }]
  })
}
