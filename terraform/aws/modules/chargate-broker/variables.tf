variable "region" {
  description = <<-EOT
    Region holding the function, the API and the parameters. Supplied by the leaf from
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
    Environment segment of the SSM secret path, e.g. `/chargate/prod/app-id`. Supplied by the
    leaf from `environment.hcl`. Deliberately NOT `terraform.workspace`: Terragrunt runs every
    leaf in the "default" workspace, so using it would collapse prod and any future environment
    onto one path.
  EOT
  type        = string
  default     = "prod"
}

variable "name_prefix" {
  description = "Prefix for every resource name. Change it to stand a second stack alongside."
  type        = string
  default     = "chargate"
}

variable "artifact_bucket" {
  description = <<-EOT
    Bucket holding the published Lambda zip. Created by the `artifacts` leaf, which MUST be
    applied first — this leaf takes it as a dependency output rather than hardcoding it so the
    ordering is expressed in the graph rather than in a runbook.
  EOT
  type        = string
}

variable "artifact_prefix" {
  description = <<-EOT
    Key prefix inside the artifact bucket. Must match both what chargate's release workflow
    publishes to (`package-feed-url: s3://<bucket>/broker`) and the prefix the publish role is
    scoped to in the `artifacts` leaf. Three places, one value — they are wired together by the
    leaf rather than by three independent literals.
  EOT
  type        = string
  default     = "broker"
}

variable "broker_artifact_version" {
  description = <<-EOT
    Which published zip to run, e.g. "2.12.0". Resolves to `<artifact_prefix>/<version>.zip`.

    THIS LINE IS THE DEPLOYMENT. Chargate's release workflow publishes the object and prints
    the line to change here; merging that change moves the broker. Objects are immutable and
    keys are version-scoped, so a changed key is the only signal Terraform needs — which is
    also why there is no `source_code_hash` anywhere in this module.

    Chargate only publishes when the zip's inputs actually CHANGED (the release workflow gates
    on `build_lambda_zip.py --changed-since <previous tag>`). Most chargate releases are CLI
    changes that touch nothing in `broker/`, and a bump per release would be a stream of PRs
    redeploying byte-identical code until nobody read them.
  EOT
  type        = string
}

variable "domain_name" {
  description = <<-EOT
    Custom hostname for the broker, e.g. "broker-chargate.magmamoose.com".

    MUST BE A FIRST-LEVEL SUBDOMAIN if it is to be Cloudflare-proxied on the free plan:
    Universal SSL covers the apex and one label only, so `broker.chargate.magmamoose.com`
    would need Advanced Certificate Manager (~$10/month) while `broker-chargate…` is free.
    Nievah and caldrith are both stuck two labels deep for exactly this reason.

    Leave EMPTY to use the API's own execute-api name, which is what the first apply should do.
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
    Normally empty: setting `domain_name` makes the module request its own (see api.tf).
    Supply this only to reuse a certificate managed elsewhere.
  EOT
  type        = string
  default     = ""
}

variable "disable_default_endpoint" {
  description = <<-EOT
    Turn off the API's own `*.execute-api.<region>.amazonaws.com` hostname, making the custom
    domain the only way in.

    THIS IS WHAT MAKES THE CLOUDFLARE PROXY MEAN ANYTHING. Proxying the custom domain hides the
    origin from a `dig`, but the execute-api hostname stays reachable and answers identically —
    so without this, an attacker who finds it bypasses Cloudflare entirely and the proxy stops
    being a cost control. Certificate Transparency logs make the custom domain discoverable in
    principle, so treat the origin as findable rather than secret.

    Default false so the FIRST apply (before any DNS exists) still has a reachable endpoint to
    smoke-test against. Flip it true in phase 2, together with `enable_custom_domain`.

    The trade: once true, a broken DNS record or an expired certificate is a total outage
    rather than a degraded one. Both are one field away from reversible.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = <<-EOT
    Lambda log retention. Set explicitly because the default is NEVER EXPIRE: a log group
    Lambda creates for itself grows without limit, and CloudWatch Logs' free allowance is 5 GB
    stored — shared across the whole AWS organization, not granted per account. Two weeks is
    longer than any incident here takes to diagnose.
  EOT
  type        = number
  default     = 14
}

variable "throttle_rate_limit" {
  description = <<-EOT
    Steady-state requests per second the front door will accept, across all callers.

    THIS IS THE DETERMINISTIC HALF OF THE COST CEILING. Requests over it are rejected by the
    gateway with 429 and never reach Lambda, so they cost a gateway request rather than a
    request AND an invocation — which caps compute, logs and egress exactly, at every load.

    Real traffic is one call per pull-request run: a few hundred a month, i.e. ~0.0001 rps.
    2/s is four orders of magnitude of headroom and still absorbs any CI matrix burst.

    What it does NOT bound is the gateway's own request bill, because AWS does not document
    whether it charges for the 429s it issues. That is what the Cloudflare proxy and the
    account-level quota decrease (magmamoose/infra#642) are for.
  EOT
  type        = number
  default     = 2
}

variable "throttle_burst_limit" {
  description = "Instantaneous burst above the rate limit. Drained at `throttle_rate_limit`, so it does not raise the sustained ceiling."
  type        = number
  default     = 10
}

variable "memory_size" {
  description = <<-EOT
    Chosen for COLD START rather than steady state: Lambda scales CPU with memory, and this
    function imports `cryptography` (a multi-megabyte compiled extension) before it can do
    anything. At this invocation rate the entire monthly compute is a rounding error against a
    400,000 GB-second allowance, so paying for a faster import is free in practice.
  EOT
  type        = number
  default     = 1024
}

variable "timeout" {
  description = <<-EOT
    Two transatlantic GitHub round trips (installation lookup, then mint) plus a possible JWKS
    fetch on a cold isolate. 15s is generous for that and still well inside the API's own
    integration timeout, so the FUNCTION's error surfaces rather than the gateway's.
  EOT
  type        = number
  default     = 15
}

variable "ops_email" {
  description = "Address subscribed to the ops topic. Empty to skip. AWS emails a confirmation link."
  type        = string
  default     = ""
}

variable "slack_workspace_id" {
  description = <<-EOT
    AWS Chatbot workspace id, for alarms in Slack. Empty to skip.

    THE WORKSPACE MUST BE AUTHORISED BY HAND IN THIS ACCOUNT'S CHATBOT CONSOLE FIRST — it is an
    OAuth handshake Terraform cannot perform, and it is per-AWS-account. Nievah's account being
    authorised does nothing for this one. Chatbot itself is free.
  EOT
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack channel id for alarms, e.g. C0123456789. Required with slack_workspace_id."
  type        = string
  default     = ""
}

variable "busy_alarm_requests_per_15min" {
  description = <<-EOT
    Requests in 15 minutes that mean something is wrong. Real traffic is a few hundred a MONTH,
    so 100 in a quarter of an hour is two orders of magnitude above anything legitimate and
    still far below anything that costs money.

    This is a notification, not a control — nothing acts on it. It exists because the
    deterministic throttle bounds the Lambda bill and not the gateway bill, so the only thing
    standing between a sustained flood and a surprise is somebody noticing.
  EOT
  type        = number
  default     = 100
}

variable "monthly_budget_usd" {
  description = <<-EOT
    Spend that should never be reached, in USD. Two budgets are free per account.

    Expected steady state is under a cent: API Gateway requests plus a few megabytes of S3.
    A dollar is therefore ~100x the expected bill and still small enough to notice.

    NOT A LIMIT. AWS Budgets cannot stop spend — they refresh at most three times a day, 8-12
    hours apart, and AWS's own documentation says you "might incur additional costs [...] before
    AWS Budgets can notify you". The real-time controls are the stage throttle and the
    Cloudflare proxy; this is the receipt that says one of them failed.
  EOT
  type        = number
  default     = 1
}
