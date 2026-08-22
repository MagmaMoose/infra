# Where diatreme publishes the broker Lambda zip, and the GitHub OIDC role it publishes with.
#
# APPLY THIS BEFORE ../diatreme-broker. There is a real chicken-and-egg on a cold start: the
# broker points at `broker/<version>.zip`, which does not exist until diatreme publishes, and
# diatreme cannot publish until this exists. Order:
#
#   1. apply THIS leaf
#   2. set BROKER_ARTIFACT_BUCKET / BROKER_PUBLISH_ROLE_ARN as repo variables in MagmaMoose/diatreme
#   3. merge to main so release.yml publishes once
#   4. apply ../diatreme-broker with broker_artifact_version set to what step 3 produced
#
# NO LONG-LIVED CREDENTIAL IS CREATED HERE. Diatreme's release workflow assumes the role below
# through GitHub's OIDC provider, so the publish identity is a short-lived STS session bound to
# one repository — nothing to rotate, nothing to leak from a secret store.

# NAMED include. Terragrunt 1.x requires a label on every include block; the unnamed 0.x form
# used by the neighbouring aws leaves fails outright on the current binary ("All include blocks
# must have 1 labels"). A name is valid in both, so this is the forward-compatible spelling.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/artifacts"
}

# The AWS provider, generated per-leaf rather than added to root.hcl — root.hcl generates
# `provider.tf` with `if_exists = "overwrite"`, so this uses a DIFFERENT filename and the two
# coexist. See the note in ../../../../prod/eu-west-1/artifacts/terragrunt.hcl (nievah's).
#
# `allowed_account_ids` is the part that matters here and is absent from nievah's copy: this repo
# now addresses three AWS accounts with one ambient credential, and without this a stale
# AWS_PROFILE would build diatreme's stack inside whichever account happens to be authenticated.
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
      Leaf      = "aws/diatreme/prod/eu-west-1/artifacts"
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
  name_prefix = "diatreme"

  # The prefix the publish role may write to and read back. Must agree with
  # `package-feed-url: s3://<bucket>/broker` in diatreme's release.yml and with
  # `artifact_prefix` in ../diatreme-broker.
  artifact_prefix = "broker"

  # The ONLY repository allowed to assume the publish role. Bound into the OIDC trust policy's
  # `sub` condition — without it, every GitHub Actions workflow on github.com could publish here.
  publisher_repo = "MagmaMoose/diatreme"

  # TRUE. A freshly created member account has no GitHub OIDC provider — AWS permits exactly one
  # per issuer per account, so another account's ARN is not reusable from here. Verified with
  # `aws iam list-open-id-connect-providers --profile mm-prd-diatreme` returning an empty list.
  create_github_oidc_provider = true
}
