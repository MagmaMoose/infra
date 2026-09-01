# VCN for the SECOND OCI tenancy (traceysargeant, eu-amsterdam-1) — the
# "cloudworkers" stack that hosts ff-oci3/ff-oci4 and ff-chr3/ff-chr4.
#
# Deliberately a mirror of terraform/oci/prod/eu-amsterdam-1/network so the two
# can be diffed line-for-line. The differences that matter:
#   1. credentials come from OCI_CW_* (see ../../../provider.hcl `env_prefix`)
#   2. the VCN is 192.168.240.0/24, not 192.168.223.0/24
#   3. `remote_networks` carries firefly's own VCN, which firefly's leaf cannot
#      have (a VCN never lists itself)
include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/network"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # Operator management CIDRs (currently just the Sargeant House WAN) live in
  # OCI Vault as `operator-mgmt-cidrs` so the public repo doesn't leak which
  # IP a hacker should target. Stored as JSON: `["A.B.C.D/32", ...]`.
  #
  # This is FIREFLY's vault OCID, read at parse time with the operator's
  # ~/.oci/config, and that is correct: the value is a list of operator WAN
  # CIDRs — plain data being passed INTO the tracey tenancy, not a credential
  # scoped to it. One secret, one place to rotate.
  #
  # Caveat worth naming: unlike the OCI_CW_* inputs below, this call has no
  # assert. It authenticates as whatever the ambient ~/.oci/config DEFAULT
  # profile is, so it silently resolves to nothing useful if that profile is not
  # firefly's. Pin `--profile` here if a second profile ever lands on an
  # operator's machine.
  operator_mgmt_cidrs_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aaqvgllhc77ptjy7npdstq6jp67j5auvhn4y4keiqcqhwa"

  # Direct `oci` call + base64decode in HCL (no `bash -c`) so this parses on
  # Windows/PowerShell, which has no bash. Pattern: cloudflare/zero-trust/prod.
  operator_mgmt_cidrs = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.operator_mgmt_cidrs_secret_ocid,
    "--region", local.region_vars.locals.region,
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))
}

inputs = {
  # The regex() calls are asserts, not cosmetics. get_env(...,"") returns "" when
  # the variable is unset, and an empty tenancy_ocid makes the OCI provider fall
  # through to ~/.oci/config's DEFAULT profile — FIREFLY's — so a forgotten env
  # var would try to build this VCN in the wrong tenancy. Failing at parse time
  # is the only safe outcome. `(?:...)` must stay NON-capturing: HCL's regex()
  # returns the capture groups instead of the match when a group is present.
  #
  # traceysargeant has no child compartments, so OCI_CW_COMPARTMENT_OCID is the
  # tenancy OCID itself; the alternation admits both.
  tenancy_ocid     = regex("^ocid1\\.tenancy\\..+$", get_env("OCI_CW_TENANCY_OCID", ""))
  compartment_ocid = regex("^ocid1\\.(?:compartment|tenancy)\\..+$", get_env("OCI_CW_COMPARTMENT_OCID", ""))

  # Declared in modules/network/variables.tf without defaults, so they must be
  # supplied — but nothing in any OCI module reads them (the provider gets its
  # credentials from the generated provider.tf). Passed empty rather than wired
  # to OCI_CW_* so nobody mistakes them for live plumbing.
  user_ocid        = ""
  fingerprint      = ""
  private_key_path = ""

  region              = local.region_vars.locals.region
  environment         = local.environment_vars.locals.environment
  ssh_public_key_path = "${get_repo_root()}/ansible/keys/id_rsa.pub"

  # VCN CIDR - using 192.168.240.0/24 split into 4x /26 subnets.
  #
  # NOT 192.168.224.0/24, which would be the obvious "next one along". The
  # FortiGate leaf sets peer_lan_subnet = 192.168.220.0/22 (terraform/fortigate/
  # prod/terragrunt.hcl), a supernet that already over-reaches across firefly's
  # own 192.168.223.0/24. Sitting next to a broken supernet invites a second
  # collision; .240 is clear of it entirely.
  vcn_cidr_blocks = ["192.168.240.0/24"]

  # Subnet configuration
  subnets = {
    edge = {
      cidr = "192.168.240.0/26" # .1-.62 for edge/routers (public) — ff-chr3 .11, ff-chr4 .12
    }
    app = {
      cidr = "192.168.240.64/26" # .65-.126 for app/workload (private) — ff-oci3 .71, ff-oci4 .72
    }
    data = {
      cidr = "192.168.240.128/26" # .129-.190 for database (private)
    }
    spare = {
      cidr = "192.168.240.192/26" # .193-.254 reserved (private)
    }
  }

  # Enable VPN for site-to-site connectivity. Creates the DRG that ../vpn
  # attaches its IPSec connections to.
  enable_vpn = true

  # ff-chr3, the app/data subnets' 0.0.0.0/0 next-hop. It masquerades their
  # traffic out to its own public IP.
  #
  # This was EMPTY for the first apply and that was deliberate, because
  # modules/network resolves the address to a private-IP OCID through a data
  # source whose postcondition fails when no such IP exists yet, and the IP
  # belongs to a CHR that lives in the edge subnet THIS module creates. On a
  # greenfield tenancy that is an unbreakable cycle: network needs the CHR, the
  # CHR needs the subnet. The bootstrap was:
  #   1. apply this leaf with "" (VCN + subnets, app/data with no default route)
  #   2. apply ../edge (ff-chr3 .11 and ff-chr4 .12 come up)
  #   3. set this and re-apply
  # Done 2026-08-31. Restore the empty string only if rebuilding from scratch.
  #
  # Single-CHR, matching firefly. Losing ff-chr3 strands app/data egress;
  # ff-chr4 is a warm spare, not an automatic failover.
  internet_gateway_ip = "192.168.240.11"

  # WireGuard mesh ports. 51820 is the default this module already had and is
  # what the ff-crs1 tunnels land on (see the port note in
  # terraform/mikrotik/wireguard-mesh/prod); 51845-51850 are the six OCI-to-OCI
  # tunnels, whose two ends both listen on the same number.
  wireguard_ingress_port_ranges = [
    { min = 51820, max = 51820 },
    { min = 51845, max = 51850 },
  ]

  # Operator IPs allowed to talk to the MikroTik plaintext binary API on the
  # public IPs in the edge subnet (the routeros terraform provider needs this).
  routeros_api_management_cidrs = local.operator_mgmt_cidrs

  # Remote networks reachable from this VCN. Drives BOTH the route rules and the
  # "allow all from remote networks" ingress rules in modules/network. Each entry
  # picks its own next hop with `via` — see modules/network/variables.tf.
  #
  # ff-oci3/ff-oci4 are agents of the firefly k3s cluster, so this VCN needs a
  # path to the control plane at home AND to the other cluster members' VXLAN
  # endpoints. Everything on-prem is reached over this tenancy's own IPSec
  # tunnels to the FortiGates (../vpn), i.e. via = "drg".
  #
  # Firefly's VCN is NOT, and the hairpin-through-FG1 plan this file originally
  # described is abandoned: two DRGs that are both Oracle AS 31898 cannot
  # exchange prefixes through a single FG1 without as-override, and the failure
  # is silent. ff-chr3 now carries that leg over WireGuard instead
  # (terraform/mikrotik/wireguard-mesh/prod).
  remote_networks = {
    sargeant_home = {
      cidr        = "192.168.19.0/24"
      description = "Sargeant home internal LAN (behind FG1/CRS) — holds the k3s control plane at .10"
    }
    fg1_vlans = {
      cidr        = "192.168.220.0/23"
      description = "FortiGate FG1 home VLANs (iot/sargeant/area51/guest/mgmt)"
    }
    fg2_lan = {
      cidr        = "192.168.99.0/24"
      description = "FortiGate FG2 LAN (reached via FG1)"
    }
    fg_transit = {
      cidr        = "10.19.19.0/29"
      description = "FortiGate FG1 lifeline transit segment"
    }
    # The entry firefly's own network leaf does not (and cannot) have: a VCN
    # never lists itself. Without it ff-oci3 has no route to ff-oci1/ff-oci2 and
    # the flannel mesh is one-way.
    #
    # via = "chr" — see the matching note on `cloudworkers_vcn` in firefly's own
    # network leaf. This entry WAS applied, pointing at the DRG, and that is why
    # the failure was asymmetric and confusing: ff-oci3 had a route towards
    # ff-oci1 and firefly had none back. Traceroute from ff-oci3 to
    # 192.168.223.71 left via the DRG and died there, because FG1 never learned
    # 192.168.223.0/24 from this tenancy's side of the AS 31898 pair.
    firefly_vcn = {
      cidr        = "192.168.223.0/24"
      description = "Firefly OCI VCN (caleb tenancy) — ff-oci1/ff-oci2, via ff-chr3 WireGuard"
      via         = "chr"
    }
    # k3s cluster CIDRs — these nodes are members of the on-prem k3s cluster
    # over the tunnel, so the VCN must admit (and return-route) pod/service
    # traffic. Without these, pod-sourced traffic from on-prem to these nodes
    # is dropped at the cloud edge.
    cluster_pods = {
      cidr        = "10.42.0.0/16"
      description = "k3s pod CIDR (flannel)"
    }
    cluster_services = {
      cidr        = "10.43.0.0/16"
      description = "k3s service CIDR"
    }
    # 192.168.72.0/24 (FranklinHouse OCI) is deliberately absent — that peering
    # is firefly's DRG-to-Johannesburg RPC, and cloudworkers has no path to it.
  }
}
