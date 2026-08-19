# Chargate's token broker: API Gateway HTTP API -> Lambda -> a repo-scoped Chargate[bot] token.
#
# The broker authenticates each caller by verifying their GitHub Actions OIDC token and mints an
# installation token scoped to that caller's own repository with `pull_requests: write` only, so
# Chargate's PR comments carry the Chargate[bot] byline. See MagmaMoose/chargate ADR-0001.
#
# IT FAILS SOFT, WHICH MEANS IT FAILS SILENTLY. chargate's client emits an empty token and exits
# 0 on every error path, so a broken broker produces no red check anywhere — just comments
# quietly reverting to github-actions[bot]. Never read "nothing has failed" as "it works".

# NAMED include. Terragrunt 1.x requires a label on every include block; the unnamed 0.x form
# used by the neighbouring aws leaves fails outright on the current binary ("All include blocks
# must have 1 labels"). A name is valid in both, so this is the forward-compatible spelling.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/chargate-broker"
}

generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TF
provider "aws" {
  region              = "${local.region_vars.locals.region}"
  allowed_account_ids = ["${local.provider_vars.locals.account_id}"]

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "chargate"
      Component = "token-broker"
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
# validate/plan/init run before artifacts exists; an apply cannot proceed on a mock.
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

  artifact_bucket = dependency.artifacts.outputs.artifact_bucket
  artifact_prefix = "broker"

  # ─────────────────────────────────────────────────────────────────────────────────────────
  # THIS LINE IS THE DEPLOYMENT.
  #
  # Chargate's release workflow publishes `broker/<version>.zip` and prints this exact line to
  # its step summary. Changing it here is what moves the broker; nothing else does. Objects are
  # immutable and keys are version-scoped, so a changed key is the only signal Terraform needs.
  #
  # Cold start: this must name an object that ALREADY EXISTS. Apply ../artifacts, wire the two
  # repo variables, let one release publish, then set this to what it produced.
  # ─────────────────────────────────────────────────────────────────────────────────────────
  broker_artifact_version = "2.11.21"

  # A first-level subdomain, deliberately. Cloudflare's free Universal SSL covers the apex and
  # ONE label, so `broker.chargate.magmamoose.com` could not be proxied without Advanced
  # Certificate Manager (~$10/month) — which is precisely the trap nievah and caldrith are in
  # with their two-label `hooks.<service>.magmamoose.com` names.
  #
  # TWO-PHASE (see api.tf): phase 1 leaves enable_custom_domain false and prints the ACM
  # validation CNAME; phase 2 turns both flags below true once the certificate is ISSUED.
  domain_name          = "broker-chargate.magmamoose.com"
  certificate_arn      = ""

  # THE MIGRATION WINDOW. `token_broker_url` is an action input with a DEFAULT, so the old
  # hostname is frozen into every tag released before the rename — and ~23 repositories pin
  # chargate by SHA through a centrally-provisioned workflow, so they cannot all be moved at
  # once. Verified 2026-08-20: every consumer still resolves `chargate.magmamoose.com`, which
  # no longer exists, and because the client fails soft they were ALL silently falling back to
  # `github-actions[bot]` with nothing red anywhere.
  #
  # Serving both costs nothing (ACM certificates and API Gateway custom domains are free).
  # Remove this entry once no pinned consumer references the old hostname.
  additional_domain_names = ["chargate.magmamoose.com"]
  enable_custom_domain = true

  # Phase 2 as well. Closing the execute-api door is what makes the Cloudflare proxy an actual
  # control rather than cosmetic — otherwise the origin stays reachable and bypassable.
  disable_default_endpoint = true

  # ── Where the alarms and the budget go ──────────────────────────────────────────────────
  #
  # This service is invisible when broken, so an alarm nobody receives is worse here than
  # elsewhere. AWS sends a confirmation link once; until it is clicked the subscription is
  # pending and delivers nothing, which Terraform reports as "created" either way.
  ops_email = "caleb@magmamoose.com"

  # Slack #finance. The workspace needs a ONE-TIME OAuth handshake in THIS account's AWS Chatbot
  # console before this can reference it — it is per-account, and nievah's account being
  # authorised does nothing here. Left empty until that is done; Terraform cannot perform it.
  slack_workspace_id = ""
  slack_channel_id   = ""
}
