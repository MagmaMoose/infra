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
  edge_artifact_version = "0.0.0-bootstrap"

  # Empty until DNS is decided: the distribution's own *.cloudfront.net name works, and the
  # GitHub App's webhook URL is one field to repoint later. A hostname here also needs an ACM
  # certificate in us-east-1, which CloudFront reads from that region regardless of this one.
  domain_name     = ""
  certificate_arn = ""

  # FALSE until k8s/base/cronjob.yaml's two CronJobs are suspended in MagmaMoose/nievah.
  # Both firing means two planner runs with different ARQ job ids that `unique=True` will not
  # collapse — duplicate issues. Suspend first, then flip this. The other order is the bug.
  enable_ticks = false

  # Alarms. AWS Chatbot needs a one-time OAuth handshake in its console that Terraform cannot
  # perform; until then, leave the workspace empty and the ops topic simply has no subscriber
  # beyond the email.
  ops_email          = ""
  slack_workspace_id = ""
  slack_channel_id   = ""
}
