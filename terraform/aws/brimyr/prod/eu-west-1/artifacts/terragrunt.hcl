# Where brimyr publishes the broker Lambda zip, and the GitHub OIDC role it publishes with.
#
# APPLY THIS BEFORE ../brimyr-broker. Cold-start ordering, same as chargate's:
#   1. apply THIS leaf
#   2. set BROKER_ARTIFACT_BUCKET / BROKER_PUBLISH_ROLE_ARN as repo variables in MagmaMoose/brimyr
#   3. let one release publish broker/<version>.zip
#   4. apply ../brimyr-broker with broker_artifact_version set to what step 3 produced
#
# NO LONG-LIVED CREDENTIAL IS CREATED HERE. brimyr's release workflow assumes the role below
# through GitHub's OIDC provider: a short-lived STS session bound to one repository, nothing to
# rotate and nothing to leak from a secret store.
#
# ── COST ────────────────────────────────────────────────────────────────────────────────
# One ~5.5 MB zip per release in S3 Standard is about $0.00013/month. Old versions expire
# after 90 days (the module's lifecycle rule); current versions never do, because a rollback
# target that expired is not a rollback target. Creating the bucket and the role costs nothing.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/artifacts"
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
      Leaf      = "aws/brimyr/prod/eu-west-1/artifacts"
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
  name_prefix = "brimyr"

  # Must agree with `artifact_prefix` in ../brimyr-broker and with whatever brimyr's release
  # workflow publishes to.
  artifact_prefix = "broker"

  # The ONLY repository allowed to assume the publish role, bound into the OIDC trust policy's
  # `sub` condition. Without it every GitHub Actions workflow on github.com could publish here.
  publisher_repo = "MagmaMoose/brimyr"

  # TRUE: this account is new and has no GitHub OIDC provider — verified with
  # `aws iam list-open-id-connect-providers --profile mm-prd-brimyr`, which returned []. AWS
  # permits exactly one per issuer per account, so chargate's is not reusable from here.
  create_github_oidc_provider = true
}
