# Holmes acts on the cluster autonomously, bounded by admission policy

Status: **proposed**
Date: 2026-08-24

## Context

HolmesGPT runs on firefly today as an on-demand investigation API (`holmesgpt/holmesgpt-holmes`,
chart `holmes@0.33.0`, ClusterIP, operator disabled). It is read-only: `get`/`list`/`watch`
across resources, no write verbs, and it cannot read Secrets or `exec` into pods.

We want two things it cannot currently do:

1. **Act, not just report.** Most of the fleet's real incidents end in a restart, a pod deletion,
   or a forced Flux reconcile. A diagnostician that can only describe the fix still needs a human
   at 2am for a step that is mechanical.
2. **Be reachable from Nievah**, so a PR-driven agent can use cluster evidence and act on it,
   for an allowlisted set of repositories.

Nievah is triggered by pull-request webhooks, and pull-request content is attacker-controllable.
That was raised, weighed, and the decision was taken to run **both** paths autonomously with no
human in the loop. This ADR therefore does not rely on a human gate anywhere. The permission
ceiling is the only control, so it has to be drawn exactly.

Two facts about this cluster shape the design:

- **Flux reverts drift.** Anything patched on a Flux-managed object is reconciled away within the
  interval. That is a free undo button, and it means Holmes can restart things but cannot durably
  change config. That limit is desirable rather than unfortunate.
- **PodDisruptionBudget coverage is already good**, which an earlier draft of this ADR got
  wrong. 24 PDBs exist; the repo has a deliberate rule (`cleanup.md`) of writing them for our
  own >=2-replica workloads and leaving operator-generated ones alone. Of the 14 workloads
  running more than one replica, 11 are covered. So `create pods/eviction` usually does have a
  floor to respect, and it is a meaningfully safer verb than `delete pods`.

## Options considered

**A. Keep it read-only, humans act.** Safest and status quo. Rejected: it does not deliver the
autonomy asked for, and the actions in question are mechanical.

**B. Give Holmes a broad write role, rely on the agent behaving.** Rejected. "The model is
careful" is not a security boundary, and `create pods` alone is full cluster takeover: a pod can
mount any Secret and run privileged.

**C. Read-only on the PR path, autonomous on the alert path.** Recommended originally, because it
keeps attacker-controllable input away from the acting path. Rejected by the decision above.

**D. One narrow write grant, identical on both paths, constrained by ValidatingAdmissionPolicy.**
Chosen.

## Decision

Both trigger paths get the same ceiling, autonomously:

| Path | Trigger | Permission |
| --- | --- | --- |
| Alert-driven | Alertmanager → Holmes | No human, max-before-dangerous |
| PR-driven | Nievah → Holmes | No human, max-before-dangerous |

**Read** stays cluster-wide. **Write** applies everywhere EXCEPT `flux-system`, `kube-*`
(`kube-system`, `kube-public`, `kube-node-lease`), `database`, `database-oci`, `external-secrets`,
`cert-manager`, `kyverno` and `holmesgpt`. That is 36 of the cluster's 46 namespaces today.

**The exclusion is enforced by admission policy, not by RoleBindings.** An earlier draft of this
ADR said namespace-scoped RoleBindings and never a ClusterRole. That is wrong for a grant defined
as "everywhere except": 36 hand-maintained bindings drift, and a namespace created next month
silently gets nothing, which looks identical to a policy that stopped working. So the grant is one
ClusterRole plus one ClusterRoleBinding, and the same ValidatingAdmissionPolicy that constrains
*what* a request may contain also constrains *where* it may land.

That inverts the failure mode, and the inversion is the price of the decision: with RoleBindings a
broken control fails closed and Holmes loses access, whereas here a missing policy would fail open
into `flux-system`. Three things bound it. The binding sets `failurePolicy: Fail`, so a CEL
evaluation error denies rather than admits. Holmes has no write on admission policies, so it
cannot remove its own ceiling. And the policies are Flux-managed, so a deletion is reconciled back
within the interval, leaving a window rather than a permanent hole.

The write grant is exactly:

| Verb | Resource | Admission constraint | Why it is bounded |
| --- | --- | --- | --- |
| `delete` | `pods` | none | The controller recreates it. Self-healing by construction. |
| `create` | `pods/eviction` | none | Respects PDBs where they exist. See the PDB gap below. |
| `patch` | Deployment / StatefulSet / DaemonSet | **only** `kubectl.kubernetes.io/restartedAt` | A rolling restart, and nothing else. |
| `patch` | Flux Kustomization / HelmRelease | **only** `reconcile.fluxcd.io/requestedAt` | Reconcile now. Cannot suspend, which would silently stop reconciliation. |
| `delete` | `jobs` | none | A wedged Job; the CronJob recreates it. |
| `patch` | `replicasets/scale` | scale to `0` only | The wedged-rollout fix in `COMMON_MISTAKES` #15, which currently needs a human. |

Admission policy is the mechanism that makes this a decision rather than a hope. RBAC grants
`patch deployments` all-or-nothing; `ValidatingAdmissionPolicy` (GA, built in on the cluster's
v1.33.4) evaluates CEL against the request and permits only the annotation named above. No
webhook to keep alive, and no extra dependency.

### Never granted, at any tier

- **Reads that leak credentials:** `secrets`.
- **Execution in another workload's context:** `pods/exec`, `pods/attach`, `pods/portforward`.
- **Creation of any workload:** `create pods` and every workload kind. One created pod mounts any
  Secret and runs privileged.
- **Credential minting:** `serviceaccounts/token`.
- **RBAC:** `escalate`, `bind`, `impersonate`, and writes to roles or bindings.
- **Destruction:** `delete namespaces`, `delete pvc`, `delete pv`, node writes.
- **Its own guardrails**, which is the constraint most easily forgotten: no write on
  `validatingadmissionpolicies`, `validatingadmissionpolicybindings`, the webhook configurations,
  its own ServiceAccount or Role, or anything in `flux-system`. An agent that can edit its own
  ceiling has no ceiling.

### Controls on the PR path that do not require a human

- **Fork guard.** Pull requests from forks never reach the acting path, the same guard
  `.github/workflows/terragrunt.yml` already applies and describes as load-bearing.
- **Repository allowlist, reusing the existing control plane.** `magmamoose/admin`'s
  `.github/nievah.yml` already carries a deny-by-default `allowlist:` with glob patterns,
  last-write-wins overrides, and safe-fail semantics: a missing or invalid file denies every repo.
  The acting path is a new per-entry override alongside `autotriage` and `automerge`, defaulting
  to off, so a repo opts in exactly the way it opts into every other autonomous behaviour. No
  second list, no second parser, and the fail-closed behaviour is inherited rather than rebuilt.
- **The question is templated, never quoted.** Nievah composes the question from structured facts
  it derives itself (repository, namespace, workload name). Pull-request prose is never
  interpolated into it. This is the difference between a pull request *causing* an investigation
  and a pull request *composing* one.

### Separate identities

Each path gets its own ServiceAccount and token against the same Holmes deployment, so the audit
trail attributes every action to a path, and either can be revoked without the other.

## Consequences

**We accept.** Anyone who can land a pull request on an allowlisted repository can, indirectly and
within the ceiling above, cause pod deletions and restarts in non-excluded namespaces. The ceiling
is drawn so that the worst outcome is workload churn that heals itself, not data loss, credential
disclosure or privilege escalation.

**Not prevented, only observed.** RBAC has no rate limit. A runaway loop deleting pods is a
self-inflicted denial of service even though each action is individually self-healing. This needs
an alert on Holmes' own action rate and a hard cap in its agent loop, and it is monitored rather
than prevented.

**The `bash` toolset stays enabled, and this is an accepted risk rather than an oversight.** It
runs `builtin_allowlist: extended`, bounded by what is in the container rather than by the API
server, so it is the one path the ceiling above does not cover. The decision taken is that Holmes
and Nievah may use any tool within reason, on the grounds that a diagnostician which cannot run
diagnostic commands is not worth deploying. What bounds it instead is the container image, the
read-only Kubernetes credential the toolset inherits, and the NetworkPolicy: bash cannot exceed
the ServiceAccount it runs as. What it CAN do that RBAC does not describe is reach the network
from inside the cluster, so egress is the surface to watch, and an egress policy is the natural
next control if this ever needs tightening.

**Prerequisite, now met: a NetworkPolicy.** The Holmes API takes no credential of its own, so
reaching it IS the authorisation, and the `holmesgpt` namespace had no ingress policy. Every pod
in all 46 namespaces could call it, which would have made a write grant a grant to everything
running. A default-deny plus an allowlist for `nievah` and `observability` ships alongside this
ADR.

**Enforcement of that policy is UNVERIFIED.** Nothing in `ansible/` passes
`--disable-network-policy`, and seven NetworkPolicies already exist elsewhere in the cluster,
which together suggest k3s' embedded controller is active. Neither is proof. Confirm with a
throwaway namespace before relying on it, because an unenforced NetworkPolicy is indistinguishable
from a working one until someone tests it:

```bash
kubectl create ns np-probe
kubectl run probe -n np-probe --image=busybox:1.36 --restart=Never -- \
  wget -q -T3 -O- http://holmesgpt-holmes.holmesgpt.svc.cluster.local/
# expect a timeout. a 200 means the policy is not being enforced.
kubectl delete ns np-probe
```

**PDB gaps.** Three of the 14 multi-replica workloads lack one: `nievah/nievah-worker` (owned by
the nievah repo), `platform2/platform2-driver` (a HelmRelease, so a chart-values change), and
`general-system/cloudflared-tengen` (not managed from this repo). Worth closing, none blocking.

**Alertmanager is not deployed.** The alert-driven row of the table above has no trigger source on
this cluster today. The NetworkPolicy already admits the `observability` namespace so that
enabling it later is a deployment rather than a deployment plus a security change nobody
remembers, but the row is aspirational until then. The PR-driven row works now.

**Placement.** Holmes must work while the cluster is degraded, but it runs in the cluster it
diagnoses, on the `worker` nodeSelector, at one replica. Per `COMMON_MISTAKES` #22 that tier now
resolves to three nodes, two of them across a VPN. Where the diagnostician runs should be a
deliberate choice, not whatever the tier resolves to. A cluster that is fully down takes Holmes
and Nievah with it, and that is accepted.

**Reversal.** Delete the ClusterRoleBinding. The policies and the read-only role can stay; the
capability disappears with that one object. Per repository, clear the override in
`.github/nievah.yml`, which takes effect on the next fetch without a deploy.
