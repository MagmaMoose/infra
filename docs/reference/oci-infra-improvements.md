# OCI Infrastructure Improvement Backlog

Companion to [cloudflare-ztna-improvements.md](./cloudflare-ztna-improvements.md).
Captured during PR #199 (k3s agent join + OCI VCN internet egress via
MikroTik). None blocking; ranked roughly by impact × effort.

## 1. Move k3s join token out of OCI instance metadata

**Resolved.** The server module no longer interpolates the k3s join
token into user_data. Instead the cloud-init script installs `oci-cli`
on first boot and calls `oci secrets secret-bundle get --auth
instance_principal` against an OCI Vault secret whose OCID is passed
in as `k3s_token_secret_ocid`. Permission is granted by a dynamic
group plus a narrow IAM policy in
[iam.tf](https://github.com/CalebSargeant/infra/blob/main/terraform/oci/modules/server/iam.tf) that together
scope the read to the specific secret OCID.

Both `k3s_url` and `k3s_token_secret_ocid` must be set together (agent
mode) or both empty (standalone server mode); a variable validation
catches OCID-shape typos at plan time, and an instance precondition
catches the "only one of the two set" mistake before any IAM resources
are created. The IAM resources are themselves gated on the same agent-
mode condition, so standalone server applies don't touch tenancy IAM
at all.

Token rotation now means: update the Vault secret. Existing nodes keep
their cached token (k3s only reads it at join), and new nodes pick up
the rotated value automatically on boot.

## 2. Propagate k3s_url / k3s_token_secret_ocid / image changes to existing instances

**Resolved (scoped to meaningful inputs only).** Added a
`terraform_data.user_data_replace_trigger` resource in the server module
hashing the inputs that meaningfully change cloud-init outcome
(`k3s_url`, `k3s_token_secret_ocid`, `image_ocid`). The instance
resource declares `replace_triggered_by` on it. Result:

- Cosmetic install-script edits (comments, log wording) don't change the
  hash → no VM replacement. **This is intentional.**
- Changing `k3s_url`, `k3s_token_secret_ocid`, or `image_ocid` changes
  the hash → forces VM recreation, new cloud-init runs.
- In server mode (`k3s_url == ""`) the OCID is folded out of the hash
  so pointing it at a different Vault secret doesn't rebuild standalone-
  server VMs that ignore it (added in #213).

The current `terraform_data` body (live in `terraform/oci/modules/server/main.tf`;
keep this snippet in sync with the implementation):

```hcl
input = sha256(jsonencode(merge(
  {
    k3s_url               = var.k3s_url
    k3s_token_secret_ocid = var.k3s_url == "" ? "" : var.k3s_token_secret_ocid
    image                 = var.image_ocid
  },
  var.cloud_init_rebuild_token == "" ? {} : { rebuild_token = var.cloud_init_rebuild_token }
)))
```

**To force a replacement for a script-only change** (e.g. a new
cloud-init step that fixes a bug in the install path), set the
`cloud_init_rebuild_token` variable to any non-empty value (a date is
the easy convention). The `merge()` then folds an extra key into the
hashed object, the hash changes, and every VM rebuilds. Clear the
variable again afterwards and routine applies stop replacing VMs.

`ignore_changes = [metadata["user_data"]]` stays as the second layer of
defence against accidental replacements from re-rendered heredoc whitespace.

## 3. HA: route OCI VCN egress via both MikroTiks, not just r1

[terraform/oci/prod/eu-amsterdam-1/network/terragrunt.hcl](https://github.com/CalebSargeant/infra/blob/main/terraform/oci/prod/eu-amsterdam-1/network/terragrunt.hcl)'s
`internet_gateway_ip = "192.168.223.11"` hard-codes mikrotik-fd1 as the
single next-hop for app+data subnets. If r1 fails, both subnets lose
internet egress even though r2 exists, is configured identically for
masquerade, and is in the same subnet.

**Design captured in [oci-vrrp-ha-design.md](./oci-vrrp-ha-design.md).**
Approach: VRRPv3 between r1+r2 over the OCI edge subnet for state
determination, plus an OCI-API failover script (running in a tiny
container on each MikroTik, auth via instance principal) that
reassigns a *floating* secondary private IP (`192.168.223.10`)
between the two routers' VNICs on master change. OCI route tables
permanently point at `.10`; whichever VNIC currently owns `.10`
gets the traffic.

OCI's SDN doesn't honour gratuitous-ARP-based VRRP failover (the
classic L2 trick), and OCI route tables enforce destination uniqueness
so ECMP across two equal default routes isn't an option. The
VRRP-for-state + API-for-action pattern is Oracle's reference HA
architecture for this exact problem.

Implementation lands as a separate PR after the design is agreed;
the design doc includes a pre-implementation smoke test (manual OCI
API floating-IP reassignment) to validate the OCI control-plane
latency before committing to the approach.

## 4. Migrate `api://...:8728` to `apis://...:8729` (TLS-wrapped binary API)

The routeros provider currently talks plaintext binary API on 8728. The
existing `TODO` comment in
[mikrotik/terragrunt.hcl](https://github.com/CalebSargeant/infra/blob/main/terraform/oci/prod/eu-amsterdam-1/mikrotik/terragrunt.hcl)
captures this. Once cert is sorted, switch to 8729 + TLS, then drop the
`routeros_api_management_cidrs` ingress rule on the edge security list
(currently the only thing preventing 8728 from being closed to the
internet).

## 5. Reserved (not ephemeral) public IPs for edge MikroTiks

**Capability landed; cutover pending.** The edge module now exposes
`var.use_reserved_public_ips` (default `false`). Setting it to `true`
detaches the ephemeral public IPs and allocates two OCI Reserved Public
IPs (free tier: 2 reserved IPs per tenancy at no cost), attached to the
same primary private IPs. The cutover changes the public IP values once,
after which the IPs survive instance recreate.

DNS auto-follows via the [`cloudflare/dns/prod`](https://github.com/CalebSargeant/infra/blob/main/terraform/cloudflare/dns/prod/terragrunt.hcl)
terragrunt dependency on `oci/prod/eu-amsterdam-1/edge` (added in #218).
The same apply that creates the reserved IPs also rewrites the
`oci1`/`oci2`/`oci.sargeant.co` A records.

Recommended sequencing for the flip:

1. `terragrunt apply` in `terraform/oci/prod/eu-amsterdam-1/edge` with
   `inputs.use_reserved_public_ips = true`. Public IPs change.
2. (Same chain, or immediately after) `terragrunt apply` in
   `terraform/cloudflare/dns/prod`. A records update.
3. (Same chain, or immediately after) `terragrunt apply` in
   `terraform/oci/prod/eu-amsterdam-1/mikrotik` if the router-side
   address-lists reference the public IPs directly (today they don't:
   they reference hostnames + RFC1918, so this step is a no-op).

Expected disruption window: tens of seconds while DNS TTL expires for
clients with cached old IPs. Inbound traffic to `oci*.sargeant.co`
during that window times out at the old IPs.
