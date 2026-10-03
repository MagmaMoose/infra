# Progressive Delivery, Renovate & Image Verification

Three `worker`-pinned, Flux-managed platform additions.

## Flagger: progressive delivery

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

A bad version never fully rolls out: it auto-aborts and reverts, with no human at
the dashboard. This is the golden-stack "failed-deploy firewall."

## Renovate: dependency automation

`kubernetes/apps/renovate` runs a self-hosted Renovate **CronJob** (every 6h) in
`automation`, autodiscovering repos under `CalebSargeant/*` and `MagmaMoose/*`.

It complements your existing GitHub **Dependabot** by covering what Dependabot
barely touches here: Flux `HelmRelease`/`HelmRepository` chart versions, Kubernetes
manifests, **Terraform**, Docker image tags, and GitHub Actions (which is most of
this repo).

- **Prerequisite**: `renovate-github-token` (a GitHub PAT with contents +
  pull-requests + workflows) in OCI Vault.

## Flux image updates

`flux-system/media` is the shared `ImageUpdateAutomation` for tags managed in
this repository, including the GitHub Contributions deployment. Its source is
the `infra-image-automation` GitRepository. This source must use the canonical
current repository URL (`https://github.com/MagmaMoose/infra`) and the
`github-app-magmamoose` credential, matching Nievah's working automation.
GitHub App tokens are scoped to one installation, so the legacy
`buxfer-sync-github-app` credential cannot write MagmaMoose repositories. Use
`fluxcdbot@users.noreply.github.com` as the generated commit author. An
installation mismatch makes the ImageUpdateAutomation fail with a Git push
authorization error and leaves all tag updates uncommitted.

## OpenHands: Nievah's standby review harness

Nievah can move a failed Claude Code review onto the OpenHands/DeepSeek harness. Both
deployments read the same `openhands-session-api-key` from OCI Vault; OpenHands must inject it
as `OH_SESSION_API_KEYS_0`, the agent-canvas V1 public-proxy key. Using only the legacy
`SESSION_API_KEY` makes agent-canvas generate a different key and rejects Nievah with HTTP 401.
The value stays in Vault and is delivered through the `openhands` ExternalSecret. Never add it
to a manifest or ConfigMap. The Deployment strips leading/trailing whitespace before starting
agent-canvas because Nievah must trim an HTTP header but agent-canvas otherwise compares the
raw environment string. Bump its non-secret `session-api-key-revision` pod annotation through
GitOps after every Vault rotation; secret-backed environment variables do not update inside a
running pod.

## Hermes: the owner's morning brief

Hermes runs one git-managed cron job, `daily-brief`, at 07:30 Europe/Amsterdam, seeded by
`kubernetes/apps/hermes/base/files/seed_cron.py` from `files/daily-brief.md`. It is the owner's
single morning standup, delivered to the Slack home channel, and it has to fit on one phone
screen:

- **Needs you**: at most three bullets of what is new since the previous brief, from Nievah's
  `needs_you` MCP tool (broken plumbing, stuck pull requests, incidents needing a person, plans
  waiting for approval), then one `Still waiting: N (oldest Xd)` line for everything already
  reported.
- **Overnight**: one line of non-zero counts (shipped and auto-fixed from `recent_activity`,
  failed jobs from `needs_you`).
- **Cluster**: one line, only while critical alerts are firing.

When nothing is new it answers `[SILENT]` and Hermes delivers nothing.

"New" needs to know when the previous brief ran. The job's pre-run script,
`files/daily_brief_context.py` (copied to `$HERMES_HOME/scripts`, the only place Hermes runs a
cron script from), prints `previous_brief_at: <time>` from the newest good run's output file,
and the brief passes it to `needs_you` as `new_since`. Do not replace it with `context_from`
pointing at the job's own id: Hermes injects only the first 8,000 characters of that output
file, which holds the whole prompt before the answer, so a job reading itself nests its prompts
and loses the previous answer from the second run on.

`cron.wrap_response: false` in the ConfigMap stops Hermes framing every cron message with a
four-line "Cronjob Response" header and footer. Hermes converts Markdown to Slack formatting, so
the prompt asks for `**bold**` and `[label](url)` links.

## Kyverno image-signature verification (SLSA scaffold)

`kubernetes/apps/kyverno-policies` adds a Kyverno `ClusterPolicy` that **keyless**
cosign-verifies `ghcr.io/calebsargeant/*` images against the GitHub Actions OIDC
identity (via the already-installed Kyverno).

It ships **Audit + `required: false`** on purpose. It **reports only, never blocks**,
and unsigned images still pass. Flip to `required: true` + `validationFailureAction:
Enforce` once you've confirmed Diatreme cosign-signs release images and the keyless
identity (issuer/subject) in the policy matches the signing workflow.
