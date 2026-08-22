# AppSec and Dev Tooling Hostnames

The public AppSec/dev-tooling endpoints hosted on firefly use `magmamoose.com`
hostnames. Public traffic enters through the Cloudflare `firefly` tunnel and is
routed to in-cluster services.

| Tool | Public URL | In-cluster target |
|---|---|---|
| Pull request dashboard | `https://pullrequests.magmamoose.com` | `oauth2-proxy.automation.svc.cluster.local:4180` |
| DefectDojo | `https://defectdojo.magmamoose.com` | `oauth2-proxy.security.svc.cluster.local:4180` |
| Dependency-Track frontend | `https://dependencytrack.magmamoose.com` | `dependency-track-frontend.security.svc.cluster.local:8080` |
| Dependency-Track API | `https://dependencytrack-api.magmamoose.com` | `dependency-track-api-server.security.svc.cluster.local:8080` |
| safe-settings | `https://safesettings.magmamoose.com` | `safe-settings.security.svc.cluster.local:3000` |

Keep these three layers aligned when changing a hostname:

- Cloudflare Tunnel ingress rules in `terraform/cloudflare/zero-trust/prod/tunnels.tf`.
- App-level URLs and allowed hosts in the Kubernetes manifests.
- DNS ownership:
  - Terraform owns tunnel CNAMEs in `terraform/cloudflare/dns-magmamoose/prod/terragrunt.hcl` for hosts without Kubernetes Ingresses (`pullrequests`, `defectdojo`).
  - external-dns owns Ingress-backed hosts (`dependencytrack`, `dependencytrack-api`, `safesettings`) from their Ingress annotations.

Dependency-Track needs both frontend and API public hostnames because the SPA
calls the API host directly from the browser. safe-settings must remain public
without a Cloudflare Access gate for `/api/github/webhooks`; GitHub authenticates
payloads with the webhook secret instead. For Ingress-backed public tunnel
hosts, set `external-dns.alpha.kubernetes.io/target` to the firefly
`*.cfargotunnel.com` hostname and `external-dns.alpha.kubernetes.io/cloudflare-proxied`
to `"true"`; otherwise external-dns publishes the private Traefik load-balancer
addresses.

## safe-settings Admin Repository

safe-settings reads its desired-state configuration from
`MagmaMoose/admin:.github/settings.yml`, with optional overlays under
`.github/suborgs/` and `.github/repos/`. The Diatreme GitHub App is installed on
all MagmaMoose repositories, but its webhook URL is owned by Diatreme
(`https://api.diatreme.magmamoose.com/webhook`). To avoid stealing that webhook,
the in-cluster safe-settings deployment runs `CRON=*/15 * * * *` for scheduled
full-sync reconciliation.

## OAuth Cookie Scope

Each oauth2-proxy-protected app must use an app-specific cookie name and a
host-specific `--cookie-domain`. Do not use `.magmamoose.com` as the cookie
domain for multiple apps: oauth2-proxy CSRF/session cookies collide across
subdomains and cause intermittent `Unable to find a valid CSRF token` failures.

## SonarQube (firefly)

A `worker`-pinned app under `kubernetes/apps/sonarqube`, mirroring the
Dependency-Track pattern (Helm chart + shared CNPG + external-dns →
Cloudflare-Tunnel Ingress on `magmamoose.com`).

| App | Host | Namespace | Chart | Notes |
|-----|------|-----------|-------|-------|
| SonarQube | `sonarqube.magmamoose.com` | `security` | `sonarqube/sonarqube` (Community Build) | code-quality + security; security findings flow to DefectDojo |

- **Database**: uses the shared CNPG cluster via a `Database` CR
  (`base/database.yaml`, owner `neondb_owner`) and the `neondb-owner-password` OCI
  Vault secret. No new Cluster/role.
- **SonarQube → DefectDojo (security findings)**: the `sonarqube-defectdojo-sync`
  CronJob (`kubernetes/apps/security-integrations`, hourly) triggers DefectDojo's
  native *SonarQube API Import*, so DefectDojo pulls each project's VULNERABILITY +
  SECURITY_HOTSPOT findings (security, **not** code smells) and dedupes them against
  the other tools feeding DefectDojo (Chargate/MegaLinter SARIF, Dependency-Track,
  Trivy …). Cross-tool dedup is enabled by the DefectDojo bootstrap
  (`enable_deduplication`). SonarQube's code-quality/coverage stays in SonarQube.
- **vm.max_map_count**: SonarQube's embedded Elasticsearch needs 524288, set by the
  chart's privileged `initSysctl` container (fine on the amd64 worker).

### OCI Vault prerequisites (add before/at first reconcile; the jobs retry)
- `sonarqube-monitoring-passcode`: any strong string; SonarQube never reports ready without it.
- `sonarqube-defectdojo-token`: a SonarQube user token (My Account → Security → Generate Token) DefectDojo uses to read findings.
- `neondb-owner-password`: already exists; reused for the SonarQube DB.

### Follow-ups (documented, not yet wired)
- SonarQube Prometheus metrics: enable `prometheusExporter` + `prometheusMonitoring.podMonitor` (the cluster scrapes all monitors via `…SelectorNilUsesHelmValues: false`).
- Google SSO (cluster oauth2-proxy / OIDC pattern).
