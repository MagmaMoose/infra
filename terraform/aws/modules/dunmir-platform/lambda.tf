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
      # An absent `email_verified` claim is refused by default. See the variable.
      COGNITO_REQUIRE_VERIFIED_EMAIL = var.cognito_require_verified_email ? "true" : "false"
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
      # THE BUCKET MUST BE IN THE ENDPOINT when path-style is off. With
      # S3_FORCE_PATH_STYLE=false, app/storage.py builds both the URL and the SigV4 canonical
      # URI WITHOUT the bucket, because it expects the bucket to be the first label of the
      # host. Pairing that with the bare regional endpoint (https://s3.<region>.amazonaws.com)
      # sends every request to https://s3.<region>.amazonaws.com/backups/<device>/<file> — where
      # S3 reads `backups` as the BUCKET NAME. Every upload and download then 403s against
      # somebody else's bucket, and no amount of IAM on our own bucket helps.
      #
      # So: the virtual-host endpoint. Path-style would also work, but AWS has been deprecating
      # it for new buckets and this form is the one with a future.
      S3_ENDPOINT_URL = var.s3_endpoint_override != "" ? var.s3_endpoint_override : "https://${aws_s3_bucket.backups.bucket}.s3.${var.region}.amazonaws.com"
      S3_BUCKET       = aws_s3_bucket.backups.bucket
      S3_REGION       = var.region
      # Path-style only against the emulator, which serves buckets at <host>:4566/<bucket>.
      # The two produce different canonical URIs and SigV4 signs the URI, so mismatching them
      # yields a SignatureDoesNotMatch that says nothing about addressing.
      S3_FORCE_PATH_STYLE = var.s3_endpoint_override != "" ? "true" : "false"
      # Only set where the browser reaches S3 at a different address than the function does
      # — see the variable. Empty on AWS, where both are the same public host.
      S3_PUBLIC_ENDPOINT_URL = var.s3_public_endpoint_override

      # PRESIGNED DOWNLOADS ARE OPT-IN, AND THIS IS THE ONLY DEPLOYMENT THAT OPTS IN.
      #
      # `app/storage.py:presigning_available()` used to infer this from STORAGE_BACKEND=s3 plus
      # credentials, which is equally true of the Kubernetes/R2 deployment. The console then took
      # the presigned path there too, the browser refused the cross-origin fetch because the
      # console's CSP names no object store, and backup downloads broke in the shipping product
      # after working for months.
      #
      # The ceiling that makes presigning necessary is specific to HERE: Mangum caps a Lambda
      # response payload at 6 MB and base64-encodes an octet-stream into it, so a backup over
      # ~4.4 MiB fails as an opaque 502. On Kubernetes the proxy streams with no ceiling, so
      # presigning buys nothing and costs a CSP origin, a bucket CORS policy, and a second way
      # for a download to fail.
      #
      # Turning this on has two hard requirements, and both are in this module so they cannot
      # drift apart from it: `aws_s3_bucket_cors_configuration.backups` in storage.tf, and the
      # bucket origin in the console's `connect-src` (see the `console_env` output).
      PRESIGNED_DOWNLOADS = "true"
      # No S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY. The signer falls back to the AMBIENT
      # credentials Lambda injects from the execution role (app/storage.py `_credentials`),
      # which expire in hours and are scoped to this one function — the alternative is a
      # long-lived IAM user whose secret sits in this configuration forever.

      # --- which store backs the control plane ---------------------------------------------
      #
      # `dynamodb` selects `dunmir_control_plane/store/dynamo.py`; anything else keeps the SQL
      # implementation, which is what every Kubernetes deployment runs. The branch lands in one
      # factory rather than at the call sites, which is the entire reason the seam exists.
      DB_BACKEND = var.db_mode == "dynamodb" ? "dynamodb" : "sql"
      # Empty unless there is a table, so a misconfiguration fails at boot naming the setting
      # rather than at the first write naming a table that does not exist.
      DYNAMODB_TABLE = var.db_mode == "dynamodb" ? aws_dynamodb_table.control_plane[0].name : ""

      # --- the heartbeat floor ----------------------------------------------------------
      #
      # THE ONE FIELD THAT CAN WALK THIS DEPLOYMENT OUT OF THE FREE TIER.
      # `devices.heartbeat_interval_seconds` is nullable, per-device, has no database
      # default, and the router accepts anything from 30s upward. The 3600 in
      # `config.DEFAULT_HEARTBEAT_INTERVAL_SECONDS` is only the SWEEP's fallback for reading a
      # NULL — it does not constrain what an operator may store.
      #
      # That is harmless on Postgres and expensive here. This topology's control-plane store is
      # provisioned at a handful of DynamoDB capacity units, bought to sit inside AWS's
      # always-free allowance, with autoscaling deliberately off — so the write rate is a fixed
      # budget rather than a performance characteristic. One busy site set to 30s spends it,
      # silently, and the first signal is a bill.
      #
      # Both values are inert unless set (see `capacity.py`), so no other topology is affected.
      #
      # 4 BEATS PER SECOND is derived, not chosen: a heartbeat costs ~3 write units — one for
      # the device's status item, two more for the liveness index, which is keyed on
      # `last_seen_at` and so rewrites its entry rather than updating in place. Against the
      # write capacity this deployment holds that is ~4/s fleet-wide. **Re-derive it whenever
      # the table's provisioned WCU changes**; the two are one number expressed twice, and
      # nothing but this comment couples them.
      #
      # The effective floor is max(300, devices / 4), so 1000 devices land at 300s with room
      # and a fleet past 1200 is held progressively slower.
      MIN_HEARTBEAT_INTERVAL_SECONDS = "300"
      MAX_HEARTBEATS_PER_SECOND      = "4"

      # --- runtime limits the vendored core hard-codes (app/limits.py) ---------------------
      #
      # The core's 64 MiB backup ceiling is unreachable behind API Gateway, whose request
      # payload caps at 10 MB — and a binary body is base64-encoded into the event JSON on the
      # way, costing 4/3. Above ~7 MiB the request is rejected by the PLATFORM before the
      # function is entered, so the agent gets an opaque 413 from something that is not us and
      # nothing appears in our logs. 6 MiB leaves headroom for the event envelope and means the
      # agent gets OUR error, naming the real limit.
      MAX_BACKUP_BYTES = tostring(6 * 1024 * 1024)

      # The pool is PER EXECUTION ENVIRONMENT, and Lambda creates as many as it likes. The
      # core's default of 10 against a db.t4g.micro's ~112 connections means eleven warm
      # containers exhaust the database and every request then 500s. Two per environment, with
      # the gateway's throttle bounding how many environments there can be, keeps Lambda's
      # elasticity and Postgres's ceiling in proportion.
      DB_POOL_MIN_SIZE = "1"
      DB_POOL_MAX_SIZE = "2"
      # Lambda FREEZES an environment between invocations; a pooled TCP connection frozen for
      # minutes may already have been dropped by the server. Retiring idle connections quickly
      # means the next thaw gets a fresh one rather than a dead one, and stops abandoned
      # environments holding backends open on the database for hours.
      DB_POOL_IDLE_SECONDS = "60"

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

      # Outbound alert webhooks are the third thing that needs egress, and the one that fails
      # WORST. The control plane POSTs to operator-configured webhook/Discord URLs inline, from
      # inside the sweep and from agent ingest. A security group DROPS rather than rejects, so
      # each unreachable route costs the full connect timeout with nothing to show for it — a
      # tenant with three routes turns every 60-second sweep into a 30-second stall, billed,
      # forever. Alerts are still recorded and still visible in the console; only the fan-out to
      # third parties is suppressed. See app/limits.py.
      ALERT_WEBHOOKS_ENABLED = "false"
      # Belt and braces for anything else that dials out: the core's timeout applies to the
      # connect phase too, and 10s of it is a long time to spend discovering a blackhole.
      OUTBOUND_CONNECT_TIMEOUT_SECONDS = "2"

      # The application's own INFO lines are DISCARDED without this. Both entrypoints call
      # logging.basicConfig(level=INFO), and under awslambdaric that is a complete no-op: the
      # runtime installs a root handler before the handler module is imported, and basicConfig
      # returns early when the root logger already has one — including the level. So the root
      # logger stays at WARNING and every log.info() in the app vanishes, which is how you end
      # up unable to tell from the logs whether backups went to S3 or fell back to local disk.
      AWS_LAMBDA_LOG_LEVEL = "INFO"

      # ZERO trusted proxies, which on this topology is both correct and the STRONGER setting.
      #
      # `app.auth.client_ip` reads 0 as "trust no forwarding header; use the real transport
      # peer". Under Mangum the peer is `requestContext.http.sourceIp`, which API Gateway sets
      # from the TCP connection it terminated. With the `api.` record DNS-only in Cloudflare
      # (grey cloud) and no CloudFront, the gateway IS the edge — so that address is the actual
      # caller and a client cannot forge it, whereas anything read out of `x-forwarded-for`
      # ultimately can be.
      #
      # It was 1, which would have been right for a single header-appending proxy. Two things
      # killed that: the edge is no longer a Function URL (those truncate `x-forwarded-for` to
      # its LEFTMOST entry, i.e. exactly the part a client types), and with the gateway as the
      # only hop there is no chain worth parsing.
      #
      # This is load-bearing and silent in both directions — too low and every caller collapses
      # into one rate-limit bucket, too high and the value becomes client-chosen — so it was
      # checked by driving four header shapes through the real handler and reading back
      # `audit_log.actor_ip`.
      TRUSTED_PROXY_COUNT = "0"
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
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "lambda" {
  # checkov:skip=CKV_AWS_158:No KMS CMK for the log group. A CMK bills per key per month and the logs carry no secret — the DSN and the JWKS are environment variables, and every credential this function handles is hashed or sealed before it is written anywhere.
  # checkov:skip=CKV_AWS_338:Retention is set explicitly (var.log_retention_days); the one-year floor this rule wants is a compliance requirement this product does not have, and CloudWatch's always-free allowance is 5 GB of INGEST pooled across the organisation.
  name              = "/aws/lambda/${local.name}-api"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-api" }
}

locals {
  # Must match what MagmaMoose/dunmir's release workflow publishes to, and the prefix the
  # publish role in the `artifacts` leaf is scoped to. The leaf wires all three from one value.
  artifact_key = "${var.artifact_prefix}/${var.artifact_version}.zip"
}

resource "aws_lambda_function" "api" {
  function_name = "${local.name}-api"
  role          = aws_iam_role.lambda.arn

  # A ZIP, ON BOTH TOPOLOGIES, which is the same artefact rather than two that
  # resemble each other. It comes from `backend/scripts/build_lambda_zip.py` in
  # MagmaMoose/dunmir either way; only the delivery differs — a local path for the
  # emulator, an S3 object for AWS.
  #
  # This used to be a container image on AWS, and the change was worth making for
  # more than the $0.10/GB-month ECR bill it removes. Lambda cannot pull an image
  # from GHCR, so the image route needed a registry in this account that nothing
  # else wanted, while the organisation already had a delivery path for exactly
  # this: `modules/artifacts` publishes a version-keyed, immutable zip and the
  # consumer pins the key. nievah, chargate, brimyr, caldrith and diatreme all use
  # it. There was no argument for this service being the exception.
  package_type = "Zip"
  handler      = "lambda_handler.handler"
  runtime      = "python3.12"

  # LOCAL FILE FOR THE EMULATOR, S3 OBJECT FOR AWS.
  filename  = var.localstack ? var.lambda_zip_path : null
  s3_bucket = var.localstack ? null : var.artifact_bucket
  s3_key    = var.localstack ? null : local.artifact_key

  # ONLY LOCALLY, and its absence on AWS is deliberate rather than an omission.
  #
  # Locally the zip is rebuilt in place, so without the hash Terraform sees no
  # attribute change and leaves the old code running — which presents as "my fix
  # did nothing". On AWS the key is version-scoped and its object immutable, so the
  # KEY CHANGE is the deploy signal; a hash there would mean reading an 23 MB
  # object from S3 on every plan to compute something the key already tells us.
  source_code_hash = var.localstack && var.lambda_zip_path != "" ? filebase64sha256(var.lambda_zip_path) : null

  # x86_64, NOT arm64, and this is the one place the module deliberately gives up
  # a discount. A zip's architecture is NOT validated at deploy time the way a
  # container image manifest's is, so the only thing standing between a
  # wrong-architecture package and a production `ModuleNotFoundError` is a check in
  # CI — and that check can only RUN the artefact if CI's machine matches it.
  # GitHub's runners are x86_64, so this is the architecture that keeps the package
  # test executable rather than skippable. arm64's ~20% GB-second discount is worth
  # exactly nothing inside the always-free 400,000 GB-second allowance, which this
  # workload does not approach. `modules/chargate-broker` made the same call.
  architectures = ["x86_64"]

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
    aws_iam_role_policy.vpc_access,
  ]

  tags = { Name = "${local.name}-api" }
}

# A Function URL, for the LOCAL PROVING GROUND ONLY.
#
# On AWS the public entrypoint is an API Gateway HTTP API (edge.tf), which invokes this function
# directly. This exists because LocalStack gates `apigatewayv2` behind its Pro licence
# ("Sorry, the apigatewayv2 service is not included within your LocalStack license"), so the
# local stack needs some entrypoint and a Function URL is the one the community image can
# serve.
#
# THE COST OF THAT, STATED PLAINLY: the local run does not exercise the real edge. It never
# did — the previous design put CloudFront there, which the community image also cannot
# emulate. What changed is that the edge is now one whose behaviour is *derivable from
# documentation* rather than one that had to be trusted: API Gateway forwards `Authorization`
# untouched and does not sign anything, so the bearer-token contract holds by construction.
#
# `AuthType NONE` is safe here and only here: nothing outside this machine can reach a
# LocalStack container. On AWS this resource does not exist, so there is no unauthenticated
# hostname to leak.
#
# There is deliberately no `invoke_mode`. It was RESPONSE_STREAM, to escape the 6 MB buffered
# response cap; that was wrong twice over. AWS supports response streaming on Node.js managed
# runtimes only (Python needs a custom runtime), and function URLs do not stream inside a VPC
# at all — so the cap always applied and the setting bought nothing. Payload limits are now
# enforced by the application instead (MAX_REQUEST_BYTES), where the caller gets a 413 that
# says what happened.
resource "aws_lambda_function_url" "local" {
  count = var.localstack ? 1 : 0

  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"
}
