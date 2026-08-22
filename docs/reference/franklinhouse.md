# FranklinHouse cluster

**franklinhouse** is the second Kubernetes cluster managed from this repo: a
3-node Proxmox VE cluster hosting a 6-VM k3s cluster. It is physically and
logically separate from [firefly](cluster-topology.md): different site,
different subnet (`192.168.69.0/24`), different Flux root, its own Postgres.

Its GitOps config previously lived in the private repo
`calebsargeant/infra-v2` and was folded into this repo on 2026-08-13.

!!! warning "This repo is public"
    infra-v2 was private; this repo is not. Anything moved here is world-visible.
    Secrets must be SOPS-encrypted (`*.enc.yaml`) or projected at runtime via an
    `ExternalSecret`, never committed as plain `data:`/`stringData:`. Base64 is
    encoding, not encryption.

## Physical topology

Three Proxmox hosts, each running exactly one control-plane VM and one worker VM.

| Proxmox host | IP | VMID | VM | VM IP | k3s role |
|---|---|---|---|---|---|
| node1 | 192.168.69.211 | 100 | fh-system-vm1 | 192.168.69.111 | server (control plane) |
| node1 | 192.168.69.211 | 103 | fh-worker-vm1 | 192.168.69.121 | agent |
| node2 | 192.168.69.212 | 101 | fh-system-vm2 | 192.168.69.112 | server (control plane) |
| node2 | 192.168.69.212 | 104 | fh-worker-vm2 | 192.168.69.122 | agent |
| node3 | 192.168.69.213 | 102 | fh-system-vm3 | 192.168.69.113 | server (control plane) |
| node3 | 192.168.69.213 | 105 | fh-worker-vm3 | 192.168.69.123 | agent |

```mermaid
flowchart TB
  subgraph n1["Proxmox node1 (.211)"]
    s1["fh-system-vm1 (.111)"]
    w1["fh-worker-vm1 (.121)"]
  end
  subgraph n2["Proxmox node2 (.212)"]
    s2["fh-system-vm2 (.112)"]
    w2["fh-worker-vm2 (.122)"]
  end
  subgraph n3["Proxmox node3 (.213)"]
    s3["fh-system-vm3 (.113)"]
    w3["fh-worker-vm3 (.123)"]
  end
  etcd["etcd quorum: needs 2 of 3 servers"]
  s1 --- etcd
  s2 --- etcd
  s3 --- etcd
```

!!! danger "One control-plane VM per Proxmox host"
    Losing a Proxmox host loses a control-plane node. Losing **two** hosts drops
    etcd below quorum and the Kubernetes API stops serving entirely. There is no
    anti-affinity safety margin here: the failure domains are stacked.

**Storage is entirely node-local.** Proxmox uses `local-lvm` (lvmthin) on every
host, plus `mdadm-raid5`/`local-ssd` pinned to node1 and `zfs-raidz1` pinned to
node2. There is no shared storage, which means a VM cannot be live-migrated or
started on a different host, but it also means forcing Proxmox quorum carries no
split-brain data-corruption risk.

Guests are Ubuntu 24.04 with **nested LVM** (`ubuntu-vg/ubuntu-lv` inside GPT
partition 3), `PasswordAuthentication no`, and user `caleb` (uid/gid 1000) with
passwordless sudo.

## k3s node roles

k3s was bootstrapped with `--cluster-init`, so the three servers run **embedded
etcd** and require 2 of 3 for quorum.

| Role | Nodes | Label | Taint |
|---|---|---|---|
| system | fh-system-vm1/2/3 | `node-role=system` | `node-role.kubernetes.io/control-plane=true:NoSchedule` |
| apps | fh-worker-vm1/2/3 | `node-role=apps` | none |

Platform workloads (Flux controllers, Traefik) are pinned to the system nodes,
which requires **both** a `node-role: system` selector and a toleration for the
control-plane taint. See the
`kubernetes/components/node-selectors/franklinhouse-system` component. Selecting
without tolerating produces unschedulable pods.

!!! note "svclb-traefik is not covered"
    Traefik's Deployment is pinned via `HelmChartConfig`, but the k3s service-LB
    helper pods (`svclb-traefik-*`) are a DaemonSet owned by the k3s servicelb
    controller and still run on workers. That is expected.

## Where things live in this repo

```text
kubernetes/
  apps/access-control/                    # the app — shared apps tree, repo convention
    base/access-control/                  #   GitRepository + ImageRepositories + deploy-key ExternalSecret
    prod/access-control/                  #   Flux Kustomization + ImagePolicy + ImageUpdateAutomation
    staging/access-control/               #   same, staging
  components/node-selectors/franklinhouse-system/   # nodeSelector + control-plane toleration
  clusters/franklinhouse/
    kustomization.yaml                    # build target of the meta `apps` Kustomization
    apps.yaml                             # the meta `apps` Kustomization itself
    flux-system/                          # bootstrap only: gotk-*, encrypted pull secret
    system/                               # Traefik HelmChartConfig
    infrastructure/                       # cluster-local tiers
      controllers/stack/cloudnative-pg/   #   CNPG operator
      services/stack/postgres/{prod,staging}/  # the CNPG Clusters
ansible/
  hosts.yaml                              # franklinhouse_* inventory groups
  franklinhouse-k3s-bootstrap.yaml        # cluster bootstrap playbook
scripts/bootstrap-franklinhouse-k3s.sh    # wrapper that manages K3S_TOKEN
```

Two scoping decisions are load-bearing:

- `clusters/franklinhouse/kustomization.yaml` references
  **`../../apps/access-control` directly**, not `../../apps`.
  `kubernetes/apps/kustomization.yaml` is *firefly's* app set (~50 apps);
  aggregating it would deploy all of firefly onto franklinhouse.
- franklinhouse's infrastructure tiers are **cluster-local**
  (`clusters/franklinhouse/infrastructure/`) rather than in the shared
  `kubernetes/infrastructure/`. `AGENTS.md` defines that shared tree as
  cluster-agnostic and its tier Kustomizations point at firefly's `stack/`
  paths, whereas franklinhouse runs its own CNPG clusters and Traefik config.

### Postgres is a deliberate exception

`AGENTS.md` says all Postgres goes through one shared CNPG cluster and forbids
new `Cluster` objects. That rule scopes to firefly. franklinhouse is a
physically separate k3s cluster and cannot reach firefly's `postgres` in the
`database` namespace, so it runs its own: the environment-isolation exception
the rule carves out.

## GitOps flow

```mermaid
flowchart LR
  git["CalebSargeant/infra (this repo)"] --> fs["flux-system Kustomization<br/>clusters/franklinhouse/flux-system"]
  fs --> apps["meta 'apps' Kustomization<br/>clusters/franklinhouse"]
  apps --> ctl["infrastructure-controllers<br/>(CNPG operator)"]
  ctl --> svc["infrastructure-services<br/>(Postgres clusters)"]
  svc --> ac["prod/staging-access-control"]
  ext["CalebSargeant/franklinhouse<br/>(app manifests)"] --> ac
```

Note the workload manifests are **not** in this repo: `access-control` is an
external-repo app. This repo holds only the control plane (GitRepository, image
automation, namespaces); the Deployments live in
`CalebSargeant/franklinhouse` under `./access-control/k8s/overlays/<env>`, and
their image tags are bumped there by `ImageUpdateAutomation`.

## Access

| Target | Method |
|---|---|
| Proxmox hosts | `ssh root@192.168.69.21{1,2,3}`: **password auth only**, 1Password item `Proxmox` (Firefly vault). SSH keys are not authorised. |
| k3s VMs | SSH key as `caleb`; `PasswordAuthentication no`. |
| Kubernetes API | `kubectl --context franklinhouse` → `https://192.168.69.113:6443` |

!!! tip "Recovering VM access without guest credentials"
    From a Proxmox host: `qm stop <vmid>`, then
    `losetup -P -f --show /dev/pve/vm-<vmid>-disk-0`, then activate the nested VG
    **scoped to that device**: `vgchange --devices <loopNp3> -ay ubuntu-vg`.
    All guests use the same VG name (`ubuntu-vg`), so an unscoped `vgchange` can
    activate the wrong guest's volume. Mount `ubuntu-lv`, append to
    `/home/caleb/.ssh/authorized_keys`, then unmount, `vgchange -an`,
    `losetup -d`, `qm start`.

## Out-of-band dependencies

The `external-secrets` operator and its `oci-vault` `ClusterSecretStore` are now
reconciled by franklinhouse's own controllers tier
(`clusters/franklinhouse/infrastructure/controllers/stack/external-secrets`), so
they are no longer manual. What remains out-of-band:

| Dependency | Needed by | Symptom if missing |
|---|---|---|
| `sops-keys` Secret (`flux-system`) | bootstrap Kustomization decryption | The whole `flux-system` Kustomization fails, so nothing reconciles at all |
| `flux-system` Secret (deploy key) | `flux-system` GitRepository | No sync from this repo |
| `access-control-deploy-key` **in OCI Vault** | the deploy-key `ExternalSecret` | Secret never materialises → `access-control` GitRepository cannot authenticate → neither env reconciles |
| `access-control-secret` **in OCI Vault** | the app's own `ExternalSecret` (defined in the **external** app repo) | Backends stay in `CreateContainerConfigError` |

## OCI Vault

franklinhouse uses **its own OCI tenancy**, a separate account from firefly's,
in a different region. Do not mix the two sets of OCIDs; neither resolves in the
other's account.

| | franklinhouse | firefly |
|---|---|---|
| Region | `af-johannesburg-1` | `eu-amsterdam-1` |
| Vault | `vault-franklinhouse` | `vault-prod` |
| Store name | `oci-vault` | `oci-vault` |

The store is deliberately named `oci-vault` on both clusters so `ExternalSecret`
manifests read identically either side.

!!! warning "Known IaC drift"
    `vault-franklinhouse` and its `key-franklinhouse` master key were created
    **via the OCI CLI on 2026-08-14**, not Terraform, because franklinhouse's OCI
    tenancy has no Terragrunt coverage in this repo at all (the only franklinhouse
    resources there are VPN tunnel PSKs, managed from the other tenancy). Adopting
    this vault into a Terragrunt leaf is outstanding work.

Secrets must be created in `vault-franklinhouse` with the exact names the
`ExternalSecret`s reference: `access-control-deploy-key` (an SSH private key
for the app repo) and `access-control-secret`. Until they exist, both
`ExternalSecret`s report NotReady and the apps cannot start.

### Managing vault secrets

Use `scripts/oci-vault-secrets.py` rather than the OCI console. It targets
either tenancy by name and pulls that account's API credentials from 1Password
at run time (into a 0700 temp dir, removed on exit; nothing is written to the
repo and no OCI profile is needed):

```bash
scripts/oci-vault-secrets.py -c franklinhouse list
```

```bash
cat id_ed25519 | scripts/oci-vault-secrets.py -c franklinhouse set access-control-deploy-key
```

`vaults`, `list`, `get`, `set` and `delete` are supported; `-V` overrides the
vault by name. `get` writes to stdout, so redirect it rather than letting a
secret land in your scrollback.

## Known risks

These are real, currently-unmitigated, and all three contributed to the
2026-08-13 outage. None is fixed by the migration: fixing them is a behavioural
change, tracked separately.

1. **No database backups.** Neither CNPG `Cluster` has a `.spec.backup` stanza
   and there are no `ScheduledBackup` objects anywhere. The only copy of the
   data is the node-local volumes.
2. **`storageClass: local-path` pins data to nodes.** Each Postgres PVC is bound
   to whichever node first scheduled it. If that node is gone, the volume is
   unreachable and the instance is unschedulable. As of the outage: prod
   `postgres-2`/`postgres-3` and staging `postgres-1` were on fh-worker-vm1
   (node1); prod `postgres-1` on fh-worker-vm2 (node2).
3. **Every node points at `.111` as its join endpoint.** The Ansible bootstrap
   bakes `--server https://<fh-system-vm1>:6443` into each node's systemd unit
   *and* into the agent load-balancer cache at
   `/var/lib/rancher/k3s/agent/etc/k3s-agent-load-balancer.json`. During the
   outage that cache listed only `.112` and `.111` (both dead, `.113` never
   present), so the surviving worker could not rejoin on its own. Consider a VIP
   or DNS name before rebuilding.
4. **No Wake-on-LAN.** No node has a WoL MAC configured, so a dead Proxmox host
   cannot be powered on remotely.

## Recovery: Proxmox loses quorum

Symptom: `cluster not ready - no quorum? (500)` in the Proxmox UI, VMs will not
start, and the node shell/console fails with
`termproxy ... failed waiting for client`. With fewer than 2 of 3 hosts up,
pmxcfs mounts `/etc/pve` **read-only**, and `qm start` needs to write there.

**Before forcing anything**, confirm the other hosts are genuinely down rather
than partitioned. If two hosts are alive and talking to each other, they
already hold quorum and forcing a third creates split brain:

```bash
pvecm status; corosync-cfgtool -s
```

Then, on the surviving host:

```bash
pvecm expected 1
```

This is in-memory only and **reverts on reboot or a corosync restart**, so
complete the work promptly. `/etc/pve` becomes writable immediately and
`qm start <vmid>` works again.

If fewer than 2 control-plane VMs can be started, etcd cannot reach quorum
either. Preferred fix is to revive a Proxmox host. Only if that is impossible,
reset etcd to a single member on a surviving server. This **permanently drops
the other two members**, which must then have `/var/lib/rancher/k3s/server/db`
removed before they can rejoin:

```bash
sudo systemctl stop k3s && sudo k3s server --cluster-reset
```

It prints `Managed etcd cluster membership has been reset` and exits; then
`sudo systemctl start k3s`. Cluster **data is preserved**; only membership
resets. Afterwards, remove the now-stale `--server https://192.168.69.111:6443`
flag from the surviving server's unit, and repoint any surviving worker's
`k3s-agent.service` and load-balancer cache at a live server.

Finally, pods left on dead nodes stay `Running` as phantoms and keep Service
endpoints pointing at unreachable IPs (this is what breaks Flux:
`source-controller` becomes unreachable). Clear them:

```bash
kubectl delete pod -n <ns> <pod> --force --grace-period=0
```

## Cutover from infra-v2

Moving the files here does **not** move the cluster. franklinhouse's Flux still
syncs from `infra-v2` until its `GitRepository` is repointed. To cut over:

1. Give franklinhouse its own read-write deploy key on **`MagmaMoose/infra`**
   (the canonical name; `CalebSargeant/infra` only resolves via a GitHub
   redirect) and write the private key into franklinhouse's `flux-system`
   Secret. A single deploy key can only be attached to one repo at a time
   (this bit the original infra-v2 migration), so generate a *new* key rather
   than reusing firefly's.
2. Ensure the `sops-keys` Secret exists in `flux-system` on franklinhouse. This
   is new: infra-v2 used no SOPS at all, but the bootstrap Kustomization now
   sets `decryption.provider: sops` for the encrypted pull secret, so without
   it the whole `flux-system` Kustomization fails to reconcile. The Secret's
   data key is `age.agekey` (firefly's convention; the
   `ansible/roles/k3s-sops-age-secret` role still says `identity.agekey` and is
   stale), and it must hold the key matching the **current** `.sops.yaml`
   recipient, rotated 2026-08-07, so an older copy cannot decrypt this repo.
3. Ensure the **external-secrets operator** is running and the **`azure-keyvault`
   `ClusterSecretStore`** exists on franklinhouse. The `access-control` app's
   `ExternalSecret` depends on both to project the deploy key into
   `gitrepository.yaml`; if either is absent on a clean rebuild, the Secret
   never materialises and the app's source auth fails silently. franklinhouse's
   GitOps reconciles only CNPG in its controllers tier: ESO and the store are
   installed out of band and must pre-exist before `access-control` reconciles.
4. Apply the updated `gotk-sync.yaml` (url → `MagmaMoose/infra`, path →
   `./kubernetes/clusters/franklinhouse/flux-system`), then
   `flux reconcile source git flux-system -n flux-system`.
5. Archive `calebsargeant/infra-v2` once reconciliation is healthy.

!!! danger "Rotate the GHCR token"
    `ghcr-pull-secret` is SOPS-encrypted here, but the same token sat as plain
    base64 in infra-v2's git history and is therefore compromised. Rotate the PAT
    and re-encrypt:
    `sops kubernetes/clusters/franklinhouse/flux-system/ghcr-pull-secret.enc.yaml`
