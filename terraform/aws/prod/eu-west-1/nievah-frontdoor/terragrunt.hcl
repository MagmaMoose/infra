# Nievah's webhook front door: CloudFront -> Lambda -> SQS FIFO -> the firefly cluster.
#
# GitHub POSTs each delivery exactly once and never re-sends one it failed to place, so while
# the cluster's ingress was the first hop, a 5xx or a reset lost the event outright — and one
# loss strands a pull request silently and permanently. This takes that hop and holds the
# delivery for up to 14 days until nievah-worker pulls it. See MagmaMoose/nievah ADR-0003.

include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/nievah-frontdoor"
}

# See the note on the matching block in ../artifacts/terragrunt.hcl.
generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TF
provider "aws" {
  region = "${local.region_vars.locals.region}"

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "nievah"
      Component = "front-door"
    }
  }
}
TF
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

# The apply ordering, expressed in the graph rather than in a runbook. The mock lets
# `validate`/`plan`/`init` run before artifacts exists; an apply cannot proceed on a mock.
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

  # ─────────────────────────────────────────────────────────────────────────────────────────
  # THIS LINE IS THE DEPLOYMENT.
  #
  # Nievah's `publish-edge` workflow uploads `edge/<version>.zip` and opens the PR that bumps
  # this. Merging it moves the edge; nothing else does. Objects are immutable and keys are
  # version-scoped, so a changed key is the only signal Terraform needs.
  #
  # The bump PR is only opened when the zip's sha256 actually CHANGED. The package is seven
  # files and most nievah releases touch none of them, so a bump per release would be a stream
  # of PRs redeploying byte-identical code until nobody read them.
  #
  # Cold start: this must name an object that already exists. Apply ../artifacts, run the
  # publish workflow once, then set this to what it produced.
  # ─────────────────────────────────────────────────────────────────────────────────────────
  edge_artifact_version = "1.41.3-gb5726f6"

  # Empty until DNS is decided: the distribution's own *.cloudfront.net name works, and the
  # GitHub App's webhook URL is one field to repoint later. A hostname here also needs an ACM
  # certificate in us-east-1, which CloudFront reads from that region regardless of this one.
  # A clean hostname for the GitHub App's webhook URL. The module requests its own REGIONAL
  # ACM certificate (see api.tf); `certificate_arn` is only for reusing one managed elsewhere.
  #
  # TWO-PHASE, because the DNS validation record lives in another Terraform state
  # (terraform/cloudflare/dns-magmamoose/prod — a Cloudflare zone is a hard provider boundary).
  # Phase 1 requested the certificate and printed the CNAME; that record is now in the
  # Cloudflare leaf, the certificate is ISSUED, so phase 2 can create the domain and mapping.
  domain_name          = "hooks.nievah.magmamoose.com"
  certificate_arn      = ""
  enable_custom_domain = true

  # TRUE since 2026-08-18, and only because k8s/base/cronjob.yaml's two CronJobs carry
  # `suspend: true` in MagmaMoose/nievah first. That order is the whole safety property:
  # `_window_id` prefers the Kubernetes Job name and falls back to a 10-minute bucket when
  # there is no Job, so the two paths mint DIFFERENT ARQ job ids for the same window and
  # `unique=True` cannot collapse them. Both live means two planner runs — duplicate issues.
  # To roll back, reverse it: set this false, apply, THEN unsuspend the CronJobs.
  enable_ticks = true

  # ── Where the alarms and the budget go ──────────────────────────────────────────────────
  #
  # Email is set because an alarm nobody receives is worse than no alarm, and this stack's
  # budget guard is the thing standing between an abusive burst and a personally-funded bill.
  # AWS sends a confirmation link once; until it is clicked the subscription is pending and
  # delivers nothing, which Terraform reports as "created" either way.
  ops_email = "caleb@magmamoose.com"

  # Slack #finance. The workspace was authorised by hand in the console — AWS Chatbot (now
  # branded "Amazon Q Developer in chat applications") needs a one-time OAuth handshake
  # before a workspace exists to reference, and Terraform cannot perform it. Everything after
  # that handshake is declarative, and Chatbot itself is free.
  slack_workspace_id = "T07C6KG3Y4A"
  slack_channel_id   = "C08BHHDGC0K"
}
