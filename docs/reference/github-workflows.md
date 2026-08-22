# GitHub Actions workflows

<!-- sources: .github/workflows -->

Ten workflows live in `.github/workflows`. Four of them are guards that fail a pull request
when a specific bug class reappears, and each guard exists because that bug class already
caused an outage.

| Workflow | File | Triggers | What it does |
| --- | --- | --- | --- |
| Terragrunt | `terragrunt.yml` | PR and push on `terraform/**`, `0 5 * * 1-5`, manual | Plans and applies Terraform. See [Terraform delivery](../operations/terraform-delivery.md). |
| Placement | `placement.yml` | PR and push on `kubernetes/**`, manual | Fails a PR when a `placement.sargeant.co` label can't reach a pod template. |
| External Secrets | `external-secrets.yml` | PR and push on `kubernetes/**`, `17 6 * * *`, manual | Checks every `ExternalSecret` remoteRef against the OCI Vault the `oci-vault` ClusterSecretStore reads. |
| Security | `security.yml` | pull request | The org Chargate gate, MegaLinter-backed, gating on net-new findings in the PR diff. |
| Release | `release.yml` | PR, push to `main`, manual | The org Diatreme release template: versioning, GitHub Release, and image builds. |
| Build and Push Multi-Arch Images to GHCR | `docker-publish.yml` | push to `main`, `*-v*` tags, PRs touching `dockerfiles/**` | Builds the four container images in `dockerfiles/`. |
| Build & Deploy Docs | `docs.yml` | **manual only** | `mkdocs build --strict`, then deploys to GitHub Pages. |
| FluxCD Deployment Tracker | `flux-deployment-tracker.yml` | `repository_dispatch` type `reconciliation` | Records a GitHub deployment when Flux reconciles. |
| Server Update Notifications | `server-update-notifications.yml` | `repository_dispatch` type `server-update`, manual | Relays host patching results. |
| Terrateam | `terrateam.yml` | manual, driven by the Terrateam backend | Not part of the normal Terraform path. |

## The guards

### Placement

kustomize `labels:` applies to every resource a kustomization emits, while the Kyverno
placement policies match only `Deployment`, `StatefulSet`, `DaemonSet` and `CronJob`. Label
a kustomization whose workload is a `HelmRelease` and the label stops at the HelmRelease:
the chart's Deployment never sees it, so nothing is pinned or prioritised.

Nothing in the cluster reports this. The policies' own typo guards don't match HelmRelease
either, so the workload is silently unplaced and it looks like it worked. This has shipped
more than once, which is why the check is a required status rather than advice.

### External Secrets

Compares every `ExternalSecret` `remoteRef` against the OCI Vault and fails the pull request
when a referenced secret doesn't exist or isn't `ACTIVE`. It parses `HelmRelease`
`spec.values.externalSecret.data` maps too, because one of the two outages that motivated it
wasn't in a `kind: ExternalSecret` document at all.

The other outage was a rename: a namespace was renamed, its `remoteRef`s were updated to
match, the vault entries weren't, all eight refs 404'd, and the namespace was down for days.

The daily `17 6 * * *` run catches drift that happens in the vault rather than in Git.

### Guards re-run on themselves

`placement.yml` and `external-secrets.yml` both include their own path and their action's
path in `paths:`. A change to a guard has to re-run the guard, or the first proof it still
works arrives on `main`.

## Runners

Terraform jobs run on `firefly-amd64`, an actions-runner-controller scale set name. The docs
build runs on `ubuntu-latest` on purpose: this repository is public, so hosted minutes are
unmetered, and self-hosting would only put the job behind the private repos in the
self-hosted queue.

## Container images

`docker-publish.yml` builds four images from `dockerfiles/`:

| Image | Namespace | Platforms | Tag prefix |
| --- | --- | --- | --- |
| `n8n` | `calebsargeant` | `linux/amd64,linux/arm64` | `n8n-v` |
| `openfortivpn` | `calebsargeant` | `linux/amd64,linux/arm64` | `openfortivpn-v` |
| `atlantis-firefly` | `calebsargeant` | `linux/amd64,linux/arm64` | `atlantis-firefly-v` |
| `mem0-server` | `magmamoose` | `linux/arm64` only | `mem0-server-v` |

`mem0-server` is arm64 only because its base image publishes a manifest index with
`linux/arm64` and nothing else, so an amd64 leg fails the build outright. Its Deployment is
pinned to the arm64 node tier to match.

!!! warning "`dockerfiles/wordpress-postgres` is not built"
    It's been in the tree since January 2026 and appears in no matrix entry, so no image is
    ever published from it.

## The docs site does not auto-deploy

`docs.yml` has its `push` trigger commented out:

```yaml
on:
#  push:
#    branches: [main]
  workflow_dispatch:
```

Merging a docs change builds nothing and publishes nothing. Run the workflow by hand:

```bash
gh workflow run "Build & Deploy Docs"
```

To check the site builds before you push:

```bash
pip install -r requirements-docs.txt
mkdocs build --strict
```
