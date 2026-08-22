# OCI MikroTik HA via VRRP + route-table failover: design doc

Status: **Design. Partial smoke test passed; implementation pending.**
Resolves `oci-infra-improvements.md` #3.

> **Pivot since the first version of this doc** (2026-05-19): the
> original plan was "VRRP triggers a script that moves a floating
> *secondary private IP* between VNICs." That doesn't work. OCI's
> `UpdatePrivateIp` API can't change `vnic_id`; you'd have to
> unassign + reassign, which creates a NEW private-ip OCID and breaks
> the route tables that referenced the old one. The smoke test below
> exposed this. **Corrected pattern:** keep the route table's
> `network_entity_id` pointing at whichever **primary** private IP
> belongs to the active master, and update the route table on
> failover. The route table is the single source of truth for "who's
> the current egress gateway"; the VRRP state machine decides who,
> and a small container on each MikroTik makes the OCI API call.

## Problem

[`terraform/oci/prod/eu-amsterdam-1/network/terragrunt.hcl`](https://github.com/CalebSargeant/infra/blob/main/terraform/oci/prod/eu-amsterdam-1/network/terragrunt.hcl)
hard-codes:

```hcl
internet_gateway_ip = "192.168.223.11"
```

which becomes the next-hop OCID for the `0.0.0.0/0` default route on
both the **app** and **data** subnets of the prod VCN. That IP belongs
to **r1** (mikrotik-fd1) specifically. If r1 dies, **both subnets lose
internet egress immediately** even though r2 is healthy in the same
subnet running identical config, because nothing repoints the OCI
route.

Single point of failure on a deliberately-redundant pair.

## Goal

When r1 fails, internet egress for the app + data subnets should
automatically fail over to r2 without operator intervention. Recovery
to the original master on r1's return is fine (pre-emption is OK in
this topology: no asymmetric WAN cost).

Target failover detection + reconvergence: **under 30 seconds**.

## Smoke test results (2026-05-19)

Before committing to the design, measured OCI control-plane latency
for `UpdateRouteTable` against the live prod compartment in
eu-amsterdam-1. 6 swaps of the app subnet's default-route
`network_entity_id` between r1's and r2's primary private IP OCIDs:

| Iteration | Direction | API call | Time-to-visible |
|---|---|---|---|
| 1 | → R2 | 1.30 s | 1.97 s |
| 1 | → R1 | 1.10 s | 1.83 s |
| 2 | → R2 | 1.08 s | 1.84 s |
| 2 | → R1 | 1.08 s | 1.78 s |
| 3 | → R2 | 1.42 s | 2.17 s |
| 3 | → R1 | 1.17 s | 1.94 s |

Average: ~1.2 s API / ~1.9 s visible. Well under the 30 s target. Data
plane convergence on top adds another second or two; total failover
should land in the 3 to 5 s range once VRRP detection (sub-second) and
hook invocation are included.

## Why OCI makes this non-trivial

OCI's VCN networking is SDN: there's no shared L2 between VNICs. A
classic VRRP setup where master broadcasts a gratuitous ARP for the
virtual IP and clients learn the new MAC doesn't work; OCI ignores the
ARP and keeps routing by VNIC ownership.

Three options considered:

### Option A: ECMP across two equal default routes

Add two `0.0.0.0/0` routes pointing at r1's and r2's private IPs.
OCI's intent: split traffic 50/50.

**Not viable.** OCI route tables enforce **destination uniqueness**:
you can't have two route rules with the same destination. The
terraform apply errors at validation. ECMP isn't a thing on OCI route
tables.

### Option B: BGP between MikroTiks and DRG

Each MikroTik peers BGP with the DRG and announces a default route.
DRG picks the active announcer; if r1's session drops, r2 wins.

**Possible but heavy.** Requires the DRG to be in BGP mode rather than
the current static-routing mode (and our existing VPN tunnels to AWS
peer ASNs would need rethinking). Operationally adds another moving
part. Skip for now; revisit only if VRRP + route-table failover
proves inadequate.

### Option C: VRRP for state + OCI route-table failover (recommended)

1. The OCI app + data route tables continue to have a single default
   route, with `network_entity_id` pointing at whichever router's
   primary private IP is currently active master (initially r1's
   `192.168.223.11` OCID).
2. Run **VRRPv3** between r1 and r2 over the OCI edge subnet. They
   negotiate state via VRRP hellos; r1 is master (priority 200), r2
   is backup (priority 100).
3. On VRRP state transition to master, the new master executes a
   **failover hook** that calls a small local HTTP listener (the
   `oci-vrrp-failover` container, alongside cloudflared).
4. The container reads each configured route table, finds the rule
   matching the configured destination (default `0.0.0.0/0`), swaps
   its `network_entity_id` to the local instance's primary private IP
   OCID, and PUTs the rule list back.

VRRP-on-OCI doesn't actually move L2; it just drives the state
machine that triggers the route-table update. Detection is sub-second
(VRRP hello = 1 s by default); reassignment is OCI-control-plane-bound
(~1.2 s API per route table, per the smoke test above).

## Concrete implementation

### Terraform changes (infra repo)

#### `terraform/oci/modules/edge/iam.tf` (new file: edge-only dynamic group + policy)

Pattern mirrors `terraform/oci/modules/server/iam.tf` (added in #210)
but with **a separate, edge-only dynamic group**. Reusing the server
module's group would broaden the k3s nodes' privileges to include
route-table-manage, and broaden the edge routers' privileges to
include the k3s Vault-read. Both directions are unnecessary
privilege expansion. Keeping them disjoint preserves least privilege.

Matching rule scopes to the specific edge instance OCIDs (not "every
instance in compartment" like the server module's group):

```hcl
locals {
  vrrp_enabled = var.enable_vrrp_failover
}

resource "oci_identity_dynamic_group" "edge_failover" {
  count = local.vrrp_enabled ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "edge-${var.environment}-failover"
  description    = "Edge MikroTik instances in ${var.compartment_ocid}; grants route-table failover for VRRP HA"
  matching_rule  = "all {instance.compartment.id = '${var.compartment_ocid}', any {instance.id = '${oci_core_instance.this["fd1"].id}', instance.id = '${oci_core_instance.this["fd2"].id}'}}"
}

resource "oci_identity_policy" "edge_route_table_failover" {
  count = local.vrrp_enabled ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "edge-${var.environment}-route-table-failover"
  description    = "Allow edge MikroTik instances to update VCN route tables for VRRP failover"

  statements = [
    # `use route-tables` is enough — `manage` would allow delete, which
    # the container doesn't need and shouldn't have.
    "Allow dynamic-group ${oci_identity_dynamic_group.edge_failover[0].name} to use route-tables in compartment ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.edge_failover[0].name} to read vcns in compartment ${var.compartment_ocid}",
  ]
}
```

#### `terraform/oci/modules/network/`: no changes

The route tables stay exactly as they are today. `internet_gateway_ip`
remains `"192.168.223.11"` (r1's primary private IP, the initial
active master). The container updates the table at runtime; terraform
doesn't need to know.

This is the big simplification vs the original "floating IP" design:
no module changes to the network module, no floating private IP
resource, no `ignore_changes` on a re-parented VNIC.

#### `terraform/oci/modules/mikrotik/`: add the failover container

Same pattern as the existing `routeros_container.cloudflared`. New
resources, all iterated `for_each = local.routers`:

```hcl
resource "routeros_container_envs" "failover_local_ip" {
  for_each = local.routers
  provider = routeros.by_router[each.key]
  name  = "FAILOVER"
  key   = "LOCAL_PRIVATE_IP_OCID"
  value = var.edge_primary_private_ip_ocids[each.key]  # per-router; passed in
}

resource "routeros_container_envs" "failover_route_tables" {
  for_each = local.routers
  provider = routeros.by_router[each.key]
  name  = "FAILOVER"
  key   = "ROUTE_TABLE_OCIDS"
  value = join(",", var.failover_route_table_ocids)
}

resource "routeros_container_envs" "failover_region" {
  for_each = local.routers
  provider = routeros.by_router[each.key]
  name  = "FAILOVER"
  key   = "OCI_REGION"
  value = var.region
}

resource "routeros_container" "failover_helper" {
  for_each = local.routers
  provider = routeros.by_router[each.key]

  remote_image  = var.failover_helper_image  # "ghcr.io/calebsargeant/oci-vrrp-failover:vX.Y.Z"
  interface     = routeros_interface_veth.failover[each.key].name
  envlist       = "FAILOVER"
  logging       = true
  start_on_boot = true
  workdir       = "/app"
  root_dir      = "${var.container_root_dir}/failover"
  comment       = local.tf_marker
  # ...same lifecycle quirks as cloudflared (stop_signal per-router, etc.)
}
```

Plus a new `routeros_interface_veth` for the container's IP
(`172.17.0.3`, vs cloudflared's `.2`) and matching bridge-port
attachment.

#### `terraform/oci/modules/mikrotik/`: add VRRP

Each router gets three RouterOS objects on `ether1` (OCI edge subnet
interface):

```routeros
# 1. VRRP virtual interface + state machine
/interface/vrrp/add \
  name=vrrp-edge \
  interface=ether1 \
  vrid=10 \
  priority=200 \  # r1=200, r2=100
  v3-protocol=ipv4 \
  on-master=":log info \"vrrp-edge: master state — triggering failover\"; /tool/fetch url=http://172.17.0.3:8080/promote method=post keep-result=no" \
  on-backup=":log info \"vrrp-edge: backup state — letting master own the route\""

# 2. VRRP virtual IP (not used by OCI routing, just for VRRP itself)
/ip/address/add \
  address=192.168.223.10/26 \
  interface=vrrp-edge \
  comment="VRRP virtual IP — owned by master at any time"
```

Both routers get all three objects via `routeros_*` resources
iterating with `for_each = local.routers`. Priority differs per router;
everything else identical. (The `.10` VRRP virtual address isn't used
by OCI routing. It's just part of the VRRP protocol; OCI ignores it.
The actual egress redirect happens via the route-table API, not via
ARP.)

#### Edge VNIC config

`skip_source_dest_check = true` is already set on both edge VNICs in
`terraform/oci/modules/edge/main.tf` line 21: VRRP hello multicast
will pass between the VNICs. No change needed.

### Container image (separate repo: mikrotik-chr)

Lives at
[`CalebSargeant/mikrotik-chr:dockerfiles/oci-vrrp-failover`](https://github.com/CalebSargeant/mikrotik-chr).
Published to `ghcr.io/calebsargeant/oci-vrrp-failover:vX.Y.Z` by that
repo's `docker-publish.yml` workflow. Stack: `python:3.13-slim` +
`oci-cli` from pip, stdlib `http.server` listener (~30 MB). See the
image's own README for full environment-variable docs.

## Test plan

1. ✅ **Pre-implementation smoke test (DONE)**: see the table at the
   top. Measured `UpdateRouteTable` latency against the live prod
   compartment; ~1.2 s API / ~1.9 s visible per swap. Cleaned up
   afterwards.
2. **VRRP-only test (no failover hook)**: add the VRRP interfaces to
   r1 + r2 with the `on-master`/`on-backup` hooks set to just logging
   (no `/tool/fetch`). Confirm state convergence via
   `/interface/vrrp/print` on both routers: r1 master, r2 backup, no
   flapping over 10 minutes. Validates that VRRP hello multicast
   actually traverses the OCI edge subnet.
3. **Failover script standalone**: bring up the container on each
   router. Manually `curl -X POST http://localhost:8080/promote` from
   inside the RouterOS shell and confirm the OCI route table actually
   flips. Verify with:

   ```bash
   oci network route-table get --rt-id <rt> --query 'data."route-rules"[?destination==`0.0.0.0/0`].{nh:"network-entity-id",desc:description}'
   ```

4. **End-to-end failover**: with VRRP + the failover hook fully
   wired, stop r1's RouterOS VM. Time how long until `traceroute
   1.1.1.1` from an app subnet VM starts succeeding via r2. Target:
   under 30 s.
5. **Failback**: start r1's VM. Confirm pre-emption returns master to
   r1 and route table follows.
6. **Split-brain probe**: simulate a network partition between r1 and
   r2 (firewall the VRRP hellos for 30 s). VRRP should declare both
   master, but only one PUT to the route table wins (whoever's last);
   the route table eventually stabilises on whichever is reachable
   when partition heals. Confirm no infinite update loop or
   priority-based oscillation.

## Rollback

Each step is independently reversible:

- **VRRP**: `/interface/vrrp/remove vrrp-edge` on each router. OCI
  route tables stay wherever the helper last set them.
- **Failover container**: `routeros_container.failover_helper` destroy.
  Routers stop responding to VRRP state changes; route table stays put.
- **IAM dynamic group + policy**: terraform destroy of both, gated on
  `var.enable_vrrp_failover` (default false, same pattern as #210).
  Tenancy IAM cleaned up.
- **Route table**: if the helper left a table pointing at a dead
  next-hop, manually `oci network route-table update` (or just
  `terragrunt apply` on the network module, which re-asserts the
  default-route to `var.internet_gateway_ip` = `192.168.223.11`).

The terraform-managed pieces are all gated on
`var.enable_vrrp_failover`, default false; landing the code without
flipping the flag is a no-op.

## Open questions

1. **Container can reach OCI metadata service?** The `instance_principal`
   auth path requires the container to read
   `http://169.254.169.254/opc/v2/...` for its credentials. RouterOS's
   container runtime puts containers on a separate bridge (172.17.0.x);
   need to confirm metadata-service traffic survives the
   bridge→host hop. Fallback already supported by the helper:
   `OCI_AUTH=api_key` + mounted `~/.oci/config`.
2. **VRRP hello multicast across the OCI edge subnet?** Per OCI docs
   it should (same subnet, same VCN), but worth confirming with the
   "VRRP-only test" (step 2 in the test plan) before relying on it.
3. **Read-modify-write race on route-table updates?** OCI route table
   updates use full-list PUT semantics. If both routers think they're
   master simultaneously (split brain), both might race the API; OCI
   serialises but the loser's payload is discarded. Acceptable for
   VRRP-driven failover because the helper is idempotent (it re-PUTs
   the same payload if invoked again with the same state): no flap
   loop, just one wasted API call.

## Out of scope (intentionally)

- DRG / VPN routing changes: VPN tunnels stay pointed at the existing
  endpoints. This design only touches the **internet egress** routing.
- WAN-side HA. The MikroTiks share the same OCI region's internet
  gateway; if eu-amsterdam-1's IGW has a region-wide problem, neither
  router can route. Geographic redundancy is its own project.
- `auto-restart-interval` for cloudflared on r2, tracked separately
  in `cloudflare-ztna-improvements.md` #2 residual gap.
