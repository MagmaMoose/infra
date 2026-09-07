resource "oci_core_virtual_network" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "vcn-${var.environment}"
  cidr_blocks    = var.vcn_cidr_blocks
  dns_label      = "vcn${var.environment}"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "ig-${var.environment}"
  vcn_id         = oci_core_virtual_network.this.id
  enabled        = true
}

# Dynamic Routing Gateway for VPN connectivity
resource "oci_core_drg" "this" {
  count          = var.enable_vpn ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "drg-${var.environment}"
}

resource "oci_core_drg_attachment" "this" {
  count        = var.enable_vpn ? 1 : 0
  drg_id       = oci_core_drg.this[0].id
  display_name = "drg-attachment-${var.environment}"

  network_details {
    id   = oci_core_virtual_network.this.id
    type = "VCN"
  }
}

# Edge Subnet - Public subnet for edge/router instances (e.g., MikroTik CHR)
resource "oci_core_subnet" "edge" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_virtual_network.this.id
  display_name               = "subnet-edge-${var.environment}"
  cidr_block                 = var.subnets.edge.cidr
  route_table_id             = oci_core_route_table.edge.id
  dns_label                  = "edge"
  prohibit_public_ip_on_vnic = false
  security_list_ids          = [oci_core_security_list.edge.id]
}

# App Subnet - Private subnet for application/workload instances
resource "oci_core_subnet" "app" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_virtual_network.this.id
  display_name               = "subnet-app-${var.environment}"
  cidr_block                 = var.subnets.app.cidr
  route_table_id             = oci_core_route_table.app.id
  dns_label                  = "app"
  prohibit_public_ip_on_vnic = true
  security_list_ids          = [oci_core_security_list.app.id]
}

# Data Subnet - Private subnet for database instances
resource "oci_core_subnet" "data" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_virtual_network.this.id
  display_name               = "subnet-data-${var.environment}"
  cidr_block                 = var.subnets.data.cidr
  route_table_id             = oci_core_route_table.data.id
  dns_label                  = "data"
  prohibit_public_ip_on_vnic = true
  security_list_ids          = [oci_core_security_list.data.id]
}

# Spare Subnet - Reserved for future use
resource "oci_core_subnet" "spare" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_virtual_network.this.id
  display_name               = "subnet-spare-${var.environment}"
  cidr_block                 = var.subnets.spare.cidr
  route_table_id             = oci_core_route_table.spare.id
  dns_label                  = "spare"
  prohibit_public_ip_on_vnic = true
  security_list_ids          = [oci_core_security_list.spare.id]
}

# Route Tables
resource "oci_core_route_table" "edge" {
  compartment_id = var.compartment_ocid
  display_name   = "rt-edge-${var.environment}"
  vcn_id         = oci_core_virtual_network.this.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  # VPN routes to remote networks — DRG entries only.
  #
  # A `via = "chr"` entry cannot appear here, and not for a policy reason: the
  # CHR's next-hop OCID is resolved by a data source that looks the address up
  # inside oci_core_subnet.edge, and oci_core_subnet.edge takes its route table
  # from THIS resource. Referencing the CHR here is a dependency cycle that
  # OpenTofu rejects outright.
  #
  # Nothing is lost. The only things in the edge subnet are the CHRs themselves,
  # and each already holds its own WireGuard route to the far tenancy — a route
  # rule here would be consulted for their traffic only if they did not, and
  # then it would point them at each other. Omitted rather than pointed at the
  # DRG, because the DRG cannot carry these prefixes at all; a rule sending them
  # there is a black hole that looks like configuration.
  dynamic "route_rules" {
    for_each = var.enable_vpn ? { for k, n in var.remote_networks : k => n if n.via == "drg" } : {}
    content {
      destination       = route_rules.value.cidr
      destination_type  = "CIDR_BLOCK"
      network_entity_id = local.drg_next_hop
      description       = route_rules.value.description
    }
  }
}

# Lookup the OCID of the edge-subnet private IP used as the internet next-hop
# (MikroTik CHR). OCI routes to in-VCN IPs reference the private-ip OCID, not
# the address itself, so this data source resolves it at apply time.
data "oci_core_private_ips" "internet_gateway" {
  count      = var.internet_gateway_ip != "" ? 1 : 0
  ip_address = var.internet_gateway_ip
  subnet_id  = oci_core_subnet.edge.id

  lifecycle {
    postcondition {
      condition     = length(self.private_ips) > 0
      error_message = "No private IP ${var.internet_gateway_ip} found in edge subnet — ensure the MikroTik CHR is up and has this IP assigned before applying the network module. (You may need to apply the `edge` module first.)"
    }
  }
}

# Next-hop OCID per remote network. Resolved once here rather than inline in each
# of the four route tables below, so they cannot drift apart — a prefix routed to
# the DRG in one subnet and to the CHR in another is an asymmetric path that
# works for exactly the subnets you happened to test from.
#
# `one()` rather than `[0]`: both the data source and the DRG are count-gated, and
# a bare [0] on an empty list errors even when the conditional would not have
# selected that branch. The four route tables get away with `[0]` only because
# their `dynamic` blocks are guarded by an empty for_each, which stops the body
# being evaluated at all.
locals {
  chr_private_ip = one(data.oci_core_private_ips.internet_gateway)
  chr_next_hop   = local.chr_private_ip != null ? local.chr_private_ip.private_ips[0].id : null
  drg_next_hop   = one(oci_core_drg.this) != null ? one(oci_core_drg.this).id : null

  remote_network_next_hop = {
    for k, n in var.remote_networks : k => (
      n.via == "chr" ? local.chr_next_hop : local.drg_next_hop
    )
  }
}

resource "oci_core_route_table" "app" {
  compartment_id = var.compartment_ocid
  display_name   = "rt-app-${var.environment}"
  vcn_id         = oci_core_virtual_network.this.id

  # Default route: send internet-bound traffic to the MikroTik CHR for NAT
  dynamic "route_rules" {
    for_each = var.internet_gateway_ip != "" ? [1] : []
    content {
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = data.oci_core_private_ips.internet_gateway[0].private_ips[0].id
      description       = "Internet egress via MikroTik (${var.internet_gateway_ip})"
    }
  }

  # VPN routes to remote networks. next-hop per entry — see var.remote_networks.
  dynamic "route_rules" {
    for_each = var.enable_vpn ? var.remote_networks : {}
    content {
      destination       = route_rules.value.cidr
      destination_type  = "CIDR_BLOCK"
      network_entity_id = local.remote_network_next_hop[route_rules.key]
      description       = route_rules.value.description
    }
  }
}

resource "oci_core_route_table" "data" {
  compartment_id = var.compartment_ocid
  display_name   = "rt-data-${var.environment}"
  vcn_id         = oci_core_virtual_network.this.id

  # Default route: send internet-bound traffic to the MikroTik CHR for NAT
  dynamic "route_rules" {
    for_each = var.internet_gateway_ip != "" ? [1] : []
    content {
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = data.oci_core_private_ips.internet_gateway[0].private_ips[0].id
      description       = "Internet egress via MikroTik (${var.internet_gateway_ip})"
    }
  }

  # VPN routes to remote networks. next-hop per entry — see var.remote_networks.
  dynamic "route_rules" {
    for_each = var.enable_vpn ? var.remote_networks : {}
    content {
      destination       = route_rules.value.cidr
      destination_type  = "CIDR_BLOCK"
      network_entity_id = local.remote_network_next_hop[route_rules.key]
      description       = route_rules.value.description
    }
  }
}

resource "oci_core_route_table" "spare" {
  compartment_id = var.compartment_ocid
  display_name   = "rt-spare-${var.environment}"
  vcn_id         = oci_core_virtual_network.this.id

  # VPN routes to remote networks. next-hop per entry — see var.remote_networks.
  dynamic "route_rules" {
    for_each = var.enable_vpn ? var.remote_networks : {}
    content {
      destination       = route_rules.value.cidr
      destination_type  = "CIDR_BLOCK"
      network_entity_id = local.remote_network_next_hop[route_rules.key]
      description       = route_rules.value.description
    }
  }
}

# Security Lists
resource "oci_core_security_list" "edge" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.this.id
  display_name   = "sl-edge-${var.environment}"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # WireGuard. One rule per range in var.wireguard_ingress_port_ranges — see
  # there for why this is not just 51820.
  dynamic "ingress_security_rules" {
    for_each = var.wireguard_ingress_port_ranges
    content {
      protocol = "17" # UDP
      source   = "0.0.0.0/0"
      udp_options {
        min = ingress_security_rules.value.min
        max = ingress_security_rules.value.max
      }
    }
  }

  # IPSec IKE
  ingress_security_rules {
    protocol = "17" # UDP
    source   = "0.0.0.0/0"
    udp_options {
      min = 500
      max = 500
    }
  }

  # IPSec NAT-T
  ingress_security_rules {
    protocol = "17" # UDP
    source   = "0.0.0.0/0"
    udp_options {
      min = 4500
      max = 4500
    }
  }

  # MikroTik Winbox
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 8291
      max = 8291
    }
  }

  # MikroTik API (port 8728, plaintext binary) — only opened to operator IPs
  # because it's used by the routeros terraform provider, which needs reach
  # from wherever `terragrunt apply` runs. Auth is challenge-response so
  # passwords don't traverse the wire in cleartext, but the session itself
  # is unencrypted; keep this list narrow. Migrate to apis://:8729 (TLS API)
  # and drop this whole block once the cert situation is sorted.
  dynamic "ingress_security_rules" {
    for_each = toset(var.routeros_api_management_cidrs)
    content {
      protocol = "6" # TCP
      source   = ingress_security_rules.value
      tcp_options {
        min = 8728
        max = 8728
      }
    }
  }

  # ICMP
  ingress_security_rules {
    protocol = 1 # ICMP
    source   = "0.0.0.0/0"
    icmp_options {
      type = 8 # Echo request
    }
  }

  # Allow all from VCN
  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr_blocks[0]
  }

  # Allow all from remote networks (VPN)
  dynamic "ingress_security_rules" {
    for_each = var.remote_networks
    content {
      protocol = "all"
      source   = ingress_security_rules.value.cidr
    }
  }
}

resource "oci_core_security_list" "app" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.this.id
  display_name   = "sl-app-${var.environment}"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH from edge subnet
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.edge.cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  # K3s API
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # HTTP/HTTPS from edge
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.edge.cidr
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.edge.cidr
    tcp_options {
      min = 443
      max = 443
    }
  }

  # ICMP from VCN
  ingress_security_rules {
    protocol = 1 # ICMP
    source   = var.vcn_cidr_blocks[0]
    icmp_options {
      type = 8 # Echo request
    }
  }

  # Allow all from VCN
  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr_blocks[0]
  }

  # Allow all from remote networks (VPN)
  dynamic "ingress_security_rules" {
    for_each = var.remote_networks
    content {
      protocol = "all"
      source   = ingress_security_rules.value.cidr
    }
  }
}

resource "oci_core_security_list" "data" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.this.id
  display_name   = "sl-data-${var.environment}"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # MySQL from app subnet
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.app.cidr
    tcp_options {
      min = 3306
      max = 3306
    }
  }

  # MySQL from edge subnet (for management)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.edge.cidr
    tcp_options {
      min = 3306
      max = 3306
    }
  }

  # SSH from edge subnet
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.edge.cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP from VCN
  ingress_security_rules {
    protocol = 1 # ICMP
    source   = var.vcn_cidr_blocks[0]
    icmp_options {
      type = 8 # Echo request
    }
  }

  # Allow all from remote networks (VPN) - for database replication/access
  dynamic "ingress_security_rules" {
    for_each = var.remote_networks
    content {
      protocol = "6" # TCP
      source   = ingress_security_rules.value.cidr
      tcp_options {
        min = 3306
        max = 3306
      }
    }
  }
}

resource "oci_core_security_list" "spare" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.this.id
  display_name   = "sl-spare-${var.environment}"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH from edge subnet
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.subnets.edge.cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP from VCN
  ingress_security_rules {
    protocol = 1 # ICMP
    source   = var.vcn_cidr_blocks[0]
    icmp_options {
      type = 8 # Echo request
    }
  }
}

# Network Security Group (for instances that need additional controls)
resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.this.id
  display_name   = "nsg-${var.environment}"
}

# NSG Rules
resource "oci_core_network_security_group_security_rule" "ssh" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "http" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "https" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "k3s_api" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}
