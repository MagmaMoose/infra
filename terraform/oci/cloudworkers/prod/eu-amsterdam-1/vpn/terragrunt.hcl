# OCI side of the site-to-site VPN from the cloudworkers tenancy to the two
# on-prem FortiGate 40Fs. Structurally identical to
# terraform/oci/prod/eu-amsterdam-1/vpn-fortigate, but terminating on THIS
# tenancy's own DRG.
#
# WHY A SECOND SET OF TUNNELS RATHER THAN A TENANCY-TO-TENANCY LINK
# ff-oci3/ff-oci4 must reach the k3s control plane at 192.168.19.10, which is
# on-prem — not in firefly's VCN. No amount of OCI-to-OCI peering reaches it:
#   - Remote Peering Connection is cross-REGION; both tenancies are in
#     eu-amsterdam-1, so it does not apply.
#   - A Local Peering Gateway would join the two VCNs, but OCI does not route
#     transitively from an LPG onward through the peer's DRG to on-prem.
# So this tenancy needs its own IPSec to FG1/FG2 regardless, and once it has
# that, firefly is reachable over the same path (hairpinning through FG1).
# A cross-tenancy LPG to cut that hairpin is a documented follow-up, not a
# prerequisite.
#
# ── BEFORE THIS CAN CARRY TRAFFIC ──────────────────────────────────────────
# BOTH DRGs ARE ORACLE AS 31898. FG1 therefore CANNOT re-advertise
# 192.168.223.0/24 (learned from firefly's DRG, AS 31898) back to this
# tenancy's DRG — standard BGP AS_PATH loop rejection drops it silently. FG1
# must ORIGINATE both 192.168.223.0/24 and 192.168.240.0/24 as redistributed
# static routes (AS_PATH [65010]), or run as-override on both OCI neighbours.
# This is the single most likely thing to half-work: the tunnels come up green
# and the prefixes never appear. Verify with a ping in BOTH directions before
# applying ../server.
#
# The FortiGate side is hand-configured on the unit — terraform/fortigate/prod
# carries no oci_vpn key, and modules/fortigate types oci_vpn as a single
# object per unit, so codifying a second DRG needs a module change (out of
# scope). Read the generated PSKs back from this module's vault.
#
# COST: modules/vpn unconditionally creates its own oci_kms_vault +
# oci_kms_key to hold the PSKs, so applying this leaf creates a second KMS
# vault in this tenancy (alongside the existing vault-cloudworkers). Confirm
# the billing position before applying.
include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/vpn"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # The FortiGate WAN public IPs are recon-grade (they reveal the operator's
  # residential ISP and home location), so they come from OCI Vault
  # `infra-recon-blockers` and are never inlined in this PUBLIC repo.
  #
  # This is FIREFLY's vault OCID, read at parse time via the operator's
  # ~/.oci/config — correct for the same reason as ../network's
  # operator-mgmt-cidrs: the peer IPs are shared facts about the on-prem edge,
  # not credentials belonging to either tenancy. Same unasserted-ambient-profile
  # caveat as ../network: this call trusts the DEFAULT ~/.oci/config profile.
  recon_blockers_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aa7mytuezgibzn4g36jxupsgy57zl4372uq47atgfra2ka"

  # Direct `oci` call + base64decode in HCL (no `bash -c`) so this parses on
  # Windows/PowerShell, which has no bash.
  recon_blockers = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.recon_blockers_secret_ocid,
    "--region", local.region_vars.locals.region,
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))

  fgt1_wan_ip = local.recon_blockers.vpn_peers.home_wan_peer_ip

  # FG2 is behind Starlink CGNAT — its public IPv4 is DYNAMIC. OCI requires an
  # IPv4 CPE, so this pins FG2's current egress IP from the recon vault. When
  # Starlink reassigns it, update the vault and re-apply (the CPE ip_address is
  # immutable, so the apply recreates the CPE + connection).
  fgt2_wan_ip = local.recon_blockers.vpn_peers.fg2_starlink_public_ip

  # PSK per FortiGate — null lets OCI auto-generate and store in the module
  # vault; read back to configure the FortiGate side. No PSK in this repo.
  # (The inputs below convert empty to null; leaving these unset is the normal
  # path.) Named with the _OCI_CW_ infix so they cannot be confused with
  # FORTIGATE_FGT{1,2}_OCI_PSK, which belong to firefly's vpn-fortigate leaf.
  fgt1_psk = get_env("FORTIGATE_FGT1_OCI_CW_PSK", "")
  fgt2_psk = get_env("FORTIGATE_FGT2_OCI_CW_PSK", "")
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    drg_id = "mock-drg-id"
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

  # DRG from network module
  drg_id = dependency.network.outputs.drg_id

  # OCI VCN advertised to the FortiGates.
  local_networks = ["192.168.240.0/24"]

  # One IPSec connection per FortiGate, BGP-routed. The BGP inside IPs (/30 per
  # tunnel) MUST match the FortiGate side. New /24s because 169.254.21.0/24
  # (decommissioned MikroTik), .22.0/24 (FGT1->firefly) and .23.0/24
  # (FGT2->firefly) are already spoken for.
  #   FGT1 (AS 65010): 169.254.26.0/24   FGT2 (AS 65020): 169.254.27.0/24
  #
  # NOT .24/.25, which the first version of this file used. That was chosen by grepping
  # the repo, and the repo does not know everything: 169.254.24.0/24 is LIVE on FG1 as
  # the transit for jhb-t1/jhb-t2, the FranklinHouse Johannesburg tunnels, which are
  # hand-configured on the unit and appear in no terraform. Building on .24 would have
  # collided with a running tunnel. Ranges verified against the DEVICE (interfaces,
  # static routes and BGP neighbours) rather than against this repo: .19 is to-fg2,
  # .22 is firefly-OCI, .24 is FranklinHouse, and .23 is reserved by ../vpn-fortigate
  # for FGT2 even though that leaf has never been applied.
  vpn_connections = {
    fortigate1 = {
      peer_ip             = local.fgt1_wan_ip
      cpe_device_shape_id = null
      type                = "other"
      # OCI requires >=1 static route even for BGP tunnels (it's ignored while the
      # tunnels run routing=BGP). Listed = everything reachable behind FG1/FG2,
      # including firefly's VCN via the hairpin described in the header.
      static_routes           = ["192.168.19.0/24", "192.168.99.0/24", "192.168.220.0/23", "192.168.223.0/24"]
      routing_type            = "BGP"
      ike_version             = "V2"
      bgp_asn                 = 65010
      bgp_oracle_ip_tunnel1   = "169.254.26.1/30"
      bgp_customer_ip_tunnel1 = "169.254.26.2/30"
      bgp_oracle_ip_tunnel2   = "169.254.26.5/30"
      bgp_customer_ip_tunnel2 = "169.254.26.6/30"
      shared_secret_tunnel1   = local.fgt1_psk != "" ? local.fgt1_psk : null
      shared_secret_tunnel2   = local.fgt1_psk != "" ? local.fgt1_psk : null
    }

    # FG2 (Starlink) — CGNAT IPv4 CPE; FG2 is the sole initiator (OCI can't reach a
    # CGNAT'd peer, so oracle-initiation is forced RESPONDER_ONLY out-of-band).
    fortigate2 = {
      peer_ip                 = local.fgt2_wan_ip
      cpe_device_shape_id     = null
      type                    = "other"
      static_routes           = ["192.168.99.0/24", "192.168.19.0/24", "192.168.220.0/23", "192.168.223.0/24"]
      routing_type            = "BGP"
      ike_version             = "V2"
      bgp_asn                 = 65020
      bgp_oracle_ip_tunnel1   = "169.254.27.1/30"
      bgp_customer_ip_tunnel1 = "169.254.27.2/30"
      bgp_oracle_ip_tunnel2   = "169.254.27.5/30"
      bgp_customer_ip_tunnel2 = "169.254.27.6/30"
      shared_secret_tunnel1   = local.fgt2_psk != "" ? local.fgt2_psk : null
      shared_secret_tunnel2   = local.fgt2_psk != "" ? local.fgt2_psk : null
    }
  }
}
