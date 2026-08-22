# Self-contained terragrunt config for the two home-lab MikroTik CRS switches
# (the "CRS behind each FortiGate"). Distinct from the OCI CHR routers at
# terraform/oci/prod/eu-amsterdam-1/mikrotik — those are cloud VMs; these are
# physical edge switches. Same bucket, separate state prefix.
remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "mikrotik/prod"
    project  = "magmamoose-terraform"
    location = "europe-west4"
  }
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  backend "gcs" {}
}
EOF
}

terraform {
  source = "${get_repo_root()}/terraform/mikrotik/modules/crs"
}

# ---------------------------------------------------------------------------
# Credentials — same "not wired yet" stance as the fortigate leaf.
#
# For now the API password + host URLs come from env vars (empty/placeholder
# defaults) so parse/validate succeeds before the switches exist. A plan/apply
# will only fail later at provider-connect time.
#
# WHEN LIVE — switch to the repo-standard OCI Vault pattern (identical to
# oci/prod/eu-amsterdam-1/mikrotik): store the admin password in vault-prod and
# replace the get_env() default below with a run_cmd() lookup, e.g.:
#
#   locals {
#     crs_pw_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.<...>"
#     # Call `oci` directly + decode in HCL (no `bash -c`/jq) so it parses on Windows too.
#     routeros_password = jsondecode(base64decode(trimspace(run_cmd("--terragrunt-quiet",
#       "oci", "secrets", "secret-bundle", "get", "--secret-id", local.crs_pw_secret_ocid,
#       "--region", "eu-amsterdam-1", "--query", "data.\"secret-bundle-content\".content",
#       "--raw-output"))))["password"]
#   }
#
# PUBLIC repo — never inline a real password. OCI Vault first; rotate if leaked.
# ---------------------------------------------------------------------------
locals {
  routeros_password = get_env("MIKROTIK_PASSWORD", "")
}

inputs = {
  routeros_username = "admin"
  routeros_password = local.routeros_password
  routeros_insecure = true

  # --- Topology (PLACEHOLDER addressing — kept consistent with fortigate) ----
  # /30 carving of 10.255.255.0/24:
  #   .0/30  FGT1<->FGT2 interconnect  (fortigate module)
  #   .4/30  FGT2<->MT1 cross-link     (FGT2 .5, MT1 .6)
  #   .8/30  FGT1<->MT2 cross-link     (FGT1 .9, MT2 .10)
  #   .12/30 MT1<->MT2 inter-switch    (MT1 .13, MT2 .14)
  # LANs: MT1 in 10.10.10.0/24, MT2 in 10.20.20.0/24 (FortiGate is the gateway).
  mikrotiks = {
    mt1 = {
      hosturl = get_env("MIKROTIK_MT1_HOSTURL", "api://192.168.88.1:8728") # CRS default mgmt IP
      ports = {
        fgt_uplink = "ether1"
        crosslink  = "ether2"
        mt_link    = "ether3"
      }
      client_ports = ["ether4", "ether5", "ether6", "ether7", "ether8"]
      # Per-port VLAN overrides, e.g. { ether7 = "iot", ether8 = "guest" }.
      # Unlisted ports fall back to default_access_vlan ("trusted").
      access_port_vlans = {}
      lan = {
        bridge_ip = "10.10.99.2/24" # mgmt VLAN
        gateway   = "10.10.99.1"    # FGT1 mgmt-VLAN gateway
      }
      crosslink = {
        address     = "10.255.255.6/30"
        fgt_gateway = "10.255.255.5" # FGT2 cross-link side
      }
      mt_link = { address = "10.255.255.13/30" }
      peer = {
        lan_subnet = "10.20.0.0/16"  # Site2 supernet
        mt_link_ip = "10.255.255.14" # MT2
      }
    }

    # MT2 isn't installed yet (FGT2 has no MikroTik behind it). Defined ahead of
    # cabling so the config is ready; apply will fail until it's reachable.
    mt2 = {
      hosturl = get_env("MIKROTIK_MT2_HOSTURL", "api://192.168.88.2:8728")
      ports = {
        fgt_uplink = "ether1"
        crosslink  = "ether2"
        mt_link    = "ether3"
      }
      client_ports      = ["ether4", "ether5", "ether6", "ether7", "ether8"]
      access_port_vlans = {}
      lan = {
        bridge_ip = "10.20.99.2/24" # mgmt VLAN
        gateway   = "10.20.99.1"    # FGT2 mgmt-VLAN gateway
      }
      crosslink = {
        address     = "10.255.255.10/30"
        fgt_gateway = "10.255.255.9" # FGT1 cross-link side
      }
      mt_link = { address = "10.255.255.14/30" }
      peer = {
        lan_subnet = "10.10.0.0/16"  # Site1 supernet
        mt_link_ip = "10.255.255.13" # MT1
      }
    }
  }
}
