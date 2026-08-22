# Brimyr's AWS leaves, in their OWN member account.
#
# `find_in_parent_folders("provider.hcl")` resolves to the NEAREST one, so this file shadows
# terraform/aws/provider.hcl for everything beneath it — the same mechanism chargate's account
# uses. MagmaMoose runs one AWS account per service front door:
#
#   chargate   495408387666
#   nievah     666802049426
#   caldrith   483461801743
#   brimyr     202518311296
#
# Blast-radius isolation, a clean IAM boundary, and per-account SCPs (magmamoose/infra#641).
# NOT free-tier multiplication: AWS applies the free tier to total usage across an organization,
# and eligibility dates from the MANAGEMENT account's creation, so a member account created
# later starts with already-expired 12-month allowances. See chargate/provider.hcl.
#
# The separation matters more than usual for the two brokers specifically: one minter holding
# both GitHub Apps' private keys would mean compromising either surface yields both identities,
# and the OIDC audience check would stop being a boundary at all.
#
# `provider = "aws"` is required by root.hcl, which reads it to suppress the OCI
# `required_providers` block for AWS leaves.
locals {
  provider = "aws"

  # Rendered into each leaf's generated provider as `allowed_account_ids`, so a stale or
  # mis-set credential fails while the provider is being configured — before a single resource
  # is planned — instead of quietly building brimyr's stack inside another account.
  account_id = "202518311296"
}

inputs = {
  provider = local.provider
}
