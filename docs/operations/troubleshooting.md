# Troubleshooting

<!-- sources: .claude/COMMON_MISTAKES.md, kubernetes, ansible -->

Symptom, cause, fix. Every error string below is quoted as it appears, so you can search for
it. Start with the first section: it catches the failure mode that looks like everything else.

## "My change didn't deploy" and every pod is Running

Check for a stalled Flux dependency before you debug anything else:

```bash
kubectl get kustomization -A | awk '$4=="False"'
```

A Kustomization that can't become ready blocks every Kustomization that `dependsOn` it. The
apps themselves keep serving and every pod stays `Running`, so from the application's side a
stalled dependency looks exactly like a config bug.

This has cost 16 hours once already: one unhealthy Postgres replica kept the shared cluster
out of a healthy state, and 14 Kustomizations that depend on it silently stopped receiving
updates. The presenting symptom was a queue that wasn't draining, in a different namespace,
with nothing pointing at Postgres.

Force a reconcile once the dependency is healthy:

```bash
flux reconcile kustomization <name> -n flux-system
```

## A pod is Pending with FailedScheduling

```text
0/4 nodes are available: Insufficient cpu
```

```text
0/4 nodes are available: Insufficient memory
```

Requests are reserved even when the workload isn't using them. Confirm what the node has
actually committed:

```bash
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
```

Two traps here:

- **A restart can strand an amd64-pinned workload.** With `strategy: Recreate` the old pod is
  deleted first, and queued pods take the freed CPU before the replacement is scheduled. Fix
  the CPU *request*, not the limit.
- **A rollout can deadlock on a full node.** `maxUnavailable: 25%` of 2 replicas rounds to
  **0**, so the controller won't free an old pod until the new one is Ready, while the new
  pod can't schedule until that memory is freed. The Deployment still reports `ready=2`, so
  it looks healthy. Break it by scaling the old ReplicaSet to zero, not by deleting the pod,
  which its ReplicaSet just recreates:

```bash
kubectl scale rs <old-rs> --replicas=0 -n <namespace>
```

!!! note "Raising a limit is free, raising a request is not"
    Limits aren't scheduler-reserved. On a node that's already at 99% memory requested you
    often can't raise the request, but you can raise the limit. Keep the request honest for
    scheduling and give the limit headroom for spikes.

## A container is OOMKilled and there are no logs

```text
Last State: Terminated
Reason: OOMKilled
Exit Code: 137
```

A container that dies before writing anything produces no logs at all. Only
`lastState.terminated` names the cause:

```bash
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState.terminated}'
```

The usual cause is a memory limit copied from the wrong column when inlining values that
used to come from a resource profile: the profile's *request* figure carried into the *limit*
line. Measure the real working set:

```bash
kubectl exec <pod> -n <ns> -- cat /sys/fs/cgroup/memory.current
```

A limit within about 10% of measured use is a deferred OOM, not a right-sizing. See
[Resource profiles](../reference/resource-profiles.md).

## A container crash-loops only on the Raspberry Pi

```text
<jemalloc>: Unsupported system page size
```

```text
errno=12 Cannot allocate memory
```

The Pi 5 can boot a 16KB-page kernel. Anything bundling a jemalloc built for 4KB pages
aborts at startup, every allocation fails, and the process exits 1 immediately.

The tell is one node failing while its identical peers are fine. Check the page size before
anything else:

```bash
getconf PAGESIZE
```

`16384` means this is your problem. Upgrading the image doesn't help: several major versions
fail identically. The fix is `kernel=kernel8.img` in `/boot/firmware/config.txt`, the stock
ARM64 4KB kernel from the same firmware package, plus a reboot. Use the playbook rather than
editing by hand:

```bash
cd ansible && ansible-playbook -i hosts.yaml firefly-pi-page-size.yaml --check
```

!!! warning "There is no fallback for a bad config.txt"
    The firmware has no recovery path. A broken `config.txt` means physically retrieving the
    machine. The playbook backs the file up and asserts the surviving entries first. Run it
    with `--check` before you run it for real.

## The API server times out on ordinary requests

```text
http: Handler timeout
```

Nodes flap `NodeNotReady` and pods get evicted, but request load is low and the node's own
workloads add up to almost nothing.

Check whether the control plane is spending its CPU on garbage collection rather than work.
`GOMEMLIMIT` set at or below the live heap leaves the runtime no garbage runway: a cycle
finishes and the next is immediately due, mark assists stall the goroutines serving requests,
and the API server misses its own lease renewals.

`GOMEMLIMIT` has to sit **above** the live heap with real runway. Below the live set the
runtime can't reach the target no matter how hard it collects, so it collects forever. Raise
`system_reserved` in lockstep, or the scheduler hands out memory the control plane already
owns. The values live in `ansible/firefly-control-plane-resources.yaml`.

## A node selector or placement label does nothing

The workload runs, on the wrong node, and nothing reports an error.

```bash
kubectl get deploy <name> -n <ns> -o jsonpath='{.spec.template.spec.nodeSelector}'
```

An empty result, or the bare chart default, means the pin never applied. Three causes:

- **The label was applied to a `HelmRelease`.** kustomize `labels:` reaches every resource a
  kustomization emits, but the placement policies match only `Deployment`, `StatefulSet`,
  `DaemonSet` and `CronJob`. The chart's Deployment never sees it. The
  [Placement workflow](../reference/github-workflows.md#placement) fails a pull request that
  does this.
- **A chart's `global.nodeSelector` lost to a per-component default.** Many charts set a
  non-empty per-component `nodeSelector`, and non-global values override the global one. Set
  it per component, and carry the chart's own `kubernetes.io/os: linux` default forward,
  because replacing the map replaces it wholesale.
- **A pod-level field was set per container.** If a chart renders two containers in one pod,
  there's no per-container `nodeSelector` key to set, and the Deployment renders with none.

Verify by rendering, not by reading the values file:

```bash
helm template <release> <chart> -f <values-file> | grep -A3 nodeSelector
```

## A kustomize patch silently stopped applying

`kustomize build` neither warns nor errors when a `patches:` target matches nothing. It just
renders the unpatched manifest.

Two ways to orphan a patch:

- **Changing the workload's kind.** Every patch whose `target.kind` still names the old kind
  is now dead.
- **The other repo renamed the workload.** `target.name` is the *Deployment* name;
  `containers[].name` is the *container* name. They differ more often than you'd think, and a
  cross-repo rename has no CI that links them.

After any kind or name change, re-render and diff, and re-check the live Deployments:

```bash
kustomize build kubernetes/clusters/firefly | grep -c 'kind: Deployment'
kubectl get deploy -n <ns>
```

For anything split across two instances of a backing service, compare the two halves
directly rather than reading either one's status. A queue that's non-empty from one pod and
empty from the other isn't a race, it's two different databases.

## A tier selector matches more nodes than you think

A tier that names a role rather than a location silently widens the moment you add a node.
Check the set a selector actually resolves to, never the comment next to it:

```bash
kubectl get nodes -l <the-selector>
```

This matters most for node-local storage. When a pod starts where a `hostPath` directory
doesn't exist, the kubelet **creates it empty**, which is indistinguishable from a first run:
the app serves an unconfigured skeleton while its real database sits on another node.

## A CNPG replica never catches up

```text
requested starting point C7/3F000000 on timeline 23 is not in this server's history
```

```text
record with incorrect prev-link
```

The replica has diverged and is in a WAL replay loop it can't exit. Don't wait it out.
Discard it and let CNPG rebuild from the primary:

!!! warning "This deletes the replica's volume"
    Run it against the diverged replica only. Confirm which instance is primary first with
    `kubectl get cluster -n database`.

```bash
kubectl delete pvc -n database postgres-N --wait=false
kubectl delete pod -n database postgres-N
```

CNPG drops the instance and bootstraps a fresh one with `pg_basebackup`.

## Flux reverts a live patch within ten minutes

Anything you patch directly on a Flux-managed object gets reconciled away. Suspend first:

```bash
flux suspend kustomization <name> -n flux-system
```

```bash
flux resume kustomization <name> -n flux-system
```

## A push to main didn't publish the docs

The docs workflow's `push` trigger is commented out. See
[GitHub Actions workflows](../reference/github-workflows.md#the-docs-site-does-not-auto-deploy).

## Terraform: a shared file changed and nothing was planned

Atlantis decides what to plan from each project's own subtree, so edits to `terraform/root.hcl`,
a `region.hcl`, or `terraform/modules/**` don't trigger the leaves they affect. The Terragrunt
workflow replans every leaf in that case. See [Terraform delivery](terraform-delivery.md).

If you're still driving a plan through Atlantis, trigger each affected leaf by hand.
