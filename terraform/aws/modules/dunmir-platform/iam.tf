# The function's execution role.
#
# Everything here is written out rather than reached for as an AWS managed policy, with one
# exception noted below. `AWSLambdaBasicExecutionRole` grants `logs:*` on `*`; this role gets
# writes to its own log group and nothing else, which is the difference between "can write logs"
# and "can read every log in the account".

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = { Name = "${local.name}-lambda" }
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "WriteItsOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    # Scoped to this function's group. `CreateLogGroup` is absent on purpose: the group is
    # created by Terraform (lambda.tf) so that its retention is set BEFORE the first line is
    # written. A group Lambda creates for itself retains forever, and by the time anyone
    # notices, the fix does not reclaim what was already stored.
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid    = "ReadWriteBackupBodies"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }

  # Deliberately NOT granted: s3:ListBucket. The store addresses every object by a key it
  # already holds in the catalogue, so listing would only ever serve an attacker enumerating
  # what exists — and its absence turns a stolen credential into "read the objects you can
  # already name" rather than "inventory every tenant's backup history".

  # NO ssm:GetParameter, and no kms:Decrypt for it. The database DSN reaches the function as an
  # environment variable rather than a parameter, because reading a parameter means calling
  # `ssm.<region>.amazonaws.com` and this function has no route to the internet — SSM has no
  # gateway endpoint, so it would need an interface endpoint at ~$7.30/month. See the note on
  # `DATABASE_URL` in lambda.tf.
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# The ONE managed policy, and it earns the exception: attaching an ENI to a VPC subnet needs
# `ec2:CreateNetworkInterface` / `DescribeNetworkInterfaces` / `DeleteNetworkInterface` on `*`,
# because the ENI does not exist yet when the permission is evaluated and therefore cannot be
# named in a resource ARN. Writing it out by hand would produce the same three actions on the
# same `*` with more lines and one more thing to keep in step with AWS.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  count = local.networked ? 1 : 0

  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ── the scheduler's role ────────────────────────────────────────────────────────────────────
#
# EventBridge Scheduler assumes a role to invoke the target; it does not use the target's own
# role. Separate from the function's so that "may invoke this function" and "may read this
# bucket" cannot be confused for one another.

data "aws_iam_policy_document" "scheduler_assume" {
  count = local.creates_schedule ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    # Without this a confused-deputy exists: any other account able to name this role ARN in
    # their own schedule could invoke our function. The condition pins the caller to this
    # account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = local.creates_schedule ? 1 : 0

  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json

  tags = { Name = "${local.name}-scheduler" }
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.creates_schedule ? 1 : 0

  name = "${local.name}-scheduler"
  role = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.api.arn, "${aws_lambda_function.api.arn}:*"]
    }]
  })
}
