# Session: 2026-09-01 — oci-to-oci network outage

## What changed
- Built a **10-tunnel WireGuard mesh** across ff-crs1 + ff-chr1..ff-chr4 (new
  `terraform/mikrotik/modules/wireguard-mesh` + `terraform/mikrotik/wireguard-mesh/prod`). Applied.
- `modules/network`: `remote_networks` entries take `via = "drg"|"chr"`; WireGuard ingress ports
  are now a variable. Both `network` leaves route the other tenancy's /24 at their local CHR.
  Applied on both sides.
- `oci-node-firewall` DaemonSet: added `192.168.240.0/24`. Applied live on all four OCI nodes as
  well, since Flux only watches `main`.
- ff-chr3/ff-chr4 had a **blank admin password** with ssh/winbox open to `0.0.0.0/0`. Set one,
  stored it in vault-prod as `mikrotik-credentials-cloudworkers`.
- Mesh transit `192.168.255.0/26` + the two new CHR public IPs added to ff-chr1/ff-chr2 TRUSTED.

## Decisions made
- ADR `2026-09-01-wireguard-mesh-between-router-sites`. One interface per tunnel (allowed-address
  cannot overlap within an interface); one leaf for all five routers across two Oracle accounts
  (both ends of a tunnel need each other's generated public key).
- The FG1 hairpin is abandoned, not fixed: both DRGs are Oracle AS 31898, so FG1 drops the far
  prefix on AS_PATH loop detection.
- **ff-crs1 gets tunnels but no prefix routes.** Home↔OCI stays on FortiGate IPSec; a /24 beats the
  default route regardless of distance, so adding one would divert working production traffic.
- Pod/service CIDRs stay on the DRG. Pod-to-pod between environments is VXLAN between node
  addresses, so routing the two /24s is enough.

## Files touched
- `terraform/mikrotik/modules/wireguard-mesh/*`, `terraform/mikrotik/wireguard-mesh/prod/`
- `terraform/oci/modules/network/{main,variables}.tf`
- `terraform/oci/{prod,cloudworkers/prod}/eu-amsterdam-1/network/terragrunt.hcl`
- `terraform/oci/prod/eu-amsterdam-1/mikrotik/terragrunt.hcl`
- `kubernetes/apps/node-tuning/base/oci-firewall-daemonset.yaml`
- `atlantis.yaml`, `AGENTS.md`, `PROJECT_INDEX.json`, `.claude/ARCHITECTURE_MAP.md`,
  `.claude/COMMON_MISTAKES.md` (#35, #36), `docs/reference/wireguard-mesh.md`, `mkdocs.yml`

## Follow-up / next steps
- **`ff-oci3`/`ff-oci4` are still cordoned** and `valkey-oci` is still pinned away from them. The
  network is fixed; uncordoning and unpinning belong to whoever owns that workaround.
- `topology.sargeant.co/tier=native-cloud` resolves to all four OCI nodes — a tier naming a role,
  not a location. It is what put a workload on a stranded node. Note it is also what makes
  `oci-node-firewall` reach the new nodes at all, so splitting it needs both sides changed.
- No cloudworkers `mikrotik` leaf: ff-chr3/ff-chr4 have **no firewall filter rules at all** and
  their masquerade is hand-configured. Needs `enable_cloudflared = false` in `modules/mikrotik`.
- Edge security list admits ssh/http/https/winbox from `0.0.0.0/0` in both VCNs. Narrow it.
- Flannel MTU is 8950 on OCI and 1450 on-prem. Predates this work (a 4000-byte pod ping ff-oci1 →
  ff-vm1 already failed while 1400 and 8000 passed), but should be aligned.
- Dead config on ff-crs1: `oci-r1`, `oci-r2`, `firefly_vpn`.
- `routeros_container.cloudflared["r1"]` has `start_on_boot` drift; deliberately not applied here.
