# kics-scan disable=CKV_AWS_27
# The two queues, and why there are two.
#
# They fail differently, and one queue would force a single retry policy onto both.
#
#   events  Drains in milliseconds, always, because Lambda is always there. Nothing that
#           happens in the cluster can make a message here fail, so maxReceiveCount is a
#           poison-message detector and anything reaching its DLQ is a genuine bug.
#   jobs    Drains only when the cluster is well. During an outage it holds the backlog for
#           14 days and NOTHING IS FAILING — the messages are simply unread.
#
# Sharing one queue would mean the consumer Lambda kept re-receiving an outage backlog it
# could do nothing with, burning invocations and eventually redriving perfectly good
# deliveries to the DLQ because the cluster was down — turning a cluster outage into
# permanent data loss, which is the failure this whole stack exists to end.
#
# BOTH ARE FIFO, for the ordering rather than the exactly-once. The message group is one pull
# request (see nievah.aws.policy.message_group_id), so two pushes to the same PR are ordered
# against each other and can never be reviewed concurrently, while every other PR in the
# fleet proceeds unblocked. ARQ had no such notion: a fast second push could race the review
# of the first. FIFO's 300 TPS ceiling is four orders of magnitude above this fleet's rate.

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "events" {
  name                        = "${var.name_prefix}-events.fifo"
  fifo_queue                  = true
  content_based_deduplication = false # the producer supplies the delivery id explicitly

  # Long enough for the consumer's 30s timeout plus retries, and no longer: a message stuck
  # invisible is a FIFO group stalled behind it.
  visibility_timeout_seconds = 180
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
  message_retention_seconds = var.jobs_retention_seconds
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "jobs" {
  name                        = "${var.name_prefix}-jobs.fifo"
  fifo_queue                  = true
  content_based_deduplication = false

  # Must exceed the time the cluster takes to replay a whole batch into the ingest. If it
  # lapses mid-batch every message in it is delivered again — and on FIFO, in order, ahead of
  # everything else in the same group. Mirrors AppConfig.sqs_visibility_seconds; the two are
  # a pair and moving one alone is a bug.
  visibility_timeout_seconds = 300
  message_retention_seconds  = var.jobs_retention_seconds

  # Deliberately generous. A receive here fails because the CLUSTER is unwell, not because
  # the message is bad, so a low count would send healthy deliveries to the DLQ during
  # exactly the outage they are meant to survive. At the consumer's poll rate this is hours
  # of sustained failure before anything is redriven.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 50
  })
}

# checkov:skip=CKV_AWS_27:No KMS CMK for SQS — home lab; SSE-SQS (AES256) is sufficient
# trivy:ignore:AVD-AWS-0096
resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.name_prefix}-jobs-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = var.jobs_retention_seconds
}

# Let the DLQs be drained back into their sources from the console once the cause is fixed.
# Without this a redrive is a hand-written script, which is the difference between recovering
# a stuck delivery in a minute and deciding it is not worth the effort.
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
