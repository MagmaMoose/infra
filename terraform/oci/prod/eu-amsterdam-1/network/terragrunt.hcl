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
  operator_mgmt_cidrs_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aaqvgllhc77ptjy7npdstq6jp67j5auvhn4y4keiqcqhwa"

  # Direct `oci` call + base64decode in HCL (no `bash -c`) so this parses on
  # Windows/PowerShell, which has no bash. Pattern: cloudflare/zero-trust/prod.
  operator_mgmt_cidrs = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.operator_mgmt_cidrs_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))
}

inputs = {
  tenancy_ocid        = get_env("OCI_TENANCY_OCID", "")
  user_ocid           = get_env("OCI_USER_OCID", "")
  fingerprint         = get_env("OCI_FINGERPRINT", "")
  private_key_path    = get_env("OCI_PRIVATE_KEY_PATH", "")
  region              = local.region_vars.locals.region
  compartment_ocid    = get_env("OCI_COMPARTMENT_OCID", "")
  environment         = local.environment_vars.locals.environment
  ssh_public_key_path = "${get_repo_root()}/ansible/keys/id_rsa.pub"

  # VCN CIDR - using 192.168.223.0/24 split into 4x /26 subnets
  vcn_cidr_blocks = ["192.168.223.0/24"]

  # Subnet configuration
  subnets = {
    edge = {
      cidr = "192.168.223.0/26" # .1-.62 for edge/routers (public)
    }
    app = {
      cidr = "192.168.223.64/26" # .65-.126 for app/workload (private)
    }
    data = {
      cidr = "192.168.223.128/26" # .129-.190 for database (private)
    }
    spare = {
      cidr = "192.168.223.192/26" # .193-.254 reserved (private)
    }
  }

  # Enable VPN for site-to-site connectivity
  enable_vpn = true

  # Default route for app + data subnets points at mikrotik-fd1 (in edge subnet)
  # which masquerades outbound traffic to its public IP. Single-MikroTik for
  # now; HA via VRRP would let this point at a shared address instead — see
  # docs/reference/oci-infra-improvements.md.
  internet_gateway_ip = "192.168.223.11"

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
  # Loaded from OCI Vault (see local.operator_mgmt_cidrs above) so the public
  # repo doesn't broadcast which IP is whitelisted.
  routeros_api_management_cidrs = local.operator_mgmt_cidrs

  # Remote networks accessible via VPN. The FortiGate sites reach OCI over the
  # per-FortiGate BGP S2S tunnels (terraform/oci/.../vpn-fortigate); these rules
  # send VCN return traffic for the on-prem CIDRs to the DRG.
  remote_networks = {
    sargeant_home = {
      cidr        = "192.168.19.0/24"
      description = "Sargeant home internal LAN (behind FG1/CRS)"
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
    # k3s cluster CIDRs — the OCI nodes are members of the on-prem k3s cluster
    # over the tunnel, so the VCN must admit (and return-route) pod/service
    # traffic. Without these, pod-sourced traffic from on-prem to the OCI nodes
    # is dropped at the cloud edge. (The OCI VMs' own host firewall must also
    # admit it — see the oci-node-firewall DaemonSet.)
    cluster_pods = {
      cidr        = "10.42.0.0/16"
      description = "k3s pod CIDR (flannel)"
    }
    cluster_services = {
      cidr        = "10.43.0.0/16"
      description = "k3s service CIDR"
    }
    franklinhouse_oci = {
      cidr        = "192.168.72.0/24"
      description = "FranklinHouse OCI Johannesburg (DRG peering)"
    }
    # The second OCI tenancy (traceysargeant) holding ff-oci3/ff-oci4. They are
    # agents of THIS cluster, so this VCN must route and admit their traffic —
    # without this entry the flannel mesh between the two OCI pairs is one-way.
    # Mirrored by `firefly_vcn` in terraform/oci/cloudworkers/.../network.
    #
    # via = "chr", NOT the DRG. The hairpin-through-FG1 story this entry was
    # first written for does not work and cannot be made to work with static
    # routes alone: both tenancies' DRGs are Oracle AS 31898, so FG1 drops the
    # far prefix on BGP AS_PATH loop detection and re-advertises nothing. The
    # tunnels come up green and the prefix never appears — which is exactly how
    # it presented on 2026-09-01: pods on ff-oci1/ff-oci2 timed out to pods on
    # ff-oci3/ff-oci4 while on-prem reached both, and traceroute from ff-oci1
    # showed the packet leaving ff-chr1's masquerade onto the public internet
    # because this route did not exist at all (this leaf had never been applied
    # since the entry was added in #685).
    #
    # The path is now ff-chr1 -> WireGuard -> ff-chr3, built by
    # terraform/mikrotik/wireguard-mesh/prod. That leaf must be applied first:
    # this route points at ff-chr1, and until ff-chr1 holds a WireGuard route
    # for 192.168.240.0/24 it will bounce the packet straight back into the VCN.
    cloudworkers_vcn = {
      cidr        = "192.168.240.0/24"
      description = "Cloudworkers OCI VCN (tracey tenancy) — ff-oci3/ff-oci4, via ff-chr1 WireGuard"
      via         = "chr"
    }
    # AWS network - uncomment when AWS VPN is configured
    # aws_af_south_1 = {
    #   cidr        = "10.0.0.0/16"  # Update with actual AWS VPC CIDR
    #   description = "AWS af-south-1 VPC"
    # }
  }
}
