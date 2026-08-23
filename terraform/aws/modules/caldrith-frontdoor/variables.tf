variable "region" {
  description = <<-EOT
    Region holding the queues, the functions and the table. Supplied by the leaf from
    `region.hcl` (which derives it from the directory name), so the path on disk and the
    region in the ARNs cannot disagree. The provider's own region comes from the leaf's
    generated `aws_provider.tf`; this variable exists because IAM policy documents have to
    build ARNs by hand.
  EOT
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = <<-EOT
    Environment segment of the SSM secret path, e.g. `/caldrith/prod/webhook-secret`. Supplied
    by the leaf from `environment.hcl`. Deliberately NOT `terraform.workspace`: Terragrunt
    runs every leaf in the "default" workspace, so using it would collapse prod and any future
    environment onto one path.
  EOT
  type        = string
  default     = "prod"
}

variable "artifact_bucket" {
  description = <<-EOT
    Bucket holding the published Lambda zips.

    NOT A `dependency` OUTPUT, unlike nievah's front door, and that is an account boundary
    rather than an oversight. `prod/eu-west-1/artifacts` applies into prd-nievah
    (666802049426); Caldrith runs in prd-caldrith (483461801743), and a bucket in one account
    cannot be a Lambda code source for a function in another without a bucket policy that
    grants it — which would put Caldrith's deploys inside Nievah's blast radius for nothing.

    So Caldrith needs its OWN artifacts leaf in its own account (`modules/artifacts` takes
    `name_prefix`/`publisher_repo`, so it needs no forking). Until that leaf exists this is a
    hand-written string and the ordering lives in a runbook rather than in the graph. See the
    cold-start note in the leaf.
  EOT
  type        = string
}

variable "artifact_version" {
  description = <<-EOT
    Which published build to run, e.g. "1.15.2". Resolves to TWO objects in the artifact
    bucket, from this one string:

      edge/<version>.zip            producer + consumer — thin, stdlib only
      edge/<version>-reconcile.zip  reconcile — the whole caldrith package and its deps

    THIS LINE IS THE DEPLOYMENT. A publish workflow in MagmaMoose/caldrith uploads both
    objects and opens the bump PR here; merging it moves the front door. Objects are immutable
    and keys are version-scoped, so a changed key is the only signal Terraform needs — which
    is also why there is no `source_code_hash` anywhere in this module.

    WHY TWO ZIPS FROM ONE VERSION. Nievah ships one ~30 KB zip to both of its functions
    because both need the same seven stdlib-only files. Caldrith cannot: the reconcile
    function carries githubkit, pydantic(-core), pydantic-settings, PyNaCl, Jinja2, PyYAML,
    structlog and wcmatch — tens of megabytes with compiled wheels in it — while the producer
    needs `caldrith.api.security`, which is `hmac` and `hashlib`. The last three of those are
    the ones a shortened list drops, and each is a ModuleNotFoundError on the first invocation
    rather than a build failure; lambda.tf says which module imports which. Handing that bundle to the function on GitHub's 10-second clock
    would buy nothing and spend cold-start time downloading and unpacking it.

    WHY BOTH KEYS ARE UNDER `edge/`. `modules/artifacts` scopes the OIDC publish role to
    `$${bucket}/edge/*` (the `$$` is an ESCAPE — HCL interpolates `$${...}` inside a heredoc
    exactly as it does inside a quoted string, and an unescaped `$${bucket}` here is not a
    plan-time error but an INIT-time one: `terraform init` cannot read the config far enough to
    decide which providers to install, so nothing in the stack runs at all), and that module is
    shared with nievah — a `reconcile/` prefix would
    have the publish workflow fail with AccessDenied on the second upload, having already
    succeeded on the first, leaving a half-published version that Terraform would happily
    point a function at. A suffix inside the granted prefix needs no change to a shared
    module.
  EOT
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every resource name. Change it to stand a second stack alongside."
  type        = string
  default     = "caldrith"
}

variable "localstack" {
  description = <<-EOT
    Target LocalStack rather than AWS. This is not a cosmetic switch — it removes the
    resources the free LocalStack image cannot honour, and each removal is a real gap in what
    a local run proves:

      API Gateway HTTP API  Paid feature on LocalStack free. Locally, requests go straight
                            to a Lambda Function URL instead (see lambda.tf). Format 2.0 is
                            the same event shape, so the handler, routing, and signature
                            checks are identical. What is NOT covered is API Gateway's own
                            config: the throttle, the $default stage, the integration — and
                            the throttle is this stack's only real-time cost control.
      Budgets / Chatbot     Neither is modelled. Both are skipped locally.

    Everything else — Lambda, SQS FIFO, DynamoDB conditional writes, S3, SSM, IAM — runs for
    real, which covers the whole ingest-to-reconcile path except the GitHub calls themselves.
  EOT
  type        = bool
  default     = false
}

variable "domain_name" {
  description = <<-EOT
    Custom hostname for the front door, e.g. "hooks-caldrith.magmamoose.com". Leave EMPTY to
    use the API's own *.execute-api.<region>.amazonaws.com name, which is what the first
    deploy should do: the GitHub App's webhook URL can be repointed in one field at any time,
    and an empty value keeps this stack from needing a certificate or a DNS record before it
    has ever received a request.
  EOT
  type        = string
  default     = ""
}

variable "enable_custom_domain" {
  description = <<-EOT
    Create the API Gateway custom domain and its API mapping. Requires `domain_name`, and
    requires the certificate to have reached ISSUED first — see the two-phase note in api.tf.

    Default false because phase 1 (requesting the certificate) and phase 2 (using it) are
    separated by a DNS record that lives in another Terraform state, so they cannot be one
    apply. Flipping this early fails with a BadRequestException naming the certificate.
  EOT
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = <<-EOT
    An EXISTING regional ACM certificate to use instead of the one this module requests.
    Normally empty: setting `domain_name` makes the module request its own (see api.tf), which
    is one less thing to create by hand. Supply this only to reuse a certificate managed
    elsewhere.
  EOT
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = <<-EOT
    Log retention for all three functions. Set explicitly because the default is NEVER EXPIRE:
    a log group Lambda creates for itself grows without limit.

    READ THIS BEFORE TUNING IT. Retention caps STORAGE ($0.03/GB-month), which is not the
    exposure here. INGESTION is $0.50/GB with a 5 GB always-free allowance, it is charged the
    moment a line is written, and NO retention setting reduces it by a byte. The reconcile
    function is the chatty one — structlog emits a JSON line per tier per repo, so a
    full-account reconcile of a large org writes thousands of lines in a burst — and the 5 GB
    is an ORGANISATION-wide allowance shared with nievah, not a per-account one.

    So: shortening this saves storage pennies. The thing that actually protects the ingestion
    allowance is Caldrith converging — a tier that re-drifts on every pass turns the reactive
    drift events into a write/event/write pump that logs for ever (see COMMON_MISTAKES, "the
    deep diff is desired-driven at EVERY level"). Two weeks is longer than any incident takes
    to diagnose.
  EOT
  type        = number
  default     = 14
}

variable "jobs_retention_seconds" {
  description = <<-EOT
    How long the jobs queue holds work nothing has taken. SQS's maximum is 14 days and that is
    what this is set to — it is a ceiling on how long an outage (GitHub's, or this stack's)
    can last before reconcile jobs begin evaporating, and there is no reason to choose a lower
    one. Also used for both DLQs, where the whole point is having time to notice and redrive.
  EOT
  type        = number
  default     = 1209600
}

variable "stale_jobs_alarm_seconds" {
  description = <<-EOT
    Age of the oldest untaken job that means reconciles have stopped happening.

    THE SINGLE MOST USEFUL ALARM IN THIS STACK, and it earns that twice over now that Caldrith
    is serverless. It fires from outside the function, so it still fires when the function is
    the broken thing — throttled by the account concurrency cap, its event source mapping
    disabled, or every invocation timing out. It is ALSO the de facto "reconcile is failing"
    alarm: a job that raises is returned to the queue and keeps ageing, so a persistent
    failure trips this in 15 minutes rather than waiting hours for the DLQ to fill. That is
    why there is no separate reconcile-errors alarm — see the alarm budget in notify.tf.

    15 minutes is comfortably longer than the slowest legitimate job (a full-account fan-out).
  EOT
  type        = number
  default     = 900
}

variable "reconcile_timeout_seconds" {
  description = <<-EOT
    Wall clock for one reconcile job.

    Sized for the slowest REAL job rather than Lambda's 900s maximum, because this number is
    doing two jobs at once. It is the deadline for a repo whose tiers make ~100 GitHub calls
    (the `files` tier alone can read, branch, commit and open a PR), and — because
    `queues.tf` derives the jobs queue's visibility timeout as 6x this — it is also what sets
    how long a poison message is invisible between retries. Raising it to 900 would make a
    stuck message invisible for 90 minutes at a time and stretch the redrive budget from
    ~5 hours to ~15, delaying the DLQ alarm by most of a working day.

    300s is ~10x the expected duration of a single-repo reconcile. Raise it with a measured
    duration in hand, not a guess, and re-read the arithmetic in queues.tf when you do.
  EOT
  type        = number
  default     = 300

  # Lambda's hard ceiling is 900s; above it the apply fails with an InvalidParameterValueException
  # naming the function. Caught here instead, because the number that actually matters is 6x this
  # one — the jobs queue's visibility timeout — and reading a Lambda error while thinking about a
  # queue is how the pairing in queues.tf gets missed.
  validation {
    condition     = var.reconcile_timeout_seconds > 0 && var.reconcile_timeout_seconds <= 900
    error_message = "reconcile_timeout_seconds must be between 1 and 900 (Lambda's maximum). Note that queues.tf derives the jobs queue visibility timeout as 6x this value."
  }
}

variable "reconcile_memory_mb" {
  description = <<-EOT
    Memory for the reconcile function. Lambda scales CPU with memory, and this function's
    cold start imports githubkit + pydantic + Jinja2 + PyYAML — pydantic-core alone is a
    compiled extension whose import cost is CPU-bound — so a low setting is slower AND, since
    billing is GB-seconds, not obviously cheaper.

    1024 MB is the flat part of that curve. At Caldrith's volume the whole function is a
    rounding error against Lambda's always-free 400,000 GB-seconds a month.
  EOT
  type        = number
  default     = 1024
}

variable "reconcile_max_concurrency" {
  description = <<-EOT
    How many reconcile jobs may run at once, capped on the event source mapping.

    THIS IS A GITHUB CONTROL BEFORE IT IS AN AWS ONE. GitHub's secondary rate limits punish
    CONCURRENT requests against one account — the documented guidance is no more than 100
    concurrent requests and to avoid running many mutating requests in parallel — and a
    full-account fan-out enqueues one job per repo at once. Uncapped, a 200-repo org would
    ask Lambda for 200 simultaneous reconciles, every one of them hammering the same
    installation's token, and GitHub would start returning 403 with a retry-after. Those
    failures are indistinguishable from a bug until you read the response body.

    It is also the Lambda-side cost control. `reserved_concurrent_executions` is NOT set (see
    lambda.tf: a new account's total concurrency quota is 10 and AWS refuses any reservation
    that leaves fewer than 10 unreserved), so this is the lever that always works.

    AND IT IS THE REAL COST CEILING OF THE STACK — `var.throttle_rate_limit` is not, whatever an
    earlier version of that variable claimed. The gateway throttle bounds INGRESS; this bounds
    WORK, and one admitted request can become hundreds of jobs. The arithmetic, worst case:
    5 concurrent invocations at `var.reconcile_memory_mb` = 1024 MB is 5 GB-seconds per second,
    ~13.0M GB-seconds over a 30-day month, and after Lambda's always-free 400,000 GB-s that is
    roughly $170 a month at the arm64 rate — about 65x the ~$2.59 the gateway throttle bounds.
    It needs the jobs queue saturated for a sustained period, so it is not likely; on a
    personally-funded account it is still the number to know, because $5-6/day is the burn rate
    until somebody notices. Note that `jobs_stale` does NOT cover this case: a drift loop the
    pollers keep up with never ages the queue, so nothing here alarms. What surfaces it is the
    budget guard's ACTUAL threshold, within a day rather than at month end. 5 x 512 MB halves
    the exposure and is a deliberate choice available at any time.

    Minimum accepted by AWS is 2. Five is roughly two minutes to walk a 200-repo org, which
    is fast enough for a config-as-code tool and slow enough to stay well inside GitHub's
    concurrency guidance.
  EOT
  type        = number
  default     = 5

  # AWS accepts 2..1000 for an event source mapping's maximum_concurrency. 1 looks like the
  # obvious way to serialise everything and is rejected — serialising is the FIFO message
  # group's job (queues.tf), not this one's.
  validation {
    condition     = var.reconcile_max_concurrency >= 2 && var.reconcile_max_concurrency <= 1000
    error_message = "reconcile_max_concurrency must be between 2 and 1000; AWS rejects 1 on an event source mapping's scaling_config. Same-repo serialisation comes from the FIFO message group, not from this."
  }
}

variable "github_api_url" {
  description = <<-EOT
    REST API base URL, passed to the reconcile function as `GITHUB_API_URL`. Configurable
    rather than hardcoded because GHES is on Caldrith's roadmap and `api.github.com` appears
    nowhere in its source for the same reason — see CLAUDE.md. Changing it here is the whole
    of the infrastructure side of that move.
  EOT
  type        = string
  default     = "https://api.github.com"
}

variable "extra_registrations" {
  description = <<-EOT
    ADDITIONAL GitHub App registrations beyond the default one — each a separate App on a
    separate host: a `*.ghe.com` tenancy, or a GHES instance.

    SLUGS, URLS AND PARAMETER NAMES ONLY. Every field is a name or a URL and none of them is a
    credential, so a secret in this variable is not merely discouraged, it is unrepresentable
    — which is the point, because a `.hcl` input becomes a value in Terraform state and this
    stack's whole security argument (module iam.tf) rests on that state holding no credential.

    THE DEFAULT REGISTRATION IS NOT IN THIS LIST AND MUST NEVER BE. `caldrith.registration`
    hardcodes `DEFAULT_REGISTRATION = "github"`: its webhook path is `/`, and its secrets are
    the four FLAT, unprefixed parameters under the secret path. Those are live in 483461801743
    right now. A `github` entry here would derive a second, slug-prefixed webhook-secret
    parameter that nobody has written — and `producer._secret_param_for` short-circuits on the
    default slug before it ever reads the map, so the entry would be inert while looking
    authoritative in the console. The validation below refuses it.

    WHAT EACH FIELD BECOMES, and every one of these shapes is a contract with code that is
    already deployed rather than a convention this module chose:

      slug                  The webhook path segment: the App points at
                            https://<front-door>/h/<slug>. `registration_from_path` returns
                            null for anything outside ^[a-z0-9][a-z0-9-]{0,31}$ and the
                            producer then answers 404 — which GitHub does not retry and does
                            not alarm on. Validated here so a bad slug is a failed plan rather
                            than a silent fleet of lost deliveries.
      api_url               REST base for that host. `https://api.<sub>.ghe.com` for a ghe.com
                            tenancy, `https://<host>/api/v3` for GHES. It travels INSIDE the
                            per-registration JSON; `var.github_api_url` remains the DEFAULT
                            registration's own and is not repurposed for this.
      app_id_param          SSM parameter NAMES, and all three are OPTIONAL. Left empty — the
      private_key_param     normal case — the module derives the natural extension of the
      webhook_secret_param  existing path: one extra segment per slug, giving
                            <secret_path>/<slug>/app-id, /private-key and /webhook-secret.
                            Set one only to point at a parameter managed elsewhere, and give
                            it a LEADING SLASH: iam.tf builds each ARN by concatenating the
                            name onto an `…:parameter` prefix, so a name without one produces
                            a malformed ARN that grants nothing and reads as AccessDenied.

    TERRAFORM CREATES NONE OF THOSE PARAMETERS, exactly as it creates none of the default
    registration's. `output "secret_parameter_names"` is the operator's create-list and the
    runbook is docs/ghe-onboarding.md in MagmaMoose/caldrith — including the cold-start step
    after writing them, which is the one that gets missed.
  EOT
  type = list(object({
    slug                 = string
    api_url              = string
    app_id_param         = optional(string, "")
    private_key_param    = optional(string, "")
    webhook_secret_param = optional(string, "")
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.extra_registrations : can(regex("^[a-z0-9][a-z0-9-]{0,31}$", r.slug))
    ])
    error_message = "Every extra_registrations slug must match ^[a-z0-9][a-z0-9-]{0,31}$ — the alphabet caldrith.registration.valid_slug enforces. Outside it, registration_from_path returns null and the producer answers 404 to every delivery for that App, which GitHub neither retries nor reports anywhere but the App's Advanced tab."
  }

  validation {
    condition     = !contains([for r in var.extra_registrations : r.slug], "github")
    error_message = "The slug 'github' is caldrith.registration.DEFAULT_REGISTRATION, served by the flat WEBHOOK_SECRET_PARAM / APP_ID_PARAM / PRIVATE_KEY_PARAM parameters that are live in this account. An entry for it here does NOT swap the default cleanly — it splits it: the producer short-circuits on the default slug before reading REGISTRATION_SECRET_PARAMS, so it keeps verifying against the flat webhook secret, while AppConfig.registry lets an explicit 'github' entry WIN over the synthesized default, so the reconcile side switches to slug-prefixed app-id and private-key parameters nobody has written. Half-swapped credentials, applied clean. If the default really must move to the list form, do it deliberately in caldrith.settings, not from here."
  }

  validation {
    condition     = length(distinct([for r in var.extra_registrations : r.slug])) == length(var.extra_registrations)
    error_message = "extra_registrations slugs must be unique: the module keys two maps and three ARN lists by slug, and a duplicate means one registration's parameter names silently replace the other's."
  }

  validation {
    condition     = alltrue([for r in var.extra_registrations : startswith(r.api_url, "https://")])
    error_message = "Every extra_registrations api_url must be https://. The reconcile function sends an App JWT and an installation token to this host on every call; over http they are readable in transit."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.extra_registrations : [
        for name in [r.app_id_param, r.private_key_param, r.webhook_secret_param] :
        name == "" || startswith(name, "/")
      ]
    ]))
    error_message = "An explicit SSM parameter name must be absolute (leading slash). iam.tf builds each ARN by concatenating the name onto the ':parameter' prefix, so a relative name yields a malformed ARN: the apply succeeds, the grant matches nothing, and every read fails AccessDenied. Leave the field empty to have the module derive the name instead."
  }
}

variable "admin_repo" {
  description = <<-EOT
    Name of the admin (config) repository holding `.github/settings.yml`, passed through as
    `ADMIN_REPO`.

    It is also the repo Caldrith REFUSES to manage: `selection.builtin_excludes` drops it from
    every target list, which is why a settings PR is previewed by `preview_config` and never
    by a dry-run reconcile (COMMON_MISTAKES, "the PR preview is NOT run_reconcile(dry_run=
    True)"). Getting this wrong does not error — it silently changes which repository is
    exempt from management.
  EOT
  type        = string
  default     = "admin"
}

variable "ops_email" {
  description = "Address subscribed to the ops topic. Empty to skip. AWS emails a confirmation link."
  type        = string
  default     = ""
}

variable "slack_workspace_id" {
  description = <<-EOT
    AWS Chatbot workspace id, for alarms in Slack. Empty to skip.

    EMPTY BY DEFAULT FOR A REASON THAT IS NOT CAUTION. Chatbot authorises a Slack workspace
    PER AWS ACCOUNT through an OAuth flow in the console, and Terraform cannot perform it.
    The authorisation nievah's front door uses lives in 666802049426 and the cost report's in
    857256953358; neither grants anything in 483461801743. Setting this before doing the
    handshake in Caldrith's own account fails the apply on
    `aws_chatbot_slack_channel_configuration` — which is the right failure, but it is a
    wasted round trip, and `ops_email` already means no alarm goes unread.
  EOT
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack channel id for alarms, e.g. C0123456789. Required with slack_workspace_id."
  type        = string
  default     = ""
}

variable "throttle_rate_limit" {
  description = <<-EOT
    Steady-state requests per second the front door will accept, across all callers.

    IT BOUNDS THE GATEWAY'S OWN BILL AND NOTHING ELSE. This variable used to claim it was
    "the cost ceiling for everything behind the gateway", and that claim was wrong by about two
    orders of magnitude, so it is worth being precise. A request rejected with 429 is rejected
    by API Gateway itself: it never reaches Lambda, never becomes an SQS message, never claims a
    DynamoDB row and never becomes a GitHub API call. What does NOT follow is that admitted
    requests and downstream work are proportional. THEY ARE NOT: one `push` on the admin repo
    fans out one reconcile job per managed repo (lambda.tf), so a single admitted request can
    become hundreds of jobs. The lever that actually bounds Lambda spend is
    `var.reconcile_max_concurrency` on the jobs event source mapping — the arithmetic is there,
    and it is the largest single exposure in this stack.

    WHAT THIS NUMBER DOES BOUND: AWS prices HTTP APIs "per million requests received" and does
    not document whether a request the gateway throttles is counted. Both readings have to be
    survivable, so:

      if 429s are NOT billed   the gateway bill is the requests that get through: 1/s is 2.59M
                               a month (1 * 86400 * 30) = about $2.59 at $1.00/million, and
                               that is the GATEWAY ceiling, full stop.
      if 429s ARE billed       this bounds nothing at the gateway, and a flood costs whatever
                               the attacker is willing to send. The controls for that reading
                               are `aws_cloudwatch_metric_alarm.api_flood` (minutes) and
                               `aws_budgets_budget.guard` (hours to a day), not this.

    Nievah sets 2/s; Caldrith is set to 1/s because it is quieter and because Caldrith's own
    traffic is bursty in a way that is SELF-INFLICTED rather than external — every write it
    makes echoes back as a drift webhook. Real traffic is ~0.011 requests per second, so 1/s
    is ~90x headroom over steady state.

    Raise it only with a number in hand for what actually needs the headroom, and re-read
    `api_flood_alarm_hourly_count` when you do — the two are validated against each other.
  EOT
  type        = number
  default     = 1
}

variable "throttle_burst_limit" {
  description = <<-EOT
    Instantaneous burst allowed above the rate limit. GitHub redelivers in bursts and a single
    admin-repo push can produce a small flurry of events, so this is what stops a legitimate
    backlog replay being throttled. Bursts drain at `throttle_rate_limit`, so this does not
    raise the sustained ceiling — and a webhook GitHub cannot deliver is one Caldrith's next
    reconcile converges anyway, which is why 5 is enough here where nievah needed 10.
  EOT
  type        = number
  default     = 5
}

variable "api_flood_alarm_hourly_count" {
  description = <<-EOT
    Requests in one hour that mean something is wrong. THE FLOOD DETECTOR — the control this
    stack was missing, and the only one that watches the gateway itself rather than what the
    gateway lets through.

    IT CATCHES CALDRITH BEFORE IT CATCHES AN ATTACKER. Caldrith's writes echo back to it as
    webhooks: a repo edit is a `repository` event, a label write is a `label` event. That
    terminates only because a re-reconcile finds no drift and issues no write. A tier that
    re-drifts on every pass — the exact bug documented in COMMON_MISTAKES under "the deep diff
    is desired-driven at EVERY level", which really did re-PATCH every repository on every
    reconcile — turns that into a self-sustaining loop billed at every layer at once. No other
    alarm here sees it: the queues drain fine, nothing errors, nothing ages. The request count
    is the only place it shows.

    WHY 1,000 AND NOT 10,000, WHICH WAS THE FIRST NUMBER PROPOSED. It depends on whether the
    `Count` metric includes requests the stage throttled, which AWS does not document either:

      if Count EXCLUDES 429s   the throttle caps an hour at `throttle_rate_limit * 3600` =
                               3,600 requests. A 10,000 threshold could then NEVER be
                               crossed — the alarm would be created, sit in OK for ever, and
                               report healthy through any flood. That is worse than no alarm,
                               because it looks like coverage.
      if Count INCLUDES 429s   10,000 works, but fires later than it needs to.

    1,000 is correct under BOTH readings: below the 3,600 ceiling so it stays reachable, and
    25x the busiest realistic hour (~40 requests) so it does not cry wolf. The `validation`
    below keeps that property true if either number is ever changed alone.
  EOT
  type        = number
  default     = 1000

  # Cross-variable validation, Terraform >= 1.9 (see versions.tf). This is the whole reason
  # the floor is 1.9: without it, raising the flood threshold or lowering the throttle turns
  # the alarm into decoration at some later date, silently, and nothing fails.
  validation {
    condition     = var.api_flood_alarm_hourly_count < var.throttle_rate_limit * 3600
    error_message = "api_flood_alarm_hourly_count must be below throttle_rate_limit * 3600, or the alarm can never fire: the stage throttle caps an hour at that many requests. Lower the threshold or raise the throttle."
  }
}

variable "monthly_budget_usd" {
  description = <<-EOT
    Spend that should never be reached, in USD. Two AWS Budgets are free per account and this
    is prd-caldrith's first, so the guard itself costs nothing. (Beyond two, AWS charges
    $0.02/budget/day — a third would be its own small surprise bill.)

    Expected steady state is a few cents: everything here is inside a permanent always-free
    allowance except API Gateway requests and the overflow bucket. A dollar is therefore
    roughly thirty times the expected bill and still small enough to notice immediately.

    The FORECASTED alert at 50% is the one that gives useful warning: on a stack that should
    cost pennies, a month trending toward fifty cents already means something changed. AWS
    Budgets can lag several hours to a day, which is why the API Gateway throttle and the
    flood alarm — enforced and evaluated in near real time — are the actual controls and this
    is the backstop.
  EOT
  type        = number
  default     = 1
}

variable "entitlement_enforce" {
  description = <<-EOT
    Whether an unentitled account is actually REFUSED, as opposed to merely logged.

    Leave false until the entitlements table has a row for every account that should keep
    working — the table is created empty, so arming this in the same apply that creates it
    stops every existing installation at once. False runs the identical code path and emits
    `reconcile.entitlement_observed` for each account it would have refused, which is the
    list you seed from.
  EOT
  type        = bool
  default     = false
}
