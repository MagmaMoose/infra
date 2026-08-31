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

# The apply ordering, expressed in the graph rather than in a runbook. The mock lets
# `validate`/`plan`/`init` run before ../artifacts exists; an apply cannot proceed on a mock.
dependency "artifacts" {
  config_path = "../artifacts"

  mock_outputs = {
    artifact_bucket = "mock-artifact-bucket"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  region      = local.region_vars.locals.region
  environment = local.environment_vars.locals.environment

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # THIS LINE IS THE DEPLOYMENT.
  #
  # MagmaMoose/dunmir's release workflow builds the zip with
  # `backend/scripts/build_lambda_zip.py` and publishes it to
  # `s3://<artifact_bucket>/backend/<version>.zip` using the OIDC role from the sibling
  # `artifacts` leaf. Setting this to that version is what moves the backend; nothing else does.
  #
  # The object at a given key is IMMUTABLE — diatreme refuses to overwrite one that exists — so
  # the key change is the deploy signal and no `source_code_hash` is needed. It also means a
  # rollback is a one-line revert to a key still holding exactly the bytes that were reviewed.
  #
  # COLD START: this must name a version that ALREADY EXISTS. ../artifacts was applied first and
  # `backend/0.0.26.zip` was published by hand into it (the module's own header documents that
  # bootstrap, because the front door cannot come up before something is there to run). From the
  # next release onward this is bumped by a reviewed PR and nothing else changes.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  artifact_version = "0.0.28"

  # Wired from the sibling leaf rather than hardcoded, so a bucket rename cannot leave this
  # pointing at a bucket that no longer exists while still planning cleanly.
  artifact_bucket = dependency.artifacts.outputs.artifact_bucket

  # Must agree with `artifact_prefix` in ../artifacts, which is what the publish role's IAM
  # policy is scoped to.
  artifact_prefix = "backend"

  # ── the database ────────────────────────────────────────────────────────────────────────────
  #
  # DYNAMODB, and this is the single most important line in the file.
  #
  # It is the only database on AWS that is free FOREVER, and this organisation has no 12-month
  # allowances at all — AWS replaced that free tier on 2025-07-15 and the payer signed up
  # 2025-09-18, two months after the cutover (recorded in modules/caldrith-frontdoor/api.tf).
  # A db.t4g.micro would therefore bill ~$15/month from its first hour, with no devices and no
  # users, which is the definition of a surprise bill.
  #
  # It is not Postgres, which is why `dunmir_control_plane/store/` exists: the application asks
  # for what it wants by name and each backend answers in its own terms, so Kubernetes keeps
  # Postgres and this keeps its free tier, from one codebase.
  #
  # The capacity is TIGHT and the allowance is shared across the whole organisation — see
  # modules/dunmir-platform/database_dynamo.tf for the arithmetic. Four sibling tables already
  # hold about half of it.
  db_mode = "dynamodb"

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
  # FALSE, AND NOT BECAUSE PHASE 2 FAILED — it worked. Reverted because
  # `api.dunmir.magmamoose.com` IS THE LIVE KUBERNETES PRODUCT'S API, served
  # through the Cloudflare tunnel in `cloudflare/zero-trust/prod/tunnels.tf` to
  # `dunmir-backend.dunmir-pro.svc.cluster.local:8000`. Attaching it here and
  # pointing DNS at API Gateway is not a deployment step, it is a CUTOVER: it
  # moves every existing operator and every deployed agent onto a database that
  # currently holds one item.
  #
  # Phase 2 also sets `disable_execute_api_endpoint`, so turning it on without the
  # DNS record leaves the AWS deployment reachable at NO hostname at all — which is
  # exactly what happened, briefly, before this was reverted.
  #
  # The cutover needs three things this leaf cannot decide: a data migration from
  # the Kubernetes Postgres, a maintenance window, and somebody's explicit call on
  # when. Until then AWS runs on its `*.execute-api` hostname, which is what
  # `execute_api_endpoint` outputs and what an agent smoke test should use.
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

  # The DynamoDB table is provisioned by Terraform (database_dynamo.tf) and needs no DSN — the
  # function finds it by name from the environment variables Terraform sets. The sweep is ready
  # to run: it fires once a minute and walks each tenant's DEVSTAT# prefix looking for stale
  # heartbeats. It is the core of the product's alerting and invisible when disabled.
  sweep_enabled = true
}
