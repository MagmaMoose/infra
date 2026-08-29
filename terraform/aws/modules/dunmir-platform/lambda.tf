# The API: one container-image function, behind a Function URL.
#
# WHY LAMBDA AND NOT ANYTHING ELSE
#   On AWS the difference between free and not is almost never compute — it is anything billed
#   by the HOUR. Lambda's 1M requests and 400,000 GB-seconds a month are **always** free, not
#   free for twelve months. An HTTP API Gateway would add a request tier that expires after a
#   year, for a feature (custom domains) CloudFront already gives us for nothing. An ALB is ~$16
#   a month before the first request. Fargate and EKS are not free at all.
#
# ONE FUNCTION, THREE JOBS
#   `lambda_handler.handler` dispatches on the event shape: an HTTP request goes to the ASGI app
#   through Mangum, `{"task": "sweep"}` runs the dead-man heartbeat sweep, `{"task": "migrate"}`
#   applies the schema. A second function would be a second image, a second set of permissions
#   and a second cold start for byte-identical code — and the migration in particular MUST run
#   in here, because the database has no public address and this is the only thing inside the
#   VPC that can reach it.
#
# ARM64. Graviton: the same free allowance, ~20% cheaper per GB-second beyond it, and what
# `docker-bake.hcl`'s `lambda` target builds. A mismatch here is an apply-time error, not a
# runtime one, which is the good kind.

locals {
  creates_schedule = !var.localstack

  # Everything the application reads from its environment. Assembled here so the whole
  # configuration surface of the deployment is one readable block rather than scattered across
  # the file.
  environment = merge(
    {
      # --- identity -------------------------------------------------------------------------
      # The browser drives Cognito; this function only VERIFIES the resulting JWT, offline,
      # against the keys below. That is what lets the VPC have no route to the internet.
      AUTH_MODE             = "cognito"
      COGNITO_REGION        = var.region
      COGNITO_USER_POOL_ID  = local.cognito.user_pool_id
      COGNITO_APP_CLIENT_ID = local.cognito.client_id
      COGNITO_MFA_REQUIRED  = var.cognito_mfa == "ON" ? "true" : "false"
      # Read once at apply time — see the `http` data source in identity.tf for why this is not
      # a runtime fetch. RSA public keys: public by definition, safe in an environment variable.
      COGNITO_JWKS = local.cognito.jwks
      # Both normally derivable from region + pool id, and both set explicitly because the local
      # stand-in stamps tokens with the REAL AWS issuer for a pool that only exists locally — so
      # the value the backend must match and the host the browser calls are different strings.
      COGNITO_ISSUER          = local.cognito.issuer
      COGNITO_PUBLIC_ENDPOINT = local.cognito.endpoint

      # --- object store ---------------------------------------------------------------------
      # Rebinds the control-plane core's backup store to S3 at boot (app/storage.py). Without
      # STORAGE_BACKEND=s3 the core falls back to a local directory, which on Lambda is a
      # read-only filesystem — uploads would fail at the first backup rather than at boot.
      STORAGE_BACKEND = "s3"
      S3_ENDPOINT_URL = var.s3_endpoint_override != "" ? var.s3_endpoint_override : "https://s3.${var.region}.amazonaws.com"
      S3_BUCKET       = aws_s3_bucket.backups.bucket
      S3_REGION       = var.region
      # Virtual-host addressing on AWS, path-style against the emulator. The two produce
      # different canonical URIs, and SigV4 signs the URI — mismatching them yields a
      # SignatureDoesNotMatch that says nothing about addressing.
      S3_FORCE_PATH_STYLE = var.s3_endpoint_override != "" ? "true" : "false"
      # No S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY. The signer falls back to the AMBIENT
      # credentials Lambda injects from the execution role (app/storage.py `_credentials`),
      # which expire in hours and are scoped to this one function — the alternative is a
      # long-lived IAM user whose secret sits in this configuration forever.

      # --- product ---------------------------------------------------------------------------
      MULTI_TENANT           = "true"
      FRONTEND_ORIGIN        = var.frontend_origin
      PUBLIC_URL             = var.frontend_origin
      PRO_UI_URL             = var.frontend_origin
      SIGNUP_ALLOWED_DOMAINS = var.signup_allowed_domains

      # There is no route to SES or to any other mail API from in here, and there will not be
      # one at this price. `none` is the honest setting: Cognito sends its own confirmation and
      # reset mail from the BROWSER's request, and invitations are handed back to the inviter as
      # a link to pass on. `console` would be wrong — it logs the message and lets the caller
      # believe it was delivered.
      EMAIL_PROVIDER = "none"

      # Billing and the GitHub config browser both need egress and therefore cannot work on this
      # topology. Off explicitly rather than left to a default, so that "billing is disabled" is
      # a decision recorded here and not a mystery discovered later.
      BILLING_ENABLED = "false"

      # ONE hop in front: CloudFront. The per-IP half of the brute-force limiter keys on the
      # address this resolves to, so a wrong count collapses every caller into one bucket —
      # silently, since nothing errors.
      TRUSTED_PROXY_COUNT = "1"
    },
    var.admin_token == "" ? {} : { ADMIN_TOKEN = var.admin_token },

    # The DSN, as a plain environment variable — and NOT out of SSM Parameter Store, which was
    # the first instinct and is impossible here.
    #
    # Reading a parameter means calling `ssm.<region>.amazonaws.com`, and this function has no
    # route to the internet. SSM has no gateway endpoint (only S3 and DynamoDB do), so reaching
    # it would need an INTERFACE endpoint at ~$7.30/month — which is the same hourly-billed
    # trap the whole topology exists to avoid, spent to move a secret from one encrypted store
    # to another.
    #
    # Lambda environment variables are encrypted at rest with a KMS key and are readable only
    # by a principal holding `lambda:GetFunctionConfiguration` on this function. That is the
    # same class of control an SSM SecureString gives, so the trade is a real cost against a
    # notional gain.
    { DATABASE_URL = local.database_url },
  )
}

# Created by Terraform, NOT by Lambda. A group Lambda creates for itself retains forever, and by
# the time anyone notices the bill, changing the retention does not reclaim what is already
# stored. This also makes the IAM policy in iam.tf able to name the group's ARN.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-api"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-api" }
}

resource "aws_lambda_function" "api" {
  function_name = "${local.name}-api"
  role          = aws_iam_role.lambda.arn

  # Image on AWS; zip locally, because container-image Lambdas are a LocalStack Pro feature.
  # See `lambda_zip_path` for what that costs the local run and how the gap is covered.
  package_type = var.localstack ? "Zip" : "Image"
  image_uri    = var.localstack ? null : var.image_uri
  filename     = var.localstack ? var.lambda_zip_path : null
  handler      = var.localstack ? "lambda_handler.handler" : null
  runtime      = var.localstack ? "python3.12" : null
  # The zip's hash, so re-running `make dev` after a code change actually redeploys. Without it
  # Terraform sees no change to any attribute and leaves the old code running, which presents as
  # "my fix did nothing".
  source_code_hash = var.localstack && var.lambda_zip_path != "" ? filebase64sha256(var.lambda_zip_path) : null

  architectures = ["arm64"]

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  environment {
    variables = local.environment
  }

  dynamic "vpc_config" {
    for_each = local.networked ? [1] : []
    content {
      subnet_ids         = aws_subnet.private[*].id
      security_group_ids = [aws_security_group.lambda[0].id]
    }
  }

  # The group must exist before the function, or Lambda creates its own with infinite retention
  # on the first invocation and Terraform's group is then a second, empty one.
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
    aws_iam_role_policy_attachment.vpc_access,
  ]

  tags = { Name = "${local.name}-api" }
}

# The HTTP entrypoint.
#
# `AWS_IAM`, not `NONE`. The URL is public DNS either way, so the authorisation type is the only
# thing standing between the internet and the origin: with `NONE` anyone who learns the
# `*.lambda-url.*.on.aws` hostname bypasses CloudFront entirely — and with it the custom domain,
# the caching and any edge control. With `AWS_IAM`, only a SigV4-signed request is accepted, and
# CloudFront's Origin Access Control does that signing. A direct hit returns 403, which is the
# check to run after the first real apply (see `function_url_for_verification` in outputs.tf).
resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = var.localstack ? "NONE" : "AWS_IAM"

  # RESPONSE_STREAM, not BUFFERED. Buffered responses are capped at 6 MB, and a device
  # backup download is a single-shot GET of a body that can exceed it — which would fail as an
  # opaque 502 on exactly the large backups that matter most.
  invoke_mode = "RESPONSE_STREAM"
}

# Lets THIS distribution, and only this distribution, invoke the URL. Without it the OAC signs
# requests correctly and Lambda rejects every one of them with a 403 that looks identical to a
# misconfigured OAC.
resource "aws_lambda_permission" "cloudfront" {
  count = local.creates_distribution ? 1 : 0

  statement_id           = "AllowCloudFrontServicePrincipal"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.api[0].arn
  function_url_auth_type = "AWS_IAM"
}
