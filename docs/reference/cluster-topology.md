# Cluster Topology: system vs worker nodes

The firefly k3s cluster has two **node roles**, which map directly onto k3s's
server/agent split. Understanding this mapping is the key to deciding *where a
workload should run*.

## The two roles

| Role | k3s role | Runs | Current node(s) | Planned | Labels |
|------|----------|------|-----------------|---------|--------|
| **system** | k3s **server** (control plane) | API server, scheduler, controller-manager, kine **plus** the cluster's system controllers (helm-controller, flux-\*, kyverno, gatekeeper, cert-manager, external-secrets, longhorn-manager, 1Password Connect, …) | **ff-pi1** (Raspberry Pi 5, arm64, 8 GiB) | ff-pi2, ff-pi3 (more Pi5s — control-plane HA / more system capacity) | `node-role.kubernetes.io/system`, legacy `type=pi` / `node-role.kubernetes.io/pi` |
| **worker** | k3s **agent** | Application workloads | **ff-vm1** (amd64, 16 vCPU / 32 GiB); **ff-oci1** / **ff-oci2** (OCI free-tier, arm64, 2 OCPU / 12 GiB — the **native-cloud** sub-tier, see below) | ff-vm2 | `node-role.kubernetes.io/worker`, legacy `type=mini` / `node-role.kubernetes.io/mini`; native-cloud nodes also carry `topology.sargeant.co/tier=native-cloud` |

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

- **System controllers** (anything that operates the cluster itself) → `system`.
- **Everything else** (applications) → `worker`.

The goal is for **ff-pi1 to run only control-plane + system controllers**, leaving
headroom for the API server, scheduler, and node-level DaemonSets
(node-exporter, fluent-bit, Alloy). The Pi is **memory-request bound** (8 GiB),
so a single over-provisioned app reservation there is expensive.

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

## Private DNS zones

`whyf.uk` is a split-horizon zone for the private Ember workload. Its application
records are managed only by the MikroTik ExternalDNS instance and resolve only
for LAN/VPN clients. The Cloudflare ExternalDNS instance explicitly excludes the
zone, so it must never publish application A, AAAA, or CNAME records there.

TLS still uses cert-manager's Cloudflare DNS-01 issuer. That issuer creates only
the short-lived `_acme-challenge` TXT records needed for Let's Encrypt validation;
it does not make an Ember application reachable from the public Internet.

Keep the private-DNS annotation (`dns.sargeant.co/visibility=private`)
on every `whyf.uk` Ingress. Do not add these hosts to a Cloudflare Tunnel or to
the public Cloudflare ExternalDNS domain filters.

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
    `kubectl label` is imperative and is lost if a node re-registers. To make the
    role labels durable, add them to each node's **k3s config**
    (`node-label:` in `/etc/rancher/k3s/config.yaml` for servers,
    `/etc/rancher/k3s/config.yaml.d/` for agents). The OCI native-cloud nodes
    already do this for their **tier** label via cloud-init
    (`terraform/oci/modules/server`); their `worker` **role** label still needs
    the `kubectl` step above after any rebuild, because the kubelet may not
    self-register `node-role.kubernetes.io/*` (NodeRestriction). The legacy
    `type=` labels are set the same way.

### Node-selector components

Kustomize components apply the selector to a workload's pod template
(`kubernetes/components/node-selectors/`):

| Component | Selects | Use for |
|-----------|---------|---------|
| `node-selectors/system` | `node-role.kubernetes.io/system` | control-plane / system controllers |
| `node-selectors/worker` | `node-role.kubernetes.io/worker` | application workloads (any agent: ff-vm1 or ff-oci*) |
| `node-selectors/native-cloud` | `topology.sargeant.co/tier=native-cloud` | always-online / public-facing apps pinned to the OCI tier (ff-oci1/ff-oci2) |
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
