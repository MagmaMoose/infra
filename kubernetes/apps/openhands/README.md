# OpenHands V1

OpenHands is the in-cluster autonomous-coding agent, used through its UI. Nievah no longer
calls it: Nievah's fallback after its Claude accounts is the Codex CLI on its own
`nievah-fallback` LiteLLM key, and a `harness: openhands` setting runs on Claude Code.
OpenHands stays deployed for interactive use. The deployment uses the multi-arch
`ghcr.io/openhands/agent-canvas` image, kept current by Flux image automation. Its public
UI/proxy listens on port 8000 (and forwards `/api` to the internal V1 agent-server). The
default LLM is an Azure OpenAI resource, called directly; the in-cluster LiteLLM gateway
profiles stay selectable.

The pod is deliberately a single stateful instance. The pod itself is the sandbox boundary:
it has GitHub write credentials and cluster DNS, but it has no Docker socket or Kubernetes API
access. Every token it holds is readable from the agent's shell, so a prompt injection from a
repository or fetched page can reach them; that is the cost of this design.

Two ingresses. `openhands.magmamoose.com` is the primary entrypoint: a proxied CNAME to the
firefly cloudflared tunnel, gated by a Caleb-only Cloudflare Access app (one exact email,
HttpOnly and binding cookies, 8h session). The macOS device-posture requirement was removed
on 2026-09-16, because the posture checks need WARP on the device. Because the pod holds
GitHub write credentials, that app has no path bypasses and must not be widened to the
Friends group. `openhands.sargeant.co` / `.local` stay LAN-only (no tunnel, no Access) as
the fallback when the Cloudflare edge is unavailable. Both hosts still need the session key:
the UI asks for it, and agent-canvas does not embed it in the page.

## Authentication and secrets

The OpenHands `ExternalSecret` reads the LiteLLM key, the bootstrap GitHub token, the Azure
OpenAI endpoint and key, and the stable `openhands-session-api-key` from OCI Vault. The session key
is what the UI asks for at sign-in. Nievah used to send it as `X-Session-API-Key` for
headless conversations; it no longer holds it, so nothing headless can start a
conversation. Inject it into agent-canvas as **`OH_SESSION_API_KEYS_0`**, its canonical V1 key variable.
`SESSION_API_KEY` is a legacy fallback: using it alone causes agent-canvas to generate a
different public-proxy key, so a headless client receives 401 responses despite both sides
sourcing the same Vault value. The bootstrap script uses the canonical key and falls back to the
image-generated key only for manual operation when the Vault key is absent. The deployment
normalizes leading/trailing whitespace from the Vault value before starting agent-canvas: HTTP
headers cannot carry a pasted trailing newline, while the agent server otherwise treats it as
part of the key. After rotating this Vault secret, bump the non-secret
`openhands.magmamoose.com/session-api-key-revision` pod-template annotation through GitOps so
the new environment value reaches the process.

`openhands-azure-openai` is JSON (`base_url`, `api_key`) holding the Azure OpenAI endpoint
and the resource's secondary key. It is for Caleb's manual use in the UI only, so it is
deliberately not on the LiteLLM gateway, where Nievah, Hermes or a fallback alias could
reach it. The secondary key can be regenerated to revoke this copy without touching
anything on the primary key; after a regeneration, update the OCI entry and restart the
pod.

Product analytics are off: `DO_NOT_TRACK=1` for the agent-server and
`AGENT_CANVAS_DISABLE_TELEMETRY=1` for the frontend, which otherwise sends PostHog an
install event without asking.

Do not put any of these values in Git. If the Vault entry is missing, create it before using
OpenHands headlessly. Flux will then reconcile the ExternalSecrets and deployment from this
directory.

## Operations

OpenHands is enabled in `kubernetes/apps/kustomization.yaml`, and `openhands` is published in
the LAN DNS role. Its LiteLLM key is capped at 150K tokens and 60 requests per minute
(`kubernetes/apps/litellm/base/keyseed-job.yaml`), so one long session cannot take the whole
Luna limit every other client shares. When the optional
`openhands-ssh-signing-key` Vault entry is provisioned, the container startup initializes an
`ssh-agent`, exports its socket, and configures Git SSH signing for normal OpenHands commits;
nested Claude sessions repeat that setup through the SessionStart hook. If the Vault entry is
created after startup, the mounted Secret is watched and the key is loaded without a manual
restart. Without that Vault entry, the pod continues without signing.

The workspace is node-local scratch state, so a node loss discards active conversations and
requires a new run. Keep the PVC bounded and monitor its usage; completed agent workspaces are
not automatically garbage-collected by the V1 API.

## Provisioning

Everything below is applied by `configmap-bootstrap.yaml`'s seed script, which the pod's
postStart hook runs on every start. The script is idempotent, so a rollout re-converges
the instance and hand-edits made in the UI are overwritten on the next restart. That is
deliberate: OpenHands keeps its settings encrypted on the state PVC, where Git cannot
reach them, so the API is the only declarative surface available.

- **LLM profiles** — `azure-gpt-5.6-sol` (active), `azure-gpt-5.6-terra` and
  `azure-gpt-5.6-luna` go straight to Azure as `azure/<deployment>` on api_version
  `2025-04-01-preview`, the oldest that serves the Responses API the SDK uses for gpt-5.
  They exist only when the `openhands-azure-openai` entry does. `gpt-5.6-luna`, `gpt-5.6-sol`
  and `gpt-5.6-terra` go through the gateway with the `litellm_proxy/` prefix; they are
  the only provider models the OpenHands virtual key allows, and they fail while the
  gateway's OpenAI account has no credit. Using `openai/` instead of `litellm_proxy/`
  reaches the same endpoint but skips LiteLLM's model-group routing, so budgets and the
  key's allow-list stop applying.
- **Agent profile** — the UI launches conversations from the active agent profile, whose
  `llm_profile_ref` picks the LLM. The seed points it at the active LLM profile.
- **Attribution policy** — the SDK's built-in prompt asks for a `Co-authored-by: openhands`
  trailer on commits and an "AI agent (OpenHands)" note on everything posted to GitHub,
  Slack and the like, and no setting removes either. The seed sets a
  `system_message_suffix` (on the agent profile and in agent settings) that overrides
  both. The commit-msg hook and the `gh` wrapper strip anything that slips through on
  those paths; the GitHub MCP server has no such backstop.
- **Credentials** — the scoped `openhands` LiteLLM key (see the LiteLLM keyseed Job), not
  the gateway master key. An agent with GitHub write access should not also hold admin
  rights over the gateway every other workload shares.
- **Stored secrets** — `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` (gh on GitHub Enterprise
  repositories), `SLACK_BOT_TOKEN` and `CLICKUP_API_KEY`, which the agent's shell sees as
  environment variables.
- **Git identity** — `misc_settings.app_preferences`, set from the `GIT_AUTHOR_*` env vars
  so the Deployment stays the single source.
- **Sub-agents** — markdown definitions in `configmap-subagents.yaml`, mounted at
  `~/.agents/agents` (outside the PVC, so they cannot drift) and enabled via
  `enable_sub_agents`. They default to off; mounting alone does nothing.
- **MCP servers** — GitHub, Context7 and the two public documentation endpoints use HTTP.
  Slack, ClickUp, Playwright, Mermaid and Microsoft 365 use stdio. Servers whose
  credentials are absent are omitted rather than configured broken, and a stored server
  Git no longer declares is deleted. There is no Nievah server: it was configured with
  this pod's own session key as its bearer, which Nievah rejects, so every connect sent
  the credential that controls OpenHands to another service for a 401. Microsoft 365
  needs its `login` tool run once interactively; Mermaid uses the local Playwright-backed
  renderer with its browser cache on the state PVC, while the hosted MermaidChart server
  would require an OAuth round-trip through the UI.
- **Git hooks** — `/git-hooks` is the global Git hooks path for the agent and strips unwanted
  PR, issue, comment and review attribution lines from `gh`, rejects hook-bypass flags
  before Git commands run in nested Claude sessions, and runs the local Chargate check,
  action SHA pinning, branch policy, commit-message cleanup, and optional SSH signing hooks.

Read the seed log with `kubectl -n openhands logs deploy/openhands | grep openhands-seed`.

## Storage and the repo mirror

Two Longhorn volumes on `longhorn-on-prem`, and the Deployment is on the on-prem
placement tier so the pod sits beside them. `openhands-state` (10Gi) holds settings,
profiles and conversation history and carries the `weekly-backup` label, so it reaches
S3; that job has no group selector, so a volume without the label gets local snapshots
only. `openhands-repos` (50Gi) holds the clones, which are reproducible from GitHub and
so are deliberately left out of the backup set.

`/workspace/repos/<owner>/<name>` is maintained by the `repo-sync` sidecar, mirroring
the `~/repos` layout. It reconciles the *set* of repositories and lets git move the
contents, which is why it replaces the previous Syncthing arrangement: Syncthing does
file-level bidirectional sync, and a git repository is a database whose index, refs and
packfiles both ends mutate. It cannot merge those, so it writes `.sync-conflict-*` files
into `.git` and corrupts the repo. Excluding `.git` is not a fix either, since that
syncs working trees detached from their own history.

The sidecar never touches work in progress. A repository with uncommitted changes, on a
non-default branch, or ahead of its remote is fetched and then left alone. Repositories
the API stops returning are moved to `/workspace/repos/.attic`, never deleted, so a
rate-limited or partial API response cannot destroy local work. The only deletions are
a failed transfer's leftover `tmp_pack_*` files, and a clone that never finished and has
nothing checked out (HEAD still on git's `refs/heads/.invalid` placeholder, or no pack
at all), which the next pass re-clones. Neither can hold work. Owners are listed in
`configmap-reposync.yaml`.

The old `openhands` local-path PVC on ff-oci2 still holds the conversation history up to
2026-09-16. The one-shot `openhands-migrate-state-v1` Job meant to copy it never ran: it
needed `openhands-state` attached on ff-oci2 while the running pod held that RWO volume,
so it sat in ContainerCreating and kept `prod-openhands` unhealthy until it was removed.
Nothing mounts the old claim; delete it and its block in `pvc.yaml` once that history is
not wanted.
