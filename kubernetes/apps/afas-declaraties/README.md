# afas-declaraties

Monthly AFAS InSite expense claims, automated: classify each day as office or
home from the calendar, ask for approval in Slack, then drive a headless browser
to file the claim.

Chart and image both come from the app's own public repo
(`CalebSargeant/afas-declaraties`); everything in this directory is the firefly
deploy config.

## Shape

| Object | Where |
|---|---|
| `HelmRepository` `ghcr-calebsargeant-charts` (flux-system) | `base/helmrepository.yaml` |
| `Namespace` `afas-declaraties` | `base/namespace.yaml` |
| CNPG `Database` `afas_declaraties` (in `database-oci`) | `prod/workload/database.yaml` |
| `ExternalSecret` `afas-declaraties-env` | `prod/workload/externalsecret.yaml` |
| `HelmRelease` | `prod/workload/helmrelease.yaml` |
| CNPG managed role `afas_declaraties` + its password Secret | `kubernetes/infrastructure/services/postgres-oci/base/` |

Workloads the chart renders: `slackd` (Deployment, 1 replica, no Service —
Slack Socket Mode dials out) and three CronJobs — `classify` nightly 23:30,
`digest` Fridays 16:00, `build` on the 28th at 06:00, all Europe/Amsterdam.

## Before this can reconcile

1. **Cut a release in the app repo.** Until `ghcr.io/calebsargeant/charts/afas-declaraties`
   exists the HelmRelease reports `no chart version found` and
   `prod-afas-declaraties` stays NotReady. That is expected, and nothing depends
   on it. Check the first published chart version against the semver range in
   `helmrelease.yaml` — see the note there about `0.0.1` vs `0.1.0`.
2. **Create the eight new OCI Vault entries** listed at the top of
   `prod/workload/externalsecret.yaml`. External Secrets resolves the list
   all-or-nothing, so one missing entry means no Secret at all; the
   `external-secrets.yml` workflow fails the PR before that can reach the
   cluster.
3. **Generate the database password URL-safe** (`openssl rand -hex 32`). It is
   interpolated into a DSN unencoded at the app end, so `@ : / ? # %` in the
   value produce a malformed connection string rather than an auth error.

## Things that will bite you

- **`DRY_RUN` is `"true"` and should stay that way** until a full cycle has been
  watched end to end. It gates the path that files a real expense claim.
- **`SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` must belong to the same Slack app.**
  Slack delivers an interaction to the app that posted the blocks, and a Socket
  Mode connection only receives its own app's interactions. Mismatched, the
  Approve/Reject buttons render and then do nothing — no error anywhere. The
  bot token here is the shared estate one, so verify with `auth.test` and
  `apps.connections.open` and compare `app_id` before the first live approval.
- **This repo is public.** The InSite hostname, the 1Password vault/item names
  and the Slack channel/approver ids are OCI Vault entries for that reason, not
  because they are cryptographic secrets. Never move one into `helmrelease.yaml`
  values "because it isn't really a secret".
- **The tier is arm64.** Image *and* the bundled Chromium must publish
  `linux/arm64`, or the pod pulls cleanly and exits immediately.
- **Never give the browser job a `backoffLimit` above 0.** A retry re-drives a
  corporate SSO login and risks locking the account out. The chart fixes this;
  do not override it here.
