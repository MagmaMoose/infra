variable "region" {
  description = <<-EOT
    Region holding the function, the database and the bucket. Supplied by the leaf from
    `region.hcl` (which derives it from the directory name), so the path on disk and the region
    in the ARNs cannot disagree. The provider's own region comes from the leaf's generated
    `aws_provider.tf`; this variable exists because IAM policy documents and the Cognito issuer
    URL have to build strings by hand.
  EOT
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = <<-EOT
    Environment segment of resource names and SSM paths, e.g. `/dunmir/prod/…`. Supplied by the
    leaf from `environment.hcl`. Deliberately NOT `terraform.workspace`: Terragrunt runs every
    leaf in the "default" workspace, so using it would collapse prod and any future environment
    onto one name.
  EOT
  type        = string
  default     = "prod"
}

variable "name_prefix" {
  description = "Prefix for every resource name. Change it to stand a second stack alongside."
  type        = string
  default     = "dunmir"
}

variable "localstack" {
  description = <<-EOT
    Target the local proving ground rather than AWS. Not a cosmetic switch — it removes the
    resources the community LocalStack image cannot honour, and **every removal is a real gap
    in what a local run proves**. Stated in full so nobody mistakes a green local apply for a
    validated production topology:

      CloudFront + ACM   Pro-only. Locally the Lambda's Function URL is reachable directly,
                         which means the ORIGIN ACCESS CONTROL that makes it private in
                         production is NOT exercised. The check for it is a curl against
                         `function_url_for_verification` after the first real apply; it must
                         return 403. Custom-domain TLS is likewise unproven.
      RDS                Not emulated at all. Locally `database_url` points at a plain Postgres
                         container in the same compose project — the same engine and the same
                         schema, so the SQL is genuinely exercised, but nothing about subnet
                         groups, parameter groups, backups or failover is.
      Cognito            Not in the community image. The local stack runs `moto`, which mints
                         REAL RS256 tokens against a REAL JWKS, so token verification and the
                         whole browser flow are genuinely exercised. What is not: pool
                         policies, the MFA configuration, and Cognito's own email delivery.
      VPC attachment     The function runs unattached locally (LocalStack executes Lambdas as
                         sibling containers on the host network), so the security-group path
                         between function and database is not exercised.
      EventBridge sched. Accepted and never fired. `smoke.py` invokes the sweep payload
                         directly instead, which covers everything downstream of the schedule —
                         the part this repo owns.
  EOT
  type        = bool
  default     = false
}

# ── database ────────────────────────────────────────────────────────────────────────────────
variable "db_mode" {
  description = <<-EOT
    Where the control-plane data lives.

      "dynamodb" — the control plane's own store, in DynamoDB. **This is what production runs**,
                   and it is the only option that is free forever; see `database_dynamo.tf` for
                   the capacity arithmetic, which is tight and organisation-wide.
      "rds"      — this module creates a `db.t4g.micro` single-AZ instance. **Read the cost note
                   below before choosing it.**
      "external" — the module creates nothing and uses `database_url` verbatim. This is what the
                   LocalStack root uses (a compose container), and it is also the escape hatch
                   for pointing at a managed Postgres somewhere cheaper.

    The first is not Postgres at all, which is why the seam in
    `dunmir_control_plane/store/` exists: the application asks for what it wants by name and
    each backend answers in its own terms, so Kubernetes keeps Postgres unchanged.

    THE COST NOTE, because "free tier" is the whole brief and this is the one line item that can
    break it. `db.t4g.micro` is free-tier eligible for **12 months**, and — per
    `terraform/aws/chargate/provider.hcl`, learned the expensive way in magmamoose/infra#641 —
    **AWS applies the free tier across an organization, dating from the MANAGEMENT account's
    creation.** A member account opened inside the existing MagmaMoose organisation therefore
    starts with an ALREADY-EXPIRED 12-month allowance and is billed from the first hour.

    So there are exactly two honest options and the choice is an account-topology decision, not
    a Terraform one:

      * a **new standalone AWS account** for Dün Mir, outside the organisation, which gets its
        own free plan; or
      * accept roughly **$15/month** (instance + 20 GB gp3) in a member account.

    Everything else in this module is on an *always*-free allowance — Lambda, CloudFront,
    Cognito, CloudWatch Logs, EventBridge Scheduler — so this variable is the only thing
    standing between the stack and a zero bill. `enable_budget_alarm` exists to make sure a
    surprise here is noticed in days rather than at the end of the month.
  EOT
  type        = string
  default     = "rds"

  validation {
    condition     = contains(["dynamodb", "rds", "external"], var.db_mode)
    error_message = "db_mode must be \"dynamodb\", \"rds\" or \"external\"."
  }
}

variable "database_url" {
  description = <<-EOT
    Postgres DSN, used verbatim when `db_mode = "external"` and ignored otherwise.

    A SECRET. It reaches the function as an ENVIRONMENT VARIABLE, not through SSM Parameter
    Store — see the note at the `DATABASE_URL` line in lambda.tf for why that is forced rather
    than chosen: reading a parameter means calling `ssm.<region>.amazonaws.com`, and a function
    with no NAT gateway cannot, since SSM has no gateway endpoint. Lambda encrypts environment
    variables at rest and gates them behind `lambda:GetFunctionConfiguration`, which is the same
    class of control an SSM SecureString gives.

    In `rds` mode the module composes this from a generated password and this variable is
    ignored. In `external` mode it arrives as an input, so whatever supplies it owns keeping it
    out of anywhere public — the LocalStack root passes a throwaway.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class. `db.t4g.micro` is the free-tier-eligible Graviton size."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = <<-EOT
    Gigabytes of gp3 storage. 20 is the free-tier ceiling AND the RDS minimum for gp3, so it is
    both the cheapest and the only sensible value here.
  EOT
  type        = number
  default     = 20
}

variable "db_ssl_root_cert_path" {
  description = <<-EOT
    Where the RDS global CA bundle sits inside the function image, for
    `sslmode=verify-full`.

    Must match the path `backend/Dockerfile.lambda` downloads it to. Both halves are
    required and they fail together: `verify-full` with no root certificate cannot
    connect at all, which is a loud failure rather than a silent downgrade — the right
    way round.
  EOT
  type        = string
  default     = "/opt/rds-global-bundle.pem"
}

variable "db_backup_retention_days" {
  description = <<-EOT
    Automated-backup retention. 7 days of backup storage up to the size of the database is
    included at no charge, so this costs nothing at the 20 GB above.

    Not 0. Zero disables automated backups entirely, which also disables point-in-time recovery
    — and this database holds every tenant's device inventory and the pointers to their
    encrypted backups.
  EOT
  type        = number
  default     = 7
}

# ── application artefact ────────────────────────────────────────────────────────────────────
#
# The function runs a ZIP published by MagmaMoose/dunmir's release workflow into the artefact
# bucket from the sibling `artifacts` leaf, keyed by version. Same shape as nievah, chargate,
# brimyr, caldrith and diatreme; see `modules/artifacts`.
variable "artifact_bucket" {
  description = <<-EOT
    The S3 bucket holding published deployment zips. `terragrunt output -raw artifact_bucket`
    from the sibling `artifacts` leaf.

    Read with the CALLER'S credentials at apply time, not the function's role — Lambda's
    UpdateFunctionCode fetches the object as whoever is running `terragrunt apply`. A principal
    that can create the function but cannot read the bucket fails at apply with an S3 error that
    does not obviously implicate the bucket.
  EOT
  type        = string
  default     = ""
}

variable "artifact_prefix" {
  description = <<-EOT
    The key prefix inside `artifact_bucket`. Must match `artifact_prefix` in the `artifacts`
    leaf, which is what the publish role's IAM policy is scoped to — a mismatch fails the
    PUBLISH with AccessDenied rather than failing here.
  EOT
  type        = string
  default     = "backend"
}

variable "artifact_version" {
  description = <<-EOT
    The published version to run, e.g. `0.1.7`. Resolves to `<artifact_prefix>/<version>.zip`.

    THIS LINE IS THE DEPLOYMENT. Changing it here is what moves the backend; nothing else does.

    Objects at these keys are immutable — diatreme refuses to overwrite one that exists — so the
    key change IS the deploy signal and there is no `source_code_hash` anywhere in this module
    for the AWS path. That also means a rollback is a one-line revert to a key that still holds
    exactly the bytes it held when it was reviewed.
  EOT
  type        = string
  default     = ""
}

variable "lambda_zip_path" {
  description = <<-EOT
    A LOCAL path to the built zip, used **only** when `localstack = true`. On AWS the same
    artefact arrives as an S3 object instead — see `artifact_version`.

    THE ZIP IS THE SAME ONE EITHER WAY, and that is the point. It is built by
    `backend/scripts/build_lambda_zip.py` in MagmaMoose/dunmir for both, so the local run
    exercises the artefact production deploys rather than a lookalike assembled by a second,
    subtly different script. The predecessor of this arrangement had exactly that problem: the
    harness resolved its own dependency set with one manylinux tag where the production build
    used two, so it silently ran asyncpg 0.30.0 against a production image holding 0.31.0.

    What this does NOT prove is the artefact running on the real Lambda runtime — LocalStack
    executes it under its own Python. That gap is covered by `make -C aws dunmir-zip-test`,
    which unzips it into `/var/task` inside `public.ecr.aws/lambda/python:3.12` and drives it
    through AWS's Runtime Interface Emulator as an unprivileged uid with no network.
  EOT
  type        = string
  default     = ""
}

variable "s3_public_endpoint_override" {
  description = <<-EOT
    Where the BROWSER fetches a presigned backup body from, when that differs from the
    endpoint the function itself uses. Empty means "the same one".

    On AWS they are the same public host, so this stays empty. The LocalStack root needs it:
    the function reaches the emulator by container name on a compose network the host cannot
    resolve, and the endpoint is part of the SIGNATURE — so it must be chosen before signing
    rather than substituted into the URL afterwards.
  EOT
  type        = string
  default     = ""
}

variable "cognito_require_verified_email" {
  description = <<-EOT
    Whether an ID token with NO `email_verified` claim may provision or re-key an
    identity.

    True (the default) refuses it, which is what a real Cognito deployment wants:
    Cognito always sends the claim, so its absence means the token did not come
    from the pool this deployment thinks it did. Only the local proving ground
    turns it off — the moto stand-in omits the claim, and papering over that with
    a fixture would hide a real difference between the two.
  EOT
  type        = bool
  default     = true
}

variable "s3_endpoint_override" {
  description = <<-EOT
    Where the function sends its S3 requests, when it is not the real regional endpoint. Used
    **only** by the LocalStack root, which points it at the emulator by container name.

    It also flips path-style addressing on, because LocalStack serves buckets at
    `<host>:4566/<bucket>` while AWS serves them at `<bucket>.s3.<region>.amazonaws.com` — and
    the two produce different canonical URIs, so a signature built for one is rejected by the
    other as an opaque `SignatureDoesNotMatch`.
  EOT
  type        = string
  default     = ""
}

variable "cognito_override" {
  description = <<-EOT
    A pool created outside this module, used **only** when `localstack = true`.

    Cognito is not in the community LocalStack image, so the local stack runs `moto`, which
    mints REAL RS256 tokens against a REAL JWKS — which is what makes the whole browser flow and
    the backend's offline verification genuinely exercised locally rather than mocked. The pool
    is created by `seed.sh` before Terraform runs (it has to exist for its keys to be read), and
    its ids are handed in here.

    `issuer` is separate from `endpoint` on purpose: moto stamps tokens with the REAL AWS issuer
    URL for a pool that only exists locally, so the value the backend must match and the host it
    would fetch keys from are two different strings.
  EOT
  type = object({
    user_pool_id = string
    client_id    = string
    issuer       = string
    endpoint     = string
    jwks         = string
  })
  default = null
}

variable "lambda_memory_mb" {
  description = <<-EOT
    Function memory, which on Lambda also buys CPU proportionally.

    512 rather than 128: the free allowance is 400,000 GB-seconds a month, so at 512 MB that is
    ~780,000 invocation-seconds — far beyond this workload — and the extra CPU cuts the cold
    start of a FastAPI import graph enough to be worth the arithmetic.
  EOT
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = <<-EOT
    Per-invocation ceiling. 30s matches CloudFront's default origin read timeout, so a request
    that is going to be cut off is cut off at the function rather than leaving it billing away
    behind a connection the edge has already abandoned.
  EOT
  type        = number
  default     = 30
}

# ── public entrypoint ───────────────────────────────────────────────────────────────────────
variable "api_domain_name" {
  description = <<-EOT
    Public hostname for the API, e.g. `api.dunmir.magmamoose.com`. Empty disables the custom
    domain and leaves the gateway's own `*.execute-api.<region>.amazonaws.com` name as the
    entrypoint.

    TWO-PHASE, like the chargate broker, because a single apply cannot create a certificate,
    write its DNS validation record into a zone Terraform does not manage here, and then use
    the certificate:

      1. set this, leave `enable_custom_domain` false -> the certificate is requested and
         `certificate_validation_record` names the CNAME to create;
      2. create that record, wait for ACM to report ISSUED, then set `enable_custom_domain`
         true and apply again.

    Getting the order wrong is not destructive, just stuck: the domain cannot be created against
    a certificate in PENDING_VALIDATION, and the certificate never validates without the record.

    This hostname is TWO labels deep under `magmamoose.com`, which under Cloudflare's Universal
    SSL would need its own certificate pack — see `k8s/base/ingress.yaml` in the dunmir repo.
    It does not apply here: the certificate is ACM's and the Cloudflare record is DNS-only
    (grey cloud) pointing at API Gateway's regional target, so Cloudflare terminates nothing.
  EOT
  type        = string
  default     = ""
}

variable "enable_custom_domain" {
  description = <<-EOT
    Phase 2 of the two-phase flow above: create the custom domain and map the stage to it.

    Turning this on also sets `disable_execute_api_endpoint`, which stops the gateway's own
    hostname answering — so the custom domain becomes the only way in rather than merely the
    pretty way in. Do not turn it on before the certificate is ISSUED; the apply will fail.
  EOT
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate ARN for `api_domain_name`, in THIS region (API Gateway regional custom
    domains do not accept a us-east-1 certificate, and vice versa).

    Empty means "let the module request one", which is the normal path — this exists for a
    certificate managed elsewhere, or one already validated.
  EOT
  type        = string
  default     = ""
}

variable "throttle_rate_limit" {
  description = <<-EOT
    Steady-state requests per second the gateway will pass to the function.

    THIS IS THE ONLY THING BOUNDING CONCURRENCY, and it is protecting the DATABASE more than the
    function. Lambda's account default is 1000 concurrent executions; each execution environment
    holds an asyncpg pool, and a db.t4g.micro tops out near 112 connections — so unbounded
    concurrency exhausts Postgres long before it exhausts Lambda, and the failure mode is 500s
    for everyone rather than throttling for some.

    50/s is far above this workload (the default heartbeat interval is one hour) and far below
    what would trouble the database.
  EOT
  type        = number
  default     = 50
}

variable "throttle_burst_limit" {
  description = "Burst allowance above `throttle_rate_limit`. Absorbs a fleet whose heartbeats align."
  type        = number
  default     = 100
}

variable "frontend_origin" {
  description = <<-EOT
    The console's origin, e.g. `https://dunmir.magmamoose.com`. Becomes `FRONTEND_ORIGIN` and
    `PUBLIC_URL` on the function.

    Credentialed CORS forbids a `*` origin, so a wrong value here fails closed — every call
    from the console is blocked by the browser with nothing in the network tab looking wrong.
    The console stays on Cloudflare; only the API is in AWS.
  EOT
  type        = string
  default     = "https://dunmir.magmamoose.com"
}

# ── identity ────────────────────────────────────────────────────────────────────────────────
variable "cognito_mfa" {
  description = <<-EOT
    Second-factor policy for the user pool: "ON" (required), "OPTIONAL", or "OFF".

    "ON" is the default because the product has always had mandatory MFA and Cognito is
    replacing the mechanism, not the policy. It is also what lets `GET /api/session/me` answer
    `totp_enrolled` truthfully without asking Cognito: a pool with MFA required cannot issue a
    token to an unenrolled user, so a request that arrived at all has demonstrably passed one.

    THE ONE-WAY DOOR: Cognito will not move a pool from "OFF" to "ON" while it has users
    without a factor, and it refuses to move an existing pool to "ON" at all in some
    configurations. Start as you mean to continue.
  EOT
  type        = string
  default     = "ON"

  validation {
    condition     = contains(["ON", "OPTIONAL", "OFF"], var.cognito_mfa)
    error_message = "cognito_mfa must be ON, OPTIONAL or OFF."
  }
}

variable "cognito_password_minimum_length" {
  description = <<-EOT
    Minimum password length. 12, and no character-class requirements — length is the whole
    policy, matching the first-party stack's own rule and the copy on the sign-up screen. Forced
    symbols and digits buy very little entropy and reliably produce `Password1!`.
  EOT
  type        = number
  default     = 12
}

variable "signup_allowed_domains" {
  description = <<-EOT
    Comma-separated email-domain allow-list, or empty for no restriction. Enforced by the
    BACKEND (`app.cognito.ensure_user`), not by the pool: Cognito has no such policy, so an
    address outside the list can create a pool account and simply never resolves to a local
    user or a workspace.
  EOT
  type        = string
  default     = ""
}

# ── operations ──────────────────────────────────────────────────────────────────────────────
variable "sweep_enabled" {
  description = <<-EOT
    Whether the dead-man sweep schedule is armed.

    Off is the correct state for a stack whose database is not wired up yet: the sweep fires
    once a minute, every firing fails, and the function-error alarm then emails on a five-minute
    cycle forever — which is how an operator learns to ignore the one alarm that can see the
    sweep fail at all.

    `lambda_handler._sweep` already tolerates a database with no SCHEMA (the window between
    apply and migrate). It cannot tolerate no database AT ALL, and should not pretend to.
  EOT
  type        = bool
  default     = true
}

variable "sweep_schedule_expression" {
  description = <<-EOT
    How often the dead-man heartbeat sweep runs. Once a minute matches the Cloudflare cron and
    the Kubernetes CronJob, so a device's "missed heartbeat" alarm fires at the same latency on
    every topology.

    EventBridge Scheduler's free allowance is 14 million invocations a month; this is ~44,000.
  EOT
  type        = string
  default     = "rate(1 minute)"
}

variable "log_retention_days" {
  description = <<-EOT
    CloudWatch Logs retention. 14 days: long enough to investigate last week's incident, short
    enough that the 5 GB always-free ingest allowance is the binding constraint rather than
    storage. Never 0 — that means "keep forever", which is the one setting that turns logs into
    a bill that grows without anyone deciding it should.
  EOT
  type        = number
  default     = 14
}

variable "backup_expiry_days" {
  description = <<-EOT
    Days after which an encrypted device backup body is expired from S3. 0 disables expiry.

    S3's free allowance is 5 GB and is one of the twelve-month ones, so this is the lever that
    keeps the bucket from being the thing that eventually costs money. 365 keeps a year of
    history, which is well beyond what any operator has asked to restore.
  EOT
  type        = number
  default     = 365
}

variable "enable_budget_alarm" {
  description = <<-EOT
    Create a $1/month AWS Budget with an email alert.

    A dollar, not a sensible operating budget — the entire point of this stack is that it costs
    nothing, so ANY charge is news. Without it the first signal that something slipped off the
    free tier is next month's invoice.
  EOT
  type        = bool
  default     = true
}

variable "ops_email" {
  description = <<-EOT
    Where the budget alert goes. AWS sends a confirmation for SNS subscriptions exactly once;
    until it is clicked the subscription is pending and delivers nothing, which Terraform
    reports as "created" either way. Budgets email directly and need no confirmation.
  EOT
  type        = string
  default     = ""
}

variable "admin_token" {
  description = <<-EOT
    The shared internal `ADMIN_TOKEN` the composed control-plane core accepts for machine
    callers. Empty leaves it unset, which is correct for a deployment where every operator
    arrives through Cognito — there is then no shared credential to leak.

    Never commit a value here. Set it out of band with `aws ssm put-parameter` and reference the
    parameter, exactly as the neighbouring stacks do with their webhook secrets.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "sweep_target_url" {
  description = <<-EOT
    Where the dead-man sweep is fired, when it is fired over HTTP.

    Empty (the default) means the sweep target is this account's own Lambda, invoked directly
    with `{"task": "sweep"}` — correct when the application runs here.

    Set it to the Kubernetes backend's `POST /internal/sweep` URL and a small function is
    created that calls it on the same schedule. That is for the topology in production today,
    where the application is on the OCI cluster and its sweep is a CronJob INSIDE the cluster it
    monitors — so a cluster that is unwell produces no sweep, no alerts, and a console showing
    every fleet healthy. Moving the trigger out makes that failure loud.

    The bearer token is NOT set here. Terraform creates the SSM parameter and leaves its value
    alone; put the cluster's `ADMIN_TOKEN` in out of band. A credential that authenticates
    `/internal/sweep` and every `/v1/admin/*` route does not belong in a state file.

    ONE SWEEP AT A TIME. Setting this does not disable the Kubernetes CronJob — remove that in
    the same change that applies this, or two sweeps race. They are idempotent so nothing
    breaks, but the writes double and "did the sweep run" stops having one answer.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.sweep_target_url == "" || startswith(var.sweep_target_url, "https://")
    error_message = "sweep_target_url must be https:// — the request carries the admin bearer token."
  }
}
