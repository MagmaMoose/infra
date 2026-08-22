# Diatreme's AWS leaves, in their OWN member account.
#
# `find_in_parent_folders("provider.hcl")` resolves to the NEAREST one, so this file shadows
# terraform/aws/provider.hcl for everything beneath it — the same mechanism chargate and brimyr
# use. MagmaMoose runs one AWS account per service front door:
#
#   chargate   495408387666
#   nievah     666802049426
#   caldrith   483461801743
#   brimyr     (see terraform/aws/brimyr/provider.hcl)
#   diatreme   628088981780
#
# WHY SEPARATE ACCOUNTS: blast-radius isolation, a clean IAM boundary, and per-account Service
# Control Policies (magmamoose/infra#641). It is NOT free-tier multiplication — AWS applies the
# free tier to total usage ACROSS an organization, not per member account.
#
# Diatreme has a sharper reason than the others. Its broker holds TWO App private keys — the
# github.com Diatreme App and the GHE (Pink Roccade) App — so a compromise here yields both
# identities. It must not also share an account with another service's minter.
#
# `provider = "aws"` is required by root.hcl, which reads it to suppress the OCI
# `required_providers` block for AWS leaves.
locals {
  provider = "aws"

  # The account these leaves must land in. Rendered into each leaf's generated provider as
  # `allowed_account_ids`, so a mis-set or stale credential fails the plan with a clear error
  # instead of quietly building diatreme's stack inside another service's account. This matters
  # more here than elsewhere: every mm-prd-* profile shares one IAM Identity Center portal, so a
  # stale AWS_PROFILE authenticates successfully against the wrong account.
  account_id = "628088981780"
}

inputs = {
  provider = local.provider
}
