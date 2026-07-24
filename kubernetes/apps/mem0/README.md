# mem0 — fleet-shared agent memory

The single durable-memory service for the agent fleet (Nievah/Claude Code, Hermes,
OpenHands, HolmesGPT). It is the `mem0` OSS REST server backed by **pgvector on the
shared CNPG `postgres` cluster** (NOT a new database — a `Database` CR on the existing
cluster, per COMMON_MISTAKES #3), with LLM + embeddings routed through the in-cluster
**LiteLLM** gateway. Lifted out of the retired `zoey` app (`zoey/k8s-mem0/`) and
promoted to a Flux-managed fleet service. Graph memory (Neo4j) is intentionally
dropped — vector memory only.

See ADR `.claude/decisions/2026-07-23-fleet-shared-memory-mem0.md`.

## Layout
- `base/mem0/database.yaml`      — CNPG `Database` CR (`agent_memory`, owner `neondb_owner`), ns `database`
- `base/mem0/extension-job.yaml` — one-shot Job that `CREATE EXTENSION vector` (needs superuser), ns `database`
- `base/mem0/externalsecret.yaml`— DATABASE_URL + POSTGRES_PASSWORD + LiteLLM key (OCI Vault), ns `automation`
- `base/mem0/{deployment,service,ingress}.yaml` — the mem0 REST server, ns `automation`
- `../../../dockerfiles/mem0-server/Dockerfile` — the image (mem0 server + pgvector deps),
  built by `.github/workflows/docker-publish.yml` like every other image in this repo

## PREREQUISITES / VALIDATE-ON-FIRST-DEPLOY (read before merging)

1. **Container image must be built, pushed, AND made public.** The upstream
   `mem0/mem0-api-server` image does not ship the pgvector client deps, so we layer them
   on in `dockerfiles/mem0-server/Dockerfile`. `.github/workflows/docker-publish.yml`
   builds it to `ghcr.io/calebsargeant/mem0-server` on any push to `main` touching that
   directory (`:latest`), or on a `mem0-server-v*` tag (pinned version). Two gotchas:
   - **New GHCR packages default to PRIVATE**, and there are no `imagePullSecrets`
     anywhere in `kubernetes/` — every other image is pulled anonymously. So after the
     first successful build, flip the package to public or the Deployment
     ImagePullBackOffs. This is a one-time manual step in the GHCR package settings.
   - **arm64 only.** The upstream base publishes a manifest index containing
     `linux/arm64` and nothing else, so the matrix entry overrides `platforms` and the
     Deployment carries the `node-selectors/native-cloud` component (ff-oci1/ff-oci2).
     Do not remove that nodeSelector — ff-vm1 is amd64 and simply cannot run this image.

   Do not hand-build and push this from a laptop: it needs a `write:packages` token and
   yields an artifact nobody can reproduce. The workflow's `GHCR_TOKEN` already has it.
2. **LiteLLM rollout required.** The LiteLLM ConfigMap in this change adds
   `text-embedding-3-small` and `gpt-4o-mini`. LiteLLM reads its YAML config at startup
   only — after this PR merges and Flux reconciles the ConfigMap, trigger a rollout so
   the new model entries load:
   ```
   kubectl rollout restart deployment/litellm -n automation
   ```
   Without this step, mem0's first embedding/completion calls will fail with "model not
   found". Confirm the env vars (`OPENAI_BASE_URL`, `OPENAI_API_KEY`) match the
   provisioned ExternalSecret. Adjust models to `claude-*`/`deepseek-*` if you prefer
   non-OpenAI extraction.
3. **pgvector extension.** This CNPG version's `Database` CR has no `spec.extensions`,
   and `neondb_owner` is not a superuser, so `extension-job.yaml` creates the extension
   using the existing `admin` superuser (secret `nextcloud-db-admin` in ns `database`).
   Reviewed choice — there is no dedicated postgres-superuser secret on this cluster.
4. **AUTH_DISABLED=true** for v1 (LAN-only ingress + in-cluster callers). Add an admin
   key before exposing beyond the LAN.

## Hardening follow-ups (before un-parking)

Surfaced by the security review of this PR; none block the (parked) merge, all are worth
doing before the app actually reconciles:

1. **Verify AppArmor node support before enabling a profile.** The modern
   `securityContext.appArmorProfile` (GA in k8s 1.30, cluster is 1.33) is deliberately NOT
   set: there is no AppArmor configuration in `ansible/`/`terraform/`, and a pod requesting a
   non-`Unconfined` profile **fails to start** if the kubelet finds AppArmor unavailable.
   mem0 has no `nodeSelector`, so it could land on the Pi. Check
   `cat /sys/module/apparmor/parameters/enabled` on each node, then add the profile.
2. **Dedicated postgres-superuser secret.** `extension-job.yaml` borrows
   `nextcloud-db-admin` (the CNPG `admin` superuser). That makes one credential serve two
   unrelated consumers — rotating for one breaks the other, and the blast radius spans both.
   A dedicated `postgres-superuser` vault entry is the real fix.
3. **In-cluster reachability.** The repo has no `NetworkPolicy`, so a `ClusterIP` service in
   `automation` is reachable unauthenticated by *any* pod — "LAN-only ingress" constrains
   north-south only. Since this store aggregates memory across Claude Code, Hermes, OpenHands
   and HolmesGPT, set the admin key (item 4 above) before first real use, not just before
   exposing it wider.
4. **Liveness probe signal.** `/docs` (FastAPI Swagger) renders fine while Postgres or LiteLLM
   is down, so a wedged backend never restarts the pod. Swap for a real health endpoint if the
   image grows one.

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
