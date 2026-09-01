# The dead-man sweep, triggered from OUTSIDE the cluster it watches.
#
# WHY THIS EXISTS SEPARATELY FROM schedule.tf. That schedule invokes this account's
# own Lambda with `{"task": "sweep"}`, which is right when the application runs
# here. It does not, yet: production is the Kubernetes topology on the OCI cluster,
# and its sweep is a CronJob *inside that cluster*, reaching
# `http://dunmir-backend:8000/internal/sweep`.
#
# That CronJob is the only thing that notices a router has stopped reporting, and
# it is in the same failure domain as the thing it monitors. When the cluster is
# unwell the sweep does not run, nothing is marked down, no alert fires, and every
# operator's console shows a healthy fleet. Quiet is indistinguishable from
# healthy — the same defect `nievah-frontdoor/notify.tf` records having found in
# Nievah, where every instrument lived inside the failure domain it watched.
#
# So the TRIGGER moves out. The sweep's logic stays where the data is; only the
# thing that decides "it is time" leaves, and it lives somewhere that keeps
# working when Amsterdam does not. A firing that cannot reach the cluster fails
# LOUDLY as a Lambda error rather than silently as a CronJob that never ran.
#
# WHY A FUNCTION AND NOT AN EVENTBRIDGE API DESTINATION. API Destinations are
# purpose-built for "call this HTTPS endpoint on a schedule" and would need no code
# at all. They also store their authorisation in a Secrets Manager secret that the
# Connection creates for you, and that secret is billed per month. The whole premise
# of this account is that it costs nothing, so the token lives in an SSM standard
# parameter (free) and twenty lines of stdlib read it. That is the only reason.

locals {
  # The HTTP sweep is opt-in and independent of `sweep_enabled`, which arms the
  # in-account schedule in schedule.tf. Exactly one of them should ever be on:
  # two sweeps racing is harmless (it is idempotent) but doubles the writes and
  # makes "did the sweep run" ambiguous.
  creates_http_sweep = var.sweep_target_url != "" && !var.localstack
}

# ── the token the sweep authenticates with ──────────────────────────────────────────────────
#
# NOT MANAGED HERE. Terraform declares the parameter's existence and its name; the value is put
# in by hand (or by whatever manages the cluster's secret) and `ignore_changes` keeps a plan
# from showing it as drift for ever. Writing the real ADMIN_TOKEN into Terraform state would
# put a credential that authenticates `/internal/sweep` and every `/v1/admin/*` route into a
# state file, which is the one place it must not be.
resource "aws_ssm_parameter" "sweep_admin_token" {
  count = local.creates_http_sweep ? 1 : 0

  name        = "/${local.name}/sweep/admin-token"
  description = "Bearer token for POST /internal/sweep on the Kubernetes backend"
  type        = "SecureString"
  value       = "PLACEHOLDER-set-me-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

data "archive_file" "sweep_poker" {
  count = local.creates_http_sweep ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/.build/sweep-poker.zip"

  source {
    filename = "handler.py"
    content  = <<-PY
      """POST /internal/sweep, and fail loudly if it does not answer.

      NOTHING IS SHIPPED WITH THIS. urllib and json are stdlib; boto3 is provided
      by the managed runtime. So the zip is one file, and there is no lock file,
      no build step and no release pipeline between a change here and the sweep
      firing — each of which would be another way for it to stop.
      """

      import json
      import os
      import urllib.error
      import urllib.request

      import boto3

      _TOKEN = None


      def _token():
          """Read the bearer once per execution environment, not once per firing.

          SSM has a request quota and this runs every sixty seconds for ever. The
          value only changes when somebody rotates it, and a rotation is followed
          by a deploy that replaces the environment anyway.
          """
          global _TOKEN
          if _TOKEN is None:
              ssm = boto3.client("ssm")
              _TOKEN = ssm.get_parameter(
                  Name=os.environ["ADMIN_TOKEN_PARAMETER"], WithDecryption=True
              )["Parameter"]["Value"]
          return _TOKEN


      def handler(event, context):
          url = os.environ["SWEEP_URL"]
          request = urllib.request.Request(
              url,
              method="POST",
              data=b"",
              headers={
                  "Authorization": "Bearer " + _token(),
                  "Content-Type": "application/json",
                  "User-Agent": "dunmir-sweep-poker",
              },
          )
          try:
              with urllib.request.urlopen(request, timeout=20) as response:
                  body = response.read(4096).decode("utf-8", "replace")
                  print(json.dumps({"status": response.status, "body": body[:500]}))
                  return {"ok": True, "status": response.status}
          except urllib.error.HTTPError as err:
              # RAISE, do not return. A non-2xx means the cluster answered and
              # refused — a wrong token, or the route gone — and the whole point of
              # moving this out of the cluster is that such a firing shows up as a
              # Lambda error metric rather than as silence.
              body = err.read(4096).decode("utf-8", "replace")
              raise RuntimeError(f"sweep returned {err.code}: {body[:500]}") from err
          except urllib.error.URLError as err:
              # The cluster is unreachable. This is the case a CronJob inside it
              # cannot report, because it is not running either.
              raise RuntimeError(f"sweep unreachable at {url}: {err.reason}") from err
    PY
  }
}

# Created explicitly rather than left to Lambda: a log group Lambda makes for itself never
# expires, and CloudWatch's free allowance is 5 GB stored. The same note is on the functions in
# `nievah-frontdoor/lambda.tf`, for the same reason.
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "sweep_poker" {
  # checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — AES256 default is sufficient here
  # checkov:skip=CKV_AWS_338:Retention is set explicitly below; the 1-year rule does not apply
  count = local.creates_http_sweep ? 1 : 0

  name              = "/aws/lambda/${local.name}-sweep-poker"
  retention_in_days = var.log_retention_days
}

# trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "sweep_poker" { # nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
  # checkov:skip=CKV_AWS_173:No KMS CMK for env vars — the token is in SSM, not in the environment
  # checkov:skip=CKV_AWS_116:No DLQ — a failed sweep is retried in 60s by the next firing
  # checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  # checkov:skip=CKV_AWS_115:No reserved concurrency — one invocation a minute
  # checkov:skip=CKV_AWS_117:NOT VPC-bound, deliberately — it has to reach the public internet
  # checkov:skip=CKV_AWS_50:X-Ray not enabled — cost not justified for one HTTP call
  count = local.creates_http_sweep ? 1 : 0

  function_name = "${local.name}-sweep-poker"
  description   = "Fires POST /internal/sweep at the Kubernetes backend, from outside it"
  role          = aws_iam_role.sweep_poker[0].arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["x86_64"]
  timeout       = 25
  memory_size   = 128

  filename         = data.archive_file.sweep_poker[0].output_path
  source_code_hash = data.archive_file.sweep_poker[0].output_base64sha256

  # NO VPC CONFIGURATION, and that is the point: the target is on the public
  # internet behind Cloudflare. A Lambda outside a VPC has egress for free; one
  # inside a VPC needs a NAT gateway at roughly $33/month to reach the same URL.
  # It holds no data and reads one parameter, so there is nothing here for a VPC
  # to protect.

  environment {
    variables = {
      SWEEP_URL             = var.sweep_target_url
      ADMIN_TOKEN_PARAMETER = aws_ssm_parameter.sweep_admin_token[0].name
    }
  }

  depends_on = [aws_cloudwatch_log_group.sweep_poker]
}

resource "aws_iam_role" "sweep_poker" {
  count = local.creates_http_sweep ? 1 : 0

  name = "${local.name}-sweep-poker"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sweep_poker" {
  count = local.creates_http_sweep ? 1 : 0

  name = "sweep-poker"
  role = aws_iam_role.sweep_poker[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.sweep_poker[0].arn}:*"
      },
      {
        # ONE PARAMETER, by name. `ssm:GetParameter` on `*` would let this
        # function read every secret the account keeps in Parameter Store, to do
        # a job that needs exactly one.
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.sweep_admin_token[0].arn
      },
    ]
  })
}

resource "aws_scheduler_schedule" "sweep_http" {
  count = local.creates_http_sweep ? 1 : 0

  name        = "${local.name}-sweep-http"
  description = "Dun Mir dead-man sweep, fired at the Kubernetes backend"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  state                        = var.sweep_enabled ? "ENABLED" : "DISABLED"
  schedule_expression          = var.sweep_schedule_expression
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.sweep_poker[0].arn
    role_arn = aws_iam_role.sweep_scheduler_http[0].arn

    retry_policy {
      # One retry, then let the next firing handle it. The sweep is idempotent and
      # runs again in sixty seconds, so a retry ladder only stacks concurrent
      # sweeps on top of whatever made the first one fail.
      maximum_retry_attempts       = 1
      maximum_event_age_in_seconds = 60
    }
  }
}

resource "aws_iam_role" "sweep_scheduler_http" {
  count = local.creates_http_sweep ? 1 : 0

  name = "${local.name}-sweep-scheduler-http"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        # Without this any EventBridge schedule in any account could assume this
        # role — the documented confused-deputy guard for Scheduler.
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "sweep_scheduler_http" {
  count = local.creates_http_sweep ? 1 : 0

  name = "invoke-sweep-poker"
  role = aws_iam_role.sweep_scheduler_http[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.sweep_poker[0].arn
    }]
  })
}
