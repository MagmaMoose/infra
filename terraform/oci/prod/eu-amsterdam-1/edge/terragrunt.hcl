include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/edge"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    edge_subnet_id            = "mock-edge-subnet-id"
    network_security_group_id = "mock-nsg-id"
    vcn_id                    = "mock-vcn-id"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  tenancy_ocid     = get_env("OCI_TENANCY_OCID", "")
  user_ocid        = get_env("OCI_USER_OCID", "")
  fingerprint      = get_env("OCI_FINGERPRINT", "")
  private_key_path = get_env("OCI_PRIVATE_KEY_PATH", "")
  compartment_ocid = get_env("OCI_COMPARTMENT_OCID", "")
  region           = local.region_vars.locals.region
  environment      = local.environment_vars.locals.environment
  shape            = "VM.Standard.E2.1.Micro"

  # Use edge subnet from network module
  subnet_id                 = dependency.network.outputs.edge_subnet_id
  network_security_group_id = dependency.network.outputs.network_security_group_id
  ssh_public_key_path       = "${get_repo_root()}/ansible/keys/sargeant_oci.pub"
  vcn_id                    = dependency.network.outputs.vcn_id

  # MikroTik CHR image from object storage
  image_ocid = "ocid1.image.oc1.eu-amsterdam-1.aaaaaaaaf6i6b6t7eedgqku6a2whieyfeeit3wl4l366meurvkc4btc4tgha"

  # Create two MikroTik CHR instances, one per fault domain
  fault_domains = {
    "fd1" = { fault_domain = 0, private_ip = "192.168.223.11" } # Fault Domain 1
    "fd2" = { fault_domain = 1, private_ip = "192.168.223.12" } # Fault Domain 2
  }
}
