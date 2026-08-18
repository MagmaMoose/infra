# kics-scan disable=CKV_AWS_28,CKV_AWS_119,CKV2_AWS_16,CKV2_AWS_62,CKV_AWS_144,CKV_AWS_21,CKV_AWS_18,CKV_AWS_145,CKV_AWS_300
# Delivery dedup, and the overflow bucket for bodies too large to ride in a message.

# PROVISIONED, NOT ON-DEMAND, and that is a free-tier decision rather than a capacity one.
# DynamoDB's always-free allowance is 25 GB of storage plus 25 write and 25 read capacity
# units — PROVISIONED units. On-demand request pricing has no always-free component, so the
# same workload that costs nothing here would be billed per request there. At 2 units this is
# a twelfth of the free allowance and roughly 120 times this fleet's peak write rate.
# checkov:skip=CKV_AWS_28:PITR off deliberately — every row is a 24h-TTL delivery id, nothing worth restoring
# checkov:skip=CKV_AWS_119:No KMS CMK for DynamoDB — home lab; AWS managed key is sufficient
# checkov:skip=CKV2_AWS_16:DynamoDB auto-scaling disabled deliberately — provisioned 2/2 to stay in always-free tier
# nosemgrep: terraform.aws.security.aws-dynamodb-table-unencrypted.aws-dynamodb-table-unencrypted
resource "aws_dynamodb_table" "dedup" {
  name         = "${var.name_prefix}-dedup"
  billing_mode = "PROVISIONED"

  read_capacity  = 2
  write_capacity = 2

  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Expiry is the whole storage plan. Without it the table grows forever at ~950 rows a day
  # and eventually leaves the 25 GB free allowance; with it the table is a rolling day and
  # never exceeds a few megabytes. TTL deletes are free — they do not consume write capacity.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    # Off deliberately. Every row is a delivery id with a 24-hour TTL; there is no state here
    # worth restoring, and PITR is charged per GB.
    enabled = false
  }
}

# GitHub allows webhook payloads up to 25 MB and SQS caps a message at 256 KB. Without
# somewhere to put the overflow a large `push` would be answered 502 and left for a human to
# redeliver by hand — a visible failure, but a failure, and one that becomes routine rather
# than rare once the queue is the only path.
#
# ON COST, HONESTLY: this is the one resource in the stack that is not literally free. S3's
# 5 GB allowance is 12-month, not always-free. With a one-day lifecycle and an overflow that
# is rare by construction, the steady-state bill is a fraction of a cent a month — and the
# producer logs `producer.overflow` with a byte count every time, so after a week the real
# rate is a fact rather than an estimate. If it turns out to be zero, delete this bucket and
# the producer degrades to the 502 it already handles.
# checkov:skip=CKV2_AWS_62:S3 event notifications not needed for this overflow bucket
# checkov:skip=CKV_AWS_144:No cross-region replication — home lab single-region setup
# checkov:skip=CKV_AWS_21:Versioning disabled deliberately — a versioned object would outlive the lifecycle expiration rule
# checkov:skip=CKV_AWS_18:S3 access logging not enabled — cost and complexity not justified for a transient overflow bucket
# checkov:skip=CKV_AWS_145:Using SSE-S3 (AES256); KMS CMK not required here
resource "aws_s3_bucket" "overflow" {
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
    # below, which is the only thing keeping this bucket free.
    status = "Disabled"
  }
}

# checkov:skip=CKV_AWS_300:abort_incomplete_multipart_upload is configured inline within the rule block; scanner expects a top-level attribute that does not exist in this provider version
resource "aws_s3_bucket_lifecycle_configuration" "overflow" {
  bucket = aws_s3_bucket.overflow.id

  rule {
    id     = "expire-overflow"
    status = "Enabled"

    filter {
      prefix = "overflow/"
    }

    # One day. The cluster reads the body within seconds of the delivery in normal operation,
    # and a delivery still unread after 24 hours has been redelivered by GitHub or repaired
    # by reconcile_tick. This is what makes the storage cost round to zero.
    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_caller_identity" "current" {}
