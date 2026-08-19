# Delivery dedup, and the overflow bucket for bodies too large to ride in a message.

# THE TABLE THAT REPLACES REDIS. `caldrith.worker.queue.dedup_delivery` is a Redis `SET NX` with
# a 24-hour TTL; this is the same claim as a DynamoDB conditional write with a TTL attribute.
# Identical semantics, no server, and — unlike the cheapest ElastiCache node at roughly $12 a
# month — actually free.
#
# PROVISIONED, NOT ON-DEMAND, and that is a free-tier decision rather than a capacity one.
# DynamoDB's always-free allowance is 25 GB of storage plus 25 write and 25 read capacity
# units — PROVISIONED units. On-demand request pricing has NO always-free component, so the
# identical workload that costs nothing here would be billed per request there. It is the one
# switch in this file that looks like a modernisation and is actually a bill.
#
# THE HEADROOM, MEASURED RATHER THAN ASSUMED. `GetFreeTierUsage` reports the allowance as
# 18,600 capacity-unit-hours a month (25 units x 744 hours) with 12 consumed org-wide today.
# This table's 2+2 is 2,976 of those, and nievah's identical table is another 2,976 — so the
# two services together sit at about a third of an allowance that is ORGANISATION-wide, not
# per-account. There is room for a third service and not much more; a fourth is the point to
# look at this again rather than the point to discover it.
# trivy:ignore:AVD-AWS-0024
# trivy:ignore:AVD-AWS-0025
resource "aws_dynamodb_table" "dedup" { # nosemgrep: terraform.aws.security.aws-dynamodb-table-unencrypted.aws-dynamodb-table-unencrypted
  #checkov:skip=CKV_AWS_28:PITR off deliberately — every row is a 24h-TTL delivery id, nothing worth restoring
  #checkov:skip=CKV_AWS_119:No KMS CMK for DynamoDB — home lab; AWS managed key is sufficient
  #checkov:skip=CKV2_AWS_16:DynamoDB auto-scaling disabled deliberately — provisioned 2/2 to stay in always-free tier
  name         = "${var.name_prefix}-dedup"
  billing_mode = "PROVISIONED"

  # AUTO-SCALING IS OFF AND THAT IS THE COST CEILING, not an oversight. With it on, a flood
  # that got past the API Gateway throttle would scale this table up to meet it — turning a
  # fixed, free 2 units into a variable, billed number at exactly the moment nobody is
  # watching. Throttled writes are the correct behaviour under attack: SQS holds the message,
  # the consumer retries, and the delivery is claimed a moment later.
  read_capacity  = 2
  write_capacity = 2

  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Expiry is the whole storage plan, and it is also what bounds Redis's replacement to one
  # rolling day of ids rather than a table that grows for ever and eventually leaves the 25 GB
  # allowance. TTL deletes are free — they do not consume write capacity. The window mirrors
  # `caldrith.worker.queue.DEDUP_TTL_SECONDS` (24 hours), which is comfortably longer than
  # GitHub's redelivery retry window; the two are a pair.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    # Off deliberately. Every row is a delivery id with a 24-hour TTL; there is no state here
    # worth restoring, and PITR is charged per GB. Losing this table entirely costs one day of
    # deduplication — some webhooks reconciled twice, which converges to the same place because
    # reconcile is idempotent. That is the cheapest disaster in the stack.
    enabled = false
  }
}

# GitHub allows webhook payloads up to 25 MB and SQS caps a message at 256 KB. Without
# somewhere to put the overflow, an oversized delivery is answered 502 and dropped.
#
# WHY THAT MATTERS FOR CALDRITH SPECIFICALLY, BECAUSE THE OBVIOUS ARGUMENT FOR DELETING THIS
# BUCKET IS WRONG. "Caldrith converges, so a dropped webhook is repaired by the next one" is
# true for drift events and false for the one that overflows. The payload that exceeds 256 KB
# is a `push` with large file lists, and `webhooks._push_touches_settings` reads exactly those
# lists to decide whether the admin settings file moved — which is what triggers the
# `update_admin_prs` sweep. Dropping big pushes is therefore not random loss that heals; it is
# a DETERMINISTIC blind spot that grows with the size of the repository, and the sweep would
# simply never run for the fleets most likely to need it.
#
# ON COST, HONESTLY, AND WITHOUT THE DATE THIS USED TO CARRY: besides the API, this is the one
# resource in the stack that is not always-free. An earlier version of this comment said S3's
# 5 GB allowance was the 12-MONTH kind and that the bucket therefore started billing on
# 2026-09-18. That was the pre-2025-07-15 free tier; the payer signed up 2025-09-18, two months
# after AWS replaced it with the Free-plan/Paid-plan credits model, so this organisation never
# had a 12-month S3 allowance and this bucket bills from the first PUT. The fuller note, and the
# two things still to confirm in the payer account's Billing -> Free Tier page, are in api.tf.
# At the expected rate (overflow is rare by construction, one
# day of retention) that is a fraction of a cent a month, dominated by PUT requests rather than
# storage. The producer should log a byte count on every use, so within a week the real rate is
# a fact rather than an estimate — and if it is zero, delete this bucket and accept the 502.
# trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "overflow" {
  #checkov:skip=CKV2_AWS_62:S3 event notifications not needed for this overflow bucket
  #checkov:skip=CKV_AWS_144:No cross-region replication — home lab single-region setup
  #checkov:skip=CKV_AWS_21:Versioning disabled deliberately — a versioned object would outlive the lifecycle expiration rule
  #checkov:skip=CKV_AWS_18:S3 access logging not enabled — cost and complexity not justified for a transient overflow bucket
  #checkov:skip=CKV_AWS_145:Using SSE-S3 (AES256); KMS CMK not required here
  bucket        = "${var.name_prefix}-overflow-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # nothing here outlives its lifecycle rule; never block a teardown
}

resource "aws_s3_bucket_public_access_block" "overflow" {
  bucket                  = aws_s3_bucket.overflow.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# checkov:skip=CKV_AWS_145:Using SSE-S3 (AES256); KMS CMK not required here
# tfsec:ignore:AWS-0132
# trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "overflow" {
  bucket = aws_s3_bucket.overflow.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# checkov:skip=CKV_AWS_21:Versioning disabled deliberately — versioned objects would outlive the lifecycle rule
# tfsec:ignore:AWS-0090
# trivy:ignore:AVD-AWS-0090
resource "aws_s3_bucket_versioning" "overflow" {
  bucket = aws_s3_bucket.overflow.id
  versioning_configuration {
    # Off deliberately. A version that outlives its object would outlive the expiration rule
    # below, which is the only thing keeping this bucket's cost rounding to zero.
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "overflow" {
  #checkov:skip=CKV_AWS_300:abort_incomplete_multipart_upload is configured inline within the rule block; scanner expects a top-level attribute that does not exist in this provider version
  bucket = aws_s3_bucket.overflow.id

  rule {
    id     = "expire-overflow"
    status = "Enabled"

    filter {
      prefix = "overflow/"
    }

    # One day. The consumer reads the body within milliseconds of the delivery in normal
    # operation; the only thing that stretches that is the events queue backing up, which the
    # stale-jobs alarm would have reported hours earlier. A body still unread after 24 hours
    # belongs to a delivery that is not going to be processed.
    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_caller_identity" "current" {}
