# kics-scan disable=CKV_AWS_158,CKV_AWS_338,CKV_AWS_173,CKV_AWS_116,CKV_AWS_272,CKV_AWS_115,CKV_AWS_117,CKV_AWS_50,CKV_AWS_258
# The two functions, and where their code comes from.
#
# THE ZIP IS BUILT AND PUBLISHED BY NIEVAH, NOT BY TERRAFORM. `scripts/build_edge_zip.py` in
# MagmaMoose/nievah packages seven files — `nievah/api/security.py`, `nievah/aws/*`, and the
# two docstring-only `__init__.py` files — into ~30 KB with no dependencies, and the release
# workflow uploads it to the artifact bucket. This module points at that object by key.
#
# WHY THAT MATTERS: the edge runs the SAME `verify_signature` file the cluster does. A
# Cloudflare Worker bundles only its own directory, so the design this replaces needed a hand
# copy of that module plus a test proving the copy had not drifted. A Lambda zip can carry the
# package, and both `__init__.py` files are docstrings with no imports — so there is nothing
# to drift. The file list lives in nievah beside the code it packages, which is the only place
# that can keep it honest.
#
# `s3_key` is version-scoped and its objects are immutable, so a key change IS the deployment
# signal and no `source_code_hash` is needed. Bumping `edge_artifact_version` is the whole
# deploy: one line, one Atlantis plan, one apply.

locals {
  # Must match the key `scripts/build_edge_zip.py` publishes to in MagmaMoose/nievah. The
  # artifacts module owns the bucket; nievah owns the layout inside it. Version-scoped and
  # treated as immutable, which is what lets a key change stand in for a source hash.
  artifact_key = "edge/${var.edge_artifact_version}.zip"
}

# Created explicitly rather than left to Lambda. A log group Lambda creates for itself has
# retention set to NEVER EXPIRE, and CloudWatch Logs' free allowance is 5 GB stored — so the
# default quietly converts a free stack into a billed one over a year or two.
# checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
# checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${var.name_prefix}-producer"
  retention_in_days = var.log_retention_days
}

# checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
# checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/${var.name_prefix}-consumer"
  retention_in_days = var.log_retention_days
}

# checkov:skip=CKV_AWS_173:No KMS CMK for env vars — home lab; secrets read from SSM, not env
# checkov:skip=CKV_AWS_116:DLQ handled at SQS layer (events_dlq); Lambda-level DLQ redundant
# checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
# checkov:skip=CKV_AWS_115:Account-level concurrency cap is 10; any reservation fails (InvalidParameterValueException)
# checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to AWS services only, no VPC resources
# checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified at this scale
# trivy:ignore:AVD-AWS-0066
# nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
resource "aws_lambda_function" "producer" {
  function_name = "${var.name_prefix}-producer"
  role          = aws_iam_role.producer.arn
  handler       = "nievah.aws.producer.handler"
  runtime       = "python3.13"

  # arm64 is ~20% cheaper per GB-second, which on a free-tier budget denominated in
  # GB-seconds means the same allowance stretches further. Nothing here is architecture
  # -sensitive: the package is pure Python and boto3 ships for both.
  architectures = ["arm64"]

  s3_bucket = var.artifact_bucket
  s3_key    = local.artifact_key

  # Generous for the work (one HMAC, one SQS send) and chosen for COLD START rather than
  # steady state: Lambda scales CPU with memory, so 512 MB imports the module roughly twice
  # as fast as 128 MB. At this invocation rate the whole function is ~400 GB-seconds a month
  # against a free 400,000.
  memory_size = 512

  # Deliberately well under GitHub's 10s and Slack's 3s. If an SQS send has not completed in
  # five seconds it is not going to, and failing fast returns a 502 that leaves the delivery
  # redeliverable rather than a timeout that tells the sender nothing.
  timeout = 5

  # NO reserved_concurrent_executions, and not because it was overlooked. This account's TOTAL
  # Lambda concurrency quota is 10 — the default for a new account — and AWS refuses any
  # reservation that would leave fewer than 10 unreserved, so any value at all fails with
  # InvalidParameterValueException.
  #
  # That quota is a harder cap than a reservation would have been: at most ten invocations run
  # concurrently across the entire account, whatever asks. If the quota is ever raised, add a
  # reservation here — the protection it provides is currently coming from a default that a
  # support ticket could silently remove.

  environment {
    variables = {
      EVENTS_QUEUE_URL = aws_sqs_queue.events.id
      OVERFLOW_BUCKET  = aws_s3_bucket.overflow.id
      SECRET_PATH      = local.secret_path
      BUILD_REF        = var.edge_artifact_version
    }
  }

  depends_on = [aws_cloudwatch_log_group.producer]
}

# checkov:skip=CKV_AWS_173:No KMS CMK for env vars — home lab; values here are queue URL and table name (not secrets)
# checkov:skip=CKV_AWS_116:DLQ handled at SQS layer (jobs_dlq); Lambda-level DLQ redundant
# checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
# checkov:skip=CKV_AWS_115:Account-level concurrency cap is 10; any reservation fails (InvalidParameterValueException)
# checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to AWS services only, no VPC resources
# checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified at this scale
# trivy:ignore:AVD-AWS-0066
# nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
resource "aws_lambda_function" "consumer" {
  function_name = "${var.name_prefix}-consumer"
  role          = aws_iam_role.consumer.arn
  handler       = "nievah.aws.consumer.handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  s3_bucket = var.artifact_bucket
  s3_key    = local.artifact_key

  # Nothing is waiting on this one, so it is sized for cost rather than latency.
  memory_size = 256
  timeout     = 30

  environment {
    variables = {
      JOBS_QUEUE_URL = aws_sqs_queue.jobs.id
      DEDUP_TABLE    = aws_dynamodb_table.dedup.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.consumer]
}

# LOCALSTACK ONLY. In production the front door is an API Gateway HTTP API (see api.tf); a
# Function URL exists here purely because API Gateway is a paid LocalStack feature and the
# local harness would otherwise have no way in at all.
#
# That substitution is honest rather than lossy: HTTP API payload format 2.0 is byte-for-byte
# the event shape a Function URL delivers, so the handler, the routing, the signature checks
# and everything downstream are the identical code path. What a local run does NOT cover is
# API Gateway's own configuration — the throttle, the $default stage, the integration — which
# is the same class of gap CloudFront had, now smaller and written down.
# checkov:skip=CKV_AWS_258:NONE auth is intentional — LocalStack only (count = var.localstack ? 1 : 0); production uses API Gateway
resource "aws_lambda_function_url" "producer" {
  count = var.localstack ? 1 : 0

  function_name      = aws_lambda_function.producer.function_name
  authorization_type = "NONE"
}

# Push, not poll: the event source mapping is Lambda's own poller, and it costs nothing.
resource "aws_lambda_event_source_mapping" "events" {
  event_source_arn = aws_sqs_queue.events.arn
  function_name    = aws_lambda_function.consumer.arn

  batch_size = 10

  # Without this a single failing record fails the WHOLE batch, so nine healthy deliveries
  # get redelivered because the tenth was malformed — and on a FIFO queue that stalls the
  # group behind it. The handler returns `batchItemFailures`; this is what makes AWS read it.
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    # One concurrent invocation is enough at this rate, and capping it means a redelivery
    # storm cannot fan out into the Lambda concurrency the rest of the account shares.
    maximum_concurrency = 2
  }
}
