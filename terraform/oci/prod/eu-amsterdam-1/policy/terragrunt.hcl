include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/policy"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

inputs = {
  tenancy_ocid     = get_env("OCI_TENANCY_OCID", "")
  user_ocid        = get_env("OCI_USER_OCID", "")
  fingerprint      = get_env("OCI_FINGERPRINT", "")
  private_key_path = get_env("OCI_PRIVATE_KEY_PATH", "")
  region           = local.region_vars.locals.region
  compartment_ocid = get_env("OCI_COMPARTMENT_OCID", "")
  environment      = local.environment_vars.locals.environment
}