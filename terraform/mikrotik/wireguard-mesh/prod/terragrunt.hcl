# ---------------------------------------------------------------------------
# The WireGuard mesh that joins the three router sites.
#
#   ff-crs1                     home (Sargeant House), behind FG1
#   ff-chr1 / ff-chr2           calebsargeant OCI, VCN 192.168.223.0/24
#   ff-chr3 / ff-chr4           traceysargeant OCI, VCN 192.168.240.0/24
#
# Ten point-to-point tunnels — every router to every other router. One leaf
# rather than one per site, because a tunnel is a single object with two ends:
# each end's peer references the other end's generated public key, and only one
# state file can hold both. Splitting it would mean copying keys between two
# terragrunt runs by hand, which is exactly the manual step this replaces.
#
# WHY THIS EXISTS AT ALL. The two OCI tenancies had no path to each other. Both
# their DRGs are Oracle AS 31898, so the plan of hairpinning through FG1 could
# never work: FG1 drops the far tenancy's prefix on BGP AS_PATH loop detection
# and silently re-advertises nothing. On 2026-09-01 that surfaced as pods on
# ff-oci1/ff-oci2 timing out to pods on ff-oci3/ff-oci4 — flannel's VXLAN
# between the two node IPs had nowhere to go — while on-prem reached both
# environments fine over its own IPSec tunnels. This mesh is the transport that
# replaces the hairpin; the two `network` leaves point their route rules at it
# with `via = "chr"`.
#
# NOT A REPLACEMENT FOR THE FORTIGATE IPSEC. The home legs are built and kept
# warm, but nothing routes production traffic over them: ff-crs1 installs no
# prefix routes, so home <-> OCI still runs over FG1's IPSec exactly as before.
# Moving that leg is a separate, deliberate change (add `routes` entries below),
# not something to fold into an outage fix. The tunnels being up means the
# option is there and provably works.
# ---------------------------------------------------------------------------

remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "mikrotik/wireguard-mesh/prod"
    project  = "magmamoose-terraform"
    location = "europe-west4"
  }
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<BACKEND
terraform {
  backend "gcs" {}
}
BACKEND
}

terraform {
  source = "${get_repo_root()}/terraform/mikrotik/modules/wireguard-mesh"
}

# ---------------------------------------------------------------------------
# Credentials. Two sets, because the two OCI environments are separate Oracle
# accounts with separate admin passwords — ff-chr3/ff-chr4 must NOT share
# firefly's. Both secrets live in firefly's vault-prod and are read at parse
# time with the operator's ~/.oci/config, the same pattern the cloudworkers
# leaves already use for `operator-mgmt-cidrs`.
#
# PUBLIC repo — no password is ever inlined here.
# ---------------------------------------------------------------------------
locals {
  # vault-prod / mikrotik-credentials — ff-crs1, ff-chr1, ff-chr2.
  firefly_creds_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aaaizjuctq6do5iou2xo5yibpuiirdwwdjurwllubxlima"

  # vault-prod / mikrotik-credentials-cloudworkers — ff-chr3, ff-chr4. Created
  # 2026-09-01, at the same time as the password it holds: both CHRs had been
  # running since 2026-08-31 with a BLANK admin password and ssh/winbox reachable
  # from 0.0.0.0/0 through the edge security list, because the ADR deferred a
  # cloudworkers mikrotik leaf and nothing else was going to set one.
  cloudworkers_creds_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aas763xzyonuime2jy45rrbs6uv3a7v5pldvzuicoqnjia"

  # Direct `oci` calls + base64decode/jsondecode in HCL (no `bash -c`, no jq) so
  # this parses on Windows/PowerShell too. Same shape as the oci/mikrotik leaf.
  firefly_password = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.firefly_creds_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))["password"]

  cloudworkers_password = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.cloudworkers_creds_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))["password"]
}

inputs = {
  # -------------------------------------------------------------------------
  # Routers.
  #
  # `hosturl` is the plaintext binary API, matching the other two mikrotik
  # leaves — see terraform/oci/prod/eu-amsterdam-1/mikrotik for why it is not
  # the TLS API yet. The OCI routers are addressed on their PUBLIC IPs because
  # that is the only address reachable from outside their own VCN; ff-crs1 is on
  # the home LAN.
  #
  # `endpoint_address` is what the far end dials for WireGuard. ff-crs1 has none
  # on purpose: it sits behind FG1 with no port forward for these ports, so it
  # is the initiator on all four of its tunnels and nothing ever dials it.
  # -------------------------------------------------------------------------
  routers = {
    "ff-crs1" = {
      hosturl          = "api://192.168.19.1:8728"
      endpoint_address = "" # behind FG1 — initiator only, see tunnels below
      site             = "home"
    }
    "ff-chr1" = {
      hosturl          = "api://134.98.139.9:8728"
      endpoint_address = "134.98.139.9"
      site             = "calebsargeant-oci"
    }
    "ff-chr2" = {
      hosturl          = "api://193.123.39.172:8728"
      endpoint_address = "193.123.39.172"
      site             = "calebsargeant-oci"
    }
    "ff-chr3" = {
      hosturl          = "api://158.178.154.125:8728"
      endpoint_address = "158.178.154.125"
      site             = "traceysargeant-oci"
    }
    "ff-chr4" = {
      hosturl          = "api://84.235.162.6:8728"
      endpoint_address = "84.235.162.6"
      site             = "traceysargeant-oci"
    }
  }

  # Kept out of `routers` because OpenTofu will not accept a sensitive value as a
  # provider for_each argument, and `routers` is that argument.
  router_passwords = {
    "ff-crs1" = local.firefly_password
    "ff-chr1" = local.firefly_password
    "ff-chr2" = local.firefly_password
    "ff-chr3" = local.cloudworkers_password
    "ff-chr4" = local.cloudworkers_password
  }

  # -------------------------------------------------------------------------
  # Tunnels. Ten of them: 5 routers, every unordered pair.
  #
  # TRANSIT ADDRESSING — 192.168.255.0/26, carved into /30s. Chosen because
  # ff-crs1 already carries 192.168.255.244/30, .248/30 and .252/30 for its
  # franklinhouse and (now superseded) oci-r1/oci-r2 links, so the top of that
  # /24 is spoken for and the bottom is clear.
  #
  # LISTEN PORTS. ff-crs1 listens on 51841-51844 — not 51820+, because it already
  # uses 51820 (ra_vpn), 51822 (franklinhouse), 51826 (p1aws_chr2), 51830, 51880,
  # 51888 and 51889, and a collision there would break a working tunnel rather
  # than fail loudly. OCI-to-OCI tunnels use 51845-51850, one per tunnel, the
  # same number at both ends, which keeps the OCI security-list rule to a single
  # contiguous range.
  #
  # THE CRS1 TUNNELS OVERRIDE THE FAR END TO 51820, and that is load-bearing.
  # Measured 2026-09-01: ff-crs1 could ping every CHR public IP but WireGuard on
  # 51841-51844 never got a single packet through — tx climbing, rx flat at 0 on
  # both ends. The home edge (FG1) only passes certain outbound UDP DESTINATION
  # ports; 51820 and 51822 are already permitted, which is why the existing
  # franklinhouse and p1aws tunnels work and these did not. Moving one tunnel's
  # far-end port to 51820 made it handshake in under a second.
  #
  # Every CHR can bind 51820 because each has exactly one tunnel to ff-crs1.
  # ff-crs1's own listen port is irrelevant to this: it is always the initiator,
  # so its port is a SOURCE port and nothing filters on that.
  #
  # 51820 is also the one UDP port firefly's edge security list already admitted
  # from 0.0.0.0/0, which is a second, independent reason it is the safe choice
  # for the leg that crosses two edges neither of us controls.
  #
  # INITIATOR — every tunnel touching ff-crs1 names ff-crs1, because nothing can
  # dial into it. OCI-to-OCI tunnels are "both": two static public IPs, so
  # either end recovering on its own is strictly better.
  # -------------------------------------------------------------------------
  tunnels = {
    # --- home <-> calebsargeant OCI ---
    "crs1-chr1" = { a = "ff-crs1", b = "ff-chr1", transit_cidr = "192.168.255.0/30", listen_port = 51841, listen_port_b = 51820, initiator = "ff-crs1" }
    "crs1-chr2" = { a = "ff-crs1", b = "ff-chr2", transit_cidr = "192.168.255.4/30", listen_port = 51842, listen_port_b = 51820, initiator = "ff-crs1" }

    # --- home <-> traceysargeant OCI ---
    "crs1-chr3" = { a = "ff-crs1", b = "ff-chr3", transit_cidr = "192.168.255.8/30", listen_port = 51843, listen_port_b = 51820, initiator = "ff-crs1" }
    "crs1-chr4" = { a = "ff-crs1", b = "ff-chr4", transit_cidr = "192.168.255.12/30", listen_port = 51844, listen_port_b = 51820, initiator = "ff-crs1" }

    # --- within calebsargeant OCI (standby path for a next-hop flip) ---
    "chr1-chr2" = { a = "ff-chr1", b = "ff-chr2", transit_cidr = "192.168.255.16/30", listen_port = 51845 }

    # --- calebsargeant OCI <-> traceysargeant OCI: the leg that was missing ---
    "chr1-chr3" = { a = "ff-chr1", b = "ff-chr3", transit_cidr = "192.168.255.20/30", listen_port = 51846 }
    "chr1-chr4" = { a = "ff-chr1", b = "ff-chr4", transit_cidr = "192.168.255.24/30", listen_port = 51847 }
    "chr2-chr3" = { a = "ff-chr2", b = "ff-chr3", transit_cidr = "192.168.255.28/30", listen_port = 51848 }
    "chr2-chr4" = { a = "ff-chr2", b = "ff-chr4", transit_cidr = "192.168.255.32/30", listen_port = 51849 }

    # --- within traceysargeant OCI (standby path for a next-hop flip) ---
    "chr3-chr4" = { a = "ff-chr3", b = "ff-chr4", transit_cidr = "192.168.255.36/30", listen_port = 51850 }
  }

  # -------------------------------------------------------------------------
  # Routes.
  #
  # Only the OCI <-> OCI leg carries production traffic. Both `network` leaves
  # send the far tenancy's /24 to their own CHR (`via = "chr"`), and these
  # entries are what that CHR does with it next.
  #
  # PRIMARY IS ALWAYS chr1 <-> chr3, because those two are the ones the VCN
  # route tables actually point at (`internet_gateway_ip` is .11 in both VCNs).
  # ff-chr2 and ff-chr4 get the mirror-image routes so that flipping a VCN route
  # table to .12 is a one-line change with a tunnel already up behind it, rather
  # than a new tunnel to build during an incident.
  #
  # No route is installed on ff-crs1 — see the header. Adding 192.168.223.0/24
  # or 192.168.240.0/24 here would immediately divert home traffic off the
  # working FortiGate IPSec, because a /24 beats the default route regardless of
  # distance.
  #
  # These entries also generate each peer's `allowed-address`: a prefix routed
  # over a tunnel is exactly the prefix that tunnel is allowed to deliver. See
  # modules/wireguard-mesh/variables.tf.
  #
  # 10.42.0.0/16 and 10.43.0.0/16 are deliberately absent. Pod-to-pod between the
  # two environments is flannel VXLAN between NODE addresses, so routing the two
  # /24s is sufficient and the pod CIDR never appears on the wire unwrapped. Both
  # VCNs already hand 10.42/10.43 to their DRG for on-prem traffic, and a second
  # competing path for the same prefix is how you get an asymmetric route that
  # passes a ping and drops a TCP session.
  # -------------------------------------------------------------------------
  routes = [
    # calebsargeant OCI -> traceysargeant OCI
    { router = "ff-chr1", dst = "192.168.240.0/24", via = "chr1-chr3", distance = 1, comment = "cloudworkers VCN via ff-chr3" },
    { router = "ff-chr1", dst = "192.168.240.0/24", via = "chr1-chr4", distance = 2, comment = "cloudworkers VCN via ff-chr4 (standby)" },
    { router = "ff-chr2", dst = "192.168.240.0/24", via = "chr2-chr3", distance = 1, comment = "cloudworkers VCN via ff-chr3" },
    { router = "ff-chr2", dst = "192.168.240.0/24", via = "chr2-chr4", distance = 2, comment = "cloudworkers VCN via ff-chr4 (standby)" },

    # traceysargeant OCI -> calebsargeant OCI
    { router = "ff-chr3", dst = "192.168.223.0/24", via = "chr1-chr3", distance = 1, comment = "firefly VCN via ff-chr1" },
    { router = "ff-chr3", dst = "192.168.223.0/24", via = "chr2-chr3", distance = 2, comment = "firefly VCN via ff-chr2 (standby)" },
    { router = "ff-chr4", dst = "192.168.223.0/24", via = "chr1-chr4", distance = 1, comment = "firefly VCN via ff-chr1" },
    { router = "ff-chr4", dst = "192.168.223.0/24", via = "chr2-chr4", distance = 2, comment = "firefly VCN via ff-chr2 (standby)" },
  ]
}
