# ff-chr3 / ff-chr4 — the two MikroTik CHR edge routers for the cloudworkers
# tenancy, one per fault domain. They are the internet gateway for the app and
# data subnets (masquerade), mirroring what the firefly CHRs do at
# terraform/oci/prod/eu-amsterdam-1/edge.
#
# APPLY ORDER: ../network first (this needs its edge subnet), then this leaf,
# then ../network again with internet_gateway_ip = "192.168.240.11".
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
  # See ../network for why these are regex-asserted rather than plain get_env.
  tenancy_ocid     = regex("^ocid1\\.tenancy\\..+$", get_env("OCI_CW_TENANCY_OCID", ""))
  compartment_ocid = regex("^ocid1\\.(?:compartment|tenancy)\\..+$", get_env("OCI_CW_COMPARTMENT_OCID", ""))

  region      = local.region_vars.locals.region
  environment = local.environment_vars.locals.environment
  shape       = "VM.Standard.E2.1.Micro"

  # Use edge subnet from network module
  subnet_id                 = dependency.network.outputs.edge_subnet_id
  network_security_group_id = dependency.network.outputs.network_security_group_id
  ssh_public_key_path       = "${get_repo_root()}/ansible/keys/id_rsa.pub"
  vcn_id                    = dependency.network.outputs.vcn_id

  # MikroTik CHR image — TENANCY-PRIVATE, so firefly's OCID cannot be reused.
  #
  # Firefly's edge leaf points at ocid1.image...tgha ("chr-7.18.2.vmdk"), a
  # CUSTOM image in firefly's root compartment. Verified 2026-08-31: reading it
  # with traceysargeant credentials returns 404 NotAuthorizedOrNotFound, and
  # traceysargeant has zero custom images of its own. Custom images do not cross
  # a tenancy boundary.
  #
  # Imported into THIS tenancy 2026-08-31 from MikroTik's official
  # chr-7.18.2.vmdk (sha256 5b2f6063505bb84a34a4795ade97469169d75f89e8630a6813d
  # 7419a64445c87), staged via the `image-import` Object Storage bucket and
  # `oci compute image import from-object --source-image-type VMDK
  # --launch-mode PARAVIRTUALIZED`. Version pinned to 7.18.2 to match firefly's
  # ff-chr1/ff-chr2, so config copied between the two CHR pairs behaves the same.
  # Resolves to the same 47694 MB PARAVIRTUALIZED image firefly runs.
  #
  # A CHR version bump here is a separate, deliberate re-import: it replaces the
  # instances, and drifting apart from firefly's pair is the thing to avoid.
  image_ocid = "ocid1.image.oc1.eu-amsterdam-1.aaaaaaaaplthqutg4gab6kxf7ikdy2i7ftsib2d6cnnfrfpof7wct3ufyxma"

  # Reserved (not ephemeral) public IPs from the very first apply. Firefly's
  # pair started ephemeral and is now stuck: flipping the flag releases the IP
  # and allocates a new one, so the address changes at that apply. Greenfield is
  # the only free moment to make this choice, and a future cloudworkers mikrotik
  # leaf will need a stable `hosturl` to reach these routers.
  # traceysargeant's reserved-public-ip SERVICE LIMIT is 6, but Always Free
  # covers only 2 at no cost, and these two use both. A third reserved IP in
  # this tenancy bills.
  use_reserved_public_ips = true

  # Two MikroTik CHR instances, one per fault domain. eu-amsterdam-1 has a
  # single availability domain, so fault domains are the only HA axis.
  # node_name drives display_name (see modules/edge) so the OCI console shows
  # ff-chr3/ff-chr4 rather than prod-mikrotik-chr-fd1/fd2.
  fault_domains = {
    "fd1" = { fault_domain = 0, private_ip = "192.168.240.11", node_name = "ff-chr3" } # Fault Domain 1
    "fd2" = { fault_domain = 1, private_ip = "192.168.240.12", node_name = "ff-chr4" } # Fault Domain 2
  }
}
