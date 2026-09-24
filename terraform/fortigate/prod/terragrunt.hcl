# Self-contained terragrunt config for the two home-lab FortiGate 40Fs.
# Deliberately does NOT include terraform/root.hcl: root.hcl generates a
# google + oci provider.tf that's irrelevant here and would force a fake
# cloud "region"/"environment" dir layout onto physical edge kit. We keep
# state in the same bucket as everything else and let the module own the
# fortios provider (see modules/fortigate/fortios_provider.tf).
remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "fortigate/prod"
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
  source = "${get_repo_root()}/terraform/fortigate/modules/fortigate"
}

# ---------------------------------------------------------------------------
# Credentials
#
# The hardware isn't wired/provisioned yet, so there are no API tokens to fetch.
# For now the management hosts + tokens come from env vars (empty by default) so
# `terragrunt validate`/parse succeeds — a `plan`/`apply` will only fail later
# at provider-connect time, once you point it at real, reachable units.
#
# WHEN THE UNITS ARE LIVE — switch to the repo-standard OCI Vault pattern
# (same as oci/mikrotik): create one REST-API admin token per FortiGate
# (`config system api-user`), store each in vault-prod, and replace the
# get_env() defaults below with run_cmd() lookups, e.g.:
#
#   locals {
#     fgt1_token_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.<...>"
#     # Call `oci` directly + decode in HCL (no `bash -c`) so it parses on Windows too.
#     fgt1_token = base64decode(trimspace(run_cmd("--terragrunt-quiet",
#       "oci", "secrets", "secret-bundle", "get", "--secret-id", local.fgt1_token_secret_ocid,
#       "--region", "eu-amsterdam-1", "--query", "data.\"secret-bundle-content\".content",
#       "--raw-output")))
#   }
#
# NOTE: API tokens are plaintext-equivalent secrets — never inline a real one
# in this PUBLIC repo. OCI Vault first; rotate immediately if leaked.
# ---------------------------------------------------------------------------
locals {
  fgt1_token = get_env("FORTIGATE_FGT1_TOKEN", "")
  fgt2_token = get_env("FORTIGATE_FGT2_TOKEN", "")

  # OCI IPsec PSKs (one per FortiGate, shared with the OCI IPSecConnection).
  # When live: store in OCI Vault and swap to run_cmd, OR read straight from the
  # oci/vpn-fortigate module's psk_secret_ids. Empty default keeps parse working.
  fgt1_oci_psk = get_env("FORTIGATE_FGT1_OCI_PSK", "")
  fgt2_oci_psk = get_env("FORTIGATE_FGT2_OCI_PSK", "")
}

inputs = {
  fortigate_insecure = true # 40Fs ship a self-signed mgmt cert

  fortigate_tokens = {
    fgt1 = local.fgt1_token
    fgt2 = local.fgt2_token
  }

  # Shared with the OCI side (terraform/oci/.../vpn-fortigate).
  fortigate_oci_vpn_psks = {
    fgt1 = local.fgt1_oci_psk
    fgt2 = local.fgt2_oci_psk
  }

  # Gateway PSK for the IPsec dial-up remote-access VPN (users auth via SAML).
  fortigate_remote_access_psks = {
    fgt1 = get_env("FORTIGATE_FGT1_RA_PSK", "")
    fgt2 = get_env("FORTIGATE_FGT2_RA_PSK", "")
  }

  # Identity — Google Workspace SAML IdP for the remote-access VPN. Fill from the
  # Google Admin SAML app; idp_cert_name must be an imported cert on the unit.
  saml_idp = {
    idp_entity_id = get_env("FORTIGATE_SAML_IDP_ENTITY_ID", "")
    idp_sso_url   = get_env("FORTIGATE_SAML_IDP_SSO_URL", "")
    idp_cert_name = "google-idp-cert"
  }

  # Visibility — empty server/collector disables the resource (placeholder host).
  syslog  = { server = get_env("FORTIGATE_SYSLOG_SERVER", "") }
  netflow = { collector_ip = get_env("FORTIGATE_NETFLOW_COLLECTOR", "") }

  # Automation-stitch webhook (chat/incident endpoint). Empty disables stitches.
  automation_webhook_url = get_env("FORTIGATE_AUTOMATION_WEBHOOK", "")

  # --- Shared dual-gateway topology -------------------------------------------
  # Both FortiGates serve the SAME VLAN subnets (FG1 = .1, FG2 = .2); each has its
  # own ISP/WAN. Managed over their WAN IPs (192.168.1.60 / .52) so a LAN reconfig
  # can't lock us out. VLANs are tagged subinterfaces on the `lan` hard-switch and
  # are inert until the MikroTik switches trunk them together. DHCP ranges are
  # split (FG1 low / FG2 high) so the two coexist once the LANs are bridged.
  # interconnect / crosslink / bgp are placeholders REQUIRED by the module but NOT
  # applied (no FG<->FG cable, no OCI yet) — the apply targets only VLAN + DHCP.
  # VLAN sizes: iot + sargeant (/25) > area51 + guest (/26) > mgmt (/27).
  fortigates = {
    fgt1 = {
      hostname = get_env("FORTIGATE_FGT1_HOST", "192.168.1.60") # WAN (Starlink) mgmt
      ports = {
        wan          = "wan"
        lan_mikrotik = "lan" # VLANs ride the lan hard-switch as tagged subinterfaces
        interconnect = "lan2"
        crosslink    = "lan3"
      }
      vlans = {
        iot      = { id = 20, ip = "192.168.220.1", netmask = "255.255.255.128", dhcp_start = "192.168.220.10", dhcp_end = "192.168.220.60", vrip = "192.168.220.1", vrrp_priority = 200 }
        sargeant = { id = 30, ip = "192.168.220.129", netmask = "255.255.255.128", dhcp_start = "192.168.220.140", dhcp_end = "192.168.220.190", vrip = "192.168.220.129", vrrp_priority = 200 }
        area51   = { id = 10, ip = "192.168.221.1", netmask = "255.255.255.192", dhcp_start = "192.168.221.10", dhcp_end = "192.168.221.30", trusted = true, vrip = "192.168.221.1", vrrp_priority = 200 }
        guest    = { id = 40, ip = "192.168.221.65", netmask = "255.255.255.192", dhcp_start = "192.168.221.70", dhcp_end = "192.168.221.90", vrip = "192.168.221.65", vrrp_priority = 200 }
        mgmt     = { id = 99, ip = "192.168.221.129", netmask = "255.255.255.224", dhcp_start = "192.168.221.135", dhcp_end = "192.168.221.145", vrip = "192.168.221.129", vrrp_priority = 200 }
      }
      # Deferred (required by the module, NOT applied yet):
      interconnect    = { ip = "10.255.255.1", peer_ip = "10.255.255.2" }
      crosslink       = { ip = "10.255.255.9" }
      peer_lan_subnet = "192.168.220.0/22"
      bgp_asn         = 65010
      peer_bgp_asn    = 65020

      # OCI VPN — oci-t1 only (first import slice; oci-t2 follows in a later PR).
      # BGP inside IPs must match terraform/oci/prod/eu-amsterdam-1/vpn-fortigate.
      # Import the three hand-built FortiOS objects before the first apply:
      #   terragrunt import 'fortios_vpnipsec_phase1interface.oci["fgt1/oci-t1"]' oci-t1
      #   terragrunt import 'fortios_vpnipsec_phase2interface.oci["fgt1/oci-t1"]' oci-t1-p2
      #   terragrunt import 'fortios_system_interface.oci_tunnel["fgt1/oci-t1"]'  oci-t1
      oci_vpn = {
        tunnels = [
          {
            name            = "oci-t1"
            remote_gw       = "193.123.39.30"
            bgp_customer_ip = "169.254.22.2/30"
            bgp_oracle_ip   = "169.254.22.1"
          }
        ]
      }
    }

    fgt2 = {
      hostname = get_env("FORTIGATE_FGT2_HOST", "192.168.1.52") # WAN (Starlink) mgmt
      ports = {
        wan          = "wan"
        lan_mikrotik = "lan"
        interconnect = "lan2"
        crosslink    = "lan3"
      }
      vlans = {
        iot      = { id = 20, ip = "192.168.220.2", netmask = "255.255.255.128", dhcp_start = "192.168.220.70", dhcp_end = "192.168.220.120", vrip = "192.168.220.1", vrrp_priority = 100 }
        sargeant = { id = 30, ip = "192.168.220.130", netmask = "255.255.255.128", dhcp_start = "192.168.220.200", dhcp_end = "192.168.220.250", vrip = "192.168.220.129", vrrp_priority = 100 }
        area51   = { id = 10, ip = "192.168.221.2", netmask = "255.255.255.192", dhcp_start = "192.168.221.35", dhcp_end = "192.168.221.55", trusted = true, vrip = "192.168.221.1", vrrp_priority = 100 }
        guest    = { id = 40, ip = "192.168.221.66", netmask = "255.255.255.192", dhcp_start = "192.168.221.95", dhcp_end = "192.168.221.115", vrip = "192.168.221.65", vrrp_priority = 100 }
        mgmt     = { id = 99, ip = "192.168.221.130", netmask = "255.255.255.224", dhcp_start = "192.168.221.148", dhcp_end = "192.168.221.156", vrip = "192.168.221.129", vrrp_priority = 100 }
      }
      # Deferred (required by the module, NOT applied yet):
      interconnect    = { ip = "10.255.255.2", peer_ip = "10.255.255.1" }
      crosslink       = { ip = "10.255.255.5" }
      peer_lan_subnet = "192.168.220.0/22"
      bgp_asn         = 65020
      peer_bgp_asn    = 65010
    }
  }
}
