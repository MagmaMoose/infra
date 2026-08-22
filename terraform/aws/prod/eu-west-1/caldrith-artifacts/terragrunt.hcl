# Where caldrith publishes its Lambda zips, and the GitHub OIDC role it publishes with.
#
# APPLY THIS BEFORE `../caldrith-frontdoor`. That leaf points at `edge/<version>.zip` and
# `edge/<version>-reconcile.zip`, neither of which exists until caldrith has published once.
#
# SEPARATE FROM `../artifacts` ON PURPOSE. That leaf applies into prd-nievah (666802049426);
# this one into prd-caldrith (483461801743). A Lambda cannot take its code from a bucket in
# another account without a bucket policy granting it, and granting that would put Caldrith's
# deploys inside Nievah's blast radius to save one string. Two buckets, two blast radii.
#
# `modules/artifacts` needed no forking — it was already parameterised on account, prefix and
# publisher repo.

include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/artifacts"
}

# The AWS provider, generated per-leaf rather than added to root.hcl — see the note in
# ../artifacts/terragrunt.hcl for why. This is now the FOURTH AWS leaf, so the "a third AWS
# leaf is the point to extract it into a shared aws.hcl include" note there is overdue; left
# as-is here so this change stays reviewable next to its siblings rather than refactoring the
# generation of every AWS leaf in the same PR.
#
# `allowed_account_ids` is the addition the nievah leaves do not carry: with three AWS accounts
# in play, the wrong AWS_PROFILE is now a plausible mistake rather than a theoretical one, and
# this turns it into a refusal at plan time instead of resources in the wrong account.
generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TF
provider "aws" {
  region              = "${local.region_vars.locals.region}"
  allowed_account_ids = ["${local.caldrith_account_id}"]

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "caldrith"
      Leaf      = "aws/prod/eu-west-1/caldrith-artifacts"
    }
  }
}
TF
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # prd-caldrith. Its own member account, as nievah has its own.
  caldrith_account_id = "483461801743"
}

inputs = {
  region = local.region_vars.locals.region

  # Bucket becomes caldrith-artifacts-483461801743.
  name_prefix = "caldrith"

  # The one repository allowed to assume the publish role. Bound into the OIDC trust policy's
  # `sub` condition — without it any GitHub Actions workflow anywhere could publish the code
  # this account's Lambdas then execute.
  publisher_repo = "MagmaMoose/caldrith"

  # TRUE here, unlike ../artifacts. AWS permits exactly one OIDC provider per issuer per
  # account; prd-nievah already had one, which is why that leaf passes an existing ARN.
  # prd-caldrith was created 2026-08-18 and has none. If this ever fails with
  # EntityAlreadyExists, flip to false and pass the ARN the error names rather than fighting it.
  create_github_oidc_provider = true
}
