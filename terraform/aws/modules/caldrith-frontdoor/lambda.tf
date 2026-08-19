# THREE functions, where nievah has two — and the third one is the whole point.
#
# CALDRITH RETIRES ITS KUBERNETES DEPLOYMENT. Nievah's front door ends at a queue that a
# cluster pulls from; that is why its iam.tf mints a long-lived `aws_iam_access_key` for an
# IAM user. The audits called that key the single largest unbounded surface in the design —
# it never expires, it lives in a vault outside AWS, and it is the one credential here that a
# leak makes permanent. Caldrith deletes the user, the key and the policy outright and puts a
# `reconcile` Lambda on the jobs queue instead. Nothing pulls from outside the account, so
# there is nothing to hand a key to.
#
#   producer   API Gateway -> verify HMAC over the raw body -> park an oversized body ->
#              send to events.fifo. Stdlib only.
#   consumer   events.fifo -> claim the delivery in DynamoDB -> parse -> decide which jobs
#              this delivery implies -> send them to jobs.fifo. Stdlib only.
#   reconcile  jobs.fifo -> mint an installation token -> run the tiers against GitHub. It
#              calls caldrith's reconcile entry points DIRECTLY, not `caldrith.worker.worker` —
#              see THE ARQ SEAM in the reconcile block below.
#
# NONE OF THE THREE HANDLER MODULES EXIST YET, AND THEY ARE THE APP-SIDE DELIVERABLE THIS STACK
# IS WAITING ON. `src/caldrith/` today holds api, audit, auth, config, reconcile and worker;
# there is no `aws/` package and no producer.py / consumer.py / reconcile.py under one. So
# `caldrith.aws.producer.handler`, `caldrith.aws.consumer.handler` and
# `caldrith.aws.reconcile.handler` below name modules that have to be written in
# MagmaMoose/caldrith and packaged by a publish workflow that does not exist either (see
# `variable "artifact_bucket"`, which already admits the artifacts leaf is missing). Terraform
# applies perfectly clean without them and every invocation then dies with
# `Runtime.ImportModuleError` — which on the producer means GitHub gets a 5xx for a delivery it
# never re-sends. Do not apply this stack before those three modules are published; this is not
# a Terraform defect, but it is the thing a reader of this file will hit first.
#
# WHAT REPLACED WHAT, EXPLICITLY, so nobody goes looking for the missing half:
#
#   FastAPI + uvicorn       -> producer, on API Gateway
#   ARQ worker process      -> reconcile, on an SQS event source mapping
#   Redis (dedup)           -> DynamoDB conditional write (storage.tf)
#   Redis (ARQ queue)       -> SQS FIFO (queues.tf)
#   ARQ cron_jobs           -> nothing. Deliberately; see THE SCHEDULE DECISION below.
#
# THERE IS NO ELASTICACHE HERE AND THAT IS THE SINGLE BIGGEST COST DECISION IN THE FILE. The
# cheapest ElastiCache node is roughly $12 a month; everything else in this stack together is
# expected to be a few cents. Redis would have cost about three hundred times the rest of the
# design combined, to do two things that a free DynamoDB table and a free SQS queue already
# do. `AppConfig.redis_url` keeps its default and nothing in this stack reads it.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE SCHEDULE DECISION: NO schedule.tf, AND HERE IS THE CHECK THAT WAS ACTUALLY DONE.
#
# `caldrith.settings.AppConfig.reconcile_cron_minutes` exists — a periodic full reconcile
# across every installation — so the question is real. It is NOT wired here, for three
# reasons, in order of weight:
#
#   1. It is already off. The default is 0, which `worker._cron_jobs()` reads as "no cron at
#      all". Wiring a schedule would be turning something ON that the application ships
#      disabled, from the infrastructure layer, where nobody looks for it.
#   2. Caldrith converges; nievah does not. Nievah's ticks moved to EventBridge because a
#      CronJob that stops firing leaves NOTHING behind and its planner silently stops. Caldrith
#      is reactive — pushes reconcile, and out-of-band edits self-heal through the drift
#      events — so a missed webhook is repaired by the next event touching that repo, not lost.
#      The cron is described in its own docstring as belt-and-braces, and `POST /reconcile`
#      (bearer-token guarded, see iam.tf) is the break-glass that covers the rest.
#   3. It is the most expensive thing this stack could possibly do on a timer. One tick fans
#      out one job per repo per installation. Hourly against a 200-repo org is ~144,000
#      reconcile invocations a month and the GitHub API calls to match, for a fleet that is
#      already correct — which would spend the always-free Lambda allowance, and Caldrith's
#      rate-limit budget, on confirming nothing changed.
#
# The seam is left clean rather than closed. If it is ever wanted, the answer is ONE
# `aws_scheduler_schedule` with `aws_sqs_queue.jobs` as its target, sending exactly the
# `reconcile_all_installations` message that `POST /reconcile` already sends — no new code
# path, no new IAM shape, and EventBridge Scheduler is always-free at 14M invocations a month
# against the ~720 a daily-to-hourly cadence would make. Start at daily, not hourly, and read
# reason 3 again first.
# ─────────────────────────────────────────────────────────────────────────────────────────────

locals {
  # TWO KEYS, ONE VERSION. Both under `edge/` because `modules/artifacts` scopes the OIDC
  # publish role to `${bucket}/edge/*` and that module is shared with nievah — see
  # `variable "artifact_version"` for what a `reconcile/` prefix would break. Version-scoped
  # and treated as immutable, which is what lets a key change stand in for a source hash.
  edge_key      = "edge/${var.artifact_version}.zip"
  reconcile_key = "edge/${var.artifact_version}-reconcile.zip"

  # Named here rather than inline because queues.tf derives both visibility timeouts from
  # them (`local.*_visibility_seconds` = 6x). Editing a timeout in one place moves the queue
  # with it; that pairing is a correctness requirement, not bookkeeping — read the note there.
  consumer_timeout_seconds  = 30
  reconcile_timeout_seconds = var.reconcile_timeout_seconds

  # SSM paths, not values. Every one of these is resolved by the function at cold start and
  # cached for the life of the execution environment.
  #
  # NOT LAMBDA ENVIRONMENT VARIABLES, AND THIS IS THE HARD RULE OF THE FILE. Environment
  # variables are plaintext to anyone holding `lambda:GetFunctionConfiguration`, they are
  # echoed by the console, and they appear in `terraform plan` output and therefore in every
  # Atlantis PR comment. The GitHub App private key can mint an installation token for every
  # repository the App is installed on — it is strictly more powerful than anything else in
  # this account — so it goes in a SecureString and its path travels in the env instead.
  ssm_app_id         = "${local.secret_path}/app-id"
  ssm_private_key    = "${local.secret_path}/private-key"
  ssm_webhook_secret = "${local.secret_path}/webhook-secret"
  ssm_manual_trigger = "${local.secret_path}/manual-trigger-token"
}

# --- log groups ------------------------------------------------------------------------------
#
# Created explicitly rather than left to Lambda. A log group Lambda creates for itself has
# retention set to NEVER EXPIRE.
#
# RETENTION CAPS STORAGE, NOT INGESTION, and it is worth being clear which problem this solves.
# Storage is $0.03/GB-month and this bounds it. INGESTION is $0.50/GB, charged when the line is
# written, with a 5 GB always-free allowance that is shared ORG-WIDE with nievah — and no
# retention value reduces it at all. The reconcile group is the one that matters: a JSON line
# per tier per repo means a full-account reconcile writes in a burst. See
# `var.log_retention_days`.
# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "producer" {
  #checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
  #checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
  name              = "/aws/lambda/${var.name_prefix}-producer"
  retention_in_days = var.log_retention_days
}

# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "consumer" {
  #checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
  #checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
  name              = "/aws/lambda/${var.name_prefix}-consumer"
  retention_in_days = var.log_retention_days
}

# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "reconcile" {
  #checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups — home lab, AES256 default is sufficient
  #checkov:skip=CKV_AWS_338:Retention set explicitly in var.log_retention_days; 1-year requirement not applicable here
  name              = "/aws/lambda/${var.name_prefix}-reconcile"
  retention_in_days = var.log_retention_days
}

# --- producer --------------------------------------------------------------------------------
#
# The only function GitHub can reach, and therefore the only one whose failure GitHub sees:
# everything downstream degrades into a queue, this one returns a 5xx to a caller that will
# never re-send. It does an HMAC and an SQS send and nothing else.
#
# It runs `caldrith.api.security.verify_signature` — the SAME module the service ran — rather
# than a re-implementation. That matters more than it looks: that function carries a fix for a
# real crash (a non-hex `X-Hub-Signature-256` makes `hmac.compare_digest` RAISE TypeError
# rather than return False, turning a malformed header into an unhandled 500 on an
# unauthenticated endpoint). A hand-copied edge implementation is a copy that drifts away from
# fixes like that one, silently, in the component that is exposed to the internet.
# trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "producer" { # nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
  #checkov:skip=CKV_AWS_173:No KMS CMK for env vars — home lab; every secret is an SSM PATH here, never a value
  #checkov:skip=CKV_AWS_116:DLQ handled at SQS layer (events_dlq); Lambda-level DLQ redundant
  #checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  #checkov:skip=CKV_AWS_115:Account-level concurrency cap may be 10; any reservation fails (InvalidParameterValueException)
  #checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to AWS services and api.github.com, no VPC resources
  #checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified at this scale
  function_name = "${var.name_prefix}-producer"
  role          = aws_iam_role.producer.arn
  handler       = "caldrith.aws.producer.handler"
  runtime       = "python3.13"

  # arm64 is ~20% cheaper per GB-second, which on a free-tier budget denominated in
  # GB-seconds means the same allowance stretches further. Nothing in this zip is
  # architecture-sensitive — it is `hmac`, `hashlib` and boto3, which ships for both.
  architectures = ["arm64"]

  s3_bucket = var.artifact_bucket
  s3_key    = local.edge_key

  # Chosen for COLD START rather than steady state: Lambda scales CPU with memory, so 512 MB
  # imports roughly twice as fast as 128 MB, and the cold start is the only part of this
  # function anywhere near GitHub's 10-second clock.
  memory_size = 512

  # Deliberately well under GitHub's 10s. If an SQS send has not completed in five seconds it
  # is not going to, and failing fast returns a 502 that leaves the delivery redeliverable
  # rather than a timeout that tells the sender nothing.
  timeout = 5

  # NO reserved_concurrent_executions, and not because it was overlooked. A new AWS account's
  # TOTAL Lambda concurrency quota is 10, and AWS refuses any reservation that would leave
  # fewer than 10 unreserved — so on an unraised account any value at all fails with
  # InvalidParameterValueException. That quota is a harder cap than a reservation would be, but
  # it is a DEFAULT rather than a decision, and a support ticket raising it would silently
  # remove this stack's concurrency ceiling. If the quota is ever raised, add reservations
  # here; until then the real per-function control is `maximum_concurrency` on the event source
  # mappings below, which works regardless of the quota.

  environment {
    variables = {
      EVENTS_QUEUE_URL = aws_sqs_queue.events.id
      OVERFLOW_BUCKET  = aws_s3_bucket.overflow.id

      # Paths. The producer reads exactly these two and cannot read the App private key — its
      # IAM policy names individual parameters rather than the path, so a `GetParametersByPath`
      # over `/caldrith/prod` is denied to it. See iam.tf.
      WEBHOOK_SECRET_PARAM       = local.ssm_webhook_secret
      MANUAL_TRIGGER_TOKEN_PARAM = local.ssm_manual_trigger

      BUILD_REF = var.artifact_version
    }
  }

  depends_on = [aws_cloudwatch_log_group.producer]
}

# --- consumer --------------------------------------------------------------------------------
#
# Claims the delivery, parses it, and turns it into jobs. It holds NO secret at all — it needs
# neither the webhook secret (the producer already verified, and re-verifying downstream of a
# trust boundary proves nothing) nor the App key (it makes no GitHub calls). Its IAM role has
# no `ssm:` statement whatsoever, which is the least-privilege claim being visible rather than
# asserted.
#
# The routing it performs is `caldrith.api.webhooks`' own: `push` on the admin repo's default
# branch -> a fan-out plus, if the settings file itself moved, an `update_admin_prs` sweep;
# `repository` created/edited -> that repo; `pull_request` on the admin repo -> `preview_config`
# (NOT a dry-run reconcile — the admin repo is excluded from management, so a dry run of it
# reports "no changes" for every settings PR ever opened; see COMMON_MISTAKES); the drift
# events -> the affected repo, or the org when there is no repository in the payload.
#
# IT ALSO HANDLES THE BREAK-GLASS ENVELOPE, and that is not decoration — it is the only route
# `POST /reconcile` has. The producer's IAM policy grants `sqs:SendMessage` on events.fifo and
# on NOTHING ELSE (iam.tf), deliberately, so an authorised manual trigger cannot be written
# straight to jobs.fifo; it arrives here as a synthetic envelope instead. It carries no
# `X-GitHub-Delivery`, so the producer generates the FIFO deduplication id itself (a uuid4, or
# `manual:<epoch>` — events.fifo has `content_based_deduplication = false`), and the consumer
# recognises the envelope and emits one `reconcile_all_installations` job. Same shape as every
# other delivery, one write target for the internet-facing role, and the App key stays at the
# far end.
# trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "consumer" { # nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
  #checkov:skip=CKV_AWS_173:No KMS CMK for env vars — home lab; values here are a queue URL and a table name
  #checkov:skip=CKV_AWS_116:DLQ handled at SQS layer (jobs_dlq); Lambda-level DLQ redundant
  #checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  #checkov:skip=CKV_AWS_115:Account-level concurrency cap may be 10; any reservation fails (InvalidParameterValueException)
  #checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to AWS services only, no VPC resources
  #checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified at this scale
  function_name = "${var.name_prefix}-consumer"
  role          = aws_iam_role.consumer.arn
  handler       = "caldrith.aws.consumer.handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  s3_bucket = var.artifact_bucket
  s3_key    = local.edge_key

  # Nothing is waiting on this one, so it is sized for cost rather than latency.
  memory_size = 256
  timeout     = local.consumer_timeout_seconds

  environment {
    variables = {
      JOBS_QUEUE_URL  = aws_sqs_queue.jobs.id
      DEDUP_TABLE     = aws_dynamodb_table.dedup.name
      OVERFLOW_BUCKET = aws_s3_bucket.overflow.id

      # The routing decisions above are made against these. ADMIN_REPO in particular decides
      # which repository is the config source AND which one is exempt from management — set it
      # wrong and nothing errors, the wrong repo is simply never reconciled.
      ADMIN_REPO         = var.admin_repo
      CONFIG_PATH        = ".github"
      SETTINGS_FILE_PATH = "settings.yml"
    }
  }

  depends_on = [aws_cloudwatch_log_group.consumer]
}

# --- reconcile -------------------------------------------------------------------------------
#
# THE FUNCTION THAT REPLACES THE CLUSTER. It performs the same six units of work the ARQ worker
# did — reconcile_installation, reconcile_repo, reconcile_org, preview_config, update_admin_prs,
# reconcile_all_installations — dispatched from an SQS message instead of from ARQ. Each
# invocation mints its OWN installation token and never shares one across installations, which
# is the same guarantee `GitHubClientFactory.for_installation` gives in the service.
#
# THE ARQ SEAM, DECIDED HERE RATHER THAN LEFT OPEN, because "SQS where ARQ used to be" is not
# by itself an answer. THIS FUNCTION DOES NOT IMPORT `caldrith.worker.worker`. That module does
# `from arq.connections import RedisSettings` and `from arq.cron import cron` at module scope
# and evaluates `RedisSettings.from_dsn(os.environ.get("REDIS_URL", ...))` in a class body, so
# importing it drags arq and a Redis DSN into a design whose entire premise is that neither
# exists here — and its job functions reach for `ctx["redis"].enqueue_job(..., _queue_name=...)`,
# an ARQ pool interface, which is the last live Redis assumption in the codebase.
#
# So the handler calls the layer BELOW the jobs: `reconcile.runner.run_reconcile`,
# `reconcile.org.run_org_reconcile`, `reconcile.preview.run_preview`, the admin-PR sweep and
# `reconcile.planner`'s repo listing, and does its own fan-out with `sqs:SendMessage`. The
# consequence for the build is concrete: arq, fastapi, uvicorn, redis and slowapi stay OUT of
# the zip. The alternative — reuse the job functions as they stand and ship arq plus an SQS shim
# exposing `enqueue_job(name, **kw, _queue_name=...)` that maps to SendMessage with the FIFO
# group and dedup ids — is coherent, and is rejected only because it buys a dependency and an
# adapter to preserve a function signature. If that is ever reversed, reverse this comment too.
#
# THE FAN-OUT IS A FINITE TREE, NOT A CYCLE, and that is why this function is allowed to write
# to the queue it reads from. Depth is three and no job enqueues its own type:
#
#   reconcile_all_installations -> reconcile_installation (one per installation)
#                                    -> reconcile_org  (one, Organization accounts only)
#                                    -> reconcile_repo (one per managed repo)  [terminal]
#
# If a future job ever enqueues its own type, this queue becomes a pump with no limit and
# `maximum_concurrency` below bounds only the RATE, never the total. Check that property
# before adding a job.
#
# THIS ZIP IS NOT NIEVAH'S 30 KB SEVEN-FILE PACKAGE. It carries the whole caldrith package plus
# githubkit, pydantic + pydantic-core, pydantic-settings, PyNaCl, Jinja2, PyYAML, structlog and
# wcmatch — two of which are COMPILED extensions.
#
# THE LAST THREE ARE THE ONES AN ABBREVIATED LIST DROPS, and each is a ModuleNotFoundError on
# the first invocation rather than anything the build or the apply notices: `structlog` is bound
# by `audit/logging.py`, which every tier and the runner import; `wcmatch` does the overlay and
# selection globbing; and `pydantic-settings` is a SEPARATE DISTRIBUTION from pydantic, imported
# by `settings.py`. Following a short inventory literally produces a function that deploys and
# cannot start. Two further consequences the build must honour, and both fail at RUNTIME rather
# than at deploy:
#
#   * WHEELS MUST BE BUILT FOR aarch64. A plain `pip install -t` on an x86_64 GitHub runner
#     produces x86_64 wheels, packages happily, uploads happily, applies happily — and the
#     function dies on its first invocation with a missing `pydantic_core._pydantic_core` or an
#     invalid ELF header. The publish workflow must use
#     `pip install --platform manylinux2014_aarch64 --only-binary=:all: --target …`, or build
#     in an arm64 container. Terraform cannot see this; only an invocation can.
#   * 250 MB UNZIPPED IS THE CEILING for an S3-sourced zip. This bundle is comfortably inside
#     it today. If it ever is not, the answer is a Lambda layer for the dependencies, NOT a
#     container image: ECR storage is $0.10/GB-month with no always-free allowance, so a
#     container image is the first thing in this design that would bill every month by
#     existing.
# trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "reconcile" { # nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
  #checkov:skip=CKV_AWS_173:No KMS CMK for env vars — home lab; the App key is an SSM PATH here, never a value
  #checkov:skip=CKV_AWS_116:DLQ handled at SQS layer (jobs_dlq); Lambda-level DLQ redundant
  #checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  #checkov:skip=CKV_AWS_115:Account-level concurrency cap may be 10; any reservation fails (InvalidParameterValueException). maximum_concurrency on the ESM is the working control
  #checkov:skip=CKV_AWS_117:Lambda is not VPC-bound; it talks to AWS services and api.github.com, no VPC resources
  #checkov:skip=CKV_AWS_50:X-Ray tracing not enabled — cost not justified at this scale
  function_name = "${var.name_prefix}-reconcile"
  role          = aws_iam_role.reconcile.arn
  handler       = "caldrith.aws.reconcile.handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  s3_bucket = var.artifact_bucket
  s3_key    = local.reconcile_key

  memory_size = var.reconcile_memory_mb
  timeout     = local.reconcile_timeout_seconds

  environment {
    variables = {
      JOBS_QUEUE_URL = aws_sqs_queue.jobs.id

      # Paths, never values. The private key is what makes this function the most privileged
      # thing in the account; see the `locals` block at the top of this file for why it is not
      # an env var.
      APP_ID_PARAM      = local.ssm_app_id
      PRIVATE_KEY_PARAM = local.ssm_private_key

      # A PLACEHOLDER THAT EXISTS ONLY TO SATISFY PYDANTIC, and without it this function fails
      # on EVERY invocation of a stack that applied perfectly. `caldrith.settings.AppConfig`
      # declares app_id, private_key AND webhook_secret as required fields with no defaults, so
      # the first `get_config()` raises `ValidationError: webhook_secret Field required` — and
      # `get_config()` is on the reconcile hot path everywhere (the worker jobs,
      # `GitHubClientFactory.__init__`, the runner's check-run post). It is also
      # `@lru_cache(maxsize=1)`, so whatever environment exists at the FIRST call is frozen for
      # the life of the execution environment; a late `os.environ` write fixes nothing.
      #
      # This function neither has nor needs the real secret. It verifies no signatures — the
      # producer did that at the edge — and iam.tf deliberately withholds the webhook-secret
      # parameter from its role, so it could not read the value even if it wanted to.
      #
      # THE HANDLER'S HALF OF THE CONTRACT, since Terraform can only supply this one: resolve
      # the two SSM paths above and set os.environ["APP_ID"] and os.environ["PRIVATE_KEY"] —
      # the names AppConfig actually reads, which are NOT the `*_PARAM` names here — BEFORE the
      # first import that touches get_config().
      WEBHOOK_SECRET = "unused-by-reconcile"

      # Never hardcode api.github.com downstream — GHES is on the roadmap and this is the whole
      # infrastructure side of that move (CLAUDE.md).
      GITHUB_API_URL = var.github_api_url

      ADMIN_REPO         = var.admin_repo
      CONFIG_PATH        = ".github"
      SETTINGS_FILE_PATH = "settings.yml"

      BUILD_REF = var.artifact_version
    }
  }

  depends_on = [aws_cloudwatch_log_group.reconcile]
}

# --- LocalStack only ---------------------------------------------------------------------------
#
# In production the front door is an API Gateway HTTP API (see api.tf); a Function URL exists
# here purely because API Gateway is a paid LocalStack feature and the local harness would
# otherwise have no way in at all.
#
# That substitution is honest rather than lossy: HTTP API payload format 2.0 is byte-for-byte
# the event shape a Function URL delivers, so the handler, the routing, the signature checks
# and everything downstream are the identical code path. What a local run does NOT cover is
# API Gateway's own configuration — the throttle, the $default stage, the integration — which
# is this stack's only real-time cost control, so it is exactly the part worth being explicit
# about not testing.
resource "aws_lambda_function_url" "producer" {
  count = var.localstack ? 1 : 0

  #checkov:skip=CKV_AWS_258:NONE auth is intentional — LocalStack only (count = var.localstack ? 1 : 0); production uses API Gateway
  function_name      = aws_lambda_function.producer.function_name
  authorization_type = "NONE"
}

# --- event source mappings ---------------------------------------------------------------------
#
# Push, not poll: the event source mapping is Lambda's own poller, and there is no server to
# run it on.
#
# ONE NUMBER TO WATCH AFTER A MONTH. Lambda's poller long-polls each queue continuously, and
# AWS does not clearly document whether those empty receives count against SQS's always-free
# 1M requests/month. Nievah has one such mapping live and org-wide SQS usage currently reads
# about 4,900 of 1,000,000, which strongly suggests they do not — but Caldrith adds two more,
# the allowance is org-wide rather than per-account, and there is no knob to slow a poller
# down if the answer turns out to be yes. The daily free-tier message the cost-report leaf
# posts to #finance is where this would show up first; read the SQS line there in a month.
resource "aws_lambda_event_source_mapping" "events" {
  event_source_arn = aws_sqs_queue.events.arn
  function_name    = aws_lambda_function.consumer.arn

  batch_size = 10

  # Without this a single failing record fails the WHOLE batch, so nine healthy deliveries get
  # redelivered because the tenth was malformed — and on a FIFO queue that stalls the message
  # group behind it. The handler returns `batchItemFailures`; this is what makes AWS read it.
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    # Parsing is milliseconds, so one or two concurrent invocations drain any realistic burst.
    # Capping it means a redelivery storm cannot fan out into the Lambda concurrency the rest
    # of the account shares — including the reconcile function, which is the one that matters.
    maximum_concurrency = 2
  }
}

# The jobs mapping, where the caps are doing real work.
resource "aws_lambda_event_source_mapping" "jobs" {
  event_source_arn = aws_sqs_queue.jobs.arn
  function_name    = aws_lambda_function.reconcile.arn

  # ONE, NOT TEN, and the difference is not stylistic. A reconcile job is seconds-to-minutes of
  # GitHub calls; ten of them in a single invocation share ONE `reconcile_timeout_seconds`
  # budget, so a batch that would each have succeeded alone can time out together — and a
  # timeout is not a per-record failure, it fails all ten and redelivers all ten, which then
  # time out again. Batching amortises invocation overhead that is already free at this
  # volume, in exchange for coupling ten repos' fates. One message, one invocation, one repo.
  batch_size = 1

  # Correct and cheap even at batch_size 1, and it stops being optional the moment somebody
  # raises the batch size without reading the paragraph above.
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    # THE GITHUB CONTROL AS MUCH AS THE AWS ONE — see `var.reconcile_max_concurrency`. GitHub's
    # secondary rate limits punish concurrent requests against one account, and a full-account
    # fan-out enqueues every repo at once. Uncapped, a large org would ask Lambda for one
    # simultaneous reconcile per repo, all against the same installation token, and GitHub
    # would answer 403 with a retry-after that reads like a bug.
    maximum_concurrency = var.reconcile_max_concurrency
  }
}
