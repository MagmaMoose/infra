# kics-scan disable=CKV_AWS_273,CKV_AWS_40
# Least privilege, resource-scoped throughout. No wildcards on resources, no managed policies
# beyond the two AWS publishes for Lambda logging, and — importantly — no role anywhere here
# can read the App private key, the PAT or the SSH signing key, because those are not in this
# account at all. The only secret AWS holds is the webhook secret set, which authenticates
# INBOUND traffic and can mint nothing.

locals {
  # NOT terraform.workspace: Terragrunt runs every leaf in the "default" workspace, so
  # that would collapse every environment onto one SSM path. The environment comes from
  # the leaf, via prod/environment.hcl.
  secret_path = "/${var.name_prefix}/${var.environment}"

  # TWO ARNs, and the first one is not redundant. `GetParametersByPath` authorises against the
  # PATH itself, not only against the parameters under it — granting `/nievah/prod/*` alone
  # produces `not authorized to perform: ssm:GetParametersByPath on resource:
  # .../parameter/nievah/prod`, naming a resource the policy looks like it covers. The
  # producer then 500s on every POST while `GET /healthz` keeps returning 200, because health
  # never reads a secret.
  secret_arns = [
    "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.secret_path}",
    "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.secret_path}/*",
  ]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- producer ---------------------------------------------------------------------------

resource "aws_iam_role" "producer" {
  name               = "${var.name_prefix}-producer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "producer" {
  statement {
    sid       = "SendToEvents"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]
  }

  # PutObject only. The producer writes an overflow body and never reads one back — the
  # cluster does that — so a compromised edge cannot exfiltrate the deliveries it parked.
  statement {
    sid       = "ParkOverflow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.overflow.arn}/overflow/*"]
  }

  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
    resources = local.secret_arns
  }

  # SecureString parameters are encrypted under the account's default SSM key; without this
  # the read above returns ciphertext and every signature check fails closed.
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "producer" {
  name   = "${var.name_prefix}-producer"
  role   = aws_iam_role.producer.id
  policy = data.aws_iam_policy_document.producer.json
}

resource "aws_iam_role_policy_attachment" "producer_logs" {
  role       = aws_iam_role.producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- consumer ---------------------------------------------------------------------------

resource "aws_iam_role" "consumer" {
  name               = "${var.name_prefix}-consumer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid = "DrainEvents"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.events.arn]
  }

  statement {
    sid       = "SendToJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # PutItem only — no GetItem, no Query, no Scan. The dedup claim is a conditional write and
  # never a read, so the narrower grant is also the complete one.
  statement {
    sid       = "ClaimDelivery"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.dedup.arn]
  }
}

resource "aws_iam_role_policy" "consumer" {
  name   = "${var.name_prefix}-consumer"
  role   = aws_iam_role.consumer.id
  policy = data.aws_iam_policy_document.consumer.json
}

resource "aws_iam_role_policy_attachment" "consumer_logs" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- the cluster ---------------------------------------------------------------------------
#
# AN IAM USER, WHICH IS NOT THE DEFAULT ANSWER AND IS THE RIGHT ONE HERE. Roles beat users
# everywhere they are reachable, but nievah-worker runs on Oracle Cloud and on a Raspberry Pi:
# there is no instance profile and no EKS OIDC provider to federate against. The two real
# options are a long-lived access key or IAM Roles Anywhere, and Roles Anywhere needs a
# certificate authority, a trust anchor and a rotation story for the client certificates —
# more moving parts than the thing it protects, for a principal that can do exactly this:
#
#   - read and delete from ONE queue
#   - read (never write) from the overflow prefix
#
# It cannot publish to a queue, invoke a function, read a secret, or see any other resource.
# A leaked key lets an attacker steal Nievah's inbound webhooks — which is bad, and is bounded
# by what a webhook already carries — and lets them do nothing else in the account.
# checkov:skip=CKV_AWS_273:No SSO configured in this account; IAM user is the intended credential path for the k8s worker
# checkov:skip=CKV_AWS_40:Policy attached directly to user by design — the cluster user has exactly one policy and no group makes sense here
# trivy:ignore:AVD-AWS-0143
resource "aws_iam_user" "cluster" {
  name = "${var.name_prefix}-cluster"
}

data "aws_iam_policy_document" "cluster" {
  statement {
    sid = "ConsumeJobs"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.jobs.arn]
  }

  statement {
    sid       = "ReadOverflow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.overflow.arn}/overflow/*"]
  }
}

resource "aws_iam_user_policy" "cluster" {
  name   = "${var.name_prefix}-cluster"
  user   = aws_iam_user.cluster.name
  policy = data.aws_iam_policy_document.cluster.json
}

# Terraform holds this secret in state, which is why the README insists the prod backend is
# an encrypted S3 bucket and not a laptop. The key goes into OCI Vault and reaches the worker
# through the existing ExternalSecret — same path as every other credential it holds.
resource "aws_iam_access_key" "cluster" {
  user = aws_iam_user.cluster.name
}
