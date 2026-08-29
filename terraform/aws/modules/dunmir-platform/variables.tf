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
    Where Postgres comes from.

      "rds"      — this module creates a `db.t4g.micro` single-AZ instance. **Read the cost note
                   below before choosing it.**
      "external" — the module creates nothing and uses `database_url` verbatim. This is what the
                   LocalStack root uses (a compose container), and it is also the escape hatch
                   for pointing at a managed Postgres somewhere cheaper.

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
    condition     = contains(["rds", "external"], var.db_mode)
    error_message = "db_mode must be \"rds\" or \"external\"."
  }
}

variable "database_url" {
  description = <<-EOT
    Postgres DSN, used verbatim when `db_mode = "external"` and ignored otherwise.

    A SECRET, and it is treated as one: it is passed to the function through SSM rather than an
    environment variable when `db_mode = "rds"` (the module composes it from a generated
    password). In `external` mode it arrives as an input, so whatever supplies it owns keeping
    it out of anywhere public — the LocalStack root passes a throwaway.
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

# ── application image ───────────────────────────────────────────────────────────────────────
variable "image_uri" {
  description = <<-EOT
    The ECR image the function runs, INCLUDING the tag or digest, e.g.
    `<account>.dkr.ecr.eu-west-1.amazonaws.com/dunmir-backend:0.1.7`.

    THIS LINE IS THE DEPLOYMENT. Changing it here is what moves the backend; nothing else does.

    It must be an ECR repository in **this account and this region** — Lambda cannot pull from
    GHCR or any other third-party registry, which is why `docker-bake.hcl`'s `lambda` target is
    deliberately outside the `default` group that publishes to GHCR.

    Prefer a digest (`@sha256:…`) for a production pin: Lambda resolves a tag once, at update
    time, so re-pushing the same tag does NOT redeploy and the function silently keeps running
    the image it resolved months ago.
  EOT
  type        = string
  default     = ""
}

variable "lambda_zip_path" {
  description = <<-EOT
    A built zip for the function, used **only** when `localstack = true`, where `image_uri` is
    ignored.

    WHY THE LOCAL RUN CANNOT USE THE IMAGE. Container-image Lambdas are a LocalStack **Pro**
    feature; the community image answers `NotImplementedError: Container images are a Pro
    feature` at the first invocation. So the local stack runs the same application code, through
    the same Mangum adapter, packaged as a zip.

    That leaves exactly one thing unproven here — the IMAGE itself: its base, its layer
    contents, and whether every package the app imports was actually COPY'd into it. That gap is
    covered separately and better, by running the real image under AWS's own Runtime Interface
    Emulator (`make -C aws dunmir-image-test`), which is the same runtime contract Lambda uses.
    The two together cover what one alone would not.
  EOT
  type        = string
  default     = ""
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
    domain and leaves the CloudFront default `*.cloudfront.net` name as the entrypoint.

    TWO-PHASE, like the chargate broker: apply once with `certificate_arn = ""` to have the
    module print the DNS validation record, create that record, wait for ACM to report ISSUED,
    then set `certificate_arn` and apply again. A distribution cannot be created with a
    certificate that is still PENDING_VALIDATION.

    Note this hostname is TWO labels deep under `magmamoose.com`, which under Cloudflare's
    Universal SSL would need its own certificate pack — see `k8s/base/ingress.yaml` in the
    dunmir repo. It does not apply here: the certificate is ACM's and the Cloudflare record is
    DNS-only (grey cloud), pointing straight at CloudFront, so Cloudflare terminates nothing.
  EOT
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate ARN for `api_domain_name`. **Must be in us-east-1** — CloudFront accepts
    certificates from nowhere else, whatever region the rest of the stack is in.

    Empty during phase 1 (see `api_domain_name`); the module then still requests the
    certificate and outputs its validation record, but does not attach it.
  EOT
  type        = string
  default     = ""
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
