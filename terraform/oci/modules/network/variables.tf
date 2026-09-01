variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the OCI API key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the OCI API private key"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., prod, dev)"
  type        = string
}

variable "vcn_cidr_blocks" {
  description = "List of CIDR blocks for the VCN"
  type        = list(string)
  default     = ["192.168.223.0/24"]
}

variable "subnets" {
  description = "Subnet configuration for edge, app, data, and spare tiers"
  type = object({
    edge = object({
      cidr = string
    })
    app = object({
      cidr = string
    })
    data = object({
      cidr = string
    })
    spare = object({
      cidr = string
    })
  })
  default = {
    edge = {
      cidr = "192.168.223.0/26"
    }
    app = {
      cidr = "192.168.223.64/26"
    }
    data = {
      cidr = "192.168.223.128/26"
    }
    spare = {
      cidr = "192.168.223.192/26"
    }
  }
}

variable "enable_vpn" {
  description = "Enable VPN connectivity (creates DRG)"
  type        = bool
  default     = false
}

variable "remote_networks" {
  description = <<-DESC
    Remote networks this VCN can reach. Drives BOTH the route rules in every
    route table AND the "allow all from remote networks" ingress rules in the
    security lists.

    `via` picks the next hop for the route half only; the ingress half is the
    same either way, because a security list does not care which door the packet
    came through.

      "drg" (default) — hand it to the DRG, i.e. out over this tenancy's IPSec
                        tunnels. Correct for anything behind the FortiGates.

      "chr"           — hand it to the MikroTik CHR at var.internet_gateway_ip,
                        which carries it over a WireGuard tunnel of its own.
                        Correct for the OTHER OCI tenancy: both DRGs are Oracle
                        AS 31898, so FG1 cannot re-advertise one tenancy's
                        prefix to the other (BGP drops it on AS_PATH loop) and
                        the DRG hairpin silently never forms. See
                        terraform/mikrotik/wireguard-mesh/prod.

    A "chr" entry needs var.internet_gateway_ip set, and needs the CHR to hold a
    route for that prefix — otherwise the CHR's own default route sends the
    packet back into the VCN, which sends it back to the CHR.
  DESC
  type = map(object({
    cidr        = string
    description = string
    via         = optional(string, "drg")
  }))
  default = {}

  validation {
    condition     = alltrue([for n in var.remote_networks : contains(["drg", "chr"], n.via)])
    error_message = "remote_networks[*].via must be \"drg\" or \"chr\"."
  }

  validation {
    condition     = var.internet_gateway_ip != "" || length([for n in var.remote_networks : n if n.via == "chr"]) == 0
    error_message = "A remote_network with via = \"chr\" needs internet_gateway_ip set — that is the CHR the route points at."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
}

variable "internet_gateway_ip" {
  description = "Private IP (in the edge subnet) of the gateway that the app/data subnets use as their 0.0.0.0/0 next-hop, typically a MikroTik CHR doing NAT to its public IP. Empty disables the default route."
  type        = string
  default     = ""
}

variable "wireguard_ingress_port_ranges" {
  description = <<-DESC
    UDP port ranges the edge subnet accepts WireGuard on, from 0.0.0.0/0. The
    CHRs' public IPs live in that subnet and a site-to-site tunnel has to be
    dialable from the far site, which is by definition an arbitrary internet
    address.

    Defaults to just 51820, which is what this module hardcoded before, so a
    leaf that does not set it renders identically.

    Worth opening explicitly even though the tunnels appear to work without it:
    OCI security lists are stateful, so a CHR that dials OUT gets the replies
    back regardless, and a mesh where both ends dial will come up on a port
    nothing admits. That is a tunnel held together by a state-table entry — it
    survives until the one moment you need it to recover unattended.
  DESC
  type = list(object({
    min = number
    max = number
  }))
  default = [{ min = 51820, max = 51820 }]
}

variable "routeros_api_management_cidrs" {
  description = "CIDRs allowed to reach the MikroTik CHR plaintext binary API (port 8728) on the public IPs in the edge subnet. The routeros terraform provider requires this access; keep the list narrow because the API session isn't TLS-wrapped. Empty disables the rule entirely."
  type        = list(string)
  default     = []
}