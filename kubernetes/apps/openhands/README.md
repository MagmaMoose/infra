# OpenHands V1

OpenHands is the in-cluster autonomous-coding lane used by Nievah when a repository or
operator selects `harness: openhands`. The deployment uses the multi-arch
`ghcr.io/openhands/agent-canvas:1.5.2` image. Its public UI/proxy listens on port 8000
(and forwards `/api` to the internal V1 agent-server), and it routes inference through the
in-cluster LiteLLM gateway using the `litellm_proxy/deepseek-v4-pro` model alias.

The pod is deliberately a single stateful instance. Its 10Gi `local-path` volume stores the
OpenHands settings and per-conversation workspaces. The pod itself is the sandbox boundary:
it has GitHub write credentials and cluster DNS, but it has no Docker socket or Kubernetes API
access. The ingress is LAN-only.

## Authentication and secrets

The OpenHands `ExternalSecret` reads the LiteLLM key, the bootstrap GitHub token, and the stable
`openhands-session-api-key` from OCI Vault. The latter is also mirrored into Nievah as
`OPENHANDS_SESSION_API_KEY`; Nievah sends it as `X-Session-API-Key` for headless conversations.
Inject it into agent-canvas as **`OH_SESSION_API_KEYS_0`**, its canonical V1 key variable.
`SESSION_API_KEY` is a legacy fallback: using it alone causes agent-canvas to generate a
different public-proxy key, so Nievah receives 401 responses despite both deployments sourcing
the same Vault value. The bootstrap script uses the canonical key and falls back to the
image-generated key only for manual operation when the Vault key is absent. The deployment
normalizes leading/trailing whitespace from the Vault value before starting agent-canvas: HTTP
headers cannot carry a pasted trailing newline, while the agent server otherwise treats it as
part of the key. After rotating this Vault secret, bump the non-secret
`openhands.magmamoose.com/session-api-key-revision` pod-template annotation through GitOps so
the new environment value reaches the process.

Do not put any of these values in Git. If the Vault entry is missing, create it before enabling
an OpenHands harness entry in the Nievah admin allowlist. Flux will then reconcile the
ExternalSecrets and deployment from this directory.

## Operations

OpenHands is enabled in `kubernetes/apps/kustomization.yaml`, and `openhands` is published in
the LAN DNS role. Nievah remains on `claude-code` by default; select OpenHands per repository
with `harness: openhands` or for one authorized command with
`/pr-review --harness openhands` / `/pr-triage --harness openhands`.
Nievah passes the per-run GitHub token through OpenHands' secret registry; the pod does not
receive Nievah's SSH signing private key, so OpenHands commits use its configured Git identity
without SSH verification.

The workspace is node-local scratch state, so a node loss discards active conversations and
requires a new run. Keep the PVC bounded and monitor its usage; completed agent workspaces are
not automatically garbage-collected by the V1 API.
