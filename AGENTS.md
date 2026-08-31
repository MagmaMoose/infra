# AI Agent Guide for Monolithic Infrastructure Repository

This guide provides essential architectural knowledge for AI agents working in this infrastructure-as-code repository.

## Big Picture: Multi-Tier Infrastructure

This monolithic repository manages a **distributed home lab** across multiple cloud providers and a local Kubernetes cluster:

- **Kubernetes Core**: 4-node k3s cluster "firefly" — Raspberry Pi 5 control plane, one on-prem amd64 worker, and two arm64 OCI free-tier VMs (the native-cloud tier). Two more native-cloud VMs (`ff-oci3`/`ff-oci4`) are declared in Terraform in a **second OCI tenancy** but not yet applied
- **Cloud Infrastructure**: Multi-provider Terraform via Terragrunt (GCP, OCI, Cloudflare, AWS/Azure future)
- **Configuration Management**: Ansible for system setup, bootstrapping, and complex provisioning
- **GitOps Pipeline**: FluxCD v2 watches this repo and auto-deploys Kubernetes manifests

### Critical Insight: Everything is Declared as Code

No manual kubectl apply or SSH commands. Changes flow through: Git → Terraform/Ansible → FluxCD → Cluster. Breaking this flow causes drift.

## Architecture Patterns You'll Encounter

### 1. Terragrunt Layering (terraform/)

Terragrunt manages configuration inheritance and state, auto-generating Terraform files:

```
terraform/
  root.hcl                       # Version pins, remote state config (GCS)
  terragrunt.hcl                 # Default backend configuration
  cloudflare/modules/            # Reusable Cloudflare modules (cloudflare-dns)
  cloudflare/dns/                # Cloudflare DNS records
  cloudflare/zero-trust/         # Cloudflare ZTNA
  gcp/prod/                      # GCP environments (uses root.hcl)
  oci/provider.hcl               # Default OCI tenancy (caleb): env_prefix = "OCI", so credentials are OCI_*
  oci/modules/                   # Reusable OCI modules (network, server, edge, mikrotik, vpn, …)
  oci/prod/                      # OCI environments, caleb tenancy (uses root.hcl)
  oci/iam-policy/                # Tenancy-root OCI IAM policies
  oci/cloudworkers/provider.hcl  # SECOND tenancy (traceysargeant): env_prefix = "OCI_CW"
  oci/cloudworkers/prod/eu-amsterdam-1/
                                 # network, edge, vpn, server. Same modules as oci/prod,
                                 # different tenancy. Builds ff-chr3/ff-chr4 + ff-oci3/ff-oci4
```

**Key Pattern**: Each provider directory structure mirrors cloud regions/environments. Terragrunt auto-generates `backend.tf` and `provider.tf` - **don't manually edit these files** (they're marked `if_exists = "overwrite"`).

**Second key pattern: a subtree can shadow the tenancy.** `terraform/root.hcl` resolves credentials through `find_in_parent_folders("provider.hcl")`, which finds the **nearest** one, and reads an optional `env_prefix` local from it (`try(..., "OCI")`). `oci/cloudworkers/provider.hcl` sets `env_prefix = "OCI_CW"`, so every leaf beneath it authenticates from `OCI_CW_*` instead of `OCI_*`. Everything else is unaffected and renders byte-identically. Region always comes from the leaf's `region.hcl`, never from an env var, so a second tenancy cannot pick up the wrong region from the ambient environment.

### 2. Kustomize Hierarchical Overlays (kubernetes/)

Layout (`infra-v2`-style — restructure completed across PRs #258, #259, #260, #263, and Phase E; the legacy `_base/` + `_clusters/` trees no longer exist):

```
kubernetes/
  apps/<app>/                    # Per-app: base/<app>/ (manifests) + prod/<app>/ (flux-kustomization)
  clusters/firefly/
    flux-system/                 # Flux bootstrap — gotk-sync points here; the root Kustomization
    kustomization.yaml           # Meta — resources: [../../apps, ../../infrastructure]
  clusters/franklinhouse/        # Second cluster (see docs/reference/franklinhouse.md)
    flux-system/                 # Flux bootstrap + SOPS-encrypted GHCR pull secret
    kustomization.yaml           # Meta — resources: [../../apps/access-control, ./infrastructure, ./system]
    infrastructure/              # Cluster-LOCAL tiers (own CNPG operator + Postgres Clusters)
    system/                      # Traefik HelmChartConfig (pinned to control-plane nodes)
  components/                    # Reusable kustomize Components: node-selectors/, resource-profiles/,
                                 # gluetun-sidecar/, wireguard-sidecar/, helm-releases/, ingress-standards/
  infrastructure/
    configs/                     # Cluster-wide namespaces (Flux Kustomization: infrastructure-configs)
    controllers/                 # cert-manager, external-secrets, 1password-connect, cloudnative-pg
                                 # (Flux Kustomization: infrastructure-controllers, dependsOn configs)
    services/                    # cloudflared, minio, external-dns×2, postgres, mariadb
                                 # (Flux Kustomization: infrastructure-services, dependsOn controllers)
```

The `franklinhouse` cluster was folded into this repo on 2026-08-13 (previously
the **private** repo `calebsargeant/infra-v2`). It lives under
`kubernetes/clusters/franklinhouse/` and is documented in
[docs/reference/franklinhouse.md](docs/reference/franklinhouse.md).

Two scoping rules keep the two clusters apart, and both matter when editing:

- `clusters/franklinhouse/kustomization.yaml` references
  **`../../apps/access-control` directly**, never `../../apps` —
  `kubernetes/apps/kustomization.yaml` is *firefly's* app set, so aggregating it
  would deploy all of firefly onto franklinhouse. For the same reason
  `access-control` is deliberately absent from that aggregator.
- franklinhouse's infrastructure tiers are **cluster-local** under
  `clusters/franklinhouse/infrastructure/`, because the shared
  `kubernetes/infrastructure/` tree is cluster-agnostic and its tier
  Kustomizations point at firefly's `stack/` paths.

franklinhouse also runs **its own CNPG Clusters** (`prod-database`,
`staging-database`), a deliberate exception to the shared-Postgres rule below:
it is a physically separate k3s cluster and cannot reach firefly's `postgres`.

**Key patterns**:
- Each `apps/<app>/prod/<app>/flux-kustomization.yaml` emits a `prod-<app>` Flux Kustomization CR; its `path:` points at `apps/<app>/base/<app>` (the manifests).
- Each infrastructure tier's `flux-kustomization.yaml` emits one Flux Kustomization CR per tier (`infrastructure-configs`, `-controllers`, `-services`), `path:` → `infrastructure/<tier>/stack` (or `configs/namespaces`).
- Kustomizations labeled `app.kubernetes.io/sops=enabled` carry an inline `decryption:` block referencing the `sops-keys` Secret in `flux-system`.
- Resource profiles (`components/resource-profiles/c.medium`: 500m-2 CPU, 1-4Gi memory etc.) are kustomize Components targeting labels on workloads.
- GitHub App-backed Flux `GitRepository` resources must use the matching App installation for the repository owner. In particular, the shared infra image automation uses `github-app-magmamoose` for `MagmaMoose/infra` (not the legacy `buxfer-sync-github-app` credential); installation tokens cannot write outside their installation.

### 3. Secret Management (Preferred → Fallback Order)

**Always prefer external secret stores over in-Git encryption.** Use the following priority order:

1. **OCI Vault + ExternalSecrets** (preferred for runtime cluster secrets) — store the secret in OCI Vault, then create an `ExternalSecret` CR pointing to it. Config lives in `kubernetes/infrastructure/controllers/stack/external-secrets/`.
2. **1Password Connect + ExternalSecrets** (preferred for app credentials & shared team secrets) — store in 1Password, inject via `OnePasswordItem` or `ExternalSecret`. Config lives in `kubernetes/infrastructure/controllers/stack/1password-connect/`.
3. **SOPS + Age** (last resort — only when a secret must live in Git with no external store available) — Age key created in `flux-system` namespace (Ansible role: `k3s-sops-age-secret`); Kustomization resources labeled `app.kubernetes.io/sops=enabled` are auto-decrypted by Flux. Workflow: `sops -e secret.yaml > secret.enc.yaml` → commit only `.enc.yaml`.

**Never commit plaintext secrets regardless of which method is used.** The SOPS `.sops.yaml` configuration is in the repo root if fallback encryption is needed.

### 4. Atlantis PR Integration

GitHub PRs trigger Terraform planning/applying via Atlantis (deployed in Kubernetes):

```yaml
# atlantis.yaml defines projects
projects:
  - name: gcp-infrastructure
    dir: terraform/gcp
    terraform_version: v1.11.3
    workflow: terragrunt  # Custom workflow auto-detects terragrunt.hcl vs plain TF
```

**Workflow**: Push to feature branch → PR → Atlantis comments with `terragrunt plan` output → `atlantis apply` comment → merge.

## Critical Developer Workflows

### Terraform Changes

```bash
cd terraform/gcp/prod  # or your provider/environment
terragrunt plan        # Auto-loads root.hcl config inheritance
terragrunt apply
```

### Ansible Playbook Validation

```bash
cd ansible
ansible-playbook -i hosts your-playbook.yml --check  # Dry-run
ansible-playbook -i hosts your-playbook.yml          # Execute
```

### Kubernetes Manifest Testing

```bash
# Validate Kustomize builds correctly
kustomize build kubernetes/clusters/firefly

# Test w/o applying
kubectl apply -k kubernetes/clusters/firefly --dry-run=client

# Preview changes
kubectl diff -k kubernetes/clusters/firefly

# Manually trigger Flux reconciliation
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization core -n flux-system    # or: misc, automation, media, etc.
```

### Pre-Commit Hooks

```bash
# Hooks are workstation-global: core.hooksPath=~/.git-hooks, config ~/.pre-commit-config.yaml.
# This repo carries no .pre-commit-config.yaml, so `pre-commit install` here is a no-op.
pre-commit run --config ~/.pre-commit-config.yaml --all-files  # Must pass before committing
```

## Project-Specific Conventions

### Ansible Playbooks Organization

**Prefix pattern** indicates target scope:
- `pi-*.yml` → Raspberry Pi bootstrap/config
- `docker-*.yml` → Docker container deployments (host-specific: `-firefly`, `-server`)
- `kubernetes-*.yml` → k3s cluster setup
- `server-*.yml` → Non-Pi servers
- Network equipment: `cisco-*.yml`, `mikrotik-*.yml`

### Terraform Module Naming

Modules live under `terraform/<provider>/modules/` (e.g., `terraform/oci/modules/network`, `terraform/cloudflare/modules/cloudflare-dns`). Environment configs in `terraform/<provider>/<env>/<region>/...` instantiate them via `source = "${get_repo_root()}/terraform/<provider>/modules/<name>"`.

### Kubernetes Namespaces

Namespaces live in `kubernetes/infrastructure/configs/namespaces/`. Mapping:
- `general-system/` → networking, secrets, DNS (1password-connect, cloudflared, external-dns)
- `database/` → postgres, stateful systems
- `media/` → media apps (sonarr, radarr, etc. w/ gluetun sidecars)
- `automation/` → Atlantis, n8n, workflow engines
- `observability/` → monitoring (Prometheus metrics in opencost, fluent-bit)
- `kube-system/` → cluster infrastructure

**Sidecar Component Pattern**: Media apps use Kustomize components to inject gluetun/wireguard sidecars for VPN bypass (e.g., `kubectl apply -k kubernetes/clusters/firefly/media/radarr`).

### Resource Profiles (Cloud Flavor Equivalents)

AWS-style naming mapped to Raspberry Pi constraints (requests → limits):
- `t.small` → cpu 250m → 1, memory 256Mi → 1Gi  (burstable, 1:1)
- `c.medium` → cpu 500m → 2, memory 1Gi → 4Gi  (compute-optimised, 1:2)
- `m.large` → cpu 1 → 4, memory 4Gi → 16Gi  (memory-optimised, 1:4)

Full table in `kubernetes/components/resource-profiles/kustomization.yaml` (5 families × 8 sizes: `p.*` 2:1 cpu/mem, `t.*` 1:1, `c.*` 1:2, `m.*` 1:4, `r.*` 1:8 — each from `pico` to `2xlarge`). Patch deployments by labelling them with `resource-profile=<name>` and applying the component.

### LiteLLM Auth Metadata

LiteLLM (`kubernetes/apps/litellm`) intentionally separates Claude Code OAuth pass-through from LiteLLM gateway authentication:
- Direct `:4000` traffic reserves `Authorization` for the client's Claude Code OAuth bearer token.
- Direct `:4000` LiteLLM gateway auth uses `x-litellm-api-key` via `general_settings.litellm_key_header_name`.
- OAuth pass-through aliases are account-neutral: a workload chooses and supplies its own
  personal or Enterprise bearer. Do not add account-specific LiteLLM models or store those
  tokens in this public repo; Nievah owns its per-GitHub-org account order.
- The LAN/VPN ingress and service port `8080` go through the `auth-proxy` sidecar, which translates OpenAI-style `Authorization: Bearer <LiteLLM key>` into `x-litellm-api-key`.
- **House rule for every LiteLLM client: authenticate with `x-litellm-api-key` (value must include the `Bearer ` prefix); never put the gateway key in `Authorization` on `:4000`.** `Authorization` is reserved for a Claude Code OAuth bearer (`sk-ant-oat…`). If a client authenticates via `Authorization`, LiteLLM sets `authenticated_with_header = "authorization"` and then refuses to forward it upstream, so `-max` pass-through silently stops working. The `:8080` auth-proxy path is the sole exception (OpenAI-protocol clients cannot send custom headers). See `docs/guides/litellm-clients.md`.
- Claude subscription-backed (`-max`) model entries must carry the **sentinel** `litellm_params.api_key: "oauth-pass-through-only-no-api-key"`, plus non-secret `model_info` metadata such as `auth_mode: claude-code-oauth-pass-through` and `billing_mode: claude-max-subscription`. **Never leave `api_key` unset on these** — an absent key is not "client must supply one"; litellm falls back to the `ANTHROPIC_API_KEY` env var, so a client that omits its OAuth bearer silently bills the operator's per-token account while the entry claims subscription billing (the 2026-08-12 finding). The sentinel makes that fail closed; a genuine `sk-ant-oat…` bearer still overrides it.
- Do **not** set `general_settings.forward_client_headers_to_llm_api` (global — forwards every client `x-*` header to *every* provider) or `litellm_settings.forward_llm_provider_auth_headers` (lets any client override the deployment key for any model via `x-api-key`). Neither is required for OAuth pass-through: on 1.95.0 the bearer travels via `add_provider_specific_headers_to_request()`, which is unconditional and already scoped to `anthropic,bedrock,vertex_ai`. Scope header forwarding per-group with `litellm_settings.model_group_settings.forward_client_headers_to_llm_api`.
- API-key-backed models are fine for plain OpenAI-compatible clients when they use the ingress or `:8080` proxy path.
- Do not force LiteLLM onto `type=pi`; the Pi node can be too resource-constrained during rolling updates, and a stuck rollout leaves ingress targeting `:8080` while only the old `:4000` pod is ready. Keep LiteLLM on a memory-oriented profile (`m.nano` or larger); the process has been observed using about 1Gi at idle.
- LiteLLM reads its YAML config at process start, and the Nginx auth-proxy mounts its config with `subPath`. When either LiteLLM ConfigMap changes, update the pod-template `checksum/config` or `checksum/auth-proxy-config` annotation in the Deployment so Flux rolls the pod and the UI/API reflects the new config.
- Warp custom inference requests come from Warp's backend, so they cannot use the LAN-only `litellm.sargeant.co` hostname. Use `litellm-warp.sargeant.co`, a public Cloudflare Tunnel hostname that routes only `/v1/chat/completions` and `/v1/models` to `http://litellm.automation.svc.cluster.local:8080`; all other paths should remain `http_status:404`. Do not put Cloudflare Access in front unless Warp can send the required Access headers.
- The old `litellm.sargeant.co` Cloudflare Access app/policy were intentionally removed from config when LiteLLM moved LAN-only, but the objects remained in Zero Trust state. Keep the `removed { destroy = false }` blocks in `terraform/cloudflare/zero-trust/prod/removed.tf` until Atlantis has applied them; otherwise any unrelated Zero Trust apply will try to destroy those stale resources.
- The self-hosted Ollama provider is represented as `ollama-lan`: a selectorless Service plus an Endpoints object pointing at `192.168.19.69:11434`, with `ollama.sargeant.co` / `.local` ingress. Do not manage a manual EndpointSlice for it; Kubernetes mirrors the Endpoints object into EndpointSlices, and Traefik needs the Endpoints backend to avoid `503 no available server`. Its bearer token must live in OCI Vault as `litellm-ollama-lan-api-key`; never commit the value. The local `qwen2.5-coder:7b-instruct-q4_K_M` route is OpenAI-chat-compatible through LiteLLM, but keep `supports_function_calling: false` until live probes return structured OpenAI `tool_calls`; it has been observed returning tool-call-shaped JSON in message content instead.
- DefectDojo (`kubernetes/apps/defectdojo`) uses the shared CNPG cluster and the shared authless Valkey service. The upstream chart still unconditionally mounts `defectdojo-valkey-specific:valkey-password` into Django/Celery and `defectdojo:METRICS_HTTP_AUTH_PASSWORD` into nginx, even when bundled Valkey and metrics are disabled. Keep `valkey-password-empty.yaml` as an empty non-credential Secret, and keep `defectdojo-metrics-http-auth-password` in OCI Vault via `externalsecret-app.yaml`; do not enable chart-generated Valkey secrets because an auto-generated password breaks the authless shared broker.
- AppSec/dev tooling public hostnames are on `magmamoose.com`: `pullrequests.magmamoose.com`, `defectdojo.magmamoose.com`, `dependencytrack.magmamoose.com`, `dependencytrack-api.magmamoose.com`, `sonarqube.magmamoose.com` and `safesettings.magmamoose.com`. Keep app-level URLs and Cloudflare Tunnel ingress rules (`terraform/cloudflare/zero-trust/prod/tunnels.tf`) in sync. Terraform owns tunnel CNAMEs only for hosts without Kubernetes Ingresses (`pullrequests`, `defectdojo`); Ingress-backed hosts (`dependencytrack`, `dependencytrack-api`, `safesettings`) must carry external-dns annotations pointing at the firefly tunnel target so external-dns does not publish private Traefik IPs. Dependency-Track needs both the frontend and API host because the SPA calls the API directly from the browser. **SonarQube and the Dependency-Track UI are gated by Cloudflare Access (Caleb group)** in `terraform/cloudflare/zero-trust/prod/access_apps.tf`; `dependencytrack.magmamoose.com/api` is a deliberate `bypass` app because the chargate CI action uploads SBOMs there and has no CF-Access-header input (Dependency-Track enforces its own X-Api-Key). `dependencytrack-api.magmamoose.com` is service-token-only. The legacy `dependency-track{,-api}.sargeant.co` aliases were DELETED: a duplicate hostname on the same tunnel silently bypasses any Access app scoped to the magmamoose.com name. Never point a CI scanner at `sonarqube.magmamoose.com` — `sonar-scanner` cannot send CF-Access service-token headers; use the in-cluster Service from the `firefly` runner.
- SonarQube (`kubernetes/apps/sonarqube`) runs on the `worker` node on **magmamoose.com** (`sonarqube.magmamoose.com`), backed by the shared CNPG `neondb_owner` database (a `Database` CR; no new Cluster). **SonarQube security findings flow to DefectDojo**: the `sonarqube-defectdojo-sync` CronJob in `kubernetes/apps/security-integrations` runs DefectDojo's native *SonarQube API Import* (VULNERABILITY + SECURITY_HOTSPOT only — not code smells), and the DefectDojo bootstrap (`kubernetes/apps/defectdojo`) sets `enable_deduplication` so those dedupe against Chargate/MegaLinter/Dependency-Track findings. OCI Vault prereqs: `sonarqube-monitoring-passcode` (readiness), `sonarqube-defectdojo-token` (DefectDojo→SonarQube).
- **Platform2** (`tengen-systems/platform2`, a multi-tenant ANPR platform) is split across two runtimes on **magmamoose.com**: the console `platform2.magmamoose.com` is a Cloudflare Worker deployed from the app repo, while the FastAPI backend (`api.platform2…` → `platform2-backend.platform2.svc:8000`) and the camera-ingest driver (`driver.platform2…` → `platform2-driver.platform2.svc:8443`) run on firefly behind the cloudflared tunnel. The two Python services are *not* Workers because they exceed the 3 MiB free-tier limit (`pydantic_core` is 4 MB uncompressed on its own). Two edge gotchas worth carrying forward: (1) the driver's tunnel ingress rule is `https://` with `no_tls_verify = true` in `origin_request` — the driver terminates its own TLS with a cert-manager internal certificate, so that switch covers only the cloudflared→pod hop and is **not** the app's `ALLOW_INSECURE_HTTP`, which must stay `false`; (2) a Cloudflare Worker **route** (unlike a Worker *custom domain*, which provisions its own record — see `terraform/cloudflare/website-magmamoose/prod`) creates no DNS, so the console hostname needs a proxied placeholder record (`AAAA 100::`, the IPv6 discard prefix) in `terraform/cloudflare/dns-magmamoose/prod` purely to anchor the route. Both charts keep `ingress.enabled: false`, so external-dns has nothing to watch and Terraform owns all three records directly.
- **Platform2's cluster side** (`kubernetes/apps/platform2`) is this repo's **first OCI Helm chart source**: a `HelmRepository` with `type: oci` at `oci://ghcr.io/tengen-systems/charts`, not an `OCIRepository` — that keeps the `chart` + semver `version` range every other HelmRelease here uses, so a chart release lands without a commit. It is app-scoped rather than in `infrastructure/flux/helmrepositories.yaml` because it needs an app-scoped credential: **tengen-systems is a different GitHub org and platform2 is private**, so the SOPS `ghcr-pull-secret` (a MagmaMoose-org token) 401s on it. The new credential is `ghcr-tengen-pull-secret`, assembled from OCI Vault `platform2-ghcr-pull` (`username` + `token`) into a `dockerconfigjson` and projected **twice** — into `flux-system` for source-controller's chart pulls and into `platform2` for the kubelet's image pulls. That is deliberately *not* the `ghcr-reader` SA+RBAC mirror (caldrith / nievah / github-usage-dashboard): that pattern only exists because `ghcr-pull-secret` is SOPS-only in `flux-system`, whereas the `oci-vault` ClusterSecretStore already serves every namespace. Also note the charts' own `externalSecret:` blocks emit `external-secrets.io/v1`, which the **0.11.x** external-secrets on this cluster does not serve (v1beta1 only) — so both releases set `externalSecret.enabled: false` and point at `existingSecret`s managed here, which is required anyway because `DATABASE_URL` must be templated from the shared CNPG `neondb_owner` password. OCI Vault prereqs: `platform2-ghcr-pull`, `platform2-backend` (`jwt_secret`, `image_master_key` — **no recovery path**, `image_token_secret`, `storage_access_key_id`, `storage_secret_access_key`), `platform2-driver` (`driver_token`). Blocked until `tengen-systems/platform2` cuts its first release: no chart or image has ever been published, so both HelmReleases report `no chart version found` and `prod-platform2` stays NotReady (its source Kustomization is `wait: false` so the namespace and the CNPG `Database` still apply).

## Integration Points & Dependencies

### External Service Integrations

| Service | Purpose | Config Location |
|---------|---------|-----------------|
| Google Cloud | Terraform state backend (GCS bucket `${company}-${environment}-terraform-state`, per `terraform/root.hcl`) | `terraform/root.hcl` remote_state |
| OCI (Oracle), caleb tenancy | Cloud infrastructure provisioning | `terraform/oci/` + env vars: OCI_TENANCY_OCID, OCI_USER_OCID, etc. |
| OCI (Oracle), traceysargeant tenancy | The cloudworkers stack (ff-oci3/ff-oci4, ff-chr3/ff-chr4) | `terraform/oci/cloudworkers/` + env vars: OCI_CW_* (see below) |
| Cloudflare | DNS automation, edge (external-dns plugin) | `terraform/cloudflare/` |
| 1Password Connect | Secret injection into Kubernetes | `kubernetes/infrastructure/controllers/stack/1password-connect/` |
| Flux GitRepository | Git polling for deployments | `kubernetes/clusters/firefly/flux-system/` defines git URLs |

### OCI Environment Variables (per tenancy)

`terraform/root.hcl` builds the generated `provider.tf` from four env vars whose **prefix is chosen by the nearest `provider.hcl`**:

```hcl
oci_env_prefix = try(local.provider_vars.locals.env_prefix, "OCI")
```

So there is one variable set per tenancy, and a leaf gets the right one purely from where it sits in the tree:

| Tenancy | provider.hcl | Credential vars |
|---|---|---|
| caleb (default) | `terraform/oci/provider.hcl` (`env_prefix = "OCI"`, the historical set, stated explicitly) | `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY_PATH` |
| traceysargeant | `terraform/oci/cloudworkers/provider.hcl` (`env_prefix = "OCI_CW"`) | `OCI_CW_TENANCY_OCID`, `OCI_CW_USER_OCID`, `OCI_CW_FINGERPRINT`, `OCI_CW_PRIVATE_KEY_PATH` |

The cloudworkers leaves read three more from the environment:

- `OCI_CW_COMPARTMENT_OCID`: traceysargeant has no child compartments, so this is the tenancy OCID itself.
- `OCI_CW_CHR_IMAGE_OCID`: the MikroTik CHR image for `ff-chr3`/`ff-chr4`. **Does not exist yet.** Custom images are tenancy-private, so firefly's CHR image OCID is unusable here (it 404s); an operator must import a CHR `.vmdk` into traceysargeant first.
- `OCI_CW_K3S_TOKEN_SECRET_OCID`: a **copy** of firefly's k3s node-token, in a vault in this tenancy. Cross-tenancy instance-principal reads are impossible (OCI Endorse/Admit accept `group`, never `dynamic-group`), so rotating the node-token means updating **two** vaults.

**Why these are wrapped in `regex()` rather than plain `get_env`**: `get_env(x, "")` returns an empty string when unset, and an empty `tenancy_ocid` makes the OCI provider fall through to `~/.oci/config`'s DEFAULT profile, which is firefly's. A forgotten variable would then plan against the **wrong tenancy** and look fine. The `regex()` asserts fail at parse time instead. Keep the groups non-capturing (`(?:...)`): HCL's `regex()` returns capture groups instead of the match when a group is present.

**Atlantis has none of the `OCI_CW_*` variables**, which is why all four `oci-cloudworkers-*` projects have `autoplan: enabled: false` in `atlantis.yaml`. Plan them from a workstation that has the variables.

### Cross-Component Communication

1. **Terraform → Kubernetes**: GCP service account credentials stored as SOPS-encrypted secret, external-secrets fetches from OCI Vault
2. **Ansible → Kubernetes**: `k3s-sops-age-secret` role creates Age encryption key in cluster during bootstrap
3. **FluxCD → Ansible**: Post-bootstrap, Flux owns all Kubernetes state; Ansible is runtime-only

## Database Conventions (CNPG)

All PostgreSQL workloads run through **one shared CloudNativePG (CNPG) cluster** (`postgres` in the `database` namespace). **Do not create additional CNPG `Cluster` objects** unless there is an explicit environment isolation requirement (e.g., a separate dev, staging, or testing environment).

### The Single-Instance Rule

- The shared cluster is defined in `kubernetes/infrastructure/services/stack/postgres/cluster.yaml` (`name: postgres`, `namespace: database`)
- When an app needs a database, create a new **database + user** inside the existing cluster — not a new `Cluster` resource
- Services available to apps:
  - Read-write: `postgres-rw.database.svc.cluster.local:5432`
  - Read-only: `postgres-ro.database.svc.cluster.local:5432`

### When a New CNPG Instance IS Acceptable

Only spin up an additional `Cluster` when:
- Creating a separate environment (dev, staging, testing)
- Running an isolated experiment that must not touch shared production data
- Explicitly requested by the user for environment separation
- A distinct **failure domain / hardware tier** needs its own DB — e.g.
  `postgres-oci` (`kubernetes/infrastructure/services/stack/postgres-oci/`,
  ns `database-oci`), the always-online cluster pinned to the OCI native-cloud
  nodes for public-facing apps. Pin a CNPG cluster via the `Cluster`'s own
  `spec.affinity.nodeSelector` — the node-selectors kustomize **component does
  not patch the `Cluster` CR**.

### Adding a Database to the Shared Cluster

Use a CNPG `Database` and `User` CR targeting the existing cluster, rather than bootstrapping a new one:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: myapp
  namespace: database
spec:
  cluster:
    name: postgres   # always point to the shared cluster
  name: myapp
  owner: myapp
```

### Which cluster: `postgres` or `postgres-oci`

Co-locate the database with the workload. The two clusters are on opposite sides
of the site-to-site link, and the round trip is not negligible — measured from a
pod on ff-oci1: **5.604 ms to ff-vm1, 0.081 ms to ff-oci1**. For a chatty ORM
application that is the dominant term in page latency (Janeway issues dozens of
queries per render, so a 50-query page is ~280 ms of pure network wait on the
wrong cluster).

- workload on the **native-cloud** tier → `postgres-oci` in `database-oci`
- workload on the **on-prem/worker** tier → `postgres` in `database`

**Give each app its own LOGIN role**, declared in the cluster's `managed.roles`
block with `passwordSecret` pointing at an ExternalSecret from OCI Vault — the
shape `neondb_owner` and `admin` already use on `postgres`, and `janeway` now
uses on `postgres-oci`. CNPG then reconciles the password from the vault, so it
cannot drift, and rotating the vault entry rotates the credential.

Do NOT reuse the cluster's `app` role (dunmir does, for historical reasons). It
owns other applications' databases, so sharing it means either application's
credentials can read the other's data — and because CNPG generates that
password rather than taking it from the vault, reading it needs a
ServiceAccount + Role + RoleBinding + kubernetes-provider `SecretStore` hop, a
Role whose whole purpose is reading Secrets. A managed role removes all four
objects. `postgres-oci` runs `enableSuperuserAccess: false`; that is fine,
because `citext` and `btree_gin` are TRUSTED extensions in PG13+ and a database
owner can create them.

### Trivy KSV-0040: do not add a per-namespace ResourceQuota

Counter-intuitive, and it cost an afternoon. Trivy's KSV-0040 ("a resource quota
policy with hard memory and CPU limits should be configured per namespace") is
evaluated per FILE across a directory scan: adding a `ResourceQuota` anywhere in
an app tree makes it fire on **every other file in that tree**, and satisfying
it in one file does not satisfy the others. Removing the ResourceQuota removes
all of them. Since Kyverno's `default-limitrange` policy already generates a
LimitRange in every namespace, and no other app here has a quota, the answer is
simply not to add one. Namespaces also belong in
`kubernetes/infrastructure/configs/namespaces/` rather than beside app
manifests — that directory holds nothing but Namespace objects, so it stays
clean.

### Shared Valkey — database index registry

`valkey.database.svc.cluster.local:6379` is authless and shared. **Claim an
unused database index and record it here**, because Django's
`RedisCache.clear()` (and any client's `FLUSHDB`) wipes a whole index — an app
pointed at someone else's index destroys their data on an ordinary operation.

| index | consumer |
|---|---|
| 0 | DefectDojo (Celery broker) |
| 4 | authentik |
| 6 | Janeway (Django cache) |

It is configured as a **broker**, not a cache: `--appendonly yes
--maxmemory 1gb --maxmemory-policy noeviction`. `noeviction` is deliberate (a
queue that drops keys loses tasks) but means a full instance returns write
errors rather than evicting, so a cache consumer must set TTLs on everything it
writes. If a consumer ever needs untimed keys, move to `volatile-lru` — which
evicts only keys that have an expiry, leaving broker queues alone — rather than
raising `maxmemory` again. Keep the container memory request above `maxmemory`
or the kubelet OOM-kills it before Valkey applies its own policy.

### Migrating Away from SQLite

**If you encounter an app using SQLite, migrate it to CNPG.** SQLite binds data to a single disk and breaks portability, HA, and backups. It is not acceptable for persistent workloads in this cluster.

- Known outstanding migration: Home Assistant (`kubernetes/apps/homeassistant/base/homeassistant/daemonset.yaml`) — marked `# todo: move from sqlite to postgres`
- When migrating, provision a new database in the shared cluster (see pattern above), update the app's connection env vars to point at `postgres-rw.database.svc.cluster.local`, and remove any SQLite volume mounts
- If the app doesn't natively support PostgreSQL, check for a supported adapter/plugin before assuming SQLite is the only option

## Native-cloud (OCI) worker tier

`ff-oci1` / `ff-oci2` (live) and `ff-oci3` / `ff-oci4` (declared, not yet applied)
are OCI free-tier **arm64** VMs that join firefly as k3s agents and form the
**native-cloud** tier — a more reliable home for always-online, public-facing
workloads (GitHub-App backends) and the `postgres-oci` DB. Full detail:
`docs/reference/cluster-topology.md`. Gotchas:

- **Two tenancies, one tier.** ff-oci1/ff-oci2 are in the **caleb** tenancy,
  ff-oci3/ff-oci4 in **traceysargeant**. One Oracle account gets one Always Free
  ARM allowance (4 OCPU / 24 GB) and the first pair already spends firefly's, so
  the second pair only exists to draw on a second account's allowance. "One per
  fault domain" now means one per fault domain **per tenancy**.
- **They do not share a network path.** ff-oci1/ff-oci2 use firefly's own DRG and
  its IPSec to FG1/FG2. ff-oci3/ff-oci4 cannot: that tunnel terminates in the
  other tenancy. They have their **own** DRG and their own IPSec to the same two
  FortiGates, so ff-oci3-to-ff-oci1 traffic (flannel VXLAN included) hairpins
  through FG1. Both OCI DRGs are Oracle **AS 31898**, so FG1 must originate both
  `192.168.223.0/24` and `192.168.240.0/24` as redistributed statics (or run
  `as-override`), otherwise AS_PATH loop rejection drops the prefixes silently
  while the tunnels still report green.
- **Provisioned in Terraform, not Ansible.** `terraform/oci/modules/server` is
  shared by **two** leaves: `terraform/oci/prod/eu-amsterdam-1/server`
  (`oci-prod-eu-amsterdam-1-server`) and
  `terraform/oci/cloudworkers/prod/eu-amsterdam-1/server`
  (`oci-cloudworkers-prod-eu-amsterdam-1-server`). Each leaf's `servers` map sets
  `node_name` (registers as `ff-ociN`) and `node_labels` (the tier label).
  Editing the **module** touches both and Atlantis won't autoplan, so run
  `atlantis plan -p oci-prod-eu-amsterdam-1-server`; the cloudworkers projects
  have autoplan disabled entirely and must be planned locally with `OCI_CW_*` set.
  Changing `node_name`/`node_labels` **replaces** the VM (cloud-init hash changes).
- **The k3s node-token is duplicated.** A dynamic-group policy in one tenancy
  cannot authorise an instance-principal read against a vault in another, so the
  cloudworkers pair reads a **copy** from its own tenancy's vault. Rotating the
  node-token means updating **both** vaults.
- **Tier label:** `topology.sargeant.co/tier=native-cloud`, set at join. The
  `node-role.kubernetes.io/worker` label is applied post-join with `kubectl`
  (the kubelet may **not** self-register `kubernetes.io`-namespaced labels —
  NodeRestriction), so don't put it in `node_labels`.
- **Pin apps** with the `placement.sargeant.co/tier: cloud` label, which Kyverno
  turns into a `nodeSelector` at admission (or inline `nodeSelector` for
  non-app-template HelmReleases). The old
  `components/node-selectors/native-cloud` component has been **deleted**; don't
  reference it. **Verify the image is arm64/multi-arch first** — several custom
  images are amd64-only.
- **Label-only, no taint** (no toleration churn across DaemonSets).

## When Making Changes

### Before Editing Terraform

- Understand which provider (check directory path)
- Run `terragrunt validate-all` from repo root
- Test with `terragrunt plan` in isolated env to avoid state mutations
- Atlantis will auto-plan on PR

### Before Editing Kubernetes Manifests

- Changes to `kubernetes/infrastructure/` or `kubernetes/components/` are cluster-agnostic (would affect any cluster reconciled from this repo). **In practice `kubernetes/infrastructure/` is firefly's** — franklinhouse deliberately does not reconcile it (see `clusters/franklinhouse/infrastructure/`)
- Changes to `clusters/firefly/` affect only firefly; `clusters/franklinhouse/` only franklinhouse
- Changes to `kubernetes/apps/access-control/` affect **franklinhouse only**; every other app under `kubernetes/apps/` is firefly's
- Validate **both** clusters — they share the `apps/` and `components/` trees:
  ```bash
  kustomize build kubernetes/clusters/firefly
  kustomize build kubernetes/clusters/franklinhouse
  ```
  For the two `flux-system/` bootstrap dirs, add `--load-restrictor LoadRestrictionsNone` (both reference `../apps.yaml`, which plain `kustomize build` rejects; Flux itself does not enforce that restriction)
- Test labels match resource profiles/node selectors
- Encrypted secrets: remember `.enc.yaml` suffix

### Before Editing Ansible

- Use `--check` flag for safety
- Test against safe hosts first (not production)
- Roles should be idempotent
- Variables go in `ansible/vars/`, not playbooks

## Raspberry Pi Constraints (Critical!)

This is **not** generic Kubernetes:

- **Memory**: ~4-8GB available after OS/k3s overhead
- **CPU**: 8 cores but weak single-threaded performance
- **Storage**: SD card or external SSD (NFS used for shared mount points)
- **Network**: Resource-heavy monitoring/sidecars will throttle others

**Always include resource limits/requests in deployments.** Oversized pods cause node evictions. Use `t.small` profile for most media apps, `c.medium` only for multi-core workloads.

## Files to Know

| File | Purpose |
|------|---------|
| (none) | Hooks are workstation-global, not repo-local: `~/.git-hooks` + `~/.pre-commit-config.yaml` |
| `.sops.yaml` | SOPS encryption key configuration |
| `atlantis.yaml` | Terraform PR automation config |
| `ATLANTIS_SETUP.md` | Deployment and secret setup guide |
| `terraform/root.hcl` | Terragrunt inheritance root + version pins |
| `kubernetes/clusters/firefly/kustomization.yaml` | Entry point for cluster deployment |
| `ansible/hosts.yaml` | Inventory (IP addresses, groups) |

## Public Repository — Security Rules (Non-Negotiable)

**This is a public GitHub repository.** Every commit and push is visible to the world. Violating these rules leaks credentials publicly and is irreversible even after deletion (Git history, forks, caches).

- **Never commit secrets, tokens, passwords, API keys, or private keys** in plain text — prefer storing them in **OCI Vault** or **1Password** and referencing via ExternalSecrets; only fall back to SOPS (`sops -e secret.yaml > secret.enc.yaml`, commit only `.enc.yaml`) when no external store is available
- **Never commit proprietary code, licensed third-party source, or internal business logic** that isn't meant for public distribution
- **Never commit cloud credentials** (GCP service account JSON, OCI private keys, Cloudflare tokens) — use environment variables or the existing `.service-account.json` gitignore pattern
- **Scan before pushing**: if you've written anything that looks like a secret, stop and verify it is either already encrypted or covered by `.gitignore`
- **Terraform state files** (`*.tfstate`, `*.tfstate.backup`) must never be committed — state is stored remotely in GCS
- **OCI config** (`terraform/.oci-config.ps1`) and **GCP credentials** (`terraform/.service-account.json`) are gitignored — do not reference or recreate them in tracked files

If you accidentally stage a secret, remove it with `git reset HEAD <file>` before committing. If it has already been committed, treat the credential as compromised and rotate it immediately.

## Red Flags & Common Mistakes

1. **Manually editing generated files** (`backend.tf`, `provider.tf`) — they regenerate with `terragrunt apply`
2. **Reaching for SOPS first** — prefer OCI Vault or 1Password ExternalSecrets; SOPS is last resort only
3. **Over-allocating resources** to Kubernetes pods — will evict everything on Raspberry Pi
4. **Not running `--check`** before Ansible execution — can break system
5. **Assuming git == deployed** — FluxCD reconciles on intervals; force with `flux reconcile`
6. **Committing any plaintext secret to a public repo** — rotate immediately if it happens
7. **Forgetting Atlantis/OpenTofu provider env vars** — for Cloudflare Terragrunt projects, export provider tokens with `extra_arguments` (e.g. `CLOUDFLARE_API_TOKEN`) and keep the provider block empty so Atlantis plans authenticate the same way local plans do
8. **Pinning false Cloudflare Tunnel defaults** — the v4 Cloudflare provider omits falsey tunnel `warp_routing` blocks on readback, so setting `warp_routing { enabled = false }` can create a persistent no-op plan. Omit the block unless WARP routing is enabled.
9. **OpenHands agent-canvas session keys** — inject a shared headless
   `X-Session-API-Key` as `OH_SESSION_API_KEYS_0`, not only as the legacy
   `SESSION_API_KEY`. The image generates and uses a separate public-proxy key when the
   canonical variable is absent, producing persistent 401s for clients such as Nievah. Its
   deployment wrapper must also trim surrounding whitespace before agent-canvas starts:
   Nievah correctly strips HTTP-header values, while the agent server otherwise compares the
   raw environment string (a clipboard/Vault trailing newline produces an unavoidable 401).
   Bump the non-secret pod-template session-key revision after Vault rotation so pods reload it.

## Definition of Done

**Work is not complete until documentation is updated.** Before considering any task finished:

1. **Update `AGENTS.md`** — if you introduced a new pattern, convention, architectural decision, or notable gotcha that future agents should know about, add it here.
2. **Update `docs/`** — if the change affects user-facing behaviour, adds a new application, changes a workflow, or modifies infrastructure: update or create the relevant page under `docs/`. These are published to https://calebsargeant.github.io/infra/.

This applies to all work: new Kubernetes apps, Terraform modules, Ansible roles, secret management changes, database additions, etc. Documentation is part of the implementation, not an afterthought.

## Immediate Next Steps for a New Agent

1. Read `README.md` for high-level overview
2. Explore `terraform/root.hcl` to understand version pinning + state management
3. Inspect `kubernetes/clusters/firefly/kustomization.yaml` and one infrastructure component (e.g., `kubernetes/infrastructure/services/stack/cloudflared/`)
4. Check `~/.pre-commit-config.yaml` (workstation-global) to understand validation before commits
5. Reference `.github/copilot-instructions.md` for detailed style/standards

## GitHub Copilot PR Reviews

When a PR is opened, **GitHub Copilot will automatically review it and may leave inline code comments** on the diff.

### Cleaning Copilot Comments

When you are asked to "clean Copilot comments" on a PR, follow this process precisely:

1. **Fetch all Copilot review comments** on the PR (comments authored by `github-copilot[bot]` or the Copilot review bot).
2. **Evaluate each comment individually**:
   - If the finding is **valid** (real bug, security issue, violation of this repo's conventions, or a meaningful improvement) → fix the code.
   - If the finding is **not valid** (false positive, stylistic preference that contradicts this project's conventions, or irrelevant to infra-as-code context) → skip it; do not modify the code.
3. **For every valid finding that was fixed**:
   - Reply to the Copilot comment in the PR explaining what was changed (e.g., `"Fixed: added resource limits per project resource-profile conventions."`).
   - **Resolve the comment thread** so it no longer appears as an open review item.
4. **For invalid findings**, leave them unresolved and unaddressed — do not reply or dismiss them without the user's explicit instruction.

### What Counts as a Valid Finding in This Repo

Given the infrastructure-as-code nature of this project, treat the following as valid findings:

- Missing `resource` limits/requests on Kubernetes `Deployment` or `StatefulSet` specs
- Unencrypted secrets committed without `.enc.yaml` suffix
- Hardcoded credentials or IP addresses that should use variables/inventory
- Terraform resources missing required outputs or using deprecated syntax
- Ansible tasks lacking `name:` fields or using non-idempotent shell commands without `creates:`/`changed_when:`
- Kustomize `kubernetes/infrastructure/` or `components/` changes that unintentionally affect any consuming cluster
- Direct edits to auto-generated files (`backend.tf`, `provider.tf`)

### What to Ignore

- Generic style suggestions that conflict with this repo's existing conventions
- Suggestions to add generic error handling to Terraform/HCL (not applicable)
- Comments about test coverage (this repo has no automated test suite by design)
- Warnings about Raspberry Pi-specific configurations that are intentional constraints

---

**Documentation**: Full guides at `docs/` (published to https://calebsargeant.github.io/infra/)
