# ============================================================================
# WireGuard mesh across MikroTik routers in three sites. See variables.tf for
# why this is one interface per tunnel rather than one interface with N peers.
# ============================================================================

locals {
  # Every (router, tunnel) pair, flattened into one list so each RouterOS object
  # can be a single for_each'd resource. `self` is the router the object is
  # created ON; `peer` is the far end.
  #
  # Both ends of a tunnel appear here, which is what lets the peer resource on
  # one end reference the interface resource on the other by key.
  ends = merge([
    for tk, t in var.tunnels : {
      "${t.a}/${tk}" = {
        tunnel    = tk
        self      = t.a
        peer      = t.b
        self_ip   = cidrhost(t.transit_cidr, 1)
        peer_ip   = cidrhost(t.transit_cidr, 2)
        self_port = coalesce(t.listen_port_a, t.listen_port)
        peer_port = coalesce(t.listen_port_b, t.listen_port)
        cfg       = t
      }
      "${t.b}/${tk}" = {
        tunnel    = tk
        self      = t.b
        peer      = t.a
        self_ip   = cidrhost(t.transit_cidr, 2)
        peer_ip   = cidrhost(t.transit_cidr, 1)
        self_port = coalesce(t.listen_port_b, t.listen_port)
        peer_port = coalesce(t.listen_port_a, t.listen_port)
        cfg       = t
      }
    }
  ]...)

  # Interface name as it appears in the RouterOS CLI: wg-<far end>. Reading
  # `/interface/wireguard print` on ff-chr1 then tells you at a glance which
  # box is on the other side, which "wg1/wg2/wg3" never would.
  #
  # RouterOS allows 32 characters; "wg-" + an ff-xxxN key is well inside that.
  iface_name = { for k, e in local.ends : k => "wg-${e.peer}" }

  # allowed-address per end = the far end's transit /32, plus every prefix this
  # router routes over this tunnel, plus any explicit extras. See variables.tf:
  # this is deliberately derived from var.routes rather than restated, because a
  # route and its allowed-address entry must agree or the tunnel blackholes.
  routed_over = {
    for k, e in local.ends : k => [
      for r in var.routes : r.dst if r.router == e.self && r.via == e.tunnel
    ]
  }

  allowed_addresses = {
    for k, e in local.ends : k => distinct(concat(
      ["${e.peer_ip}/32"],
      local.routed_over[k],
      lookup(var.extra_allowed_addresses, "${e.self}/${e.tunnel}", []),
    ))
  }

  # An end dials out when it is named as the tunnel's initiator (or when both
  # are). A dialling end needs the far side to actually have a public address —
  # asserted below rather than left to produce a peer with an empty endpoint,
  # which RouterOS accepts and which then never connects.
  initiates = {
    for k, e in local.ends : k => (e.cfg.initiator == "both" || e.cfg.initiator == e.self)
  }
}

# A tunnel whose initiator cannot reach the far end is a tunnel that will never
# come up, and it fails silently: RouterOS is happy to hold a peer with no
# endpoint. Catch it at plan time instead.
resource "terraform_data" "endpoint_assertions" {
  for_each = { for k, e in local.ends : k => e if local.initiates[k] }

  lifecycle {
    precondition {
      condition     = var.routers[each.value.peer].endpoint_address != ""
      error_message = "Tunnel ${each.value.tunnel}: ${each.value.self} is an initiator but its peer ${each.value.peer} has no endpoint_address, so there is nothing to dial. Give ${each.value.peer} an endpoint_address, or make ${each.value.peer} the initiator instead."
    }
  }
}

# A routes entry whose router is not an endpoint of its named tunnel fails at
# apply time with a bare "key not found". Catch it at plan time instead.
resource "terraform_data" "route_assertions" {
  for_each = { for r in var.routes : "${r.router}/${r.dst}/${r.via}" => r }

  lifecycle {
    precondition {
      condition     = contains(keys(local.ends), "${each.value.router}/${each.value.via}")
      error_message = "Route ${each.value.dst} on ${each.value.router} via ${each.value.via}: ${each.value.router} is not an endpoint of tunnel ${each.value.via}. Valid routers for that tunnel are its 'a' and 'b' values in var.tunnels."
    }
  }
}

# --- Interfaces ---

# private_key is left unset on purpose: RouterOS generates the keypair and the
# provider reads `public_key` back. No WireGuard private key is ever written in
# this PUBLIC repo, and none has to be handed between the two OCI accounts —
# each peer resource below just references the other end's computed public_key.
resource "routeros_interface_wireguard" "this" {
  for_each = local.ends
  provider = routeros.by_router[each.value.self]

  name        = local.iface_name[each.key]
  listen_port = each.value.self_port
  mtu         = each.value.cfg.mtu
  disabled    = each.value.cfg.disabled
  comment     = "mesh ${each.value.self} <-> ${each.value.peer} ${var.comment_suffix}"
}

resource "routeros_ip_address" "transit" {
  for_each = local.ends
  provider = routeros.by_router[each.value.self]

  address   = "${each.value.self_ip}/${split("/", each.value.cfg.transit_cidr)[1]}"
  interface = routeros_interface_wireguard.this[each.key].name
  network   = cidrhost(each.value.cfg.transit_cidr, 0)
  comment   = "mesh transit to ${each.value.peer} ${var.comment_suffix}"

  lifecycle {
    # Same reason as oci/modules/mikrotik's container_gateway address: some CHR
    # builds reject `vrf` as an unknown parameter on create but read it back as
    # "main", which shows as permanent drift.
    ignore_changes = [vrf]
  }
}

# --- Peers ---

resource "routeros_interface_wireguard_peer" "this" {
  for_each = local.ends
  provider = routeros.by_router[each.value.self]

  interface  = routeros_interface_wireguard.this[each.key].name
  public_key = routeros_interface_wireguard.this["${each.value.peer}/${each.value.tunnel}"].public_key

  allowed_address = local.allowed_addresses[each.key]
  comment         = "mesh peer ${each.value.peer} ${var.comment_suffix}"
  disabled        = each.value.cfg.disabled

  # An initiating end holds the far side's address and keeps the session warm.
  # A non-initiating end carries no endpoint at all and is marked responder, so
  # it waits to be dialled — the only arrangement that works when the far side
  # is behind NAT with no port forward.
  endpoint_address     = local.initiates[each.key] ? var.routers[each.value.peer].endpoint_address : null
  endpoint_port        = local.initiates[each.key] ? tostring(each.value.peer_port) : null
  persistent_keepalive = local.initiates[each.key] ? each.value.cfg.persistent_keepalive : null
  is_responder         = local.initiates[each.key] ? null : true

  depends_on = [terraform_data.endpoint_assertions]
}

# --- Routes ---

resource "routeros_ip_route" "mesh" {
  for_each = { for r in var.routes : "${r.router}/${r.dst}/${r.via}" => r }
  provider = routeros.by_router[each.value.router]

  dst_address = each.value.dst
  gateway     = local.ends["${each.value.router}/${each.value.via}"].peer_ip
  distance    = each.value.distance
  comment     = "${each.value.comment} ${var.comment_suffix}"

  # Without this a downed tunnel keeps its route installed and the standby at a
  # higher distance never takes over — the whole point of having two.
  # `ping` rather than `arp`: the far end is a /30 across a tunnel, and RouterOS
  # does not ARP over WireGuard.
  check_gateway = "ping"

  depends_on = [routeros_ip_address.transit, terraform_data.route_assertions]
}
