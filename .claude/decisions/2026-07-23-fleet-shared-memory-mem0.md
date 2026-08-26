# Fleet shared memory: mem0 on shared CNPG pgvector, one MCP over SSE

- Status: accepted
- Date: 2026-07-23

## Context

The fleet has no shared memory today: Hermes has private markdown memory, Holmes none,
Nievah only ephemeral Valkey keys. Caleb wants ONE store both Claude Code AND the fleet
(Hermes, OpenHands, HolmesGPT) can read/write ("speak with Claude's memory / have Claude
write to my agent memory DB"), and was unsure which of many options is best.

Archaeology found the groundwork already exists in the **retired `zoey` app** (Nievah's
"abomination" predecessor): `zoey/k8s-mem0/` has mem0-server + pgvector + Neo4j, applied by
hand (never via Flux — hence absent from this repo). `zoey` also had **OpenViking**
(volcengine context DB) — Flux-registered then retired (#442). Caleb rates OpenViking
overkill.

There are three distinct planes, and conflating them is the mistake: **routing/metering**
(LiteLLM — already have it, NOT memory), **context/hand-off** (task_context table — strongly
consistent), **durable memory** (vector — eventually consistent). LiteLLM's cache is
prompt-keyed response caching, not shared memory.

## Decision

- **mem0 (OSS)** as the shared durable-memory layer, backed by **pgvector on the existing
  shared CNPG `postgres`** (a `Database` CR `agent_memory`, NOT a new cluster). Model + embed
  calls via **LiteLLM**. Winner over Zep/Graphiti (needs Neo4j/graph DB — breaks "my
  Postgres"), Letta (wants to own the agent runtime), Cognee (documented fallback if we
  outgrow flat facts), and roll-your-own pgvector (labor). Drop Neo4j/graph — vector only.
- Exposed as **one MCP server over SSE** (the transport all four clients accept; Holmes is
  SSE-only) — every agent points at the one endpoint. **Namespacing**: shared `user_id=caleb`
  for cross-agent facts, per-agent `agent_id` for private scratch.
- Claude Code's native memory (CLAUDE.md hierarchy + machine-local auto-memory) is NOT the
  shared store; the **MCP memory server is the bridge** that lets Claude Code persist into
  the shared DB.
- **task_context** (hand-off state: issue → plan → model → approval → PR) lives in a **plain
  relational table** in the same Postgres — never in vector memory.
- Promote mem0 from Zoey-private/hand-applied to **Flux-managed** (`kubernetes/apps/mem0`).
  Do NOT resurrect OpenViking for the fleet.

## Consequences / open items
- The mem0 **container image** must be built/pushed (upstream lacks pgvector deps); ideally
  its own repo + CI. The self-hosted mem0 **MCP-over-SSE** packaging is in flux (OpenMemory
  deprecated) — storage layer lands first; the SSE MCP shim is a fast follow.
- pgvector extension is created by a bootstrap Job using the `admin` superuser (no dedicated
  superuser secret on the cluster; Database CR here has no `spec.extensions`).
- `text-embedding-3-small` + `gpt-4o-mini` added to LiteLLM so mem0's default models resolve.
