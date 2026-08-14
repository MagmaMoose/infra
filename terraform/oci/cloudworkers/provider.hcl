locals {
  provider = "oci"

  # SECOND OCI TENANCY (tracey@sargeant.co, eu-amsterdam-1). A separate Oracle
  # account, so it carries its OWN Always Free allowance — which is the entire
  # point: firefly's own tenancy already spends all 4 OCPU / 24 GB of ARM on
  # ff-oci1 + ff-oci2, leaving no room to grow the cloud worker tier there.
  #
  # This prefix shadows terraform/oci/provider.hcl's "OCI" for every leaf beneath
  # this directory, so these leaves authenticate as this tenancy and never as
  # firefly's. The four OCI_CW_* variables must be present in whatever runs
  # terragrunt (Atlantis, and .github/workflows/terragrunt.yml).
  env_prefix = "OCI_CW"
}

inputs = {
  provider = local.provider
}
