locals {
  provider = "oci"

  # SECOND OCI TENANCY (tracey@sargeant.co, eu-amsterdam-1). A separate Oracle
  # account, so it carries its OWN Always Free allowance — which is the entire
  # point: firefly's own tenancy already spends all 4 OCPU / 24 GB of ARM on
  # ff-oci1 + ff-oci2, leaving no room to grow the cloud worker tier there.
  #
  # This prefix shadows terraform/oci/provider.hcl's "OCI" for every leaf beneath
  # this directory, so these leaves authenticate as this tenancy and never as
  # firefly's.
  #
  # env_prefix reaches ONLY the generated provider.tf. Whatever runs terragrunt
  # needs five variables, not four: OCI_CW_TENANCY_OCID, OCI_CW_USER_OCID,
  # OCI_CW_FINGERPRINT and OCI_CW_PRIVATE_KEY_PATH for the provider, plus
  # OCI_CW_COMPARTMENT_OCID, which every leaf below passes as a module input and
  # asserts with regex(). The edge and server leaves need two more on top
  # (OCI_CW_CHR_IMAGE_OCID, OCI_CW_K3S_TOKEN_SECRET_OCID) until those OCIDs are
  # created and inlined. See
  # .claude/decisions/2026-08-31-second-oci-tenancy-cloudworkers.md.
  env_prefix = "OCI_CW"
}

inputs = {
  provider = local.provider
}
