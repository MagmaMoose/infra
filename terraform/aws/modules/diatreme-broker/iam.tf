# The function's identity, and the two grants that `GET /healthz` will never tell you are wrong.

data "aws_caller_identity" "current" {}

locals {
  # `/diatreme/prod`. The environment comes from the leaf via prod/environment.hcl, never from
  # terraform.workspace — Terragrunt runs every leaf in the "default" workspace, so using that
  # would collapse every environment onto one path.
  secret_path = "/${var.name_prefix}/${var.environment}"

  # TWO ARNs, AND THE FIRST IS NOT REDUNDANT. `GetParametersByPath` authorises against the PATH
  # ITSELF, not only against the parameters beneath it — granting `/diatreme/prod/*` alone
  # produces `not authorized to perform: ssm:GetParametersByPath on resource:
  # .../parameter/diatreme/prod`, naming a resource the policy looks like it already covers.
  #
  # The symptom is the nastiest one this service has: /token 503s `config_unavailable` on every
  # request while /healthz keeps returning 200, because health deliberately answers before
  # configuration is consulted. And because the client fails soft, nothing anywhere goes red.
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

resource "aws_iam_role" "broker" {
  name               = "${var.name_prefix}-broker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# checkov:skip=CKV_AWS_356:CloudWatch Logs CreateLogStream/PutLogEvents are scoped to this function's own log group; kms:Decrypt cannot be resource-scoped and is bounded by the ViaService condition instead
data "aws_iam_policy_document" "broker" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.broker.arn}:*"]
  }

  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
    resources = local.secret_arns
  }

  # The JWKS snapshot table. Scoped to the one table by ARN: this role has no business
  # reading or writing anything else, and a wildcard here would let a compromised broker
  # rummage through any future table in the account.
  #
  # No DeleteItem: entries expire via the table's TTL attribute, so nothing in the
  # application ever needs to remove one.
  statement {
    sid       = "JwksSnapshotCache"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.jwks_cache.arn]
  }

  # SecureString parameters are encrypted under the account's default SSM key; without this the
  # read above returns ciphertext and every mint fails closed — again with a green /healthz.
  #
  # `resources = ["*"]` because the AWS-managed `aws/ssm` key's ARN is not knowable here without
  # a data source that would itself need permissions. The ViaService condition is the real
  # bound: this role can only use KMS *through* SSM, in this region.
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

resource "aws_iam_role_policy" "broker" {
  name   = "${var.name_prefix}-broker"
  role   = aws_iam_role.broker.id
  policy = data.aws_iam_policy_document.broker.json
}
