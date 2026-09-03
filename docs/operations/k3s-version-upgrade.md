# k3s version upgrade (firefly)

Firefly is currently running an **unsupported** version spread. This is the runbook to
close it, and the reasoning for why it cannot be done in one jump.

## The problem

```
ff-pi1    control-plane,master   v1.33.4+k3s1    192.168.19.10   <- API server
ff-pi2    on-prem,system         v1.33.4+k3s1    192.168.19.11   <- runs CoreDNS
ff-vm1    on-prem,worker         v1.33.5+k3s1    192.168.19.13
ff-oci1   cloud,worker           v1.33.4+k3s1    192.168.223.71
ff-oci2   cloud,worker           v1.33.4+k3s1    192.168.223.72
ff-oci3   cloud,worker           v1.36.4+k3s1    192.168.240.71  <- 3 minors AHEAD
ff-oci4   cloud,worker           v1.36.4+k3s1    192.168.240.72  <- 3 minors AHEAD
```

Kubernetes' version-skew policy allows a kubelet to be **up to 3 minor versions older**
than kube-apiserver. It allows a kubelet to be **newer by exactly zero**. ff-oci3 and
ff-oci4 joined on 2026-09-01 running v1.36.4 against a v1.33.4 API server, which is not a
tight-but-legal configuration — it is outside the supported matrix entirely, and the
failure mode is silent: the kubelet speaks API versions the server has never heard of, and
what breaks depends on which feature a workload happens to touch.

## Why it is three upgrades, not one

The control plane must move **one minor at a time**. There is no supported 1.33 → 1.36
jump, so the sequence is 1.33 → 1.34 → 1.35 → 1.36 on ff-pi1, each step verified before
the next.

The skew stays invalid until the server reaches 1.36 — an intermediate 1.34 server still
has two nodes ahead of it. That window is unavoidable while moving forward. The
alternative is to *downgrade* ff-oci3/ff-oci4 to 1.33 first, which restores a supported
state immediately and lets the whole cluster then move up together at its own pace. Pick
that one if the window matters more than the destination.

Latest per minor at time of writing:

| Minor | Latest        |
|-------|---------------|
| 1.34  | v1.34.11+k3s1 |
| 1.35  | v1.35.8+k3s1  |
| 1.36  | v1.36.4+k3s1  |

## Do this first: CoreDNS is a single replica

```
coredns-69b6458dcd-6nkkr   1/1   Running   ff-pi2
```

One CoreDNS pod serves the entire cluster, and it is on **ff-pi2**. Draining or restarting
that node during the upgrade takes cluster DNS to zero — every pod, every namespace, for as
long as it takes to reschedule. Do not start the upgrade before fixing this.

CoreDNS here is a **k3s Addon**, not a Flux resource:

```
objectset.rio.cattle.io/owner-gvk: k3s.cattle.io/v1, Kind=Addon
source: /var/lib/rancher/k3s/server/manifests/coredns.yaml
```

so `kubectl scale` is reverted the moment k3s restarts — which is exactly what an upgrade
does. Raise `replicas` in that file on ff-pi1 and add a `topologySpreadConstraint` (or
anti-affinity) so the two land on different nodes. Verify with a k3s restart *before*
trusting it under an upgrade.

## Prerequisites

1. **Snapshot the datastore.** `k3s etcd-snapshot save` on ff-pi1 (or copy
   `/var/lib/rancher/k3s/server/db/` if this cluster is on SQLite). Do not skip this —
   it is the only rollback that works if an upgrade eats the datastore.
2. **Confirm a current CNPG backup exists.** See `backup-and-restore.md`.
3. **Check Longhorn's supported Kubernetes range** for the target version before starting.
   Longhorn gates on this and will not tell you politely.
4. **Check Flux and cert-manager** support the target minor.
5. Fold in `ansible/firefly-k3s-metrics-bind.yaml` so each node restarts **once**, not
   twice — see below.

## Recommended method: system-upgrade-controller

Rancher's system-upgrade-controller drives this node by node: it cordons, drains
(respecting PodDisruptionBudgets — nievah has them), upgrades, uncordons, and only then
moves on. It is the "try not to take things down" path and is what k3s itself documents.

Use a **server Plan** with `concurrency: 1`, and an **agent Plan** that depends on it via
`prepare`. Run one minor per pass: set the server Plan's version, let it finish and
verify, then move the agent Plan, then repeat for the next minor.

Manual alternative, per node, if you would rather watch each step:

```bash
# server (ff-pi1) — one minor at a time
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.11+k3s1 sh -
# agents
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.11+k3s1 K3S_URL=... K3S_TOKEN=... sh -
```

## Sequence

For each target in `v1.34.11+k3s1`, `v1.35.8+k3s1`, `v1.36.4+k3s1`:

1. Snapshot the datastore.
2. Upgrade **ff-pi1** (server) and wait for the API to return.
3. Verify before touching anything else:
   ```bash
   kubectl get nodes -o wide
   kubectl -n kube-system get pods
   kubectl get kustomizations -A          # Flux still reconciling
   kubectl get clusters.postgresql.cnpg.io -A
   ```
4. Upgrade the agents, one at a time: ff-vm1, ff-oci1, ff-oci2, then ff-pi2 **last**
   (it holds CoreDNS — and only after CoreDNS is genuinely running 2 replicas on
   different nodes).
5. ff-oci3/ff-oci4 are already at 1.36.4 and are skipped until the final pass.

Agents may lag the server by up to 3 minors, so once ff-pi1 is on 1.36 the cluster is back
inside the supported matrix even before every agent has moved. That is the point at which
the urgency ends.

## Fold in the metrics bind

`ansible/firefly-k3s-metrics-bind.yaml` writes a k3s config drop-in that binds the
scheduler, controller-manager and kube-proxy metrics off localhost, which is what
`KubeSchedulerDown` / `KubeControllerManagerDown` / `KubeProxyDown` actually need in order
to stop firing. Writing the drop-in does nothing until k3s restarts, so apply it to a node
**immediately before** that node's upgrade restart and get both for one outage:

```bash
ansible-playbook -i hosts.yaml firefly-k3s-metrics-bind.yaml --limit 192.168.19.10
# then upgrade that node
```

## Rollback

k3s keeps the previous binary, and the install script is idempotent, so a bad minor is
rolled back by re-running it with the older `INSTALL_K3S_VERSION` **plus** restoring the
datastore snapshot taken in step 1. Restoring the binary alone is not enough once the
newer API server has written newer resource versions into the datastore.
