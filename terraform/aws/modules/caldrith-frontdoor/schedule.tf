# kics-scan disable=CKV_AWS_297
# The periodic full reconcile — the belt-and-braces this deployment has never had.
#
# WHY IT IS NEEDED AT ALL, given that Caldrith converges. Almost every change arrives as a
# webhook about the repository that changed, and a missed one self-heals through the next
# drift event touching it. A file delivered from a SOURCE repo is the exception and breaks
# that assumption completely: nothing about the consuming repo changed, so there is no
# event to converge on, and the copy waits for something unrelated to reconcile that repo.
# Observed at ninety minutes and counting, with every check green
# (MagmaMoose/caldrith#107). `RECONCILE_CRON_MINUTES` was the answer on the ARQ deployment;
# that deployment is retired, the setting is inert here, and nothing replaced it.
#
# WHY IT TARGETS THE PRODUCER AND NOT jobs.fifo, which is the shape the code used to
# suggest. Two reasons, and the first is decisive: jobs.fifo sets
# `content_based_deduplication = false`, and Scheduler's SQS target supplies a
# MessageGroupId but no MessageDeduplicationId, so every send would be rejected outright.
# The second is that the queue the App-key function drains has exactly one writer today —
# the consumer — and a timer is not a good reason to make it two. Through the producer, the
# fire reaches jobs.fifo the way a webhook does: events.fifo, then the consumer's policy.
#
# WHAT ARRIVES: `{"caldrith_reconcile": "all"}`, matched EXACTLY by the producer. A schedule
# shipping anything else raises and logs `producer.scheduled_unknown` with the accepted
# value, rather than being quietly refused somewhere downstream — nievah shipped `planner`
# where the code wanted `planner_tick` and nothing anywhere would have said so.

resource "aws_scheduler_schedule" "reconcile" {
  # checkov:skip=CKV_AWS_297:No KMS CMK for EventBridge Scheduler — AWS managed key is sufficient
  count = var.localstack || !var.enable_reconcile_schedule ? 0 : 1

  name                         = "${var.name_prefix}-reconcile"
  schedule_expression          = var.reconcile_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    # Fire at the stated minute. Nothing here reasons about windows, but a drifting fire
    # makes "when did the last full reconcile run" unanswerable from the expression alone.
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.producer.arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ caldrith_reconcile = "all" })

    retry_policy {
      # A fire that cannot be enqueued is a skipped window, and the producer raises rather
      # than returning on a failed send precisely so this retries. It is idempotent for a
      # window: the delivery id is derived from the minute, so a retry inside the
      # five-minute FIFO dedup window collapses against the original instead of fanning
      # out across every installation twice.
      maximum_retry_attempts       = 5
      maximum_event_age_in_seconds = 300
    }
  }
}

# NOT CREATED UNDER LOCALSTACK, which mocks the Scheduler API and never fires a schedule —
# so the resource would exist, prove nothing, and read as covered.
resource "aws_iam_role" "scheduler" {
  count = var.localstack || !var.enable_reconcile_schedule ? 0 : 1
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
  count = var.localstack || !var.enable_reconcile_schedule ? 0 : 1
  name  = "${var.name_prefix}-scheduler"
  role  = aws_iam_role.scheduler[0].id

  # One function, one action. The schedule is a caller of the front door and holds nothing
  # else — in particular no sqs:SendMessage, so a compromised schedule role cannot skip the
  # producer and write to a queue directly.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.producer.arn
    }]
  })
}
