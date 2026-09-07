# ff-oci3 / ff-oci4 — the cloudworkers half of the firefly native-cloud worker
# tier. Same shape and role as ff-oci1/ff-oci2 in
# terraform/oci/prod/eu-amsterdam-1/server; the reason they live in a second
# tenancy at all is that firefly's Always Free ARM allowance (4 OCPU / 24 GB)
# is entirely consumed by the first pair.
#
# APPLY LAST. These VMs join an existing cluster at boot, so they need
# ../network, ../edge (internet egress for apt + get.k3s.io) and ../vpn (a
# route to the control plane) all working first. A node that boots before the
# tunnel is up retries the token fetch five times and then exits 1.
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
  # See ../network for why these are regex-asserted rather than plain get_env.
  #
  # compartment_ocid especially: modules/server/iam.tf interpolates it into a
  # dynamic-group matching_rule ("instance.compartment.id = '<ocid>'"). OCI does
  # not validate an OCID inside a matching rule, so a wrong or empty value
  # creates a dynamic group that matches NOTHING, terraform applies green, and
  # the only evidence is five denied token fetches in /var/log/oci-secret-fetch.log
  # on a VM you cannot SSH into yet.
  tenancy_ocid     = regex("^ocid1\\.tenancy\\..+$", get_env("OCI_CW_TENANCY_OCID", ""))
  compartment_ocid = regex("^ocid1\\.(?:compartment|tenancy)\\..+$", get_env("OCI_CW_COMPARTMENT_OCID", ""))

  region        = local.region_vars.locals.region
  environment   = local.environment_vars.locals.environment
  shape         = "VM.Standard.A1.Flex"
  ocpus         = 2  # 2 OCPUs per server
  memory_in_gbs = 12 # 12GB memory per server

  # Use app subnet from network module
  subnet_id                 = dependency.network.outputs.app_subnet_id
  network_security_group_id = dependency.network.outputs.network_security_group_id
  ssh_public_key_path       = "${get_repo_root()}/ansible/keys/id_rsa.pub"
  vcn_id                    = dependency.network.outputs.vcn_id

  # Canonical-Ubuntu-24.04-Minimal-aarch64-2025.01.31-1. Same OCID as firefly's
  # server leaf and that is correct: this is an Oracle PLATFORM image, which is
  # visible from every tenancy in the region (verified 2026-08-31 against
  # traceysargeant). Only CUSTOM images are tenancy-private — see ../edge, whose
  # CHR image is not reusable for exactly that reason.
  #
  # (Firefly's leaf comments this OCID as "Ubuntu 22.04 for ARM". That comment
  # is wrong; the image is 24.04 Minimal.)
  #
  # Hardcoded rather than looked up with an oci_core_images data source on
  # purpose: modules/server folds image_ocid into the user_data replace-trigger
  # hash, so a "newest matching image" lookup would silently replace both nodes
  # the next time Canonical publishes.
  image_ocid = "ocid1.image.oc1.eu-amsterdam-1.aaaaaaaahc3kbflujx4g536l4yuzzy7udc6ltwlbt7iqbkt33i6zx62yy7va"

  # Two servers, one per fault domain (eu-amsterdam-1 has a single availability
  # domain, so fault domains are the only HA axis). These are the second pair of
  # the "native-cloud" worker tier: arm64 VMs that join firefly as k3s agents.
  #
  # node_name registers them as ff-oci3/ff-oci4 (the ff-<type><n> standard)
  # instead of the OS hostname. node_labels bakes the tier label at join so it
  # survives node re-registration; node-role.kubernetes.io/worker must be
  # applied post-join with kubectl (the kubelet may not self-set kubernetes.io
  # labels — NodeRestriction). See docs/reference/cluster-topology.md.
  servers = {
    "fd1" = { fault_domain = 0, private_ip = "192.168.240.71", node_name = "ff-oci3", node_labels = ["topology.sargeant.co/tier=native-cloud"] } # Fault Domain 1
    "fd2" = { fault_domain = 1, private_ip = "192.168.240.72", node_name = "ff-oci4", node_labels = ["topology.sargeant.co/tier=native-cloud"] } # Fault Domain 2
  }

  # Join the existing firefly k3s cluster as agents. Reached over this tenancy's
  # own IPSec tunnels to FG1/FG2 (../vpn), not over firefly's.
  k3s_url = get_env("K3S_URL", "https://192.168.19.10:6443")

  # Match the firefly control plane (ff-pi1). Unpinned, the installer takes the
  # `stable` channel as of the VM's boot date, so two nodes built from the same
  # code months apart join on different minors: ff-oci1/ff-oci2 came up on
  # v1.33.4+k3s1 in June 2026 and ff-oci3/ff-oci4 on v1.36.4+k3s1 on 2026-08-31,
  # three minors AHEAD of the API server. The skew policy allows a kubelet to
  # trail the control plane by up to three minors and never to lead it, so that
  # second pair was unsupported from the moment it registered.
  #
  # This pin governs VMs created AFTER it lands; it is not in the user_data
  # replace hash, so applying it will not rebuild the running nodes (see
  # modules/server/main.tf). Raise it only together with the control plane.
  k3s_version = "v1.33.4+k3s1"

  # A COPY of firefly's node-token, held in a vault in THIS tenancy.
  #
  # It cannot be firefly's secret OCID. The cloud-init fetches the token with
  # `oci --auth instance_principal`, and modules/server/iam.tf grants that access
  # with a dynamic group + policy created in THIS tenancy — a policy here can
  # never authorise a read against a secret over there. OCI's cross-tenancy
  # Endorse/Admit statements only accept `group`, never `dynamic-group`, so
  # there is no policy-only way to close the gap. Duplicating the secret is the
  # supported answer, and it is what FranklinHouse already does.
  #
  # Consequence worth knowing: rotating the k3s node-token now means updating
  # TWO vaults.
  #
  # Created 2026-08-31 in vault-cloudworkers (the vault was already provisioned
  # in this tenancy but held no key and no secret) under a SOFTWARE-protected
  # AES key, key-cloudworkers. Software protection rather than firefly's HSM
  # because software keys carry no per-key charge.
  #
  # The vault must stay in eu-amsterdam-1: modules/server passes --region to the
  # in-VM fetch from var.region.
  #
  # Do NOT swap this for a placeholder if it ever needs re-pointing.
  # modules/server anchors only the OCID PREFIX, so a plausible-looking
  # placeholder passes validation AND passes the agent-mode precondition, and
  # you get two VMs that boot, retry five times and exit 1. Worse, the value is
  # inside the user_data replace hash, so correcting it later REPLACES both VMs.
  k3s_token_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaao6ivuuqa635dkzooqb5vwq25sjlo7jhwdvpmzjpy7lp6ulyk6uxa"
}
