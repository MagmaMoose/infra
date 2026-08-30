# Where Dün Mir publishes the backend Lambda zip, and the GitHub OIDC role it publishes with.
#
# APPLY THIS BEFORE ../platform. Cold-start ordering, the same as brimyr's and chargate's:
#   1. apply THIS leaf
#   2. set BACKEND_ARTIFACT_BUCKET / BACKEND_PUBLISH_ROLE_ARN as repo variables in
#      MagmaMoose/dunmir, from this leaf's outputs
#   3. let one release publish backend/<version>.zip
#   4. apply ../platform with artifact_version set to what step 3 produced
#
# NO LONG-LIVED CREDENTIAL IS CREATED HERE. dunmir's release workflow assumes the role below
# through GitHub's OIDC provider: a short-lived STS session bound to one repository, nothing to
# rotate and nothing to leak from a secret store.
#
# ── COST ────────────────────────────────────────────────────────────────────────────────
# One ~23 MB zip per release in S3 Standard is about $0.0005/month. Old versions expire after
# 90 days (the module's lifecycle rule); current versions never do, because a rollback target
# that expired is not a rollback target. Creating the bucket and the role costs nothing.
#
# That is the whole reason this leaf exists rather than an ECR repository: the same artefact as
# a container image is ~210 MB and ECR bills $0.10/GB-month, so ten retained releases would be
# about $0.21/month — small, but it is the only meter in the stack that grows every time a
# release is cut, and it buys nothing a zip does not do.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/artifacts"
}

generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TFP
provider "aws" {
  region              = "${local.region_vars.locals.region}"
  allowed_account_ids = ["${local.provider_vars.locals.account_id}"]

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "dunmir"
      Leaf      = "aws/dunmir/prod/eu-west-1/artifacts"
    }
  }
}
TFP
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
  provider_vars    = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
}

inputs = {
  region      = local.region_vars.locals.region
  name_prefix = "dunmir"

  # Must agree with `artifact_prefix` in ../platform and with what dunmir's release workflow
  # publishes to. The module scopes the publish role's PutObject/GetObject grants to
  # `<prefix>/*`, so a mismatch fails the PUBLISH with AccessDenied rather than failing here.
  artifact_prefix = "backend"

  # The ONLY repository allowed to assume the publish role, bound into the OIDC trust policy's
  # `sub` condition. Without it every GitHub Actions workflow on github.com could publish here.
  publisher_repo = "MagmaMoose/dunmir"

  # TRUE: this account is new and has no GitHub OIDC provider — verified with
  # `aws iam list-open-id-connect-providers --profile mm-prd-dunmir`, which returned
  # `{"OpenIDConnectProviderList": []}`. AWS permits exactly one per issuer per account, so the
  # providers in the nievah/chargate/brimyr accounts are not reachable from here.
  create_github_oidc_provider = true
}
