# kics-scan disable=CKV_AWS_158,CKV_AWS_338,CKV_AWS_173,CKV_AWS_116,CKV_AWS_272,CKV_AWS_115,CKV_AWS_117,CKV_AWS_50,CKV_AWS_258
# The reporter.
#
# THE CODE IS IN THIS REPO, unlike the front door's, and the difference is deliberate rather
# than inconsistent. nievah's Lambda shares `verify_signature` with the cluster, so its source
# has to live beside the code it must not drift from, and it arrives here as a published
# artifact pinned by version. This function shares nothing with anything — it reads Cost
# Explorer and formats a string — so a published artifact would add a build, a bucket, a
# publish role and a version bump PR to deploy 200 lines that only this module ever runs.
#
# `archive_file` reads src/ at plan time and `source_code_hash` makes a source change a
# visible diff, so editing the handler and running apply IS the deployment.

data "archive_file" "report" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/.build/handler.zip"

  # Not cosmetic. Running the handler locally (which the README asks you to do before every
  # change here) leaves a __pycache__ beside it, and without this exclusion that bytecode
  # goes into the zip — so `source_code_hash` changes according to whether someone happened
  # to run Python in this directory, and Terraform reports a redeploy for a function whose
  # source is byte-identical. The .pyc itself is inert; the phantom diff is the damage.
  excludes = ["__pycache__", "**/__pycache__/**", "*.pyc"]
}

# Created explicitly rather than left to Lambda: a log group Lambda creates for itself has
# retention set to NEVER EXPIRE, and CloudWatch Logs' free allowance is 5 GB stored.
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "report" {
  # checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
  # checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

# nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
# trivy:ignore:AVD-AWS-0066
# trivy:ignore:AWS-0066
resource "aws_lambda_function" "report" {
  # checkov:skip=CKV_AWS_173:No KMS CMK for env vars — the only variable is a topic ARN, not a secret
  # checkov:skip=CKV_AWS_116:No DLQ — a missed daily report is re-sent by the next day's run; see the alarm in notify.tf
  # checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  # checkov:skip=CKV_AWS_115:No reserved concurrency — one invocation a day cannot starve anything
  # checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to AWS APIs only
  # checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified for one invocation a day
  function_name = var.name_prefix
  role          = aws_iam_role.report.arn
  handler       = "handler.handler"
  runtime       = "python3.13"

  # arm64 is ~20% cheaper per GB-second. Nothing here is architecture-sensitive: the package
  # is one pure-Python file and boto3 ships in the runtime for both.
  architectures = ["arm64"]

  filename         = data.archive_file.report.output_path
  source_code_hash = data.archive_file.report.output_base64sha256

  # Cost Explorer is not a fast API — two grouped calls against a month of data routinely take
  # several seconds each — and this runs once a day, so the timeout is set for the worst case
  # rather than the typical one. A truncated report is worse than a slow one.
  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      SNS_TOPIC_ARN     = aws_sns_topic.cost.arn
      CUR_BUCKET        = aws_s3_bucket.cur.id
      CUR_BUCKET_REGION = aws_s3_bucket.cur.region
      CUR_EXPORT_NAME   = var.name_prefix
      CUR_PREFIX        = var.export_prefix
    }
  }

  # Without this the function can race its own log group: Lambda creates one on first
  # invocation with no retention, and Terraform then owns a group it did not make.
  depends_on = [
    aws_cloudwatch_log_group.report,
    aws_iam_role_policy.logs,
  ]
}
