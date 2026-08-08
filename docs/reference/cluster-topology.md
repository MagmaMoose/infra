# Cluster Topology: system vs worker nodes

The firefly k3s cluster has two **node roles**, which map directly onto k3s's
server/agent split. Understanding this mapping is the key to deciding *where a
workload should run*.

## The two roles

| Role | k3s role | Runs | Current node(s) | Planned | Labels |
|------|----------|------|-----------------|---------|--------|
| **system** | k3s **server** (control plane) | API server, scheduler, controller-manager, kine **plus** the bootstrap- and network-critical controllers: flux-\*, cert-manager, external-secrets, 1Password Connect, external-dns, CoreDNS/Traefik | **ff-pi1** (Raspberry Pi 5, arm64, 8 GiB) | ff-pi2, ff-pi3 (more Pi5s — control-plane HA / more system capacity) | `node-role.kubernetes.io/system`, legacy `type=pi` / `node-role.kubernetes.io/pi` |
| **worker** | k3s **agent** | Application workloads, plus the policy engine and the operators whose workloads live here (kyverno, cloudnative-pg) | **ff-vm1** (amd64, 8 vCPU / 27.4 GiB allocatable); **ff-oci1** / **ff-oci2** (OCI free-tier, arm64, 2 OCPU / ~11.9 GiB allocatable — the **native-cloud** sub-tier, see below) | ff-vm2 | `node-role.kubernetes.io/worker`, legacy `type=mini` / `node-role.kubernetes.io/mini`; native-cloud nodes also carry `topology.sargeant.co/tier=native-cloud` |

```mermaid
flowchart TB
  subgraph system["system role — k3s servers"]
    pi1["ff-pi1 (now)"]
    pi2["ff-pi2 (planned)"]
    pi3["ff-pi3 (planned)"]
  end
  subgraph worker["worker role — k3s agents"]
    vm1["ff-vm1 (now)"]
    vm2["ff-vm2 (planned)"]
    subgraph nc["native-cloud sub-tier (OCI, arm64)"]
      oci1["ff-oci1 (now)"]
      oci2["ff-oci2 (now)"]
    end
  end
  cp["Control plane + system controllers"] --> system
  apps["Application workloads"] --> worker
```

!!! note "Naming: pi == system, mini == worker"
    The repo historically named these roles after the **hardware** (`pi`, `mini`).
    They are now also exposed under **role-based** names (`system`, `worker`) which
    describe *intent* and survive hardware changes (e.g. an amd64 system node, or a
    Pi worker). The hardware names remain as **aliases** during migration. Prefer the
    role names for new and migrated workloads.

## Choosing where a workload runs

- **`system`** — the control plane, plus only what must keep working when *no worker
  does*: Flux (it installs everything else, so it cannot depend on anything else),
  cert-manager, the secrets plane (external-secrets + 1Password Connect), DNS and
  ingress, and node-level DaemonSets.
- **`worker`** — applications, the policy engine, and operators whose managed
  workloads already live on a worker.
- **Everything else** → `worker`. `system` is the exception, not the default.

!!! warning "`system` is not a synonym for 'infrastructure'"
    The earlier rule here was "anything that operates the cluster itself → `system`",
    and it is how an 8 GiB Pi ended up hosting the whole controller tier. Most
    controllers only need an API connection; needing an API connection is not a
    reason to sit on the API server. Ask instead: *if every worker were down, would
    this still need to run?* If the answer is no, it belongs on `worker`.

### Why ff-pi1 has far less room than it looks

ff-pi1 reports 8063Mi capacity, but the k3s server process — API server, scheduler,
controller-manager, kine and the kubelet in one Go binary — holds roughly 2.5-3 GiB
of that, and it lives in `system.slice`, **outside** `kubepods.slice`. The kubelet
neither counts it against Allocatable by default nor can ever evict it.

Left unreserved, the node therefore advertised its full 8063Mi while ~4.8 GiB was
already spoken for, and pods drifted onto it against roughly 5 GiB of headroom that
did not exist — until it exhausted memory and swap and hard-locked, needing a
physical reset. `ansible/firefly-control-plane-resources.yaml` closes that gap: it
sets `system-reserved`/`kube-reserved` so Allocatable tells the truth (~3823Mi), adds
an `eviction-soft` threshold that sheds load while the node is still responsive, and
caps the k3s Go heap with `GOMEMLIMIT`.

The practical consequence when placing work: **treat ff-pi1 as a ~3.8 GiB node, not
an 8 GiB one.**

## The native-cloud tier (OCI)

`ff-oci1` and `ff-oci2` are OCI free-tier ARM VMs (`VM.Standard.A1.Flex`, 2 OCPU /
12 GiB each, one per fault domain) that join firefly as k3s **agents** over the
FortiGate-to-OCI site-to-site VPN. They are the **native-cloud** sub-tier: more
reliable / always-on than the home-lab nodes, so they host **public-facing,
always-online** workloads (e.g. GitHub-App backends) and the `postgres-oci`
database.

They are ordinary `worker` nodes **plus** an extra tier label:

| Label | Where it's set | Why |
|-------|----------------|-----|
| `topology.sargeant.co/tier=native-cloud` | k3s `--node-label` at agent registration (cloud-init, `terraform/oci/modules/server`) | Pin workloads to OCI **specifically** (vs `ff-vm1`, which shares the `worker` role). Durable across node re-registration. |
| `node-role.kubernetes.io/worker` | `kubectl` post-join (see below) | Generic worker role. **Cannot** be set via `--node-label` — the kubelet may not self-register `kubernetes.io`-namespaced labels (NodeRestriction). |

!!! info "Provisioning is in Terraform, not Ansible"
    The VMs and their k3s agent join are defined entirely in
    `terraform/oci/modules/server` (+ the `server` leaf). cloud-init fetches the
    k3s node-token from OCI Vault via instance-principal at boot — no token in
    state or metadata. `node_name` / `node_labels` in the leaf's `servers` map
    set the k3s `--node-name` (so they register as `ff-oci1`/`ff-oci2`, not the
    OS hostname) and the tier label. Changing either replaces the VM (it alters
    the cloud-init hash). Because this edits a shared **module**, Atlantis
    autoplan won't fire — run `atlantis plan -p oci-prod-eu-amsterdam-1-server`.

### Pinning to native-cloud

- **Apps**: reference the component
  `../../../../components/node-selectors/native-cloud` from the app's base
  `kustomization.yaml` (or set `nodeSelector: { topology.sargeant.co/tier: native-cloud }`
  inline for non-app-template HelmReleases). Verify the image is **arm64 /
  multi-arch** first — several custom images (`atlantis-firefly`, etc.) are
  amd64-only today.
- **CNPG**: a Cluster CR is **not** a Deployment/StatefulSet, so the
  node-selectors component does **not** reach it. Pin it via the Cluster's own
  `spec.affinity.nodeSelector` — see
  `kubernetes/infrastructure/services/stack/postgres-oci/base/cluster.yaml`
  (2 instances, one per OCI node via required hostname anti-affinity).

## How it's codified

### Node labels

```bash
# Applied to the live nodes (cluster-admin / `ember` context):
kubectl label node ff-pi1  node-role.kubernetes.io/system=""  --overwrite
kubectl label node ff-vm1  node-role.kubernetes.io/worker=""  --overwrite
# native-cloud (OCI) nodes — the worker ROLE label still goes on via kubectl
# (kubelet can't self-set kubernetes.io labels). Their tier label is already
# baked at join (cloud-init --node-label), so it does NOT need re-applying.
kubectl label node ff-oci1 node-role.kubernetes.io/worker=""  --overwrite
kubectl label node ff-oci2 node-role.kubernetes.io/worker=""  --overwrite
```

!!! warning "Labels must persist across node re-registration"
    `kubectl label` is imperative. The labels survive a reboot, because they live
    in etcd — but **not** the Node object being deleted and re-added, which is what
    a rebuild or re-join does. Everything pinned to them goes `Pending` at that
    moment, and that includes the Flux controllers, so the cluster cannot
    reconcile its own fix.

    Only **half** the labels can be made durable, and it is worth knowing which:

    | label | applied by | durable? |
    |---|---|---|
    | `node-role.kubernetes.io/*` | API, `ansible/firefly-node-labels.yaml` | no |
    | `topology.sargeant.co/*` | kubelet self-registration | **yes** |

    NodeRestriction rejects kubelet-set labels inside the `kubernetes.io`
    namespace outside a short allow-list, and `node-role.kubernetes.io/*` is not on
    it. Putting those in k3s's `node-label:` does **not** silently no-op — the node
    refuses to register.

    Run `ansible/firefly-node-label-durability.yaml` to write the self-registerable
    labels into every node's k3s config drop-in. It takes effect at the *next*
    registration, so it changes nothing today and needs no restart — that is the
    point of it.

### Placement labels

`kubernetes/components/node-selectors/` has been **removed**. Placement is now one
label on the workload, applied by a Kyverno mutating policy at admission
(`kubernetes/apps/kyverno-policies/base/clusterpolicy-place-*.yaml`):

| Label | Lands on | Use for |
|-------|----------|---------|
| `placement.sargeant.co/tier: system` | ff-pi1 | control-plane / system controllers |
| `placement.sargeant.co/tier: on-prem` | ff-vm1 | workloads tied to on-prem storage or network |
| `placement.sargeant.co/tier: cloud` | ff-oci1 / ff-oci2 | always-online, public-facing, or multi-arch apps |
| `placement.sargeant.co/tier: worker` | any agent | genuinely placement-agnostic workloads |

Set it in the app's `kustomization.yaml`:

```yaml
labels:
  - pairs:
      placement.sargeant.co/tier: cloud
    includeSelectors: false     # immutable on a live Deployment
    includeTemplates: false
```

!!! warning "`worker` spans both sites"
    `node-role.kubernetes.io/worker` matches ff-vm1 **and** both OCI nodes. A
    workload meaning "the on-prem worker" must use the `on-prem` tier — several
    drifted to the cloud tier by selecting `worker` alone, which put their pods on
    the far side of the site-to-site VPN from their storage.

!!! warning "A placement label on a HelmRelease does nothing"
    The Kyverno policies match `Deployment`/`StatefulSet`/`DaemonSet`/`CronJob`. A
    label on a `HelmRelease` never reaches the pod template the chart renders — set
    `nodeSelector` in the chart's values instead. CI enforces this
    (`.github/actions/placement-label-guard`).
| `node-selectors/pi` | `type=pi` | **legacy alias** for `system` |
| `node-selectors/mini` | `type=mini` | **legacy alias** for `worker` |

Reference one from an app's base `kustomization.yaml`:

```yaml
components:
  - ../../../../components/node-selectors/worker
```

## Storage and the "everything off the Pi" migration

Most legacy stateful apps were pinned to ff-pi1 not by a node-selector but by
**storage**: `hostPath` PVs on the Pi's local disks (`/mnt/nvme/*`, `/mnt/raid/*`,
`/mnt/data/*`) and `local-path` PVs already bound to ff-pi1. A node-selector flip
alone would orphan their data, so moving them off the Pi requires a **data
migration**, not just a label change.

The storage model going forward:

| Need | Backend | Notes |
|------|---------|-------|
| Movable app config / databases | **Longhorn** (`longhorn` SC) | Replicated across nodes (`default-replica-count=2`), so the volume is reachable from any node — this is what un-pins a stateful app from the Pi. |
| Bulk media / downloads | **NFS** (`192.168.19.5:/mnt/raid5/...`) | Network-shared, node-independent. |
| Legacy (being retired) | `hostPath` / `local-path` on ff-pi1 | Node-bound; migrate to Longhorn/NFS, then schedule on `worker`. |
| CloudNativePG instances | CNPG-managed | Drain a node by editing the `Cluster` affinity; CNPG re-replicates — no manual copy. |

!!! info "hostNetwork exceptions"
    `homeassistant` and `homebridge` use `hostNetwork: true` (HomeKit/mDNS). They
    can run on a worker (also on the LAN), but their **advertised IP changes** when
    they move off the Pi — expect HomeKit re-pairing / mDNS cache refreshes.
