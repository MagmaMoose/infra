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
resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${var.name_prefix}-producer"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/${var.name_prefix}-consumer"
  retention_in_days = var.log_retention_days
}

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

# AWS_IAM, not NONE. The URL is reachable only by a caller that can sign a SigV4 request for
# it, which — per the policy in edge.tf — is the CloudFront distribution and nothing else.
# With NONE this URL would be a second, unprotected front door on a guessable hostname,
# permanently, and no amount of CloudFront configuration would close it.
resource "aws_lambda_function_url" "producer" {
  function_name      = aws_lambda_function.producer.function_name
  authorization_type = var.localstack ? "NONE" : "AWS_IAM"
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
