# Dün Mir's backend on AWS: a Lambda behind an API Gateway HTTP API, an RDS Postgres it can
# reach and nothing else can, a Cognito pool the BROWSER talks to, and an S3 bucket for
# encrypted device backups.
#
# The console stays on Cloudflare. Only the API is here.
#
# WHAT MAKES THIS FREE, AND THE ONE THING THAT DOES NOT
#   Lambda, Cognito, EventBridge Scheduler and CloudWatch Logs are all on ALWAYS-free allowances
#   this workload will not approach. API Gateway, ECR and S3 are twelve-month tiers whose
#   post-expiry cost is cents at this scale. RDS is the one that matters: free for twelve months
#   and about $15/month after — and per `../../../provider.hcl`, a member account inside the
#   existing organisation has ALREADY spent those twelve months. Read that file before creating
#   the account.
#
# THE SHAPE THAT MAKES IT WORK
#   The function sits in a VPC with **no NAT gateway and no interface endpoints**, because both
#   are billed by the hour. It therefore has no route to the internet, and the application was
#   built around that: the browser talks to Cognito directly and the backend only verifies the
#   resulting JWT offline, against a JWKS Terraform reads once at apply time. S3 is reached
#   through a gateway endpoint, which is free. Nothing else is reached at all.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/dunmir-platform"
}

generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TF
provider "aws" {
  region              = "${local.region_vars.locals.region}"
  allowed_account_ids = ${jsonencode(compact([local.provider_vars.locals.account_id]))}

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "dunmir"
      Component = "platform"
    }
  }
}
TF
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
  provider_vars    = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
}

inputs = {
  region      = local.region_vars.locals.region
  environment = local.environment_vars.locals.environment

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # THIS LINE IS THE DEPLOYMENT.
  #
  # Dün Mir's AWS deploy workflow builds `docker-bake.hcl`'s `lambda` target, pushes it to ECR in
  # THIS account, and prints the exact line to paste here. Changing it is what moves the backend;
  # nothing else does.
  #
  # It must be an ECR repository in this account and region — Lambda cannot pull from GHCR, which
  # is why the `lambda` bake target is deliberately outside the `default` group that publishes
  # there.
  #
  # Prefer a digest over a tag for production: Lambda resolves a tag once, at update time, so
  # re-pushing the same tag does NOT redeploy and the function silently keeps running whatever it
  # resolved months ago.
  #
  # COLD START: this must name an image that ALREADY EXISTS. Run the deploy workflow once, then
  # set this to what it produced.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  image_uri = ""

  # ── the database ────────────────────────────────────────────────────────────────────────────
  # "rds" creates a db.t4g.micro. See ../../../provider.hcl for what that costs and when.
  db_mode = "rds"

  # ── the public entrypoint ───────────────────────────────────────────────────────────────────
  #
  # TWO-PHASE, like the chargate broker. Phase 1: leave `enable_custom_domain` false; the module
  # requests the certificate and outputs its DNS validation record. Create that record in
  # Cloudflare (DNS-only), wait for ACM to report ISSUED, then flip the flag and apply again.
  # A custom domain cannot be created against a certificate still PENDING_VALIDATION.
  #
  # Phase 2 also closes the gateway's own `*.execute-api` hostname, so the custom domain becomes
  # the only way in rather than merely the pretty way in.
  #
  # The `api.` record is a CNAME to `api_domain_target` and must be **DNS-only (grey cloud)**:
  # proxying it would put Cloudflare in front of a hostname whose certificate ACM issued for
  # that exact name. It also sidesteps the two-label-hostname trap entirely — Cloudflare's
  # Universal SSL covers one label, `api.dunmir.magmamoose.com` is two, and here Cloudflare
  # terminates nothing.
  api_domain_name      = "api.dunmir.magmamoose.com"
  enable_custom_domain = false

  # Credentialed CORS forbids a `*` origin, so a wrong value fails CLOSED — every call from the
  # console is blocked by the browser with nothing in the network tab looking wrong.
  frontend_origin = "https://dunmir.magmamoose.com"

  # ── identity ────────────────────────────────────────────────────────────────────────────────
  #
  # "ON" is a one-way door in Cognito: a pool will not move to required MFA once it has users
  # without a factor. The product has always had mandatory MFA; Cognito is replacing the
  # mechanism, not the policy.
  cognito_mfa = "ON"

  # Empty = anyone may sign up and found their own workspace, which is the hosted product. Set a
  # comma-separated domain list to close it. Enforced by the BACKEND, not by the pool — Cognito
  # has no such policy — so a stranger can create a pool account and simply never resolve to a
  # workspace.
  signup_allowed_domains = ""

  # ── where the alarms and the budget go ──────────────────────────────────────────────────────
  #
  # The budget is $1, not a sensible operating budget: the whole premise is that this stack is
  # free, so any charge is news. AWS sends the SNS confirmation link exactly once — until it is
  # clicked the subscription is pending and delivers nothing, which Terraform reports as
  # "created" either way.
  ops_email           = "caleb@magmamoose.com"
  enable_budget_alarm = true
}
