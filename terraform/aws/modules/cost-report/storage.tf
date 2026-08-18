# kics-scan disable=CKV_AWS_18,CKV_AWS_21,CKV_AWS_144,CKV_AWS_145,CKV2_AWS_62,CKV2_AWS_61
# Where AWS writes the Cost and Usage export, and the three settings that keep it free.
#
# EVERYTHING BILLING LIVES IN us-east-1. The Data Exports API is single-region, and putting
# the bucket beside it removes a whole class of "which region is this in" mistake. The Lambda
# reads it cross-region from eu-west-1, which for a few KB a day is a data transfer charge of
# about seven ten-millionths of a dollar a month.
#
# THE COST CONTROLS ARE THE POINT, not boilerplate. This bucket is the only thing in the
# stack that can grow without bound, so:
#   1. the export is configured OVERWRITE_REPORT, so each delivery REPLACES the last rather
#      than adding to a pile;
#   2. versioning is deliberately OFF — with it on, "overwrite" silently means "keep both",
#      which turns the one safeguard above into unbounded growth;
#   3. a lifecycle rule expires objects anyway, so a future change to either of the above
#      cannot quietly start accumulating.
# Any one of those failing still leaves the other two.

# checkov:skip=CKV_AWS_18:No access logging — logging this bucket would cost more than the bucket
# checkov:skip=CKV_AWS_21:Versioning is off ON PURPOSE; see the note above
# checkov:skip=CKV_AWS_144:No cross-region replication — a regenerable daily export
# checkov:skip=CKV_AWS_145:AES256 rather than a KMS CMK; a CMK costs $1/month, more than everything else here combined
# checkov:skip=CKV2_AWS_62:No event notifications needed; the schedule drives the read
# checkov:skip=CKV2_AWS_61:Lifecycle rule IS configured below
# trivy:ignore:AVD-AWS-0089
# trivy:ignore:AVD-AWS-0090
# trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket" "cur" {
  provider = aws.us_east_1
  bucket   = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cur" {
  provider                = aws.us_east_1
  bucket                  = aws_s3_bucket.cur.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.cur.id

  rule {
    apply_server_side_encryption_by_default {
      # AES256, not a KMS CMK. A customer-managed key is $1/month standing charge — twenty
      # thousand times this organisation's monthly spend, and the data is a cost report.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cur" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.cur.id

  rule {
    id     = "expire-old-exports"
    status = "Enabled"

    filter {}

    # Long enough that the 1st-of-the-month read of the previous billing period always finds
    # its file, short enough that nothing accumulates. The report never looks back further
    # than the previous billing period.
    expiration {
      days = var.export_retention_days
    }

    # A failed multipart upload otherwise bills for its parts forever, invisibly — there is
    # no object to see in the console.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The service principals AWS delivers the export with. Both are required: `bcm-data-exports`
# creates and manages the export, `billingreports` is the principal that actually writes the
# object. Getting this wrong produces an export stuck in an unhealthy state with no object
# ever appearing, and nothing in CloudTrail pointing at the bucket policy as the cause.
data "aws_iam_policy_document" "cur_bucket" {
  statement {
    sid    = "AllowDataExportsToWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com", "billingreports.amazonaws.com"]
    }

    actions   = ["s3:PutObject", "s3:GetBucketPolicy"]
    resources = [aws_s3_bucket.cur.arn, "${aws_s3_bucket.cur.arn}/*"]

    # Confused-deputy guard: without SourceAccount, any AWS customer's export could in
    # principle be pointed at this bucket.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*",
        "arn:aws:bcm-data-exports:us-east-1:${data.aws_caller_identity.current.account_id}:export/*",
      ]
    }
  }

  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cur.arn, "${aws_s3_bucket.cur.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cur" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.cur.id
  policy   = data.aws_iam_policy_document.cur_bucket.json

  # Without this the policy can be written before public access is blocked, which S3 rejects.
  depends_on = [aws_s3_bucket_public_access_block.cur]
}
