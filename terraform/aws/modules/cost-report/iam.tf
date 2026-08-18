# kics-scan disable=CKV_AWS_355
# The function's role, and why every action on it is a read.
#
# THIS ROLE CANNOT SPEND MONEY, only observe it. That is the whole security argument for
# running a scheduled job in the management account — the account that can do the most damage
# in the organisation — and it is worth stating rather than assuming. There is no
# `organizations:*` write, no `ce:Create*`, no `iam:*`; the widest thing here is the ability
# to read a cost figure and publish one string to one topic.

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "report" {
  name = var.name_prefix

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Organizations and Free Tier do not support resource-level permissions on these read actions —
# the API is account-scoped and there is no ARN to name — so "*" is not laziness here, it is
# the only form the actions accept. S3 access is scoped to the export bucket by ARN.
# checkov:skip=CKV_AWS_355:organizations/freetier read actions do not support resource-level restrictions
resource "aws_iam_role_policy" "report" {
  name = var.name_prefix
  role = aws_iam_role.report.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The cost data itself, as a file. No ce:* anywhere in this policy — the Cost
        # Explorer API bills $0.01 a request and this stack deliberately does not use it.
        Sid      = "ReadTheExport"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.cur.arn}/*"
      },
      {
        Sid      = "ListTheExport"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.cur.arn
      },
      {
        # Free-tier allowances and forecasts. Free to call, and org-wide by nature — it is
        # the authority on the limits the CUR file is then attributed against.
        Sid      = "ReadFreeTierUsage"
        Effect   = "Allow"
        Action   = ["freetier:GetFreeTierUsage"]
        Resource = "*"
      },
      {
        # Turns 12-digit account ids into names. Read-only, and the report degrades to bare
        # ids rather than failing if it is ever removed.
        Sid      = "NameTheAccounts"
        Effect   = "Allow"
        Action   = ["organizations:ListAccounts"]
        Resource = "*"
      },
      {
        Sid      = "PublishTheReport"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.cost.arn
      },
    ]
  })
}

# Scoped to this function's own log group rather than the managed AWSLambdaBasicExecutionRole,
# which grants CreateLogGroup across the account.
resource "aws_iam_role_policy" "logs" {
  name = "${var.name_prefix}-logs"
  role = aws_iam_role.report.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.report.arn}:*"
    }]
  })
}
