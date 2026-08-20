include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/server"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    app_subnet_id             = "mock-app-subnet-id"
    network_security_group_id = "mock-nsg-id"
    vcn_id                    = "mock-vcn-id"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  tenancy_ocid     = get_env("OCI_TENANCY_OCID", "")
  compartment_ocid = get_env("OCI_COMPARTMENT_OCID", "")
  region           = local.region_vars.locals.region
  environment      = local.environment_vars.locals.environment
  shape            = "VM.Standard.A1.Flex"
  ocpus            = 2  # 2 OCPUs per server
  memory_in_gbs    = 12 # 12GB memory per server

  # Use app subnet from network module
  subnet_id                 = dependency.network.outputs.app_subnet_id
  network_security_group_id = dependency.network.outputs.network_security_group_id
  ssh_public_key_path       = "${get_repo_root()}/ansible/keys/id_rsa.pub"
  vcn_id                    = dependency.network.outputs.vcn_id

  # Ubuntu 22.04 for ARM
  image_ocid = "ocid1.image.oc1.eu-amsterdam-1.aaaaaaaahc3kbflujx4g536l4yuzzy7udc6ltwlbt7iqbkt33i6zx62yy7va"

  # Create two servers, one per fault domain. These are the "native-cloud"
  # worker tier: arm64 free-tier VMs that join firefly as k3s agents and host
  # always-online, public-facing workloads + the postgres-oci CNPG cluster.
  #
  # node_name registers them as ff-oci1/ff-oci2 (the ff-<type><n> standard)
  # instead of the OS hostname. node_labels bakes the tier label at join so it
  # survives node re-registration; the node-role.kubernetes.io/worker label is
  # applied post-join with kubectl (kubelet can't self-set kubernetes.io labels).
  # See docs/reference/cluster-topology.md.
  servers = {
    "fd1" = { fault_domain = 0, private_ip = "192.168.223.71", node_name = "ff-oci1", node_labels = ["topology.sargeant.co/tier=native-cloud"] } # Fault Domain 1
    "fd2" = { fault_domain = 1, private_ip = "192.168.223.72", node_name = "ff-oci2", node_labels = ["topology.sargeant.co/tier=native-cloud"] } # Fault Domain 2
  }

  # Join the existing firefly k3s cluster as agents. The actual node-token
  # never travels through terraform — the OCID below points at the OCI
  # Vault secret (`k3s-firefly-node-token` in vault-prod) that the VMs
  # fetch at boot via instance principal. See iam.tf for the dynamic
  # group + policy that grants that read.
  k3s_url               = get_env("K3S_URL", "https://192.168.19.10:6443")
  k3s_token_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aam3bqx2dsmdg6wrdjvdhc6mcgnqil766lofkbv6nlujoa"
}
