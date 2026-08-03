# Atlantis for Terragrunt/Terraform Pull Request Automation

This directory contains the Kubernetes manifests for deploying Atlantis on the firefly cluster. Auth uses a **GitHub App** with credentials sourced from **OCI Vault** via `ExternalSecret`.

## What's included

| File | Purpose |
| --- | --- |
| `deployment.yaml` | Atlantis server, mounts the App PEM at `/etc/atlantis/github-app/private-key.pem` |
| `service.yaml` | ClusterIP service |
| `ingress.yaml` | Public ingress at `atlantis.sargeant.co` |
| `pv.yaml` + `pvc.yaml` | Persistent storage for `/atlantis-data` |
| `configmap.yaml` | Server-side Atlantis config (Terragrunt workflow, repo allow-list) |
| `serviceaccount.yaml` | RBAC |
| `externalsecret.yaml` | Pulls App ID + PEM + webhook secret from OCI Vault into `Secret/atlantis` |
| `secret-aws.yaml.template`, `secret-azure.yaml.template` | Optional SOPS-encrypted cloud-provider creds (AWS access keys / Azure SP) — orthogonal to GitHub auth |

## Initial setup (one-time)

### 1. Create the GitHub App

Browser-only (gh CLI doesn't support App creation). Go to https://github.com/settings/apps/new and fill in:

| Field | Value |
| --- | --- |
| GitHub App name | `atlantis-architect` (this repo's actual App; any unique name works if you're forking) |
| Homepage URL | `https://atlantis.sargeant.co` |
| Webhook URL | `https://atlantis.sargeant.co/events` |
| Webhook secret | Generate with `openssl rand -hex 32` — save this |
| Repository permissions | Administration: Read · Checks: R/W · Contents: R/W · Issues: R/W · Pull requests: R/W · Commit statuses: R/W (Metadata: auto-checked Read) |
| Subscribe to events | Issue comment, Pull request, Pull request review, Pull request review comment, Push |
| Where can this GitHub App be installed | Only on this account |

Click **Create GitHub App**.

### 2. Install the App on your repo(s)

App settings → **Install App** → next to your account → **Only select repositories** → pick `CalebSargeant/infra` (and any other Terraform-managed repos) → **Install**.

### 3. Generate the App's private key

App settings → note the **App ID** (a number) → **Private keys** → **Generate a private key** → downloads `atlantis-architect.YYYY-MM-DD.private-key.pem` (or whatever you named the App).

### 4. Store the 3 values in OCI Vault

| OCI Vault secret name | Value |
| --- | --- |
| `atlantis-github-app-id` | App ID number (as a string) |
| `atlantis-github-app-private-key` | Full content of the `.pem` file (multi-line, including `-----BEGIN/END RSA PRIVATE KEY-----` lines) |
| `atlantis-github-webhook-secret` | The webhook secret you generated in step 1 |

The same vault/`ClusterSecretStore` is already wired (see `kubernetes/_base/core/external-dns-cloudflare/externalsecret.yaml`, `kubernetes/_base/core/cloudflared/externalsecret.yaml` for examples).

### 5. Deploy

`externalsecret.yaml` is already part of the Kustomization. After Flux reconciles, `Secret/atlantis` is materialized in `automation` namespace with keys `app-id`, `app-key-pem`, `webhook-secret`. The Deployment mounts the PEM and starts the server with App auth.

## GCP service account (required for any terragrunt project with GCS state)

All GCP terragrunt projects in this repo use a GCS backend (`sargeant-prod-terraform-state`) and the google provider impersonates `deployer@magmamoose-terraform.iam.gserviceaccount.com`. Atlantis needs a service-account key to (a) read/write the state bucket and (b) mint impersonation tokens for the deployer SA. Without this, terragrunt fails at dependency resolution with `Backend initialization required` → cascading `Unknown variable: dependency` errors.

> **Note:** The legacy `gcp-prod-project` Atlantis project (defined in `atlantis.yaml`) uses a different state bucket (`terraform-state-firefly`) via its own Terragrunt include chain. Cloudflare-only leaves do not use the google provider at all and therefore do not need this GCP SA key. The `atlantis@magmamoose-terraform.iam.gserviceaccount.com` SA is only required for projects that use GCS state and/or the google provider.

Atlantis runs as the dedicated **`atlantis@magmamoose-terraform.iam.gserviceaccount.com`** SA with least-privilege bindings:

- `roles/storage.objectAdmin` on `gs://sargeant-prod-terraform-state` — the GCS backend uses this key directly (the backend config carries no impersonation).
- `roles/iam.serviceAccountTokenCreator` on `deployer@magmamoose-terraform` — lets the google provider impersonate `deployer@` for resource ops.

Its JSON key lives in OCI Vault as `atlantis-gcp-sa-key`; `externalsecret-gcp.yaml` materializes it into `Secret/atlantis-gcp`, the deployment mounts it at `/etc/atlantis/gcp/key.json`, and `GOOGLE_APPLICATION_CREDENTIALS` points there.

> **Org-policy gotcha for a rebuild.** The `magmamoose.com` org enforces `iam.disableServiceAccountKeyCreation` (Google's secure-by-default policy), so `gcloud iam service-accounts keys create` is blocked unless a project-scoped policy override turns that constraint off for `magmamoose-terraform`. Impersonation also needs `iamcredentials.googleapis.com` enabled on the project. Both are already in place.

### Rotating the key

```bash
SA=atlantis@magmamoose-terraform.iam.gserviceaccount.com
SECRET=ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aa4xoor56xht5nfiwmlxp4sthoihyaedfvafummky4v4xa

# 1. Mint a fresh key (needs the org-policy override noted above).
gcloud iam service-accounts keys create /tmp/atlantis-sa-key.json --iam-account "$SA"

# 2. Push it to OCI Vault as a new version of the existing secret.
oci vault secret update-base64 --secret-id "$SECRET" \
  --secret-content-content "$(base64 < /tmp/atlantis-sa-key.json | tr -d '\n')" \
  --region eu-amsterdam-1 --force

# 3. Resync ESO, then restart Atlantis to pick up the new key file.
kubectl -n automation annotate externalsecret atlantis-gcp force-sync="$(date +%s)" --overwrite
kubectl -n automation rollout restart deployment/atlantis

rm -f /tmp/atlantis-sa-key.json   # don't leave the key on disk
```

The OCI Vault secret already exists, so rotation uses `update-base64`; the original secret was created with `create-base64` (which additionally needs `--compartment-id`/`--vault-id`/`--key-id`). Afterwards revoke the superseded key with `gcloud iam service-accounts keys delete <KEY_ID> --iam-account "$SA"`.

## Optional cloud-provider credentials

For Atlantis to actually drive Terraform that needs AWS / Azure / etc., create the optional secrets:

```bash
cp secret-aws.yaml.template secret-aws.yaml
# Edit secret-aws.yaml — fill in your credentials
sops -e secret-aws.yaml > secret-aws.enc.yaml
rm secret-aws.yaml

# Then add `- secret-aws.enc.yaml` to kustomization.yaml's resources
```

These map to env vars `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ARM_CLIENT_ID`, etc. — they're independent of the GitHub App auth above.

## Supported environments

- AWS (via AWS credentials)
- Azure (via Azure service principal)
- GCP (via existing service account)
- OCI (via existing configuration)
- Cloudflare (via existing configuration)

## Usage

Once deployed, Atlantis will:

1. Run `terraform plan` (or `terragrunt plan`) when a PR with infrastructure changes is opened/updated
2. Post the plan output as a PR comment
3. Apply with `atlantis apply` (after PR approval, depending on workflow)

See [`docs/guides/atlantis-setup.md`](../../../../../docs/guides/atlantis-setup.md) for detailed setup and usage instructions.

## Why GitHub App over PAT

- Per-installation, short-lived tokens (auto-rotated by Atlantis using the PEM to mint a fresh JWT) vs static PAT
- Granular per-repo permissions (no need for a broad `repo` scope on a user account)
- Not tied to any user — survives team-member changes
- Better audit trail in GitHub
