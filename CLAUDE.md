# Monolithic Infrastructure

Home-lab infra-as-code: Terragrunt+Terraform (GCP/OCI/AWS/Cloudflare), Ansible bootstrap, FluxCD
over k3s ("firefly", 5 nodes) plus a second cluster (franklinhouse). **Public repo** — every commit
is world-visible. Some namespaces (notably `internal`) and some sibling repos are private: work on
them normally, but never name them, their workloads or their contents in commit messages, PR text
or code comments — describe them generically instead ("other workloads on the node").

`CLAUDE.md` is canonical. `AGENTS.md` is the long-form guide for agents that auto-load it; when a
rule changes, change it in both.

@.claude/ARCHITECTURE_MAP.md
@.claude/QUICK_START.md

## Load on demand
- `.claude/COMMON_MISTAKES.md` — 30 recorded incidents, each symptom → cause → what to do instead.
  **Read it before touching** Flux placement/labels, CNPG Postgres, a Terragrunt leaf, a tick or
  cron schedule, a scanner suppression, or anything pinned to a node. It is deliberately NOT
  auto-loaded: at ~3,900 tokens it cost more per session than everything else here combined.
- `PROJECT_INDEX.json` — module/leaf/app map. Read before exploring unfamiliar code.
- `AGENTS.md` — deep guide. Read for detail beyond the architecture map.
- `.claude/{decisions,sessions}/` — load only when the current task touches them.

## [tooling]
- Build/test/lint output: summarise; don't echo full stdout unless a failure requires it
- grep/find/glob: matching paths + relevant lines only, no surrounding context unless asked
- Shell output >50 lines: store full to `.claude/last_output.txt`, reference by path
- Prefer targeted line-range reads over whole-file reads
- Don't re-read files to "verify" after a write — trust Edit/Write

## [maintenance]
- Bug >1h to fix → append to `.claude/COMMON_MISTAKES.md`
- Architectural decision → ADR at `.claude/decisions/YYYY-MM-DD-<topic>.md` (run `/adr`)
- Public behaviour/API/config/setup changed → sync `./docs` (run `/claude-skills:docs-update`)
- New module/refactor → regenerate the affected `PROJECT_INDEX.json` section, update `generated`
- New pattern/convention → also update `AGENTS.md` (def-of-done)
- End of meaningful session → `.claude/sessions/YYYY-MM-DD-<slug>.md` from `sessions/TEMPLATE.md`,
  <300 tokens (run `/session-summary`)
- Keep this file + its `@`-imports under ~1,000 tokens; push detail into on-demand `.claude/` files
