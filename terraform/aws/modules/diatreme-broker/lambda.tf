# The function, and where its code comes from.
#
# THE ZIP IS BUILT AND PUBLISHED BY CHARGATE, NOT BY TERRAFORM. `broker/scripts/build_lambda_zip.py`
# in MagmaMoose/diatreme packages `app/` (minus `main.py`) plus the resolved pyjwt[crypto] and
# httpx wheels into ~5.3 MB, and the release workflow uploads it. This module points at that
# object by key.
#
# `s3_key` is version-scoped and its objects are immutable, so a key change IS the deployment
# signal and no `source_code_hash` is needed. Bumping `broker_artifact_version` is the whole
# deploy: one line, one plan, one apply.
#
# WHY NOT `data "archive_file"`: Terraform cannot resolve a platform-targeted wheel set, and a
# Terraform run that rewrites the code it deploys deploys something nobody reviewed.

locals {
  # Must match what diatreme's release workflow publishes to, and the prefix the publish role in
  # the `artifacts` leaf is scoped to. The leaf wires all three from one value.
  artifact_key = "${var.artifact_prefix}/${var.broker_artifact_version}.zip"
}

# Created explicitly rather than left to Lambda. A log group Lambda creates for itself has
# retention set to NEVER EXPIRE, and CloudWatch Logs' 5 GB allowance is pooled across the whole
# organization — so the default quietly converts a free stack into a billed one.
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "broker" {
  # checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
  # checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
  name              = "/aws/lambda/${var.name_prefix}-broker"
  retention_in_days = var.log_retention_days
}

# trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "broker" { # nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
  # checkov:skip=CKV_AWS_173:No KMS CMK for env vars — the secrets are in SSM, not here; these values are a path and a version string
  # checkov:skip=CKV_AWS_116:No DLQ — this is a synchronous request/response API, there is no async invocation to redrive
  # checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  # checkov:skip=CKV_AWS_115:Account-level concurrency cap is 10; any reservation fails (InvalidParameterValueException)
  # checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to SSM and api.github.com, no VPC resources
  # checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified at this scale
  function_name = "${var.name_prefix}-broker"
  role          = aws_iam_role.broker.arn
  handler       = "app.lambda_handler.handler"
  runtime       = "python3.12"

  # x86_64, NOT arm64 — and this is the one place this module deliberately diverges from the
  # nievah front door. The package carries compiled wheels (`cryptography`, `cffi`), and
  # diatreme's CI runs on `ubuntu-latest`/x86_64/py3.12. Matching that means
  # `tests/test_lambda_package.py::TestImportable` can unzip and actually EXECUTE the shipped
  # artifact on the pull request, rather than skipping. Catching a wrong-platform wheel in CI is
  # worth far more than arm64's ~20% discount on a bill that is already zero.
  architectures = ["x86_64"]

  s3_bucket = var.artifact_bucket
  s3_key    = local.artifact_key

  memory_size = var.memory_size
  timeout     = var.timeout

  # NO reserved_concurrent_executions, and not because it was overlooked. This account's TOTAL
  # Lambda concurrency quota is 10 — verified, and AWS *publishes* the default as 1000, so
  # `get-aws-default-service-quota` disagrees with `get-service-quota` here. AWS refuses any
  # reservation that would leave fewer than 10 unreserved, so any value at all fails with
  # InvalidParameterValueException.
  #
  # The quota is a harder cap than a reservation would have been: at most ten invocations run
  # concurrently across the entire account, whatever asks. If it is ever raised, add a
  # reservation here — the protection is currently coming from a default that a support ticket
  # could silently remove.

  environment {
    variables = {
      # The two secrets are NOT here. Anything holding lambda:GetFunctionConfiguration could
      # read an environment variable, and it would be visible in the console; they come from
      # SSM at request time instead. This is only where to look for them.
      SECRET_PATH = local.secret_path

      # Defaults to name_prefix, which is the value this was hardcoded to. See the variable.
      OIDC_AUDIENCE = var.oidc_audience != "" ? var.oidc_audience : var.name_prefix
      # Empty = the public-app model: any repository the Diatreme App is installed on may mint.
      # The App installation is the access control, not this list.
      ALLOWED_REPOSITORIES = ""
      GITHUB_API_URL       = "https://api.github.com"

      # Diatreme mints RELEASE tokens, so it needs `contents: write` to push tags and
      # commits — chargate only ever comments, hence its narrower set. Widening this
      # widens every consumer's token, so it is deliberately spelled out here rather
      # than defaulted in code.
      TOKEN_PERMISSIONS_JSON = jsonencode({ contents = "write", pull_requests = "write" })

      # Last-known-good JWKS snapshots (MagmaMoose/diatreme#150). Unset disables the
      # rescue path entirely and the broker behaves as it did before it existed.
      JWKS_TABLE_NAME = aws_dynamodb_table.jwks_cache.name

      BUILD_REF = var.broker_artifact_version
    }
  }

  depends_on = [aws_cloudwatch_log_group.broker]
}
