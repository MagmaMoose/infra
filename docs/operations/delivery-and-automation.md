# Progressive Delivery, Renovate & Image Verification

Three `worker`-pinned, Flux-managed platform additions.

## Flagger — progressive delivery

`kubernetes/apps/flagger` deploys the Flux-native canary controller in
`flagger-system`. It uses **Traefik** (the k3s ingress) for traffic shifting and the
existing **kube-prometheus-stack** (`prometheus-operated.observability:9090`) for
canary metric analysis; Flagger's bundled Prometheus is disabled.

The controller does nothing until you add a `Canary` per app you want rolled out
progressively. Minimal Traefik example:

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: foo
  namespace: bar
spec:
  provider: traefik
  targetRef: { apiVersion: apps/v1, kind: Deployment, name: foo }
  service: { port: 80 }
  analysis:
    interval: 1m
    threshold: 5         # max failed checks before rollback
    maxWeight: 50
    stepWeight: 10
    metrics:
      - name: request-success-rate
        thresholdRange: { min: 99 }
        interval: 1m
```

A bad version never fully rolls out — it auto-aborts and reverts, with no human at
the dashboard. This is the golden-stack "failed-deploy firewall."

## Renovate — dependency automation

`kubernetes/apps/renovate` runs a self-hosted Renovate **CronJob** (every 6h) in
`automation`, autodiscovering repos under `CalebSargeant/*` and `MagmaMoose/*`.

It complements your existing GitHub **Dependabot** by covering what Dependabot
barely touches here: Flux `HelmRelease`/`HelmRepository` chart versions, Kubernetes
manifests, **Terraform**, Docker image tags, and GitHub Actions — which is most of
this repo.

- **Prerequisite**: `renovate-github-token` (a GitHub PAT with contents +
  pull-requests + workflows) in OCI Vault.

## OpenHands — Nievah's standby review harness

Nievah can move a failed Claude Code review onto the OpenHands/DeepSeek harness. Both
deployments read the same `openhands-session-api-key` from OCI Vault; OpenHands must inject it
as `OH_SESSION_API_KEYS_0`, the agent-canvas V1 public-proxy key. Using only the legacy
`SESSION_API_KEY` makes agent-canvas generate a different key and rejects Nievah with HTTP 401.
The value stays in Vault and is delivered through the `openhands` ExternalSecret — never add it
to a manifest or ConfigMap.

## Kyverno image-signature verification (SLSA scaffold)

`kubernetes/apps/kyverno-policies` adds a Kyverno `ClusterPolicy` that **keyless**
cosign-verifies `ghcr.io/calebsargeant/*` images against the GitHub Actions OIDC
identity (via the already-installed Kyverno).

It ships **Audit + `required: false`** on purpose — it **reports only, never blocks**,
and unsigned images still pass. Flip to `required: true` + `validationFailureAction:
Enforce` once you've confirmed Diatreme cosign-signs release images and the keyless
identity (issuer/subject) in the policy matches the signing workflow.
