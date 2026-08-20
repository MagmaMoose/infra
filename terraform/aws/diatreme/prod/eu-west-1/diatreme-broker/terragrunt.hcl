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
  domain_name = "broker-diatreme.magmamoose.com"

  # THE CUTOVER. api.diatreme.magmamoose.com is frozen into every published action version as
  # the default token-broker-url, and consumers pin by SHA, so it must keep answering for as
  # long as any pinned version is in use — which is indefinitely. Serving it from AWS as well
  # is what lets the Cloudflare Worker be retired without breaking a single pinned consumer.
  additional_domain_names = ["api.diatreme.magmamoose.com"]

  # PHASE 2. Certificate ISSUED 2026-08-20 after the validation CNAME was published in
  # terraform/cloudflare/dns-magmamoose (grey, necessarily — a proxied validation record
  # answers with Cloudflare's own value and the certificate never leaves PENDING_VALIDATION).
  #
  # certificate_arn STAYS EMPTY. It is not "the ARN to use" — api.tf reads it as "a certificate
  # managed elsewhere, so do not request one", `count = var.certificate_arn != "" ? 0 : 1`.
  # Pasting the module's OWN certificate ARN here therefore plans to destroy the certificate it
  # just had issued, and breaks the certificate_validation_record output on the way past. The
  # module already holds this one in state; enabling the domain is the whole of phase 2.
  certificate_arn      = ""
  enable_custom_domain = true

  # TRUE as of phase 2b, after broker-diatreme.magmamoose.com was verified serving /healthz,
  # /readyz and the /token ladder through the Cloudflare proxy. Flipping this in the same apply
  # that first stood the custom domain up would have left no reachable door if the domain
  # misbehaved, and that ordering matters more here than for the other two brokers: diatreme
  # fails hard, so a wrong turn takes every consumer's release with it.
  #
  # This is what makes the orange-cloud proxy an actual control rather than cosmetic. While
  # execute-api stayed open the origin was directly reachable and the proxy trivially
  # bypassable, so neither the WAF nor the rate limiting in front of it bounded anything.
  disable_default_endpoint = true

  ops_email = "caleb@magmamoose.com"

  # Requires a one-time OAuth handshake in THIS account's AWS Chatbot console; it is per-account,
  # so another account being authorised does nothing here. Terraform cannot perform it.
  slack_workspace_id = ""
  slack_channel_id   = ""
}
