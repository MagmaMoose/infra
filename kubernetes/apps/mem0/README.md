# mem0 — fleet-shared agent memory

The single durable-memory service for the agent fleet (Nievah/Claude Code, Hermes,
OpenHands, HolmesGPT). It is the `mem0` OSS REST server backed by **pgvector on the
shared CNPG `postgres` cluster** (NOT a new database — `Database` CRs on the existing
cluster, per COMMON_MISTAKES #3), with LLM + embeddings routed through the in-cluster
**LiteLLM** gateway. Lifted out of the retired `zoey` app (`zoey/k8s-mem0/`) and
promoted to a Flux-managed fleet service. Graph memory (Neo4j) is intentionally
dropped — vector memory only.

See ADR `.claude/decisions/2026-07-23-fleet-shared-memory-mem0.md`, and
`MagmaMoose/nievah#197` for the fix-it-or-replace-it decision this shape came out of.

## Layout
- `base/database.yaml`       — TWO CNPG `Database` CRs, ns `database`, both owned by
  `neondb_owner`: `agent_memory` (the pgvector store) and `mem0_app` (the server's
  auth/user/api-key schema, which alembic migrates). The second is not optional — see below.
- `base/extension-job.yaml`  — one-shot Job that `CREATE EXTENSION vector` on
  `agent_memory` (needs superuser), ns `database`
- `base/externalsecret.yaml` — DATABASE_URL + POSTGRES_PASSWORD + LiteLLM key +
  ADMIN_API_KEY + JWT_SECRET (OCI Vault), ns `automation`
- `base/{deployment,service,ingress}.yaml` — the mem0 REST server, ns `automation`
- `base/networkpolicy.yaml`  — ingress allowlist for the server, ns `automation`
- `../../../dockerfiles/mem0-server/Dockerfile` — the image, built by
  `.github/workflows/docker-publish.yml` like every other image in this repo

## Two databases, not one

`agent_memory` holds the vectors. `mem0_app` holds users, API keys, refresh tokens and
request logs — a plain SQLAlchemy schema under alembic. Upstream creates the second one
from `server/init-db.sh`, wired into the postgres container's `docker-entrypoint-initdb.d`;
CNPG has no such hook, so it is declared as a `Database` CR instead. Nothing creates it
lazily: `alembic upgrade head` connects to it by name and fails if it is absent.

## The image is built from upstream SOURCE

This is the load-bearing decision and it is easy to undo by accident. `mem0/mem0-api-server`
on Docker Hub has exactly **one** tag (`latest`), last pushed 2025-09-10, while mem0ai/mem0's
`server/` tree is actively security-patched — two large rounds since (2026-07-30 and
2026-08-21). There is no server image release channel upstream; releases are SDK-only. So
`dockerfiles/mem0-server/Dockerfile` does what upstream's own `server/Dockerfile` does:
`python:3.12-slim` plus `server/requirements.txt`, at a pinned commit.

Two consequences worth knowing before editing anything:

1. **It is multi-arch, and that is why the Deployment is on-prem.** The published image is
   arm64-only, which forced mem0 onto the OCI node tier while its Postgres runs on ff-vm1 —
   every query crossed the site-to-site VPN. `python:3.12-slim` is multi-arch, so the
   `placement.sargeant.co/tier` label in `base/kustomization.yaml` is now `on-prem` and the
   pod sits on the same node as the database. Reverting the Dockerfile to the published base
   silently re-breaks that, because an arm64-only image on `on-prem` (amd64 ff-vm1) is an
   outright pull failure.
2. **Three pins move together**: `MEM0_REF` (the server commit), `mem0ai==` (the SDK the
   server imports — upstream's requirements float it, and server and SDK ship from the same
   repo) and the base image's **index** digest. A per-arch digest breaks the other leg.

## PREREQUISITES / VALIDATE-ON-FIRST-DEPLOY (read before un-parking)

1. **Container image must be built, pushed, AND public.**
   `.github/workflows/docker-publish.yml` builds it to `ghcr.io/magmamoose/mem0-server` on
   any push to `main` touching `dockerfiles/mem0-server/**` (`:latest`), or on a
   `mem0-server-v*` tag (pinned version).
   - **Visibility: already public, and not by accident.** There are no `imagePullSecrets`
     anywhere in `kubernetes/` — every image here is pulled anonymously — so a private
     package would ImagePullBackOff. GHCR packages normally default to private, BUT a
     package created by `GITHUB_TOKEN` under the org inherits the visibility of the repo
     that pushed it, and `MagmaMoose/infra` is public. Verified anonymously:
     `GET ghcr.io/v2/magmamoose/mem0-server/manifests/latest` -> `200`.
   - **Org namespace, not the personal one.** mem0 publishes under
     `ghcr.io/magmamoose/*` (like nievah and the rest of the fleet), whereas the other
     images in `dockerfiles/` use `ghcr.io/calebsargeant/*`. The workflow authenticates
     these with *different* credentials — the built-in `GITHUB_TOKEN` (which can push to
     this repo's own org, given `packages: write`) versus the `GHCR_TOKEN` PAT (required
     for the personal namespace, which `GITHUB_TOKEN` cannot reach). Setting
     `registry_owner` without the matching login would 403.

   Do not hand-build and push this from a laptop: it needs a `write:packages` token that
   no local credential here carries, and yields an artifact nobody can reproduce.
2. **Two OCI Vault entries — the only thing still outstanding.** Neither exists yet:
   ```
   mem0-admin-api-key    # the X-API-Key every fleet caller presents
   mem0-jwt-secret       # required at import even though the JWT flow is unused here
   ```
   Generate each with `openssl rand -base64 48`. Until they exist the ExternalSecret never
   populates and the pod will not start — which is the intended failure, since the
   alternative is the fleet's memory serving unauthenticated.
3. **LiteLLM model entries — satisfied.** The server's own default model moved to
   `gpt-5-mini`, which this gateway does not register, so `deployment.yaml` sets
   `MEM0_DEFAULT_LLM_MODEL` / `MEM0_DEFAULT_EMBEDDER_MODEL` explicitly to the two that ARE
   registered. LiteLLM reads its YAML at startup only; the entries have been in the ConfigMap
   since 2026-08-03 and both litellm pods restarted 2026-08-22, so they are loaded. If the
   ConfigMap changes again: `kubectl rollout restart deployment/litellm -n automation`.
4. **pgvector extension.** This CNPG version's `Database` CR has no `spec.extensions`,
   and `neondb_owner` is not a superuser, so `extension-job.yaml` creates the extension
   using the existing `admin` superuser (secret `nextcloud-db-admin` in ns `database`).
   Reviewed choice — there is no dedicated postgres-superuser secret on this cluster.
5. **First boot is worth watching.** In order: `wait-for-databases` (both DBs reachable,
   `vector` present) -> `migrate` (`alembic upgrade head` against `mem0_app`) -> the server.
   A failure in either initContainer shows as that container's status, not as a restarting
   app. Then measure the working set, because the memory limit is an estimate:
   ```
   kubectl exec deploy/mem0 -n automation -- cat /sys/fs/cgroup/memory.current
   ```
   Tighten the **request** against that number; leave the limit generous (COMMON_MISTAKES
   #13, #14).

## Authentication

`ADMIN_API_KEY`, presented as the `X-API-Key` header. The server compares it with
`secrets.compare_digest` and treats the caller as admin without a registered user, so no
setup wizard or user registration is needed for machine-to-machine use:

```
curl -H "X-API-Key: $MEM0_ADMIN_API_KEY" https://mem0.sargeant.co/memories?user_id=caleb
```

`AUTH_DISABLED=true` was the v1 posture and is gone. It was never a misconfiguration — the
published server shipped with no auth at all and the vendor's guide recommends fronting it
with a reverse proxy — but the current server has a real auth layer, so there is no reason
to keep the door open.

Reachability is constrained independently by `base/networkpolicy.yaml`: `nievah`,
`openhands`, `holmesgpt`, the `hermes` pod in `automation`, and Traefik in `kube-system` for
the LAN ingress. It is ONE policy selecting `app: mem0` rather than the namespace-wide
default-deny used in `holmesgpt` — `automation` is shared with five other apps, and a
`podSelector: {}` there would cut ingress to all of them.

## Health probes

Both probes hit `/auth/setup-status`, which runs `SELECT count(*) FROM users` against
`mem0_app`. They used to hit `/docs`, the FastAPI Swagger page, which renders from the
in-process OpenAPI schema and stays `200` while Postgres is face down — so the pod reported
Ready while unable to serve a single memory. `/auth/setup-status` is the one endpoint that
both round-trips the database and needs no credential, which matters because a `httpGet`
probe cannot read a Secret for its headers.

## Hardening follow-ups

1. **Verify AppArmor node support before enabling a profile.** The modern
   `securityContext.appArmorProfile` (GA in k8s 1.30, cluster is 1.33) is deliberately NOT
   set: there is no AppArmor configuration in `ansible/`/`terraform/`, and a pod requesting a
   non-`Unconfined` profile **fails to start** if the kubelet finds AppArmor unavailable.
   Check `cat /sys/module/apparmor/parameters/enabled` on ff-vm1, then add the profile.
2. **Dedicated postgres-superuser secret.** `extension-job.yaml` borrows
   `nextcloud-db-admin` (the CNPG `admin` superuser). That makes one credential serve two
   unrelated consumers — rotating for one breaks the other, and the blast radius spans both.
   A dedicated `postgres-superuser` vault entry is the real fix.
3. **Egress policy.** `networkpolicy.yaml` restricts ingress only. mem0's egress is Postgres,
   LiteLLM and DNS; an egress rule that misses one presents as a hang rather than an error,
   so add it with the pod running rather than blind.
4. **The memory-change history is ephemeral.** mem0 keeps a SQLite audit trail of
   ADD/UPDATE/DELETE events and opens it with a bare `sqlite3.connect()` — it does not create
   the parent directory, so the default `/app/history/history.db` is an immediate crash on a
   read-only root. It is pointed at the `/tmp` emptyDir, which means it is lost on restart.
   Accepted: nothing in the fleet reads `/memories/{id}/history`, and the durable state is in
   Postgres. If that trail ever matters it needs a PVC, not a different path.

## MCP exposure (the fleet interface — fast follow)

mem0's storage layer is here; the shared **MCP-over-SSE** endpoint every agent points at
is the next step. mem0's own self-hosted MCP packaging is in flux (OpenMemory deprecated),
so it is deliberately NOT baked in yet. Wiring:
- **Claude Code** — `~/.claude.json` mcpServers → `@tensakulabs/mem0-mcp` (npx) against
  `MEM0_BASE_URL=http://mem0.sargeant.co`, `MEM0_USER_ID=caleb`, `MEM0_AGENT_ID=claude-code`
  (proven in `zoey/k8s-mem0/claude-mcp-config.json`).
- **Hermes / OpenHands / HolmesGPT** — need a remote SSE MCP shim in-cluster; pick a
  maintained wrapper, add it as a second container/Deployment, expose SSE. Holmes is
  SSE-only. Namespace memories by `agent_id` (`claude-code`/`hermes`/`holmes`/`openhands`)
  with a shared `user_id=caleb` for cross-agent facts.
