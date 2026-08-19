# Chargate's AWS leaves, in their OWN member account.
#
# `find_in_parent_folders("provider.hcl")` resolves to the NEAREST one, so this file shadows
# terraform/aws/provider.hcl for everything beneath it. That is the same mechanism the OCI side
# uses to hold more than one tenancy in this repo (see terraform/oci/cloudworkers/provider.hcl
# and the `oci_env_prefix` local in root.hcl) — applied here because MagmaMoose runs one AWS
# account per service front door:
#
#   chargate   495408387666
#   nievah     666802049426
#   caldrith   483461801743
#
# WHY SEPARATE ACCOUNTS, stated correctly: blast-radius isolation, a clean IAM boundary, and
# per-account Service Control Policies (magmamoose/infra#641). It is NOT for free-tier
# multiplication — AWS applies the free tier to total usage ACROSS an organization and does not
# grant it per member account, and free-tier eligibility dates from the MANAGEMENT account's
# creation, so a member account created later has already-expired 12-month allowances on day one.
# The comment in kubernetes/apps/atlantis/base/externalsecret-aws.yaml asserting otherwise is
# wrong; do not propagate it.
#
# `provider = "aws"` is required by root.hcl, which reads it to suppress the OCI
# `required_providers` block for AWS leaves.
locals {
  provider = "aws"

  # The account these leaves must land in. Rendered into each leaf's generated provider as
  # `allowed_account_ids`, so a mis-set or stale credential fails the plan with a clear error
  # instead of quietly building chargate's stack inside nievah's account.
  account_id = "495408387666"
}

inputs = {
  provider = local.provider
}
