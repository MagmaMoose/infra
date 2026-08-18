# Where nievah publishes the Lambda zip, and the identity it publishes with.
#
# THIS LEAF MUST BE APPLIED BEFORE `nievah-frontdoor`, and there is a real chicken-and-egg on
# the very first run: the front door points at `edge/<version>.zip`, which does not exist
# until nievah publishes, and nievah cannot publish until this exists. Order for a cold start:
#
#   1. apply THIS leaf
#   2. run nievah's `publish-edge` workflow once (or `aws s3 cp` a zip by hand)
#   3. apply `nievah-frontdoor` with `edge_artifact_version` set to what step 2 produced
#
# After that the two are independent and a deploy is a one-line bump in the front-door leaf.
#
# NO LONG-LIVED CREDENTIAL IS CREATED HERE. Nievah's workflow assumes the role below through
# GitHub's OIDC provider, so the publish identity is a short-lived STS session bound to one
# repository — nothing to rotate, nothing to leak from a secret store.

data "aws_caller_identity" "current" {}

# checkov:skip=CKV2_AWS_62:S3 event notifications not needed for this artifact bucket
# checkov:skip=CKV_AWS_144:No cross-region replication — home lab single-region setup
# checkov:skip=CKV_AWS_18:S3 access logging not enabled — cost not justified for a low-traffic artifact store
# checkov:skip=CKV_AWS_145:Using SSE-S3 (AES256); KMS CMK not required here
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.name_prefix}-artifacts-${data.aws_caller_identity.current.account_id}"

  # Deliberately NOT force_destroy, unlike the overflow bucket in nievah-frontdoor. That one
  # holds a rolling day of replayable webhook bodies and must never block a teardown; this one
  # holds every deployable artifact, and a `destroy` that silently emptied it would take the
  # rollback targets with it. The two buckets are separate for exactly this reason.
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# checkov:skip=CKV_AWS_145:Using SSE-S3 (AES256); KMS CMK not required here
# tfsec:ignore:AWS-0132
# trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ON. The keys are version-scoped and treated as immutable, so versioning should never
# actually branch — which is the point: if an object ever IS overwritten, versioning is what
# lets you prove it and recover the original. A 30 KB zip makes the storage argument moot.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# No expiration on current versions — a rollback target that expired is not a rollback target.
# At ~30 KB an artifact, a decade of releases is single-digit megabytes. Only superseded
# versions (which should not exist; see above) are aged out.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- the publish identity --------------------------------------------------------------

# ACCOUNT-WIDE AND SHARED. AWS permits exactly one OIDC provider per issuer URL per account,
# so a second `aws_iam_openid_connect_provider` for token.actions.githubusercontent.com would
# fail with EntityAlreadyExists. `create_github_oidc_provider = false` lets a later stack
# reuse the one this created rather than fighting it.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints
}

locals {
  oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
}

data "aws_iam_policy_document" "publish_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # THE LOAD-BEARING CONDITION. Without a `sub` claim check, ANY GitHub Actions workflow in
    # ANY repository on github.com could assume this role — the OIDC provider trusts GitHub,
    # not your GitHub. This binds it to one repo, and to its default branch plus its tags, so
    # a pull request from a fork cannot publish an artifact the front door would then run.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.publisher_repo}:ref:refs/heads/main",
        "repo:${var.publisher_repo}:ref:refs/tags/*",
      ]
    }
  }
}

resource "aws_iam_role" "publish" {
  name               = "${var.name_prefix}-artifact-publisher"
  assume_role_policy = data.aws_iam_policy_document.publish_assume.json

  # A publish is seconds. A short session bounds what a leaked token from a compromised
  # workflow run is worth.
  max_session_duration = 3600
}

data "aws_iam_policy_document" "publish" {
  # Write-only into one prefix. The publisher cannot read what is already there, cannot
  # delete, and cannot list the bucket — so a compromised workflow can add an artifact
  # (which still has to be pointed at by a reviewed Terraform change before it runs
  # anywhere) but cannot quietly replace or remove a known-good one.
  statement {
    sid       = "PublishArtifact"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/edge/*"]
  }

  # HeadObject, so the workflow can compare the new zip's digest against what is already
  # published and skip both the upload and the bump PR when nothing changed. Without this the
  # front-door leaf would get a version-bump PR on every nievah release, most of which would
  # redeploy byte-identical code.
  statement {
    sid       = "CompareBeforePublishing"
    actions   = ["s3:GetObjectAttributes"]
    resources = ["${aws_s3_bucket.artifacts.arn}/edge/*"]
  }
}

resource "aws_iam_role_policy" "publish" {
  name   = "${var.name_prefix}-artifact-publisher"
  role   = aws_iam_role.publish.id
  policy = data.aws_iam_policy_document.publish.json
}
