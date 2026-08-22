# Identity Provider (Authentik)

`kubernetes/apps/authentik` deploys [Authentik](https://goauthentik.io/) (an
open-source OIDC/SAML identity provider) on the amd64 `worker` node, at
`authentik.magmamoose.com`. It's the foundation for unifying SSO across the cluster
(SonarQube, Grafana, DefectDojo, …) in place of per-app oauth2-proxy.

## How it's wired

- **Postgres**: the shared CNPG cluster (`Database` CR, owner `neondb_owner`). No
  bundled Postgres.
- **Redis**: the shared authless **Valkey** (`valkey.database`), on its own DB index
  (`AUTHENTIK_REDIS__DB=4`) to avoid colliding with DefectDojo. The goauthentik chart
  bundles no Redis, so this is required.
- **Secrets** (`authentik.existingSecret`, env-injected into server + worker):
  `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL__PASSWORD` (reuses
  `neondb-owner-password`), `AUTHENTIK_BOOTSTRAP_PASSWORD`, `AUTHENTIK_BOOTSTRAP_TOKEN`.
- **Exposure**: public via the tunnel (it *is* the auth, so no oauth2-proxy/Access in
  front). Note `magmamoose.com` is on Tucows clientHold until that lifts.

## ⚠️ OCI Vault prerequisites
- `authentik-secret-key`: `openssl rand -base64 60 | tr -d '\n'`
- `authentik-bootstrap-password`: initial `akadmin` password
- `authentik-bootstrap-token`: initial API token
- `neondb-owner-password`: already exists; reused.

> This is the IdP **foundation**. Migrating apps onto it (an OIDC provider per app,
> then swapping each app's oauth2-proxy for Authentik) is the follow-on work. Do it
> incrementally, app by app, verifying each before moving the next.

## First-run verification
Because this couldn't be applied to a live cluster from CI, sanity-check on first
reconcile: the server + worker pods reach **Ready**, the worker connects to Valkey,
and `https://authentik.magmamoose.com` serves the setup flow (log in as `akadmin`
with the bootstrap password).
