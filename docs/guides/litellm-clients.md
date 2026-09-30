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
Hosted alternative: gpt-5.6-luna (the only OpenAI chat model a non-OpenHands key may name)
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
Claude Max subscription**. That's exclusive to Claude Code's OAuth. To use them
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

## Virtual keys, and why clients should not use the master key

The gateway has no public self-service signup. The UI is on the LAN/VPN host only, and it
signs in with the admin credentials or an invite an admin created. SSO is the one path on
which LiteLLM creates users by itself; it is not configured, and if it ever is,
`ui_access_mode: admin_only` turns every non-admin away from the UI on that path and
`default_internal_user_params` leaves such a user on `gpt-5.6-luna` with a $0 budget. Only a
proxy admin may create a key outside a team (`key_generation_settings`, which LiteLLM reads
from `litellm_settings` only). An invited user with a password can still sign in, so invite
nobody you would not give a key to. The master key is an operator credential, not an
application credential; it can bypass model and budget allow-lists and must never be
mounted into a workload.

**The default model is `gpt-5.6-luna`.** A key created with no model list (what the UI
sends when you pick none) gets `gpt-5.6-luna` and nothing else
(`default_key_generate_params`). `gpt-5.6-terra` and `gpt-5.6-sol` form the
`openhands-only` access group, which only the `openhands` key is given.

The gateway's per-client access is virtual keys in Postgres, not anything in
`config.yaml`. Each key has an alias, a budget, and a `models` allow-list, so a compromised
client reaches only what its key names:

| Alias | Vault entry | Models | Budget per 30 days |
|---|---|---|---|
| `openhands` | `openhands-litellm-api-key` | `gpt-5.6-luna`, the fallback aliases, and the `openhands-only` group (`gpt-5.6-terra`, `gpt-5.6-sol`) | $50 |
| `nievah` | `nievah-litellm-api-key` | `claude-haiku-4-5-max`, `claude-sonnet-4-6-max`, `claude-opus-4-8-max` | none (subscription only, so no money) |
| `nievah-fallback` | `nievah-fallback-litellm-api-key` | `fallback-easy`, `fallback-medium`, `fallback-hard` (all Luna) | $25 |
| `hermes` | `hermes-litellm-api-key` | `agent-chat`, `agent-light` (Luna), the speech roles | $25 |
| `holmes` | `holmesgpt-litellm-api-key` | `agent-investigate`, `agent-light` (Luna) | $25 |
| `mem0` | `mem0-litellm-api-key` | `gpt-5.6-luna`, `text-embedding-3-small` | $10 |
| `github-contributions`, `github-timesheet`, `docs-distributor` | `<alias>-litellm-api-key` | `gpt-5.6-luna` | $10 each |

**Nievah has two keys, and they must stay two.** `nievah` is its gateway key
(`LITELLM_API_KEY`), which every primary leg presents on the Claude Max subscription. A
budget on it would count subscription tokens at list price and refuse reviews for spend
that was never money, and scoping it to the fallback aliases takes every primary leg off
Claude. `nievah-fallback` is the only key Nievah's fallback rides.

Keys are database rows, so a restore from backup brings back whatever the dump held and
nothing in Git corrects it. `kubernetes/apps/litellm/base/keyseed-job.yaml` upserts every
managed key from its OCI Vault value on each run. Bump the Job's name suffix whenever the
model list or key set changes, since Jobs are immutable. Any new workload must receive a
dedicated scoped key; never reuse the master or OpenHands key.

**A key's vault value must be one line that starts with `sk-`.** LiteLLM refuses to create
any other key and answers 401 to a client presenting one, and a trailing newline breaks the
header every client sends. `openssl rand -hex 32` gives neither, so store a new key with:

```bash
printf 'sk-%s' "$(openssl rand -hex 32)" | scripts/oci-vault-secrets.py -c firefly set <entry>
```

`set` on an entry that already exists writes a new current version, so it replaces a live
key: check whether an entry exists first. LiteLLM also requires key aliases to be unique,
so replacing a key's vault value leaves its old row holding the alias until you delete it
in the UI, and the keyseed Job's create call fails until then.

Management endpoints (`/key/*`, `/team/*`) still want the `Bearer ` prefix *inside*
`x-litellm-api-key`. Renaming the header via `litellm_key_header_name` does not change
the value grammar, and sending the bare key returns "Malformed API Key".

### Tenant keys and budgets

A key or team for a tenant is created with `models: ["tenant-metered"]`, the access group
on the per-token Claude and DeepSeek entries. Leaving `models` empty grants every model,
including the `-max` subscription entries and the Ollama models, which book $0 so no budget
ever trips on them. Put the budget on one team per tenant (`max_budget`,
`budget_duration`) rather than on a key: without an enterprise licence a key cannot be
regenerated, and replacing one resets its spend.

- **Over budget** returns HTTP 429 with `error.type` `budget_exceeded` on every route,
  `/v1/messages` included. Rate limits also return 429, so match on the type, not the status.
- **Across replicas**, spend counters, budget reservations and rate limits live in
  `valkey-oci` db 1 (`general_settings.coordination_redis`). Without it each pod counts
  alone and a budget overshoots.
- **Spend logs** keep spend, tokens and model, never request or response bodies
  (`store_prompts_in_spend_logs: false`). Rows are kept forever: no retention is set.
- **Prices are pinned** on the `tenant-metered` entries (`model_info` input, output and cache
  costs, the values in LiteLLM v1.101.0's price map). Without them each pod reads the price
  map from GitHub `main` at start, so a restart could change what a tenant is billed.
- **Read spend** with `/team/info`, `/key/info` (accepts the key's SHA-256),
  `/spend/logs/v2` and `/team/daily/activity`. `/global/spend/report` and the other
  `*/spend/report` endpoints need an enterprise licence.

## Role aliases: switching provider in one place

The house agents never name a provider model. Each asks for a role, and every role points
at the one tier, `tier-light`, defined once in the `model_list` and reused through YAML
anchors:

| Role | Called by | Model today |
|---|---|---|
| `fallback-easy`, `fallback-medium`, `fallback-hard` | Nievah, after its Claude legs fail | gpt-5.6-luna |
| `agent-chat` | Hermes: conversations and cron runs | gpt-5.6-luna |
| `agent-investigate` | HolmesGPT, including Nievah's alert investigations | gpt-5.6-luna |
| `agent-light` | cheap summarising work, such as Holmes' health checks | gpt-5.6-luna |
| `speech-to-text`, `text-to-speech` | Hermes voice on Slack | gpt-4o-mini-transcribe, gpt-4o-mini-tts |

There is one tier on purpose. A standard (`gpt-5.6-terra`) and a heavy (`gpt-5.6-sol`) tier
used to sit beside it; they were removed so that no role can reach those two models, which
are OpenHands' alone, by swapping an anchor. To move provider, point `tier-light` at another
provider entry (or write its `model`, `api_key` and pinned prices there) and update the
Deployment's `checksum/config`. Nievah, Hermes and Holmes follow on the next rollout with no
change in their own configs. A new agent should get a new role, not a provider model name.

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
