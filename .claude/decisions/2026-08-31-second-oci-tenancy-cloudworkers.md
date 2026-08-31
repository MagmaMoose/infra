# A second OCI tenancy ("cloudworkers") carries the next pair of firefly cloud workers

Status: **accepted**, not yet applied
Date: 2026-08-31

## Context

Firefly's `native-cloud` tier is `ff-oci1` and `ff-oci2`: two `VM.Standard.A1.Flex` instances at
2 OCPU and 12 GB each, in the `caleb` OCI tenancy, `eu-amsterdam-1`. That is exactly the Always
Free ARM allowance for one Oracle account (4 OCPU, 24 GB). There is no headroom left. Any third
ARM node in that tenancy is a paid node.

An Always Free allowance is per account, not per person, and a second account already exists:
**traceysargeant**, home region `eu-amsterdam-1`. It was queried read-only on 2026-08-31 and the
state is worth recording, because the whole plan depends on it:

- One availability domain, `TTzG:eu-amsterdam-1-AD-1`. Fault domains are the only HA axis.
- **No child compartments**, so the compartment OCID is the tenancy OCID itself.
- Greenfield: zero VCNs, zero instances, zero custom images.
- `vault-cloudworkers` already exists (ACTIVE, created 2026-08-14) but holds **zero KMS keys and
  zero secrets**. It is an empty shell.
- Service limits: `standard-a1-core-count` 41 available / 0 used, `standard-a1-memory-count` 277,
  `standard-e2-micro-core-count` **2 available / 0 used**, `reserved-public-ip-count` 6,
  `drg-count` 5, `vcn-count` 50.

The nodes being added are agents of the **existing** firefly k3s cluster. Nothing about this is a
new cluster. The only new boundary is the OCI account.

## Decision

Run traceysargeant as a parallel stack under `terraform/oci/cloudworkers/`, four leaves that
mirror firefly's own and source the same shared modules:

| Leaf | Creates |
| --- | --- |
| `network` | VCN 192.168.240.0/24, four /26 subnets, DRG |
| `edge` | `ff-chr3` .11, `ff-chr4` .12, MikroTik CHR on `VM.Standard.E2.1.Micro` |
| `vpn` | This tenancy's own IPSec to FG1 and FG2, BGP |
| `server` | `ff-oci3` .71, `ff-oci4` .72, arm64 k3s agents joining firefly |

Subnets: edge .0/26, app .64/26, data .128/26, spare .192/26. The VCN is **not** 192.168.224.0/24,
which would be the obvious next one along. `terraform/fortigate/prod` sets
`peer_lan_subnet = 192.168.220.0/22`, a supernet that already over-reaches across firefly's own
192.168.223.0/24. Sitting next to a broken supernet invites a second collision. 192.168.240.0/24
is clear of it.

### How one repo drives two tenancies

`terraform/root.hcl` reads the **nearest** `provider.hcl` through `find_in_parent_folders` and
takes an `env_prefix` local from it, defaulting to `"OCI"`. It then builds four credential
variable names from that prefix: `<PREFIX>_TENANCY_OCID`, `_USER_OCID`, `_FINGERPRINT`,
`_PRIVATE_KEY_PATH`. `terraform/oci/provider.hcl` names `"OCI"` explicitly, which changes nothing
for existing leaves. `terraform/oci/cloudworkers/provider.hcl` sets `"OCI_CW"` and shadows it for
every leaf beneath that directory.

**That mechanism covers the generated provider block and nothing else.** No module reads the
prefix, and no input is derived from it. This is why every cloudworkers leaf separately asserts
its tenancy and compartment with HCL `regex()`:

```hcl
tenancy_ocid     = regex("^ocid1\\.tenancy\\..+$", get_env("OCI_CW_TENANCY_OCID", ""))
compartment_ocid = regex("^ocid1\\.(?:compartment|tenancy)\\..+$", get_env("OCI_CW_COMPARTMENT_OCID", ""))
```

`get_env(..., "")` returns an empty string when the variable is unset, and an empty `tenancy_ocid`
makes the OCI provider fall through to the DEFAULT profile in `~/.oci/config`, which on the
operator's machine is firefly. Without the assert, a forgotten environment variable does not fail:
it quietly builds the cloudworkers VCN inside firefly's tenancy. `regex()` fails at parse time,
before a plan is even attempted, which is the only safe outcome. The group must stay non-capturing
(`(?:...)`), because HCL's `regex()` returns capture groups instead of the match when a group is
present. The alternation admits a tenancy OCID because traceysargeant has no child compartments.

The same reasoning drives the two OCIDs that do not exist yet, `OCI_CW_CHR_IMAGE_OCID` and
`OCI_CW_K3S_TOKEN_SECRET_OCID`. Both are asserted the same way so the leaf cannot be planned
against a placeholder. Both are meant to be replaced with literal OCIDs once created, matching how
every other leaf in this repo pins an image or a secret.

## Options considered

**Grow firefly's tenancy on paid ARM.** Rejected. A second account gives the same capacity for
nothing, and the operational cost of that account is lower than the recurring bill.

**Cross-tenancy IAM for the k3s node-token**, so cloudworkers instances read firefly's existing
vault secret rather than a copy. Rejected because OCI cannot express it. Cross-tenancy
authorization is `Endorse` / `Admit` / `Define`, and those statements accept a **`group`**, never a
**`dynamic-group`**. The cloud-init fetch authenticates as an instance principal, which is only
ever a dynamic-group member, so no wording of the policy closes the gap. Duplicating the secret
into a vault in the tracey tenancy is the supported answer, and it is what FranklinHouse already
does.

**Remote Peering Connection between the two VCNs.** Rejected: RPC is a cross-region facility and
both tenancies are in `eu-amsterdam-1`.

**Local Peering Gateway.** An LPG does join two VCNs in-region, but the thing these nodes must
reach is the k3s control plane at 192.168.19.10, which is on-prem, not inside firefly's VCN, and
OCI does not route transitively from an LPG onward through the peer's DRG. So this tenancy needs
its own IPSec to FG1 and FG2 regardless of any peering, and once it has that, firefly is reachable
over the same path by hairpinning through FG1. An LPG to cut that hairpin is a possible later
optimisation, not a prerequisite, and it is a larger change than the VPN leaf that has to exist
anyway.

**A terraform module for the vault, key and node-token secret.** Rejected for now. Firefly's own
vault is not terraform-managed either, so this would introduce a new pattern in one corner rather
than across the repo, and KMS pricing in a second free-tier account is unresolved. Note that
`modules/vpn` unconditionally creates its own `oci_kms_vault` and `oci_kms_key` for the IPSec
PSKs, so applying the `vpn` leaf already creates a **second** vault in this tenancy alongside
`vault-cloudworkers`. Confirm the billing position before applying it.

**A cloudworkers `mikrotik` config leaf.** Out of scope, not rejected. `modules/mikrotik` requires
a cloudflared tunnel token, hardcodes r1/r2 keys, and wants public IPs known at plan time. CHR
masquerade for ff-chr3 and ff-chr4 is configured out of band for now.

## Apply order

Not obvious, and the network leaf is applied twice on purpose.

1. `network` with `internet_gateway_ip = ""`
2. `edge` (creates ff-chr3 on .11 and ff-chr4 on .12)
3. `network` again with `internet_gateway_ip = "192.168.240.11"`
4. `vpn`
5. `server`

The two-pass network apply exists because of a real cycle. `modules/network` resolves
`internet_gateway_ip` to a private-IP OCID through a data source whose postcondition fails when no
such IP exists. That IP belongs to ff-chr3, and ff-chr3 lives in the edge subnet that this same
module creates. On a greenfield tenancy the network needs the CHR and the CHR needs the subnet.
Passing `""` on the first pass breaks the cycle: the VCN and subnets come up, the app and data
subnets simply have no default route yet, which is harmless because nothing is running in them.
Step 3 is a one-line follow-up commit, not a console change.

`server` is last because these VMs join the cluster at boot. A node that comes up before the
tunnel carries traffic retries the token fetch five times and then exits 1.

## Operator prerequisites

None of this applies cleanly until all five are done.

1. **Import a MikroTik CHR image into traceysargeant.** Firefly's edge leaf points at a **custom**
   image (`chr-7.18.2.vmdk`, 47694 MB, PARAVIRTUALIZED) in firefly's root compartment. Custom
   images are tenancy-private: reading that OCID with traceysargeant credentials returns 404
   `NotAuthorizedOrNotFound`, verified 2026-08-31, and the tenancy has no custom images of its own.
   Upload MikroTik's official `chr-7.x.vmdk` to a bucket in this tenancy, then
   `oci compute image import from-object-uri --source-image-type VMDK --launch-mode PARAVIRTUALIZED`.
   The Ubuntu image needs nothing done: `Canonical-Ubuntu-24.04-Minimal-aarch64-2025.01.31-1` is an
   Oracle **platform** image and is visible from any tenancy in the region, so the server leaf
   reuses firefly's OCID as-is. (Firefly's own leaf miscomments that OCID as "Ubuntu 22.04". It is
   24.04 Minimal.)
2. **Create a KMS key in `vault-cloudworkers` and store a copy of firefly's k3s node-token.** The
   vault exists but is empty. The vault must be in `eu-amsterdam-1`, because `modules/server`
   passes `--region` to the in-VM fetch from `var.region`.
3. **Configure the FortiGate side by hand.** `terraform/fortigate/prod` carries no `oci_vpn` key
   and `modules/fortigate` types `oci_vpn` as a single object per unit, so codifying a second DRG
   needs a module change. Read the generated PSKs back from the module's vault. See the BGP hazard
   below, which must be fixed at the same time.
4. **Set the `OCI_CW_*` variables** wherever terragrunt runs. `env_prefix` reaches only the
   generated provider, so this is more than the four credential names:
   - provider: `OCI_CW_TENANCY_OCID`, `OCI_CW_USER_OCID`, `OCI_CW_FINGERPRINT`,
     `OCI_CW_PRIVATE_KEY_PATH` (a path to a key file, not the key body)
   - passed as a module input and `regex()`-asserted by every leaf: `OCI_CW_COMPARTMENT_OCID`
     (traceysargeant has no child compartments, so this is the tenancy OCID itself)
   - until the OCIDs from steps 1 and 2 are inlined into the leaves:
     `OCI_CW_CHR_IMAGE_OCID`, `OCI_CW_K3S_TOKEN_SECRET_OCID`
   - optional, only to pin a PSK instead of letting OCI generate one:
     `FORTIGATE_FGT1_OCI_CW_PSK`, `FORTIGATE_FGT2_OCI_CW_PSK`
5. **Remove the CI exclusion.** `scripts/terragrunt-pipeline.sh` skips
   `terraform/oci/cloudworkers/**` in `discover_all` until the above is done, because the leaves
   deliberately refuse to parse without those variables and a failed plan blocks the apply job for
   every firefly stack too. Delete the `-not -path` line once the tenancy is bootstrapped, and note
   the runner will also need a `~/.oci/config` for the parse-time vault lookups in `network` and
   `vpn` (a pre-existing gap that already affects five firefly leaves).

## Consequences

**The k3s node-token now lives in two vaults, and rotation touches both.** There is no mechanism
keeping them in step. A rotation that forgets the tracey copy is not visible until ff-oci3 or
ff-oci4 is replaced and fails to re-join, which may be weeks later.

**The CHR image must be imported per tenancy, and re-imported on every version bump we want in
both places.** Nothing detects that the two tenancies have drifted onto different CHR versions.

**The BGP hazard is the single most likely thing to half-work.** Both DRGs are Oracle AS 31898.
FG1 therefore cannot re-advertise 192.168.223.0/24, which it learned from firefly's DRG in AS
31898, back to this tenancy's DRG: standard AS_PATH loop rejection drops it silently. FG1 must
**originate** both 192.168.223.0/24 and 192.168.240.0/24 as redistributed static routes (AS_PATH
[65010]), or run `as-override` on both OCI neighbours. The failure looks like success: the tunnels
come up green and the prefixes never appear. Ping in both directions before applying `server`.

**Atlantis cannot autoplan these four leaves.** It is injected with firefly's OCI credentials only
and has no `OCI_CW_*` at all, so an autoplan hard-fails on the empty `regex()` asserts. That is the
assert working as intended: without it the empty values would fall through to firefly's ambient
`~/.oci/config` and plan against the wrong tenancy. All four are registered in
`atlantis.yaml` with `autoplan.enabled: false`; run
`atlantis plan -p oci-cloudworkers-prod-eu-amsterdam-1-<leaf>` by hand, or run terragrunt locally.
Flipping them on requires per-tenancy credentials in the Atlantis deployment first. A red check
nobody can fix is a red check everyone learns to ignore.

**e2-micro headroom in the new tenancy is exactly zero.** The limit is 2 cores and the two CHRs use
both. There is no room for a third micro instance, and a failed CHR cannot be stood up beside its
replacement. The reserved public IPs are taken from the first apply for the same reason firefly's
pair is stuck on ephemeral ones: flipping that flag later releases the address and allocates a new
one, and greenfield is the only free moment to choose.

**Firefly's own network leaf changes.** `remote_networks` gains `cloudworkers_vcn`
(192.168.240.0/24), without which the flannel mesh between the two OCI pairs is one-way. That is a
live edit to firefly infra and it replans `oci-prod-eu-amsterdam-1-network`. It does not depend on
anything in the new tenancy existing, so it can land first.

**`modules/edge` gained an optional `node_name`.** It defaults to empty and `display_name` falls
back to the historical `<environment>-mikrotik-chr-<key>`, so firefly's CHRs keep
`prod-mikrotik-chr-fd1` / `-fd2` and plan no change. It is deliberately not wired to
`create_vnic_details.hostname_label`, which would be a live `UpdateVnic` on the running CHRs.

**`scripts/terragrunt-pipeline.sh` was matching nothing for shared modules.** Its "replan
everything" pattern looked for `terraform/modules/`, a path that has never existed in this repo;
modules live at `terraform/<provider>/modules/`. Every shared-module edit to date has triggered
zero replans. Fixed here, which means module edits now correctly fan out, so expect the pipeline to
do noticeably more work on those commits than it used to.

**Two Oracle accounts to keep alive.** An Always Free account reclaimed for inactivity takes half
the cloud worker tier with it, and console and billing access for that half sits with a second
identity.

**Reversal.** Destroy the four leaves and drop `cloudworkers_vcn` from firefly's network leaf.
Nothing in firefly depends on ff-oci3 or ff-oci4 beyond their being registered nodes, so the
cluster loses capacity and nothing else.
