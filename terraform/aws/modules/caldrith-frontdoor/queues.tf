# kics-scan disable=CKV_AWS_27
# The two queues, and why there are two now that BOTH are drained by a Lambda.
#
# Nievah has two because one end was a Kubernetes cluster that could be down for a fortnight.
# Caldrith retired its cluster entirely, so that argument does not transfer — and the queues
# stayed anyway, for reasons that are specific to what each one carries.
#
#   events  One webhook delivery, verified but unparsed. Draining it is a parse and a routing
#           decision: no network calls, no GitHub, milliseconds. Nothing outside this account
#           can make a message here fail, so maxReceiveCount is a poison-message detector and
#           anything reaching its DLQ is a genuine bug in the consumer.
#   jobs    One unit of reconcile work. Draining it means dozens of GitHub API calls that fail
#           for reasons this stack does not control — a GitHub incident, a secondary rate
#           limit, an installation whose token was revoked, a repo deleted between the fan-out
#           and the job.
#
# THE REASON THAT ACTUALLY MATTERS: THE INGEST MUST NEVER QUEUE BEHIND GITHUB. During a GitHub
# outage the jobs queue backs up for hours while events keeps draining in milliseconds, so
# deliveries continue to be accepted, deduplicated and recorded — which is the entire property
# this stack exists to provide, since GitHub POSTs each delivery exactly once and never
# re-sends one it failed to place. Sharing one queue would put a 200-repo fan-out and a
# fortnight-old GitHub outage directly in front of the next incoming webhook.
#
# The rest follows from that split: the two need visibility timeouts an order of magnitude
# apart (30s of parsing vs 300s of reconciling), different redrive budgets, and different
# concurrency caps — jobs is capped for GitHub's sake, not AWS's (see
# `var.reconcile_max_concurrency`). One queue can carry exactly one of each.
#
# BOTH ARE FIFO, for the ordering rather than the exactly-once — BUT THE MESSAGE GROUP IS NOT
# THE SAME ON BOTH, and asserting one rule for both queues is a bug rather than a shorthand.
#
#   jobs    THE GROUP IS ONE REPOSITORY (`<owner>/<repo>`), or the account (`<owner>`) for
#           account-scoped work — org settings, a full fan-out. Here it is a correctness
#           requirement and not a nicety: two concurrent reconciles of the SAME repo both read
#           live state, both compute a diff against it, and both PATCH — the classic lost
#           update, and on a full-replace tier like `labels` or `collaborators` (which PRUNE
#           anything undeclared) the loser's view of the world is written last. FIFO makes
#           same-repo work strictly serial while every other repo in the fleet proceeds
#           unblocked. Note the unit is the REPO, not the pull request nievah groups by.
#   events  THE GROUP IS `X-GitHub-Delivery` — one group per delivery. The repo rule is not
#           merely unnecessary here, it is UNIMPLEMENTABLE: the producer verifies and forwards
#           WITHOUT parsing (that is the consumer's job), and for an oversized delivery it has
#           just parked the body in S3 precisely because it will not handle it — so it cannot
#           derive owner/repo at all. Whatever constant it fell back to would put every
#           delivery in ONE group, and with `function_response_types = ["ReportBatchItemFailures"]`
#           a FIFO batch failure blocks the rest of its group: a single poison payload would
#           stall ALL ingest for up to 5 receives x 180s before it DLQs. That is the
#           head-of-line failure the two-queue split above exists to prevent, reintroduced one
#           layer earlier. One group per delivery costs nothing to give up: no head-of-line
#           blocking, full parallelism, the deduplication id is unchanged, and every ordering
#           guarantee that matters is re-established at `jobs`.
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
  events_visibility_seconds = local.consumer_timeout_seconds * 6
  jobs_visibility_seconds   = local.reconcile_timeout_seconds * 6
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "events" {
  name       = "${var.name_prefix}-events.fifo"
  fifo_queue = true

  # DECLARED, NOT INHERITED, and the skip above is why this line has to exist. That suppression
  # says "SSE-SQS (AES256) is sufficient" — an assertion about a control the configuration did
  # not set. Encryption at rest would otherwise be left to an AWS-side default whose behaviour
  # differs by creation path (console-created queues get SSE-SQS; API/SDK/Terraform-created ones
  # historically did not), and the AWS provider only drift-detects this attribute when it is
  # PRESENT in the config — so if it were off, nothing would ever say so. Not cosmetic here:
  # events.fifo carries the full verified webhook body, including push payloads with commit and
  # file lists from private repos, and jobs.fifo carries installation ids and every managed
  # `<owner>/<repo>`. The skip stays — CKV_AWS_27 is only about a customer-managed KMS key — and
  # now it reads truthfully.
  sqs_managed_sse_enabled = true

  # FALSE, so the PRODUCER supplies the deduplication id explicitly, and it supplies
  # `X-GitHub-Delivery`. Content-based dedup would hash the body — and GitHub's redelivery of
  # the same event is byte-identical, so it would appear to work, right up to the first two
  # genuinely distinct events that happen to carry identical payloads.
  #
  # This is the FIRST of two dedup layers and the weaker one: FIFO's window is five minutes,
  # and GitHub redelivers over hours. The durable claim is the DynamoDB conditional write in
  # storage.tf, with a 24-hour TTL. Neither replaces the other.
  content_based_deduplication = false

  visibility_timeout_seconds = local.events_visibility_seconds
  message_retention_seconds  = 345600 # 4 days; a message here is either handled or a bug

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 5
  })
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "events_dlq" {
  name                      = "${var.name_prefix}-events-dlq.fifo"
  fifo_queue                = true
  sqs_managed_sse_enabled   = true # declared, not inherited — see the note on the events queue
  message_retention_seconds = var.jobs_retention_seconds
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "jobs" {
  name       = "${var.name_prefix}-jobs.fifo"
  fifo_queue = true

  # Declared, not inherited — see the note on the events queue. A job message names the
  # installation and every managed `<owner>/<repo>`.
  sqs_managed_sse_enabled = true

  # FALSE, and the choice the CONSUMER then makes is worth writing down because both options
  # are defensible and one of them is a trap.
  #
  #   Recommended: a dedup id scoped to the DELIVERY (e.g. `<job>:<owner>/<repo>:<delivery>`).
  #   Exactly-once per webhook, no behaviour to reason about. This is what the consumer does.
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

  # TEN, NOT NIEVAH'S FIFTY, AND THE NUMBER HAD TO CHANGE WHEN THE CONSUMER DID. Nievah is
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
resource "aws_sqs_queue_redrive_allow_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.events.arn]
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "jobs_dlq" {
  queue_url = aws_sqs_queue.jobs_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.jobs.arn]
  })
}
