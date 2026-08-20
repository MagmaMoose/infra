# Pointing dev tools at the LiteLLM gateway

The LiteLLM proxy (`kubernetes/apps/litellm`) is an OpenAI-compatible gateway. Any
tool that speaks the OpenAI API can route through it: one endpoint, one key, unified
usage tracking + the LiteLLM admin UI.

- **In-cluster direct URL:** `http://litellm.automation.svc.cluster.local:4000`
- **In-cluster API-key proxy URL:** `http://litellm.automation.svc.cluster.local:8080`
- **LAN/VPN URL:** `https://litellm.sargeant.co`
- **Public Warp endpoint:** `https://litellm-warp.sargeant.co/v1`

> **Note:** Some tools (such as the Codex config.toml and OpenCode examples below) require the base URL to include `/v1`; others (the OpenAI SDK, the `OPENAI_BASE_URL` environment variable) omit it because the client appends `/v1` automatically. When in doubt, check the tool's documentation.

- **Auth:**
  - Direct `:4000` traffic reserves `Authorization` for Claude Code OAuth pass-through.
  - Direct `:4000` LiteLLM gateway auth uses `x-litellm-api-key`; for client use, prefer a **virtual key** created in the admin UI.
  - The LAN/VPN ingress and in-cluster `:8080` path go through the `auth-proxy` sidecar, which copies OpenAI-style `Authorization: Bearer <LiteLLM key>` into `x-litellm-api-key`.
- **Model names:** clients request a `model_name` from the proxy's `config.yaml`
  (`claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`, …).

## 🔑 House rule: send `x-litellm-api-key`, never `Authorization`

**Every client of this gateway authenticates with the `x-litellm-api-key` header.
`Authorization` is reserved for one thing only: a Claude Code OAuth bearer
(`sk-ant-oat…`) on a `-max` model.**

```http
POST /v1/chat/completions
x-litellm-api-key: Bearer sk-<your LiteLLM virtual key>     ✅ gateway auth
Authorization:     Bearer sk-ant-oat...                     ✅ ONLY for -max models
```

```http
Authorization: Bearer sk-<your LiteLLM virtual key>          ❌ never on :4000
```

Note the `Bearer ` prefix is required **inside** `x-litellm-api-key` too — LiteLLM
rejects a bare key with `Malformed API Key passed in. Ensure Key has 'Bearer ' prefix.`

Why it matters:

- Keeping the two credentials in separate headers is what lets LiteLLM tell
  "who is allowed to use the gateway" apart from "whose Claude subscription pays".
  If you authenticate with `Authorization`, LiteLLM sets
  `authenticated_with_header = "authorization"` and then *deliberately* refuses to
  forward that header upstream — so OAuth pass-through silently stops working and
  you land on whatever the model entry's own credential is.
- **The one exception is the `:8080` auth-proxy path** (the LAN/VPN ingress, the
  in-cluster `:8080` URL, and the public `litellm-warp.sargeant.co` tunnel). It
  exists because OpenAI-protocol clients *cannot* send a custom header; the nginx
  sidecar copies `Authorization` into `x-litellm-api-key` for them. Those clients
  are per-token only and can never reach the Max subscription.

Sending the gateway key in `Authorization` is not a credential-leak risk — LiteLLM's
`clean_headers()` drops any bearer that is not `sk-ant-oat…`, so your virtual key is
never forwarded to Anthropic, OpenAI, or DeepSeek. It is a **correctness** rule: it is
the difference between a `-max` call billing your subscription and failing outright.

## Warp custom inference

Warp's custom inference requests are made by Warp's backend, so the endpoint must
resolve to a public address. Do not point Warp at the LAN-only
`litellm.sargeant.co` host, because it resolves to the private Traefik address.
Use the Cloudflare Tunnel hostname instead:

```text
Base URL: https://litellm-warp.sargeant.co/v1
Model: qwen2.5-coder-7b-instruct-local
Equivalent model: gpt-4o-mini
Auth: Authorization: Bearer <dedicated LiteLLM virtual key>
```

The `litellm-warp.sargeant.co` tunnel rules only route `/v1/chat/completions`
and `/v1/models` to LiteLLM's `:8080` auth-proxy path. UI, key management,
health, and generic model-management paths fall through to `http_status:404` at
`cloudflared`. Create a dedicated LiteLLM virtual key for Warp and scope it to
the local qwen model.

## Seeing the Claude auth path in the UI

Spend alone does **not** prove whether a request used an API key or Claude Code
OAuth; LiteLLM can estimate/display spend for either path. The source of truth is
the model config:

- The Claude subscription (`-max`) models carry a deliberately invalid sentinel
  `litellm_params.api_key` (`oauth-pass-through-only-no-api-key`). **Do not "clean
  this up" by removing it.** An absent `api_key` does not mean "client must supply
  one" — LiteLLM resolves it via `AnthropicModelInfo.get_api_key(None)`, which falls
  back to the `ANTHROPIC_API_KEY` env var. Until 2026-08-12 that meant a client which
  omitted its OAuth bearer silently billed the operator's per-token Anthropic account
  while the entry advertised `billing_mode: claude-max-subscription`. The sentinel
  makes that case fail closed at Anthropic; a real `sk-ant-oat…` bearer still
  overrides it, because `optionally_handle_anthropic_oauth()` prefers the OAuth
  header and drops `x-api-key`.
- `litellm_settings.model_group_settings.forward_client_headers_to_llm_api` lists
  **only** the three `-max` groups. It used to be `general_settings.
  forward_client_headers_to_llm_api: true`, a global that forwarded every client
  `x-*` header to *every* provider (OpenAI, DeepSeek, Ollama) — not just Claude.
- `general_settings.litellm_key_header_name: x-litellm-api-key` keeps LiteLLM
  gateway auth separate from the Claude OAuth bearer token.

> **What actually carries the OAuth bearer.** Neither
> `forward_client_headers_to_llm_api` nor `forward_llm_provider_auth_headers` is what
> makes pass-through work — verified against the running 1.95.0 image.
> `_get_forwardable_headers()` only ever forwards `x-*` and `anthropic-beta`, never
> `Authorization`. The bearer travels via `add_provider_specific_headers_to_request()`,
> which is called unconditionally and is already scoped to `anthropic,bedrock,vertex_ai`
> — so a Claude OAuth token can never leak to OpenAI or DeepSeek. Do not re-add either
> flag believing pass-through depends on it. In particular
> `forward_llm_provider_auth_headers: true` lets **any** client send
> `x-api-key: <anything>` and override the deployment's configured key for **any**
> model (`litellm_pre_call_utils.py:1405`); it is intentionally unset.
- Each Claude model has `model_info.auth_mode: claude-code-oauth-pass-through` and
  `model_info.billing_mode: claude-max-subscription`; this metadata should show on
  model detail views/API responses even though it is not secret material.

### Multiple Claude subscription accounts

The `-max` entries are deliberately **account-neutral**: LiteLLM forwards the OAuth bearer each
Claude Code client supplied and never stores or selects a personal versus Enterprise Claude
account itself. Separate workloads can therefore use their own subscription account through the
same model alias and gateway virtual key. The workload, not LiteLLM, owns the routing policy;
for example Nievah selects its Enterprise bearer for `samenlevingszaken`, retries personal
Claude, then falls back to OpenHands.

If the UI does not expose the custom `model_info` fields directly, query the model
metadata through the proxy API while authenticated with the master key:

```bash
curl https://litellm.sargeant.co/model/info \
  -H "x-litellm-api-key: $LITELLM_MASTER_KEY"
```

## ⚠️ Billing: subscription vs. per-token

There are two ways the proxy talks upstream:

| Path | Who | Billing | How |
|---|---|---|---|
| **Subscription** | **Claude Code only** (incl. the diatreme dispatcher), `-max` models | Flat-rate Max plan | Claude Code sends its **OAuth** token in `Authorization`; LiteLLM relays it to Anthropic via `add_provider_specific_headers_to_request()`. Gateway is authed separately via `x-litellm-api-key`. **Omit the OAuth token and the call now fails** rather than falling through to the operator's API key. |
| **Per-token (API key)** | **Codex, OpenCode, OpenAI Agents SDK**, anything OpenAI-protocol | Per-token on a provider account | The client sends a LiteLLM virtual key in `Authorization` to the LAN/VPN or `:8080` proxy path; the proxy maps it to `x-litellm-api-key`; LiteLLM calls the provider with its configured `api_key`. |

The three tools below put a **key** in `Authorization`, so they **cannot use the
Claude Max subscription** — that's exclusive to Claude Code's OAuth. To use them
through LiteLLM you must add at least one **API-key'd model** to the proxy, e.g.:

```yaml
# kubernetes/apps/litellm/base/litellm/configmap.yaml  (model_list)
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY        # per-token on your OpenAI account
  - model_name: gemini-2.0-flash
    litellm_params:
      model: gemini/gemini-2.0-flash
      api_key: os.environ/GEMINI_API_KEY
  - model_name: claude-sonnet-api                # Claude per-token (NOT the Max plan)
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY
```

…plus the matching `ExternalSecret` entry + `Deployment` env for each key.

### Self-hosted Ollama

LiteLLM can also route to a local/self-hosted Ollama server. Prefer the
`ollama_chat/` provider prefix for chat models, and set `api_base` to the service
that can reach Ollama from the LiteLLM pod.

```yaml
# kubernetes/apps/litellm/base/litellm/configmap.yaml  (model_list)
  - model_name: qwen2.5-coder-7b-instruct-local
    litellm_params:
      model: ollama_chat/qwen2.5-coder:7b-instruct-q4_K_M
      api_base: http://ollama-lan.automation.svc.cluster.local:11434
      api_key: os.environ/OLLAMA_LAN_API_KEY
    model_info:
      mode: chat
      auth_mode: bearer-token-to-ollama-lan
      billing_mode: self-hosted
      supports_function_calling: false
```

The firefly deployment exposes the LAN Ollama server as
`ollama-lan.automation.svc.cluster.local:11434` and
`https://ollama.sargeant.co` using a selectorless Service with matching
Endpoints pointed at `192.168.19.69:11434`. Kubernetes mirrors that Endpoints
object into EndpointSlices, but Traefik needs the Endpoints backend to avoid
`503 no available server`. Store the upstream bearer token in OCI Vault as
`litellm-ollama-lan-api-key`; the repo only references it through
`ExternalSecret/automation/litellm`.

For local models, resource sizing matters more than LiteLLM config: the Ollama
host needs enough CPU/memory, and tool/function calling depends on the model's
actual capabilities. LiteLLM recommends `ollama_chat/` for better chat
responses, and its proxy config can mark a model with
`supports_function_calling: true` for tool-capable Ollama models. Keep the local
`qwen2.5-coder:7b-instruct-q4_K_M` entry marked false unless live probes return
structured OpenAI `tool_calls`; it currently emits tool-call-shaped JSON in the
assistant message content instead.

## Operational note

LiteLLM intentionally has no hard node selector. The Pi node can be too tight to
schedule a replacement pod during rolling updates, and the ingress depends on the
`auth-proxy` sidecar being present on `:8080`. The app uses a memory-oriented
resource profile because the LiteLLM process can sit around 1Gi at idle.

LiteLLM reads its YAML config at process start, and the Nginx auth-proxy mounts
its config with `subPath`. When either ConfigMap changes, update the pod-template
`checksum/config` or `checksum/auth-proxy-config` annotation in the Deployment so
Flux performs a normal rollout.

## How routing works

The client chooses the route by sending a `model` value. LiteLLM matches that value
against `model_list[].model_name`, then calls the provider/model named in
`litellm_params.model`.

```text
client model="claude-sonnet-4-6"
  -> model_list entry model_name="claude-sonnet-4-6"
  -> litellm_params.model="anthropic/claude-sonnet-4-6"
```

If multiple entries share the same `model_name`, they form a model group and the
router can load-balance between them. `router_settings.routing_strategy` controls
the picker (`simple-shuffle`, `least-busy`, `usage-based-routing`,
`latency-based-routing`, etc.), and `model_group_alias` can map a friendly or
legacy client name to a configured group. Fallbacks only happen when explicitly
configured; LiteLLM does not infer "best model for this prompt" on its own.

---

## Codex CLI

Codex CLI is an OpenAI-compatible client, so it is a good fit for API-key-backed
models behind LiteLLM. Use the LAN/VPN URL or the in-cluster `:8080` proxy path
so Codex can keep using normal `Authorization` bearer auth.

```bash
export OPENAI_BASE_URL="https://litellm.sargeant.co"   # or the in-cluster URL
export OPENAI_API_KEY="<your-litellm-virtual-key>"
codex --model gpt-4o --full-auto
```

Or persist it in `~/.codex/config.toml`:

```toml
model = "gpt-4o"
[model_providers.litellm]
name = "LiteLLM"
base_url = "https://litellm.sargeant.co/v1"
env_key = "OPENAI_API_KEY"      # Codex reads the key from this env var
```

## OpenCode

OpenCode has the same auth caveat as Codex CLI: the model entries are fine, but
the request path must use the LAN/VPN URL or the in-cluster `:8080` proxy path.

`~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": { "baseURL": "https://litellm.sargeant.co/v1" },
      "models": {
        "gpt-4o": { "name": "GPT-4o" },
        "claude-sonnet-api": { "name": "Claude Sonnet (API)" }
      }
    }
  }
}
```

Then in OpenCode run `/connect`, pick provider **LiteLLM**, and paste your LiteLLM
virtual key. Model keys must match the proxy's `model_name` values exactly. If a reasoning
model rejects params, add `additional_drop_params: ["reasoningSummary"]` to the
proxy `litellm_settings`.

## OpenAI Agents SDK (Python)

Use a LiteLLM virtual key (created in the admin UI) for client authentication.

```python
import os
from agents import Agent, Runner, ModelProvider, Model, OpenAIChatCompletionsModel, RunConfig, set_tracing_disabled
from openai import AsyncOpenAI

client = AsyncOpenAI(
    base_url=os.getenv("LITELLM_BASE_URL", "https://litellm.sargeant.co"),
    api_key=os.environ["LITELLM_API_KEY"],  # your LiteLLM virtual key
)
set_tracing_disabled(True)

class LiteLLMProvider(ModelProvider):
    def get_model(self, model_name: str | None) -> Model:
        return OpenAIChatCompletionsModel(model=model_name or "gpt-4o", openai_client=client)

# Runner.run(agent, "...", run_config=RunConfig(model_provider=LiteLLMProvider(), model="gpt-4o"))
```

Uses the Chat Completions path (not the Responses API), which LiteLLM serves for all
configured models.
