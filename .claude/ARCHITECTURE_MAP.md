# Architecture Map

```
Git → .github/workflows/terragrunt.yml    → cloud (GCP/OCI/AWS/Cloudflare)
Git → FluxCD (watches main)               → k3s firefly (RPi) → apps + infra tiers
Ansible → bootstraps systems/k3s          → runtime-only after Flux owns the cluster
```

Three sources of truth (in flow order):
1. `terraform/` — Terragrunt wraps TF; GCS backend (all clouds); 1 leaf = 1 state file.
   `terragrunt.yml` plans/applies; Atlantis is legacy and covers only 20 of 27 leaves
2. `ansible/` — host config, k3s bootstrap, network devices (idempotent roles)
3. `kubernetes/` — Flux: cluster root → infrastructure (configs→controllers→services) + apps

Secrets order: **OCI Vault → 1Password → SOPS (last resort, `.enc.yaml` only)**.

**Two** clusters now live here (franklinhouse folded in from the private
`calebsargeant/infra-v2` on 2026-08-13):

| Cluster | Root | Apps | Infra |
|---|---|---|---|
| firefly | `kubernetes/clusters/firefly/` | `../../apps` (whole aggregator) | `../../infrastructure` (shared) |
| franklinhouse | `kubernetes/clusters/franklinhouse/` | `../../apps/access-control` **only** | `./infrastructure` (cluster-local) |

Never add `access-control` to `kubernetes/apps/kustomization.yaml` (that is
firefly's app set), and never point franklinhouse at `../../apps`. Details:
`docs/reference/franklinhouse.md`.
