# Session: 2026-08-31 — oci-cloudworkers-leaves

## What changed
- Wrote the four `terraform/oci/cloudworkers/prod/eu-amsterdam-1/` leaves (network, edge, vpn, server)
  for the second OCI tenancy: ff-oci3/ff-oci4 workers and ff-chr3/ff-chr4 CHRs.
- `modules/edge` gained `fault_domains[*].node_name` so CHRs can be named ff-chr3/ff-chr4.
  Verified no-op for the live firefly edge leaf.
- Firefly's network leaf gained `cloudworkers_vcn` in `remote_networks` (additive, in-place).
- Fixed `scripts/terragrunt-pipeline.sh`: the shared-module regex matched `terraform/modules/`,
  a path that has never existed, so module edits triggered zero replans.

## Decisions made
- VCN `192.168.240.0/24`, not `.224`: `terraform/fortigate/prod` sets `peer_lan_subnet`
  `192.168.220.0/22`, a supernet already over-reaching firefly's `.223.0/24`.
- k3s node-token is duplicated into a vault in the second tenancy. Cross-tenancy
  instance-principal reads are impossible (Endorse/Admit take `group`, never `dynamic-group`).
- Connectivity is that tenancy's own DRG + IPSec to FG1/FG2. RPC is cross-region only, and an
  LPG would not reach the on-prem control plane.
- Unknown-yet OCIDs (CHR image, token secret) come from env vars wrapped in HCL `regex()` so the
  leaves fail at parse time instead of applying against a placeholder. Empirically confirmed the
  group must be non-capturing: `(...)` returns `["tenancy"]`, `(?:...)` returns the whole match.
- Cloudworkers excluded from `discover_all` until the tenancy is bootstrapped, so a failed plan
  cannot block applies for firefly stacks.

## Files touched
- New: 4 leaves, `.claude/decisions/2026-08-31-second-oci-tenancy-cloudworkers.md`
- Modified: `modules/edge/{main,variables}.tf`, firefly `network/terragrunt.hcl`,
  `cloudworkers/provider.hcl`, `atlantis.yaml`, `scripts/terragrunt-pipeline.sh`,
  `AGENTS.md`, `PROJECT_INDEX.json`, `docs/reference/cluster-topology.md`, `docs/glossary.md`

## Applied to traceysargeant (2026-08-31)
- `network` 22 resources, then a second pass to set `internet_gateway_ip=192.168.240.11`
  (2 in-place route table updates).
- `vpn` 14 resources. Tunnel headends 158.101.193.222 / 193.123.39.248, BGP inside
  169.254.24.0/24 (FG1, ASN 65010) and 169.254.25.0/24 (FG2, ASN 65020). All tunnels DOWN
  until the FortiGate side is built. PSKs are in that leaf's own vault, per tunnel.
- `edge` 4 resources. ff-chr3 158.178.154.125 / .11, ff-chr4 84.235.162.6 / .12, both
  RUNNING on reserved IPs, RouterOS 7.18.2.
- Bootstrapped by hand: `key-cloudworkers` (AES, SOFTWARE, so no per-key charge) and a copy
  of the node-token as `k3s-firefly-node-token` in `vault-cloudworkers`; MikroTik
  chr-7.18.2.vmdk imported into the tenancy; srcnat masquerade for the app and data /26s
  added to BOTH CHRs (neither had any NAT rule, the FranklinHouse failure mode).
- `server` NOT applied. IAM (dynamic group + policy) landed; both A1 instances fail with
  `500-InternalError, Out of host capacity`. OCI-side, not config. Re-run the leaf to retry;
  it is idempotent and only the two instances are missing.

## Follow-up / next steps
- Operator bootstrap blocks any apply: import a CHR image into the tenancy (firefly's is a
  tenancy-private custom image and 404s), create a KMS key + token secret in the empty
  `vault-cloudworkers`, hand-configure the FortiGate tunnels, set `OCI_CW_*`.
- BGP hazard: both DRGs are AS 31898, so FG1 must originate `192.168.223.0/24` and
  `192.168.240.0/24` as redistributed statics, or use `as-override`.
- `calebsargeant/pre-commit-hooks` `security-check.sh` crashes on any staged `.tf`/`.hcl`
  (`run_security_tool` called with 3 of 4 args). Pre-existing, blocks clean commits.
