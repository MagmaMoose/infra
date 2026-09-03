# k3s version upgrade (firefly)

Procedure for moving firefly across k3s minor versions, written from the 2026-09-03 run
that took the cluster from v1.33.4 to v1.36.4. Every step below was executed; the
surprises are called out where they bit.

## Why it is not one jump

The control plane moves **one minor at a time**: 1.33 → 1.34 → 1.35 → 1.36, each verified
before the next. A kubelet may be up to 3 minors OLDER than kube-apiserver and newer by
exactly zero.

That last clause is what created the original problem. ff-oci3/ff-oci4 were provisioned on
v1.36.4 against a v1.33.4 API server — outside the supported matrix, failing silently
depending on which API a workload touched.

**A catch-up pass must never downgrade a node that is already ahead.** The agent Plan
carries an explicit exclusion for exactly this. Dropping it turns a 1.34 pass into a
kubelet downgrade on those two nodes, which is worse than the skew being fixed.

## Method: system-upgrade-controller, not SSH

SUC runs in-cluster and needs only the API. That is not a stylistic preference: ff-oci3
and ff-oci4 were unreachable by SSH for their first two days (see the placeholder-key note
in `terraform/oci/.../server/terragrunt.hcl`), and an upgrade path that depends on SSH
stops at whichever node last drifted.

Deployed via Flux as `kubernetes/apps/system-upgrade-controller`. Plans are NOT in git —
a Plan names one target version, so leaving one committed re-runs an upgrade nobody asked
for. Apply them by hand, one pass at a time.

### Server plan

```yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata: {name: k3s-server, namespace: system-upgrade, labels: {k3s-upgrade: server}}
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: In, values: ["true"]}
  serviceAccountName: system-upgrade
  upgrade: {image: rancher/k3s-upgrade}
  version: v1.34.11+k3s1     # then v1.35.8+k3s1, then v1.36.4+k3s1
```

### Agent plan

```yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata: {name: k3s-agent, namespace: system-upgrade, labels: {k3s-upgrade: agent}}
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
      # Drop this ONLY on the final pass, when the target is >= their version.
      - {key: kubernetes.io/hostname, operator: NotIn, values: ["ff-oci3", "ff-oci4"]}
  serviceAccountName: system-upgrade
  prepare: {args: ["prepare", "k3s-server"], image: rancher/k3s-upgrade}
  upgrade: {image: rancher/k3s-upgrade}
  version: v1.34.11+k3s1
```

`prepare` gates the agents on the server plan, so a kubelet cannot run ahead of the API.

### Cordon, do not drain

`cordon: true` with **no drain block**. A k3s upgrade swaps the binary and restarts the
service; it does not stop containerd, so pods keep running through it. Draining buys
nothing and deadlocks: this cluster has single-replica `minAvailable: 1` PDBs
(`database/postgres-primary`, `dunmir/*`, `automation/litellm`) that can never satisfy an
eviction, so the plan would hang on the first node holding one.

## Before you start

**Back up the datastore, and use `VACUUM INTO`.** firefly is on SQLite/kine, not etcd —
`k3s etcd-snapshot save` returns "etcd datastore disabled". Do NOT use `sqlite3 .backup`:
it restarts the copy whenever the source is written, and against a live kine datastore it
never converges (observed stalling at 262M of 593M). `VACUUM INTO` is one consistent pass:

```bash
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db \
  "VACUUM INTO '/var/lib/rancher/k3s/server/db/backups/state.db.pre-upgrade-$(date +%Y%m%d)';"
sudo sqlite3 <that file> "PRAGMA integrity_check;"   # must print: ok
```

It took 2 seconds and produced a verified 378M file from a 593M source.

**Stage the metrics drop-in first.** `/etc/rancher/k3s/config.yaml.d/10-metrics-bind.yaml`
(see `ansible/firefly-k3s-metrics-bind.yaml`) does nothing until k3s restarts — so write it
to every node BEFORE a pass and the upgrade restart activates it for free, instead of
costing a second outage. Verify after with `ss -lntp | grep -E ':10249|:10257|:10259'`:
the ports must show `*:` and not `127.0.0.1:`.

## The CoreDNS trap

**Every k3s upgrade rewrites `/var/lib/rancher/k3s/server/manifests/coredns.yaml` and
reverts `replicas: 2` back to the default 1.** This happened on both server upgrades in the
run and will happen on every future one.

It matters because CoreDNS shipped as a single replica: whichever node holds it takes
cluster DNS to zero when drained or restarted. Re-assert the replica count after EACH
server upgrade, before touching another node:

```bash
sudo sed -i 's/^  revisionHistoryLimit: 0$/  replicas: 2\n  revisionHistoryLimit: 0/' \
  /var/lib/rancher/k3s/server/manifests/coredns.yaml
```

The k3s addon controller picks the edit up on its own; no restart needed. The manifest
already carries a `topologySpreadConstraints` on `kubernetes.io/hostname` with
`whenUnsatisfiable: DoNotSchedule`, so the two land on different nodes automatically.

A durable fix means `coredns.yaml.skip` plus managing CoreDNS through Flux. Until someone
does that, this step is manual and mandatory.

The custom server block (`coredns-custom` ConfigMap, the `vcnprod.oraclevcn.com` NXDOMAIN
guard) is a normal ConfigMap and DOES survive — it came through both upgrades and the
CoreDNS image bump from 1.12.3 to 1.14.6 intact.

## Sequence, per minor

1. Snapshot the datastore (`VACUUM INTO`, verify `integrity_check`).
2. Stage `10-metrics-bind.yaml` on every node if not already there.
3. Patch the server Plan's `version`. Watch it: `kubectl get plan -n system-upgrade`.
4. The API goes away for a few minutes while k3s restarts. On ff-pi1 (a Pi, with a ~600M
   datastore) it returned `ServiceUnavailable` for around two minutes after
   `systemctl is-active k3s` already said `active`. That is normal — watch
   `journalctl -u k3s` for controllers starting rather than assuming a failure.
5. **Re-assert CoreDNS `replicas: 2`.**
6. Verify before going further:
   ```bash
   kubectl get nodes -o wide                       # all Ready, none SchedulingDisabled
   kubectl get deploy -n kube-system coredns       # 2/2
   kubectl get kustomizations -A                   # compare against the known-bad list
   kubectl get clusters.postgresql.cnpg.io -A      # all healthy
   ```
7. Patch the agent Plan's `version`; it upgrades one node at a time.

Note that `prod-defectdojo`, `prod-dependency-track`, `prod-github-usage-dashboard`,
`prod-quarry`, `prod-renovate` and `prod-security-integrations` were already failing before
the upgrade. Know your baseline or you will chase them.

## Rollback

Re-run the install script with the older `INSTALL_K3S_VERSION` **and** restore the
datastore snapshot. Restoring the binary alone is not enough once a newer API server has
written newer resource versions into the datastore.
