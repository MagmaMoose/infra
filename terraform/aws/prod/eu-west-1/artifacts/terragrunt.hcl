# Where nievah publishes the Lambda zip, and the GitHub OIDC role it publishes with.
#
# APPLY THIS BEFORE `../nievah-frontdoor`. See the cold-start ordering at the top of
# ../../../modules/artifacts/main.tf — the front door points at an object that does not exist
# until nievah has published once.

include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/artifacts"
}

# The AWS provider, generated per-leaf rather than added to root.hcl.
#
# root.hcl generates `provider.tf` with `if_exists = "overwrite"`, so this uses a DIFFERENT
# filename and the two coexist. Keeping it here rather than in root.hcl means adding AWS does
# not touch a file every OCI, GCP, Cloudflare and MikroTik leaf includes — which, per
# COMMON_MISTAKES #6, is a file Atlantis autoplan cannot see changes to anyway, so a mistake
# in it would go unplanned across the whole repo.
#
# Duplicated in ../nievah-frontdoor/terragrunt.hcl. Two copies is cheaper than the indirection;
# a third AWS leaf is the point to extract it into a shared `aws.hcl` include.
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
      Leaf      = "aws/prod/eu-west-1/artifacts"
    }
  }
}
TF
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

inputs = {
  region = local.region_vars.locals.region

  # The one repository allowed to assume the publish role. Bound into the OIDC trust policy's
  # `sub` condition — without it, any GitHub Actions workflow anywhere could publish here.
  publisher_repo = "MagmaMoose/nievah"
}
