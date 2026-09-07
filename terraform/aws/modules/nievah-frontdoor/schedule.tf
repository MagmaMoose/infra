# kics-scan disable=CKV_AWS_297
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
  # THE `tick` VALUE MUST MATCH nievah.worker.tick.CRONJOB_TICKS EXACTLY, which is
  # ("planner_tick", "standup_tick") — WITH the suffix. This map's keys used to be the
  # payload as well as the resource name, so the schedules shipped `planner`/`standup` and
  # every fire would have been refused by enqueue_tick as `tick.unknown`. Nothing would have
  # caught it: the message IS consumed, `_run_tick` maps the refusal to 400, the consumer
  # treats 400 as a permanent rejection and DELETES it, so the queue stays empty and
  # `nievah-jobs-not-being-consumed` never fires. With the CronJobs suspended that is a
  # silently dead planner — the exact failure this whole migration exists to end, reintroduced
  # by the migration. The comment that used to sit here stated the requirement and the code
  # three lines below it did not meet it; it was caught by firing a deliberately unknown tick
  # at the deployed Lambda and reading `known` back out of the log line.
  #
  # Key = the schedule's own name (stays `nievah-planner`). Value.tick = the payload.
  ticks = {
    # Every two hours across the working day, matching the schedule in k8s/base/cronjob.yaml
    # that this replaces. PLANNER_HOURS in the ConfigMap does not schedule anything — it
    # feeds the catch-up interval — so this is the single thing deciding when a run starts.
    planner = {
      tick = "planner_tick"
      cron = "cron(7 6,8,10,12,14 * * ? *)"
    }
    # 06:30 UTC, matching k8s/base/cronjob.yaml. This read `12` until 2026-08-18, which
    # would have moved the standup 18 minutes earlier the moment ticks were enabled and cut
    # the planner-to-standup gap from 23 minutes to 5 — the exact margin that file's own
    # comment says to WIDEN, not shrink, since the standup reports on what the planner just
    # did. A schedule copied between two systems has to be diffed, not eyeballed.
    standup = {
      tick = "standup_tick"
      cron = "cron(30 6 * * ? *)"
    }
    # THE EVALUATOR, not the schedule. Unlike the two above — which each ARE one job's
    # schedule — this one only wakes the maintenance tick so it can read the per-repo crons in
    # the admin repo's `.github/nievah-maintenance.yml` and decide what is owed. Hourly is the
    # cadence, and it is a contract in two directions: a per-repo cron whose MINUTE is not one
    # this fires at can never have a first run (`is_due` needs an exact minute match with no
    # prior run), and the worker's MAINTENANCE_TICK_MINUTES must say the same minute this
    # does. The tick alarms on any schedule it can never observe rather than letting it sit in
    # config looking healthy — 24 fires a day against EventBridge's 14M/month free tier.
    maintenance = {
      tick = "maintenance_tick"
      cron = "cron(0 * * * ? *)"
    }
    # The auto-triage lane's retry. That lane starts from ONE webhook delivery, and GitHub
    # never re-sends one it failed to place, so a dropped delivery strands a PR silently —
    # "no job ran" and "a job ran and found nothing" are the same empty log.
    #
    # THIS SCHEDULE IS LOAD-BEARING IN A WAY THE OTHERS ARE NOT. `_audit_schedule` reports on
    # the PREVIOUS fire, so it only ever runs BECAUSE a tick fired. A reconcile tick with no
    # schedule therefore never runs and never alarms — the repair job failing in exactly the
    # silence it exists to break. If you remove this entry, remove TICK_RECONCILE from
    # CRONJOB_TICKS in the same change.
    #
    # Minute 20 deliberately: away from the planner (7) and maintenance (0), so an hour's
    # three fires do not arrive together on a single-runner queue.
    reconcile = {
      tick = "reconcile_tick"
      cron = "cron(20 * * * ? *)"
    }
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
  # checkov:skip=CKV_AWS_297:No KMS CMK for EventBridge Scheduler — home lab; AWS managed key is sufficient
  for_each = var.localstack || !var.enable_ticks ? {} : local.ticks

  name                         = "${var.name_prefix}-${each.key}"
  schedule_expression          = each.value.cron
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    # Fire at the stated minute. The planner's catch-up arithmetic reasons about windows, and
    # a flexible window would let a fire drift into the next one.
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.producer.arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ nievah_tick = each.value.tick })

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
