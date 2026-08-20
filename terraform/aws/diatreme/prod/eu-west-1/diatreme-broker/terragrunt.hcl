# Diatreme's token broker: API Gateway HTTP API -> Lambda -> a repo-scoped Diatreme[bot] token.
#
# The broker verifies each caller's GitHub Actions OIDC token and mints an installation token
# scoped to that caller's own repository. Unlike chargate's, this one carries `contents: write`
# — it mints RELEASE tokens, so a compromise here can push to any repository the App is
# installed on. That is why it lives in its own account.
#
# IT FAILS HARD, WHICH IS THE POINT. `scripts/request-public-app-token.sh` exits 1 on any
# non-200, so a broken broker is a red X on every consumer's release. MagmaMoose/diatreme#147 is
# what that looks like: releases blocked across every consumer repository for hours because one
# hostname lost egress. Read an alarm here as "nobody can release", not "a service is degraded".

# NAMED include. Terragrunt 1.x requires a label on every include block.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/diatreme-broker"
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
      Service   = "diatreme"
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

# The apply ordering, expressed in the graph rather than in a runbook.
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
  name_prefix = "diatreme"

  artifact_bucket = dependency.artifacts.outputs.artifact_bucket
  artifact_prefix = "broker"

  # ─────────────────────────────────────────────────────────────────────────────────────────
  # THIS LINE IS THE DEPLOYMENT. Objects are immutable and keys are version-scoped, so a
  # changed key is the only signal Terraform needs. Cold start: this must name an object that
  # ALREADY EXISTS — apply ../artifacts, publish once, then set this to what that produced.
  # ─────────────────────────────────────────────────────────────────────────────────────────
  broker_artifact_version = "0.1.0"

  # Both audiences, deliberately. Older pinned action versions still request `release-runner`,
  # and consumers pin by SHA, so dropping it breaks repositories that cannot be updated.
  oidc_audience = "diatreme,release-runner"

  # A first-level subdomain: Cloudflare's free Universal SSL covers the apex and ONE label, so
  # `broker.diatreme.magmamoose.com` would need Advanced Certificate Manager. It is also already
  # shipped as `token-broker-fallback-url` in MagmaMoose/diatreme, so this name is load-bearing.
  #
  # TWO-PHASE: phase 1 leaves both flags false and prints the ACM validation CNAME; phase 2
  # turns them true once the certificate is ISSUED.
  domain_name          = "broker-diatreme.magmamoose.com"
  certificate_arn      = ""
  enable_custom_domain = false

  # Phase 2. Until the custom domain works, execute-api is the ONLY door — closing it now would
  # leave nothing reachable to verify against.
  disable_default_endpoint = false

  ops_email = "caleb@magmamoose.com"

  # Requires a one-time OAuth handshake in THIS account's AWS Chatbot console; it is per-account,
  # so another account being authorised does nothing here. Terraform cannot perform it.
  slack_workspace_id = ""
  slack_channel_id   = ""
}
