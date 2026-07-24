# AppSec and Dev Tooling Hostnames

The public AppSec/dev-tooling endpoints hosted on firefly use `magmamoose.com`
hostnames. Public traffic enters through the Cloudflare `firefly` tunnel and is
routed to in-cluster services.

| Tool | Public URL | In-cluster target | Edge gate |
|---|---|---|---|
| Pull request dashboard | `https://pullrequests.magmamoose.com` | `oauth2-proxy.automation.svc.cluster.local:4180` | oauth2-proxy (Google, @magmamoose.com) |
| DefectDojo | `https://defectdojo.magmamoose.com` | `oauth2-proxy.security.svc.cluster.local:4180` | oauth2-proxy; `^/api/v2` + `^/webhook` skipped for CI |
| SonarQube | `https://sonarqube.magmamoose.com` | `sonarqube-sonarqube.security.svc.cluster.local:9000` | Cloudflare Access (Caleb) |
| Backstage | `https://backstage.magmamoose.com` | `backstage-developer-hub.core.svc.cluster.local:7007` | Cloudflare Access (Caleb) — its ONLY gate |
| Dependency-Track frontend | `https://dependencytrack.magmamoose.com` | `dependency-track-frontend.security.svc.cluster.local:8080` | Cloudflare Access (Caleb); `/api` bypassed for CI |
| Dependency-Track API | `https://dependencytrack-api.magmamoose.com` | `dependency-track-api-server.security.svc.cluster.local:8080` | Cloudflare Access service token only |

Keep these three layers aligned when changing a hostname:

- Cloudflare Tunnel ingress rules in `terraform/cloudflare/zero-trust/prod/tunnels.tf`.
- App-level URLs and allowed hosts in the Kubernetes manifests.
- DNS ownership:
  - Terraform owns tunnel CNAMEs in `terraform/cloudflare/dns-magmamoose/prod/terragrunt.hcl` for hosts without Kubernetes Ingresses (`pullrequests`, `defectdojo`).
  - external-dns owns Ingress-backed hosts (`dependencytrack`, `dependencytrack-api`, `safesettings`) from their Ingress annotations.

Dependency-Track is single-hostname and same-origin: the tunnel splits `^/api(/|$)`
to the apiserver ahead of the frontend catch-all, and the frontend's
`/static/config.json` `API_BASE_URL` is the apex itself. `dependencytrack-api.magmamoose.com`
is a legacy fallback with no known caller, gated by a Cloudflare Access service
token and slated for removal. The `dependency-track{,-api}.sargeant.co` aliases were
deleted — a duplicate hostname on the same tunnel silently bypasses any Access app
scoped to the magmamoose.com name. safe-settings must remain public
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

## SonarQube and Backstage (firefly)

Two `worker`-pinned apps under `kubernetes/apps/{sonarqube,backstage}`, mirroring
the Dependency-Track pattern (Helm chart + shared CNPG + external-dns →
Cloudflare-Tunnel Ingress on `magmamoose.com`).

| App | Host | Namespace | Chart | Notes |
|-----|------|-----------|-------|-------|
| SonarQube | `sonarqube.magmamoose.com` | `security` | `sonarqube/sonarqube` (Community Build) | code-quality + security; security findings flow to DefectDojo |
| Backstage | `backstage.magmamoose.com` | `core` | `rhdh/backstage` (Red Hat Developer Hub community) | prebuilt `quay.io/rhdh-community/rhdh:next-1.10`; catalog + TechDocs + dynamic plugins |

- **Database**: both use the shared CNPG cluster via a `Database` CR
  (`base/database.yaml`, owner `neondb_owner`) and the `neondb-owner-password` OCI
  Vault secret — no new Cluster/role. Backstage keeps all plugin data in the single
  `backstage` DB via `pluginDivisionMode: schema`.
- **Backstage = Red Hat Developer Hub (community)** — a *prebuilt* Backstage
  distribution, so there is no custom image to build. The chart's OpenShift-isms are
  overridden for k3s: `route.enabled: false`, bundled Postgres off (shared CNPG),
  Lightspeed off, community image pinned, exposed via the standalone Ingress. GitHub
  integration activates when `backstage-github-token` exists in OCI Vault (optional;
  Backstage boots without it).
- **SonarQube → DefectDojo (security findings)**: the `sonarqube-defectdojo-sync`
  CronJob (`kubernetes/apps/security-integrations`, hourly) triggers DefectDojo's
  native *SonarQube API Import*, so DefectDojo pulls each project's VULNERABILITY +
  SECURITY_HOTSPOT findings (security — **not** code smells) and dedupes them against
  the other tools feeding DefectDojo (Chargate/MegaLinter SARIF, Dependency-Track,
  Trivy …). Cross-tool dedup is enabled by the DefectDojo bootstrap
  (`enable_deduplication`). SonarQube's code-quality/coverage stays in SonarQube.
- **vm.max_map_count**: SonarQube's embedded Elasticsearch needs 524288, set by the
  chart's privileged `initSysctl` container (fine on the amd64 worker).

### OCI Vault prerequisites (add before/at first reconcile; the jobs retry)
- `sonarqube-monitoring-passcode` — any strong string; SonarQube never reports ready without it.
- `sonarqube-defectdojo-token` — a SonarQube user token (My Account → Security → Generate Token) DefectDojo uses to read findings.
- `backstage-github-token` *(optional)* — a GitHub PAT for Backstage's GitHub integration.
- `neondb-owner-password` — already exists; reused for both DBs.

### Follow-ups (documented, not yet wired)
- SonarQube Prometheus metrics: enable `prometheusExporter` + `prometheusMonitoring.podMonitor` (the cluster scrapes all monitors via `…SelectorNilUsesHelmValues: false`).
- ~~Google SSO for both~~ — delivered instead by **Cloudflare Access** (Caleb group), see `terraform/cloudflare/zero-trust/prod/access_apps.tf`. SonarQube and Dependency-Track keep their own logins behind Access; Backstage has none (community chart with no auth provider defaults to guest), so Access is its only gate.
- Remaining: Backstage Kubernetes plugin (in-cluster SA) and GitHub org catalog discovery.
- Never point a CI code scanner at `sonarqube.magmamoose.com` — `sonar-scanner` cannot send `CF-Access-Client-Id`/`-Secret`. Run it on the in-cluster `firefly` self-hosted runner against `sonarqube-sonarqube.security.svc.cluster.local:9000`.
