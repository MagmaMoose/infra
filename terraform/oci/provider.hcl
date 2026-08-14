locals {
  provider = "oci"

  # Prefix of the env vars carrying this tenancy's API credentials, consumed by
  # the `oci_env_prefix` local in terraform/root.hcl. "OCI" is the historical set
  # (OCI_TENANCY_OCID / OCI_USER_OCID / OCI_FINGERPRINT / OCI_PRIVATE_KEY_PATH),
  # so naming it explicitly here changes nothing for existing leaves.
  #
  # A second tenancy shadows this by placing its own provider.hcl further down the
  # tree — find_in_parent_folders resolves to the NEAREST one. See
  # terraform/oci/cloudworkers/provider.hcl.
  env_prefix = "OCI"
}

inputs = {
  provider = local.provider
}
