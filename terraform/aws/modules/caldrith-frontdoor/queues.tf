# kics-scan disable=CKV_AWS_27
# ONE QUEUE. There were two until 2026-09-03 and the deleted one is worth understanding before
# anybody reintroduces it.
#
# `events.fifo` carried a verified but unparsed webhook delivery, and a `consumer` Lambda
# drained it, parsed it, and turned it into the jobs below. The argument for the split was that
# THE INGEST MUST NEVER QUEUE BEHIND GITHUB: during a GitHub outage jobs backs up for hours,
# and a shared queue would put a 200-repo fan-out in front of the next incoming webhook.
#
# THAT ARGUMENT WAS ABOUT THE WRONG THING. The ingest is the producer, and the producer never
# READS a queue — it is invoked by API Gateway. A jobs backlog cannot reach it whether there
# are two queues or one. What the split actually bought was a redrive budget for the
# claim-and-route step, which is real but much smaller than it looked.
#
# WHAT IT COST WAS NOT SMALL. A Lambda event source mapping long-polls forever at
# `scaling_config.maximum_concurrency` pollers x 3 receives a minute, and an empty receive is
# billed like any other request. Measured over three days in prd-caldrith: 28,661 empty
# receives on events.fifo and 64,646 on jobs.fifo, against 7,565 and 52 real messages — 80% of
# the account's SQS usage, none of it moving with delivery volume. Worse, all 7,552 deliveries
# in that window routed to nothing (`check_run` alone was 70% of them), so the queue's entire
# job was to carry work that did not exist.
#
# The producer now claims, parses, routes and sends here directly, and a delivery that implies
# no work costs no SQS request at all. See caldrith's
# .claude/decisions/0001-fold-consumer-into-producer.md for what that traded away.
#
# THIS QUEUE IS FIFO, for the ordering rather than the exactly-once.
#
#   THE GROUP IS ONE REPOSITORY (`<owner>/<repo>`), or the account (`<owner>`) for
#   account-scoped work — org settings, a full fan-out. It is a correctness requirement and not
#   a nicety: two concurrent reconciles of the SAME repo both read live state, both compute a
#   diff against it, and both PATCH — the classic lost update, and on a full-replace tier like
#   `labels` or `collaborators` (which PRUNE anything undeclared) the loser's view of the world
#   is written last. FIFO makes same-repo work strictly serial while every other repo in the
#   fleet proceeds unblocked. Note the unit is the REPO, not the pull request nievah groups by.
#
# FIFO's 300 TPS ceiling is four orders of magnitude above this fleet's rate.

locals {
  # THE 6x RULE, APPLIED RATHER THAN REMEMBERED. AWS requires a queue's visibility timeout to
  # be at least the consuming function's timeout, and recommends 6x it to leave room for
  # batching and in-flight retries. Nievah states that pairing in a comment and asks you not to
  # move one without the other; here the arithmetic does it, so they cannot drift.
  #
  # It is not a theoretical drift. Set the visibility below the function timeout and the event
  # source mapping refuses to create with an InvalidParameterValueException — that one is
  # loud. Set it merely too LOW and it is silent: a job still running when visibility lapses
  # is redelivered to a second invocation, so two reconciles of the same repo run
  # concurrently, which is precisely what the FIFO message group above exists to prevent.
  jobs_visibility_seconds = local.reconcile_timeout_seconds * 6
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "jobs" {
  name       = "${var.name_prefix}-jobs.fifo"
  fifo_queue = true

  # DECLARED, NOT INHERITED, and the AWS provider only drift-detects this attribute when it
  # is PRESENT in the config — so if encryption were off, nothing would ever say so. Not
  # cosmetic here: a job message names the
  # installation and every managed `<owner>/<repo>`.
  sqs_managed_sse_enabled = true

  # FALSE, and the choice the PRODUCER then makes is worth writing down because both options
  # are defensible and one of them is a trap.
  #
  #   Recommended: a dedup id scoped to the DELIVERY (e.g. `<job>:<owner>/<repo>:<delivery>`).
  #   Exactly-once per webhook, no behaviour to reason about. This is what the producer does.
  #
  #   Tempting: a dedup id scoped to the REPO (`reconcile_repo:<owner>/<repo>`). Because
  #   reconcile is idempotent and converges, forty drift events for one repo inside five
  #   minutes would collapse into ONE job — free debouncing, and a real cut to both Lambda
  #   invocations and GitHub API calls during exactly the storm that costs the most.
  #
  # The trap in the tempting one: FIFO's five-minute window starts when the message is SENT,
  # not when it is processed. Drift that occurs one minute after a job was enqueued produces a
  # message that is silently DROPPED as a duplicate of work that had already passed the point
  # of noticing it — so the repo stays drifted until something else triggers a reconcile. That
  # is a self-healing system quietly failing to heal, which is the one failure mode Caldrith
  # must not have. Reach for it only if a drift storm ever shows up as a cost, and only with
  # the periodic full reconcile enabled to catch what it drops.
  content_based_deduplication = false

  # 6x the reconcile timeout — see the `locals` block above. Changing
  # `var.reconcile_timeout_seconds` moves this automatically, and moving this is what changes
  # how long a failing message stays invisible between attempts.
  visibility_timeout_seconds = local.jobs_visibility_seconds
  message_retention_seconds  = var.jobs_retention_seconds

  # TEN, NOT NIEVAH'S FIFTY, BECAUSE A RECEIVE HERE FAILS DIFFERENTLY. Nievah is
  # generous because a receive there fails when a CLUSTER is unwell, and a low count would
  # redrive healthy deliveries during exactly the outage they are meant to survive. Here a
  # receive fails because a reconcile RAISED — and every attempt is a full Lambda invocation
  # that re-runs the tiers, which means it re-issues its GitHub API calls. Fifty attempts at a
  # poison job is fifty rounds of writes against a repo, fifty invocations, and (on FIFO) a
  # message group stalled behind it the entire time.
  #
  # Ten attempts at a 30-minute visibility timeout is ~5 hours of sustained failure before
  # anything is redriven — long enough to ride out a GitHub incident, short enough that a
  # genuine poison message lands in the DLQ the same working day. Note that the stale-jobs
  # alarm fires long before this, at 15 minutes, precisely because 5 hours is far too long to
  # find out.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 10
  })
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.name_prefix}-jobs-dlq.fifo"
  fifo_queue                = true
  sqs_managed_sse_enabled   = true # declared, not inherited — see the note on the events queue
  message_retention_seconds = var.jobs_retention_seconds
}

# Let the DLQs be drained back into their sources from the console once the cause is fixed.
# Without this a redrive is a hand-written script, which is the difference between recovering
# a stuck reconcile in a minute and deciding it is not worth the effort.
#
# For Caldrith there is a second recovery path nievah does not have, and it is usually the
# better one: `POST /reconcile` re-derives the work from the config rather than replaying a
# stale job. Redrive when you want the exact original message; trigger a reconcile when you
# just want the fleet correct.
resource "aws_sqs_queue_redrive_allow_policy" "jobs_dlq" {
  queue_url = aws_sqs_queue.jobs_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.jobs.arn]
  })
}
