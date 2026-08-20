# Monolithic Infrastructure

Home-lab infra-as-code: Terragrunt+Terraform (GCP/OCI/Cloudflare), Ansible bootstrap, FluxCD on single-node k3s ("firefly") on a Pi. **Public repo** — every commit is world-visible. Some namespaces (notably `internal`) and some sibling repos are private: work on them normally, but never name them, their workloads or their contents in commit messages, PR text or code comments — describe them generically instead ("other workloads on the node").

@.claude/ARCHITECTURE_MAP.md
@.claude/COMMON_MISTAKES.md
@.claude/QUICK_START.md

## Load on demand
- `PROJECT_INDEX.json` — module/leaf/app map. Read before exploration.
- `AGENTS.md` — 19KB deep guide. Read for detail beyond the architecture map.
- `.claude/{decisions,sessions}/` — load only when current task touches them.

## [tooling]
- Build/test/lint output: summarise; don't echo full stdout unless a failure requires it
- grep/find/glob: matching paths + relevant lines only, no surrounding context unless asked
- Shell output >50 lines: store full to `.claude/last_output.txt`, reference by path
- Prefer targeted line-range reads over whole-file reads
- Don't re-read files to "verify" after a write — trust Edit/Write

## [maintenance]
- Bug >1h to fix → append to `COMMON_MISTAKES.md`
- Architectural decision → ADR at `.claude/decisions/YYYY-MM-DD-<topic>.md`
- New module/refactor → regenerate affected `PROJECT_INDEX.json` section
- New pattern/convention → also update `AGENTS.md` (def-of-done)
- End of meaningful session → write `.claude/sessions/YYYY-MM-DD-<slug>.md` from `TEMPLATE.md`, <300 tokens
