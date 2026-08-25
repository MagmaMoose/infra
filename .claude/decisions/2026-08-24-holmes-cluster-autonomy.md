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
- **There are zero PodDisruptionBudgets, cluster-wide.** `create pods/eviction` is therefore
  identical to `delete pods` today: there is no floor for an eviction to respect.

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

**Read** stays cluster-wide. **Write** is namespace-scoped via RoleBindings, never a ClusterRole,
and excludes `flux-system`, `kube-system`, `database`, `database-oci`, `external-secrets`,
`cert-manager`, `kyverno` and `holmesgpt`.

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
- **Repository allowlist.** Only allowlisted repositories reach the acting path.
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

**The `bash` toolset is outside all of this.** It runs with `builtin_allowlist: extended` and is
bounded by what is in the container, not by the API server. It must be audited before any write
verb is granted, and disabled on the acting path if that audit is not conclusive.

**Prerequisite: a NetworkPolicy.** There is none in the `holmesgpt` namespace, so every pod in the
cluster can already reach the API. Granting a write verb without fixing that grants it to
everything running.

**Recommended alongside: PodDisruptionBudgets.** With none defined, eviction buys nothing over
deletion. Adding PDBs to anything with more than one replica would let eviction refuse to remove
the last replica, which raises the safe ceiling for free.

**Placement.** Holmes must work while the cluster is degraded, but it runs in the cluster it
diagnoses, on the `worker` nodeSelector, at one replica. Per `COMMON_MISTAKES` #22 that tier now
resolves to three nodes, two of them across a VPN. Where the diagnostician runs should be a
deliberate choice, not whatever the tier resolves to. A cluster that is fully down takes Holmes
and Nievah with it, and that is accepted.

**Reversal.** Delete the RoleBindings. The ValidatingAdmissionPolicies and the read-only role can
stay; the capability disappears with the bindings alone.
