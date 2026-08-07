# Atlantis Setup Guide

This guide covers the setup and configuration of [Atlantis](https://www.runatlantis.io/) for automated Terraform / Terragrunt pull request workflows on the firefly Kubernetes cluster.

The deployment uses **GitHub App authentication** with credentials sourced from **OCI Vault** via an `ExternalSecret`. The legacy Personal Access Token (PAT) flow is no longer supported.

## What is Atlantis?

Atlantis is a server that wraps `terraform` / `terragrunt` and exposes them through GitHub pull requests:

- When a PR is opened or updated, Atlantis runs `terragrunt plan` and posts the output as a PR comment.
- A comment like `atlantis apply` (after PR review) runs `terragrunt apply` against the saved plan.
- Plans are locked per project: a second PR touching the same paths queues behind the first.

## Architecture

| Component | Where | Notes |
| --- | --- | --- |
| Atlantis server | Deployment in `automation` namespace, firefly k3s cluster | One replica, runs as `100:1000` |
| Persistent storage | PVC `atlantis`, 10Gi, `local-path` storage class | Holds working dirs, plan files, locks |
| Ingress | `https://atlantis.sargeant.co` via Traefik + Cloudflare Tunnel | Webhook receiver |
| Auth | GitHub App `atlantis-architect` (App ID `3765954`) | Installed on `CalebSargeant/infra` |
| Secret source | OCI Vault → `ExternalSecret` → K8s `Secret/atlantis` | Three keys (see below) |

### Required OCI Vault keys

| OCI Vault secret name | Value |
| --- | --- |
| `atlantis-github-app-id` | The numeric App ID (e.g. `3765954`) |
| `atlantis-github-app-private-key` | Full content of the App's `.pem` file, with `-----BEGIN/END RSA PRIVATE KEY-----` lines |
| `atlantis-github-webhook-secret` | The webhook secret configured on the App |

`ExternalSecret/atlantis` (in `kubernetes/apps/atlantis/base/atlantis/externalsecret.yaml`) pulls these into `Secret/atlantis` in the `automation` namespace with keys `app-id`, `app-key-pem`, and `webhook-secret`.

## Initial Setup (one-time)

### 1. Create the GitHub App

In a browser (GitHub CLI doesn't support App creation), go to https://github.com/settings/apps/new (or `https://github.com/organizations/<org>/settings/apps/new` for an org-owned App):

| Field | Value |
| --- | --- |
| GitHub App name | `atlantis-architect` or any unique name |
| Homepage URL | `https://atlantis.sargeant.co` |
| Webhook URL | `https://atlantis.sargeant.co/events` |
| Webhook secret | Generate with `openssl rand -hex 32` — save it for OCI Vault |
| Where can this GitHub App be installed? | **Any account** (required if you want to install it on accounts other than the App's owner) |

**Repository permissions:**

| Permission | Level |
| --- | --- |
| Administration | Read |
| Checks | Read & Write |
| Contents | Read & Write |
| Issues | Read & Write |
| Metadata | Read (auto-selected) |
| Pull requests | Read & Write |
| Commit statuses | Read & Write |

**Subscribe to events:** Issue comment, Pull request, Pull request review, Pull request review comment, Push.

Click **Create GitHub App**, then on the App settings page click **Generate a private key** and save the downloaded `.pem` file.

### 2. Install the App on your repository

App settings → **Install App** → next to your account → **Only select repositories** → pick `CalebSargeant/infra` (and any other Terraform-managed repos) → **Install**.

### 3. Populate OCI Vault

Three values: App ID, the PEM file content, and the webhook secret you generated.

Either via the OCI console (https://cloud.oracle.com/security/kms/vaults → `vault-prod` → Secrets → Create), or via `oci` CLI:

```bash
VAULT_ID=ocid1.vault.oc1.eu-amsterdam-1.fruyd6i7aagf4.abqw2ljrzcituk5pndpbgsvhtkgenvf2ae7xnlbctmskmcfj2gw6xsjhbgfq
COMPARTMENT_ID=ocid1.tenancy.oc1..aaaaaaaaq7zpfzcaj4amfz7xwv33rlsopwd4m2ydhgjdidoan67vry5ejlsq
KEY_ID=ocid1.key.oc1.eu-amsterdam-1.fruyd6i7aagf4.abqw2ljr2tquiix4j3greeqmtg3hxutkve2u5vrhk5umbz2w4drizdoqy3ca

push() {
  oci vault secret create-base64 \
    --compartment-id "$COMPARTMENT_ID" --vault-id "$VAULT_ID" --key-id "$KEY_ID" \
    --secret-name "$1" \
    --secret-content-content "$(printf '%s' "$2" | base64 | tr -d '\n')"
}

# This guide is firefly-specific: the App ID below is the actual App
# (3765954, atlantis-architect). Substitute your own value if you're
# forking this for a different cluster/App.
#
# The webhook secret IS genuinely secret — paste the value you saved
# in step 1 when creating the App. Do NOT regenerate it here; it
# must match what GitHub signs requests with.
push atlantis-github-app-id "3765954"
push atlantis-github-webhook-secret "<THE_VALUE_FROM_STEP_1>"

# PEM: push directly from the file (do NOT round-trip through a shell variable —
# it picks up surrounding quotes which break PEM parsing).
B64=$(base64 -i ~/Downloads/atlantis-architect.YYYY-MM-DD.private-key.pem | tr -d '\n')
oci vault secret create-base64 \
  --compartment-id "$COMPARTMENT_ID" --vault-id "$VAULT_ID" --key-id "$KEY_ID" \
  --secret-name atlantis-github-app-private-key \
  --secret-content-content "$B64"
```

Flux's `ExternalSecret` reconciles within 1h, or force-sync immediately:

```bash
kubectl annotate externalsecret atlantis -n automation \
  force-sync="$(date +%s)" --overwrite
```

### 4. Verify

```bash
# ExternalSecret synced?
kubectl get externalsecret atlantis -n automation
# READY=True, STATUS=SecretSynced

# Secret materialized with all three keys?
kubectl get secret atlantis -n automation -o jsonpath='{.data}' | jq 'keys'
# Expect: ["app-id", "app-key-pem", "webhook-secret"]

# Atlantis pod Ready?
kubectl get pods -n automation -l app=atlantis
# atlantis-xxxx 1/1 Running

# Logs free of auth errors?
kubectl logs -n automation -l app=atlantis --tail=20
# Expect: "Atlantis started - listening on port 4141"
```

## Optional Cloud-Provider Credentials

Atlantis also needs credentials to talk to whichever cloud(s) your Terragrunt code targets. These are independent of the GitHub App auth above.

Templates exist at the **active** Atlantis path (the one `prod-atlantis` Flux Kustomization reconciles):

- `kubernetes/apps/atlantis/base/atlantis/secret-aws.yaml.template`
- `kubernetes/apps/atlantis/base/atlantis/secret-azure.yaml.template`

(The same templates also still exist under `kubernetes/_base/automation/atlantis/` from before the Phase 2 migration — those are inert. Edit and encrypt in `kubernetes/apps/atlantis/base/atlantis/` only.)

For each cloud:

```bash
cd kubernetes/apps/atlantis/base/atlantis
cp secret-aws.yaml.template secret-aws.yaml
# fill in the values
sops -e secret-aws.yaml > secret-aws.enc.yaml
rm secret-aws.yaml
# uncomment `- secret-aws.enc.yaml` in kustomization.yaml
```

These map to env vars `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ARM_CLIENT_ID`, etc.

GCP, OCI, and Cloudflare credentials are provided by the existing platform (1Password Connect / OCI Vault / configmaps) — no extra secret needed.

## Daily Usage

### 1. Open a PR with Terragrunt / Terraform changes

Atlantis sees the webhook, runs `terragrunt plan` against the changed dirs, posts the plan as a PR comment.

### 2. Review the plan

The comment contains the plan diff. If it looks wrong, push more commits — autoplan re-runs.

### 3. Apply

After PR approval, comment `atlantis apply` on the PR. Atlantis re-acquires the lock, runs `terragrunt apply` against the previously saved plan, and posts the result.

### 4. Merge

After apply succeeds, merge the PR. Atlantis releases the project lock.

## Common Commands

| Comment | Action |
| --- | --- |
| `atlantis plan` | Re-run plan on the current commit |
| `atlantis apply` | Apply the saved plan |
| `atlantis unlock` | Release locks for the current PR (use when discarding a PR) |
| `atlantis help` | Print the full command reference |

## Rotating the GitHub App's Private Key

1. App settings → **Private keys** → **Generate a private key** (the new one is downloaded, the old one stays valid until you delete it).
2. Update OCI Vault: overwrite `atlantis-github-app-private-key` with the new PEM content (use the `oci vault secret update-base64` command; **read directly from the file**, don't round-trip through a shell variable).
3. Force-sync: `kubectl annotate externalsecret atlantis -n automation force-sync="$(date +%s)" --overwrite`.
4. Roll the deployment: `kubectl rollout restart deploy/atlantis -n automation`.
5. Verify atlantis is healthy, then delete the old private key in the App settings.

## Rotating the Webhook Secret

1. Generate a new value: `openssl rand -hex 32`.
2. Update OCI Vault `atlantis-github-webhook-secret`.
3. Update the App's webhook secret in https://github.com/settings/apps/atlantis-architect → Webhook.
4. Force-sync the ExternalSecret + roll the Deployment as above.
5. Verify by opening a test PR — if Atlantis comments, the new secret works.

## Troubleshooting

### `error: secret "atlantis" not found`

`ExternalSecret/atlantis` hasn't synced yet, or `ClusterSecretStore/oci-vault` is broken.

```bash
kubectl describe externalsecret atlantis -n automation
kubectl get clustersecretstore oci-vault
```

### `wrong number of installations, expected 1, found 2`

The GitHub App is installed on multiple accounts/orgs and Atlantis doesn't know which one to use. Either uninstall from the extras, or set `ATLANTIS_GH_APP_INSTALLATION_ID` env var on the Deployment, sourced from a new OCI Vault key.

List installations via the App's JWT:

```bash
APP_ID=3765954
PEM_PATH=/path/to/private-key.pem
NOW=$(date +%s); EXP=$((NOW+540))
HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
PAYLOAD=$(printf '%s' "{\"iat\":$NOW,\"exp\":$EXP,\"iss\":\"$APP_ID\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -binary -sha256 -sign "$PEM_PATH" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
JWT="$HEADER.$PAYLOAD.$SIG"
curl -sH "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
  https://api.github.com/app/installations | jq '.[] | {account: .account.login, id, target: .target_type}'
```

### `could not parse private key: invalid key`

The PEM in OCI Vault is malformed (e.g. round-tripped through `op item get` which wraps values in quotes). Re-upload directly from the original `.pem` file using `base64 -i <file>` — never via a shell variable.

### `unable to create dir "/atlantis-data/...": permission denied`

The PVC has files owned by an alien UID. The `fix-data-ownership` init container in `deployment.yaml` handles this: it stat's the volume root and chowns recursively only if not already `100:1000`.

**If you suspect ownership has drifted** (or the init container's idempotent check is wrong about the current state), the simplest recovery is to **delete the pod** so the init re-runs on the next scheduled pod:

```bash
kubectl delete pod -n automation -l app=atlantis
```

**If you need to force a chown without rolling the Deployment** (e.g. atlantis is mid-apply and you can't disturb it), run a one-shot Job that mounts the same PVC:

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: atlantis-data-chown
  namespace: automation
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 0
      containers:
        - name: chown
          image: busybox:1.36
          command:
            - sh
            - -c
            - chown -R 100:1000 /atlantis-data && chmod -R u+rwX,g+rwX /atlantis-data
          volumeMounts:
            - name: data
              mountPath: /atlantis-data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: atlantis
EOF
```

Note: `kubectl exec` into the init container is **not** an option — init containers exit after they complete, so there's no running process to exec into.

### Webhook events not arriving

1. App webhook URL points at `https://atlantis.sargeant.co/events` (note the path).
2. Cloudflare Tunnel is healthy: `kubectl get ds cloudflared -n general-system` shows desired = ready.
3. Ingress route exists: `kubectl get ingress atlantis -n automation`.
4. Check **Recent Deliveries** on the App's Advanced page — GitHub logs each webhook attempt with the response code.

## Migrating to Atlantis Architect (v1)

The Atlantis server documented here is the **v0 dogfood**. A SaaS replacement — Atlantis Architect — is in design (see `magmamoose/atlantis-architect`). When it ships, this in-cluster Atlantis becomes redundant for new repos; the existing App can be repurposed as the Atlantis Architect control-plane App by swapping its webhook URL from `https://atlantis.sargeant.co/events` to the Worker endpoint. No new credential issuance needed.
