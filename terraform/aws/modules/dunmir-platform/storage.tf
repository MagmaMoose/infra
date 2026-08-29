# The bucket holding encrypted device-backup bodies.
#
# The application already speaks S3 — `app/storage.py` signs SigV4 by hand against any
# S3-compatible endpoint and rebinds the control-plane core's three store functions at boot when
# `STORAGE_BACKEND=s3`. So nothing here is new capability; it is the bucket that leg points at,
# reached from the VPC through the free gateway endpoint in network.tf.
#
# WHAT IS IN IT. Ciphertext produced on the RouterOS device itself, keyed by tenant. The
# backend never holds the plaintext and never holds the key, which is why a bucket policy that
# merely blocks the public is a sufficient control here rather than a nervous one.

resource "aws_s3_bucket" "backups" {
  bucket = "${local.name}-backups"

  # No `force_destroy`. `terraform destroy` should fail on a bucket that still has objects in
  # it, because those objects are every tenant's backup history and the correct response to
  # "Terraform cannot delete this" is to stop and think.
  tags = { Name = "${local.name}-backups" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id

  # ACLs disabled entirely. Nothing writes here but the function, using its role, so the only
  # thing an ACL could do is grant access nobody asked for.
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3, not SSE-KMS. The bodies are already encrypted on the device before they are
      # uploaded, so KMS would add a per-request charge and a second key to lose in exchange for
      # encrypting ciphertext twice.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Off, deliberately. Every object here is already an immutable point-in-time snapshot with its
  # own catalogue row, so versioning would store a second copy of data that is never overwritten
  # — and versioned objects are the classic way a bucket quietly outgrows its free allowance,
  # because a lifecycle rule that expires current versions leaves the non-current ones behind.
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count = var.backup_expiry_days > 0 ? 1 : 0

  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backup_expiry_days
    }

    # A multipart upload the function abandoned mid-flight leaves parts that are billed and
    # invisible in the console's object listing. The store does single-shot PUTs, so this should
    # never fire — which is exactly why it is cheap insurance rather than a workaround.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
