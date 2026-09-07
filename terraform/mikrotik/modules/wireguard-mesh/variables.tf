# ---------------------------------------------------------------------------
# A point-to-point WireGuard mesh across MikroTik routers in different sites.
#
# ONE INTERFACE PER TUNNEL, deliberately, rather than one interface carrying
# every peer. WireGuard's `allowed-address` is both the crypto-routing table AND
# the inbound source filter, and within a single interface the peers' lists must
# not overlap — longest-prefix match picks exactly one. A mesh with two routers
# per site inevitably has two peers advertising the same site prefix, so a
# single-interface mesh cannot express "primary and standby" at all. With one
# interface per tunnel the overlap is legal (it is across interfaces, not within
# one), and ordinary `/ip/route` distances choose the active path.
#
# It also matches what the home router already does for its other links
# (`franklinhouse`, `p1aws_chr2`): one interface, one peer, one /30.
# ---------------------------------------------------------------------------

variable "routers" {
  description = <<-DESC
    Every router that participates in the mesh, keyed by its short name (ff-chr1,
    ff-crs1, ...). The key is used verbatim in interface names and comments, so
    keep it short and stable — renaming a key destroys and recreates that
    router's interfaces.

    `endpoint_address` is what OTHER routers dial to reach this one. Leave it
    empty for a router that has no reachable listener (behind CGNAT or a firewall
    nobody wants to punch a hole in); such a router must be the initiator on
    every tunnel it takes part in.

    Passwords are NOT in here — they live in var.router_passwords, because
    OpenTofu refuses to use a sensitive value as a provider `for_each` argument
    and this map is exactly that argument.
  DESC
  type = map(object({
    hosturl  = string # binary-API URL, e.g. "api://134.98.139.9:8728"
    username = optional(string, "admin")
    insecure = optional(bool, true)

    # Public address the peers dial. Empty = this router never accepts an
    # unsolicited handshake and must appear as `initiator` on all its tunnels.
    endpoint_address = optional(string, "")

    # Free-text, recorded in this module's outputs so a reader can tell which
    # site a router belongs to without decoding the name.
    site = optional(string, "")
  }))
}

variable "router_passwords" {
  description = "API password per router, keyed the same as var.routers. Split out of `routers` so that map stays non-sensitive and can drive the provider's for_each."
  type        = map(string)
  sensitive   = true

  # No default: an empty password is how both cloudworkers CHRs sat exposed for
  # a day, so it should never be the quiet fallback.

  validation {
    condition     = alltrue([for p in values(var.router_passwords) : p != ""])
    error_message = "router_passwords holds an empty password. Set one on the device and put it in the vault; do not manage a router that anyone can log into."
  }
}

variable "tunnels" {
  description = <<-DESC
    One entry per point-to-point link. `a` and `b` are keys into var.routers;
    which is which only decides who takes the first usable address in
    `transit_cidr`.

    `transit_cidr` must be a /30. `a` gets .1, `b` gets .2.

    `listen_port` is used on BOTH ends unless `listen_port_a` / `listen_port_b`
    override it. Same port on both ends keeps the OCI security-list rule to one
    contiguous range; the override exists because one end of a tunnel may sit
    behind an edge device that only passes certain UDP DESTINATION ports, and
    the far end then has to listen on one of those. WireGuard itself does not
    care: peers never need to agree on a port number.

    `initiator` is a router key, or "both". A router named here sets
    `endpoint-address` + `persistent-keepalive` and dials out; the other end is
    marked `is-responder` and carries no endpoint, so it waits. Use a single
    initiator whenever one end is behind NAT — that end must be the initiator,
    because nothing can dial IT.
  DESC
  type = map(object({
    a            = string
    b            = string
    transit_cidr = string
    listen_port  = number

    # Per-end overrides. Set one when the other end can only be reached on a
    # particular UDP port — see the note above.
    listen_port_a = optional(number)
    listen_port_b = optional(number)

    initiator            = optional(string, "both")
    persistent_keepalive = optional(string, "25s")

    # 1420 = 1500 (internet path MTU) - 60 (IPv4 + UDP + WireGuard headers), and
    # it is what every existing tunnel on the home router already uses. Raising
    # it above the real path MTU produces a tunnel that handshakes and then
    # silently drops full-size packets, which is far harder to spot than a
    # tunnel that never comes up.
    mtu = optional(string, "1420")

    disabled = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for t in var.tunnels : can(cidrhost(t.transit_cidr, 2)) && tonumber(split("/", t.transit_cidr)[1]) == 30])
    error_message = "Every tunnel's transit_cidr must be a /30."
  }

  validation {
    condition     = alltrue([for t in var.tunnels : contains([t.a, t.b, "both"], t.initiator)])
    error_message = "Each tunnel's `initiator` must be its own `a`, its own `b`, or \"both\"."
  }

  validation {
    condition     = length(distinct([for t in var.tunnels : t.transit_cidr])) == length(var.tunnels)
    error_message = "Two tunnels share a transit_cidr."
  }
}

variable "routes" {
  description = <<-DESC
    Static routes to install over the mesh. `via` names a tunnel; the gateway is
    resolved to the FAR end's transit address, so a route entry never repeats an
    IP that is already derived from `tunnels`.

    These entries also drive `allowed-address`: whatever a router routes over a
    tunnel is exactly what that tunnel's peer is permitted to send it. Keeping
    the two in one place is the point — a route with no matching allowed-address
    is a tunnel that comes up and then blackholes, and it is the single most
    common way to get this wrong by hand.

    `distance` chooses primary vs standby when two tunnels reach the same
    prefix. RouterOS prefers the lowest distance that is `active`.
  DESC
  type = list(object({
    router   = string # key into var.routers — the router the route is installed on
    dst      = string
    via      = string # key into var.tunnels
    distance = optional(number, 1)
    comment  = string
  }))
  default = []
}

variable "extra_allowed_addresses" {
  description = <<-DESC
    Prefixes to add to a peer's `allowed-address` beyond the transit /30 and
    whatever var.routes already implies. Keyed "<router>/<tunnel>", meaning "on
    <router>, for the peer reached over <tunnel>".

    Needed when a router must ACCEPT traffic from a prefix it does not itself
    route back over that tunnel — an asymmetric path, or a source that is
    answered via some other link.
  DESC
  type        = map(list(string))
  default     = {}
}

variable "comment_suffix" {
  description = "Appended to every RouterOS object this module creates, so the CLI shows who owns them."
  type        = string
  default     = "(managed by Terraform: wireguard-mesh)"
}
