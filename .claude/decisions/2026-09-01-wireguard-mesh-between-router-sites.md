# A WireGuard mesh between the three router sites replaces the DRG hairpin

Status: **accepted**, applied 2026-09-01
Date: 2026-09-01

## Context

`terraform/oci/cloudworkers` (ADR 2026-08-31) put `ff-oci3` and `ff-oci4` in a second Oracle
account and joined them to the existing firefly k3s cluster. Its `vpn` leaf gave that tenancy its
own IPSec to FG1 and FG2, and the plan for reaching firefly's own VCN was to **hairpin through
FG1**: cloudworkers' DRG sends 192.168.223.0/24 over IPSec to FG1, FG1 forwards it to firefly's
DRG, and back.

That plan cannot work, and the leaf's own header said so before it was applied: **both DRGs are
Oracle AS 31898.** FG1 cannot re-advertise a prefix learned from one AS-31898 neighbour to the
other — standard BGP AS_PATH loop rejection drops it, silently. It half-worked exactly as
predicted: tunnels green, prefixes absent.

Measured on 2026-09-01, ~19h after the nodes joined:

| from | to | result |
| --- | --- | --- |
| pod on ff-vm1 (on-prem) | pod on ff-oci4 | OK |
| pod on ff-oci1 | pod on ff-oci4 | timeout |
| pod on ff-oci2 | pod on ff-oci4 | timeout |

`valkey-oci` had already been pinned away from the new nodes as an outage workaround.

Four independent faults, each sufficient on its own:

1. **Firefly's VCN had no route to 192.168.240.0/24.** The `cloudworkers_vcn` entry was committed
   in #685 but the leaf was never applied. `traceroute` from ff-oci1 showed the packet falling
   through to the 0.0.0.0/0 rule, hitting ff-chr1's masquerade and leaving for the public
   internet.
2. **Cloudworkers' VCN routed 192.168.223.0/24 at its DRG.** That half *was* applied, which is why
   the failure was asymmetric and read like a firewall problem.
3. **No transport between the two tenancies at all.** ff-chr1..ff-chr4 had zero WireGuard
   interfaces. ff-crs1 had `oci-r1`/`oci-r2` left over from an earlier attempt: running, zero
   bytes, pointing at a public IP that no longer belongs to anything, with their addresses
   disabled.
4. **`oci-node-firewall`'s CIDR list never learned about the new environment.** It admits
   10.42/16, 10.43/16, 192.168.19/24 and 192.168.223/24. Nothing else. On ff-oci3 and ff-oci4 the
   chain still ends in the OCI image's `REJECT --reject-with icmp-host-prohibited`, so **pod
   traffic between ff-oci3 and ff-oci4 was rejected by their own host firewall** — the new
   environment was broken internally, not only across the tenancy boundary, and the DaemonSet
   reported Running throughout.

Also found and fixed in passing: **ff-chr3 and ff-chr4 had a blank admin password** and their
subnet's security list admits ssh/http/https/winbox from 0.0.0.0/0. They had been reachable that
way since 2026-08-31, because the cloudworkers ADR deferred a `mikrotik` leaf and nothing else was
going to set one.

The operator's requirement, given during the fix: a **full mesh** — calebsargeant OCI to
traceysargeant OCI, and each of those to the home router.

## Decision

`terraform/mikrotik/wireguard-mesh/prod`, one leaf driving a new
`terraform/mikrotik/modules/wireguard-mesh`, builds **ten point-to-point WireGuard tunnels** —
every unordered pair of ff-crs1, ff-chr1, ff-chr2, ff-chr3, ff-chr4. `modules/network` gains a
`via` field on `remote_networks` so a VCN can hand a prefix to its local CHR instead of the DRG,
and both `network` leaves use it for the other tenancy's /24.

### One interface per tunnel, not one interface with N peers

WireGuard's `allowed-address` is both the crypto-routing table and the inbound source filter, and
within one interface the peers' lists must not overlap — longest-prefix match selects exactly one
peer. With two routers per site, two peers inevitably advertise the same site prefix, so a
single-interface mesh **cannot express primary-and-standby at all**. One interface per tunnel makes
the overlap legal (it is across interfaces, not within one) and lets ordinary `/ip/route`
distances choose. It also matches what ff-crs1 already does for `franklinhouse` and `p1aws_chr2`.

### One leaf for all five routers, across two Oracle accounts

A tunnel is one object with two ends, and each end's peer references the other end's **generated**
public key. Splitting the leaf per site would mean copying keys between two terragrunt runs by
hand. Private keys are generated on the routers and never leave them; the provider reads back only
`public_key`.

### Routes: only the OCI-to-OCI leg moves

`ff-crs1` gets four tunnels and **no prefix routes**. Home to OCI keeps running over FG1's IPSec
exactly as before. Adding `192.168.223.0/24` on ff-crs1 would divert it immediately — a /24 beats
the default route regardless of distance — and re-routing a working production path is not part of
fixing an outage. The tunnels are up and provably pass traffic, so moving that leg later is a
four-line change.

`ff-chr1 <-> ff-chr3` is primary because those are the two the VCN route tables point at
(`internet_gateway_ip` is `.11` in both VCNs). ff-chr2 and ff-chr4 carry mirror-image routes at
distance 2, so flipping a VCN route table to `.12` is a one-line change with a tunnel already
behind it.

10.42.0.0/16 and 10.43.0.0/16 are **not** routed over the mesh. Pod-to-pod between environments is
flannel VXLAN between node addresses, so routing the two /24s is sufficient and the pod CIDR never
appears unwrapped on the wire. Both VCNs already hand 10.42/10.43 to their DRG for on-prem
traffic; a second competing path for the same prefix is how you get an asymmetric route that
passes a ping and drops a TCP session.

## Two things that only showed up on the wire

**The home edge filters outbound UDP by destination port.** ff-crs1 could ping every CHR public IP
while WireGuard on 51841-51844 never delivered a single packet — tx climbing, rx flat at zero on
both ends. 51820 and 51822 already work (that is why `franklinhouse` and `p1aws_chr2` were fine),
so the four ff-crs1 tunnels override the far end's listen port to **51820**. Each CHR can bind it
because each has exactly one tunnel to ff-crs1. ff-crs1's own port is a source port and nothing
filters on it.

**A router that drops pings to its own transit address makes every route over it inactive.** Each
mesh route carries `check-gateway=ping`. `modules/mikrotik` builds an input chain of
established/related, then TRUSTED, then drop — and 192.168.255.0/26 matched none of them, so
ff-chr1 dropped the health check aimed at it and every route on ff-chr3 sat `inactive` while the
tunnel itself was perfectly healthy. The mesh transit range is now in `trusted_addresses`. (The
module's RFC1918 list does not help: it is only used in the forward chain.)

## Options considered

**Fix the FG1 hairpin with `as-override` or by originating both prefixes as redistributed
statics.** Rejected. It is achievable, but it puts the only path between two cloud environments
through a hand-configured on-prem appliance that `terraform/fortigate/prod` does not model, and
makes every OCI-to-OCI packet cross the operator's home DSL twice. Latency measured after the
change: 1-2 ms CHR to CHR. The hairpin was 165 ms on the equivalent on-prem leg.

**A cross-tenancy Local Peering Gateway.** Still the cheapest possible OCI-to-OCI path and still
worth doing later, but it does not satisfy the full-mesh requirement, does nothing for the home
legs, and an LPG cannot carry the pod CIDR conversation the cluster actually needs.

**Widen `oci-node-firewall` to accept all RFC1918** instead of naming each environment. Rejected:
the list is the only written statement of which networks are allowed to reach these nodes, and
"all of RFC1918" is not a statement. The real fix is that it must name every OCI environment
*including the node's own* — recorded in the manifest and in COMMON_MISTAKES.

**Preshared keys on every peer.** Deferred. WireGuard's handshake is secure without them; a PSK is
a post-quantum hedge, and generating 20 of them in terraform state during an outage fix is not
where that belongs.

## Consequences

- OCI-to-OCI now depends on ff-chr1 and ff-chr3 being up. Both have a standby with a live tunnel,
  but promotion is a manual VCN route-table edit, matching the existing single-CHR egress design.
- The mesh transit range 192.168.255.0/26 is now trusted for input on ff-chr1/ff-chr2. That is the
  same trust the far site's public IPs already have.
- If BOTH tunnels from a CHR are down, `check-gateway` withdraws its routes and the CHR falls back
  to its default route — into the VCN, which routes the prefix straight back to that CHR. The loop
  is TTL-bounded and only exists while a site is entirely unreachable, but it is real.
- Node MTU is 9000 on the OCI nodes and 1500 on-prem, so flannel is 8950 vs 1450 in one cluster.
  This predates the change (a 4000-byte pod-to-pod ping ff-oci1 to ff-vm1 already failed while
  1400 and 8000 passed) and the mesh does not make it worse, but it should be aligned.

## Follow-ups

1. A cloudworkers `mikrotik` leaf: ff-chr3/ff-chr4 have no firewall filter rules at all and their
   masquerade is hand-configured. Needs `enable_cloudflared = false` in `modules/mikrotik`.
2. Narrow the edge security list: ssh/http/https/winbox from 0.0.0.0/0 is wider than anything in
   that subnet needs.
3. Delete `oci-r1`/`oci-r2` and the disabled `firefly_vpn` from ff-crs1 — dead config that reads
   like a working tunnel.
4. Align flannel MTU across the cluster.
5. `routeros_container.cloudflared["r1"]` has `start_on_boot` drift (false on the device, true in
   config). Untouched here; decide which is intended.
