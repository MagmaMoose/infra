# Brimyr's token broker: API Gateway HTTP API -> Lambda -> a repo-scoped Brimyr[bot] token.
#
# Verifies the caller's GitHub Actions OIDC token and mints an installation token scoped to
# that caller's own repository with `pull_requests: write` only, so Brimyr's patch-coverage
# comment carries the Brimyr[bot] byline. See MagmaMoose/brimyr#11.
#
# The SECOND instance of this module. brimyr#11 called that "the extraction point": the module
# is parameterised and instantiated twice rather than forked. The only value that had to become
# a variable was `oidc_audience`, which was hardcoded to "chargate" — and it is the security
# boundary, so it had to.
#
# TWO BROKERS, NEVER ONE. Separate accounts, separate GitHub Apps, separate SSM paths, separate
# audiences. A single minter holding both Apps' private keys would mean compromising either
# surface yields both identities, and the audience check would stop being a boundary at all.
#
# IT FAILS SOFT, WHICH MEANS IT FAILS SILENTLY. brimyr's client falls back to GITHUB_TOKEN on
# every error path, so a broken broker produces no red check anywhere — just comments quietly
# reverting to github-actions[bot]. Never read "nothing has failed" as "it works"; the smoke
# workflow in MagmaMoose/brimyr is the only thing that actually notices.
#
# ── COST: READ THIS BEFORE CHANGING ANY NUMBER BELOW ────────────────────────────────────
#
# This bill is paid out of one person's salary. Treat every setting here as a spend control,
# because that is what it is.
#
# THERE IS NO HARD SPEND CAP IN AWS. A budget ALARMS; it does not stop anything. On a public,
# unauthenticated endpoint the stage throttle is the only real cap, so it is deliberately
# tighter here than the module's defaults:
#
#                        module default   here    worst case if hammered for a full month
#   throttle_rate_limit        2            1      2.59M requests instead of 5.18M
#   throttle_burst_limit      10            5
#   memory_size             1024 MB      512 MB    keeps Lambda compute inside the always-free
#                                                  400,000 GB-s, which 1024 MB does not
#
#   at the module defaults:  ~$16.81/month sustained  (APIGW $5.18 + Lambda $11.45 + logs)
#   at the settings below:    ~$2.91/month sustained  (APIGW $2.59 + Lambda $0.32 + $0 logs)
#   at realistic use (~300 requests/month):  fractions of a cent
#
# Free-tier facts that actually apply to this account, which is NOT in its 12-month window
# (eligibility dates from the ORGANIZATION's management account, so a later member account
# starts with expired allowances):
#
#   ALWAYS free, never expires   Lambda 1M requests + 400,000 GB-s/month · CloudWatch Logs 5 GB
#                                ingestion · SSM Parameter Store Standard · public ACM
#                                certificates · SNS first 1,000 email notifications ·
#                                the first 2 AWS Budgets
#   BILLED FROM THE FIRST UNIT   API Gateway HTTP API, $1.00/million requests · S3 storage
#
# So: raising memory_size above 512 MB pushes compute out of the always-free tier under load.
# Raising the throttle raises the ceiling linearly. Neither is free, and neither is needed —
# real traffic is a handful of requests per pull request.

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
      Service   = "brimyr"
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

  # Drives resource names AND the SSM secret path: `/brimyr/prod/{app-id,private-key}`, which
  # is where those two SecureStrings are already seeded by hand.
  name_prefix = "brimyr"

  # THE SECURITY BOUNDARY. Must equal what brimyr's client asks GitHub for
  # (brimyr.broker_client.OIDC_AUDIENCE). Never chargate's value.
  oidc_audience = "brimyr"

  artifact_bucket = dependency.artifacts.outputs.artifact_bucket
  artifact_prefix = "broker"

  # THIS LINE IS THE DEPLOYMENT. Objects are immutable and keys are version-scoped, so a changed
  # key is the only signal Terraform needs. It must name an object that ALREADY EXISTS.
  broker_artifact_version = "1.2.0"

  # First-level subdomain, deliberately: Cloudflare's free Universal SSL covers the apex and ONE
  # label, so `broker.brimyr.magmamoose.com` would need Advanced Certificate Manager (~$10/month
  # — real money here). That is the trap nievah and caldrith are in with their two-label names.
  #
  # TWO-PHASE, and both DNS records live in THIS repo — see
  # terraform/cloudflare/dns-magmamoose/prod/terragrunt.hcl, where caldrith's and nievah's
  # already are. Neither is created by hand.
  #
  #   Phase 1 (this state): the certificate is requested and `certificate_validation_record`
  #   names the validation CNAME. Add it to the Cloudflare leaf with `proxied = false` — a
  #   proxied validation record answers with Cloudflare's own value, so ACM never sees the
  #   token and the certificate sits in PENDING_VALIDATION forever.
  #
  #   Phase 2: once the certificate is ISSUED, set both flags below to true, apply again, then
  #   add the service CNAME (`target_domain_name` -> broker-brimyr) PROXIED in the same file.
  # PHASE 2 (current): the certificate is ISSUED, so the custom domain and its API mapping
  # are created and the generated execute-api URL is closed. Closing it is what gives the
  # Cloudflare proxy any meaning — otherwise the origin stays reachable and bypassable.
  domain_name              = "broker-brimyr.magmamoose.com"
  certificate_arn          = ""
  enable_custom_domain     = true
  disable_default_endpoint = true

  # ── Spend controls. See the COST block at the top before changing these. ────────────────
  throttle_rate_limit  = 1
  throttle_burst_limit = 5
  memory_size          = 512

  # A budget ALARMS, it does not cap. $1 is an early-warning tripwire, not a limit — at
  # realistic use this stack costs fractions of a cent, so $1 means "something is very wrong".
  # The first two budgets per account are free.
  monthly_budget_usd = 1

  # This service is invisible when broken, so an alarm nobody receives is worse here than
  # elsewhere. AWS sends a confirmation link ONCE; until it is clicked the subscription is
  # pending and delivers nothing, which Terraform reports as "created" either way.
  ops_email = "caleb@magmamoose.com"

  # Slack needs a one-time OAuth handshake in THIS account's AWS Chatbot console before it can
  # be referenced — it is per-account, and chargate's account being authorised does nothing
  # here. Left empty until that is done; Terraform cannot perform it.
  slack_workspace_id = ""
  slack_channel_id   = ""
}
