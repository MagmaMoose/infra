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

# CORS, WITHOUT WHICH THE PRESIGNED DOWNLOAD CANNOT WORK AT ALL.
#
# A presigned URL authorises the REQUEST; it says nothing about whether a browser is allowed to
# READ the response. `console.dunmir` and the bucket are different origins, so the fetch in
# `frontend/src/lib/api.ts:saveFromUrl` is a cross-origin request, and with no CORS
# configuration S3 returns the object with no `Access-Control-Allow-Origin` header — the browser
# then discards a perfectly good 200 and the promise rejects with an opaque TypeError that names
# neither CORS nor S3. Signing correctly and being unreadable look identical from the console.
#
# This was missed the first time because the LocalStack smoke test proves the round trip with a
# PYTHON http client, which enforces neither CORS nor CSP. Nothing in an end-to-end suite that
# does not drive a real browser can catch it.
#
# SCOPED TO THE CONSOLE ORIGIN, not `*`. The URL is a bearer credential for one object, so a
# wildcard would let any page the operator happens to have open read a backup body if it ever
# obtained a URL. GET and HEAD only: nothing about a download writes.
resource "aws_s3_bucket_cors_configuration" "backups" {
  count = var.frontend_origin != "" ? 1 : 0

  bucket = aws_s3_bucket.backups.id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = [var.frontend_origin]

    # `Content-Disposition` so the browser honours the filename the signature carries, and the
    # two range headers so a large backup can resume rather than restart.
    allowed_headers = ["range", "if-match", "content-disposition"]
    expose_headers  = ["Content-Length", "Content-Type", "Content-Disposition", "ETag"]

    # An hour. The policy changes about never, and each preflight is a round trip before a
    # download that the operator is already waiting on.
    max_age_seconds = 3600
  }
}

locals {
  # Whether the console will be handed presigned URLs. Kept as a local rather than a variable
  # because it is not independently choosable: it requires the bucket CORS rule above and the
  # bucket origin in the console's CSP, and all three are decided together. See the
  # PRESIGNED_DOWNLOADS note in lambda.tf for why this is opt-in rather than inferred.
  presigned_downloads = true

  # The origin the BROWSER fetches a presigned object from — which is not always the one the
  # function signs against (the emulator serves both, at different addresses). This is the value
  # that has to appear in the console's `connect-src` and in the bucket's CORS rule.
  #
  # An ORIGIN, not a URL: `connect-src` and a CORS `allowed_origins` both match scheme + host +
  # port and reject anything carrying a path. The override is documented as an endpoint, so the
  # path is trimmed off rather than assumed absent.
  s3_public_origin = (
    var.s3_public_endpoint_override != ""
    ? try(regex("^https?://[^/]+", var.s3_public_endpoint_override), var.s3_public_endpoint_override)
    : "https://${aws_s3_bucket.backups.bucket}.s3.${var.region}.amazonaws.com"
  )
}
