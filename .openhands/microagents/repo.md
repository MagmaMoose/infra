---
name: repo
type: repo
agent: CodeActAgent
---

# Monolithic Infrastructure

Home-lab infrastructure as code: Terragrunt and Terraform across GCP, OCI, AWS and
Cloudflare; Ansible for host bootstrap; FluxCD over k3s. Two clusters: `firefly`
(5 nodes, the main one) and `franklinhouse`.

## Read these first

`CLAUDE.md` is canonical and short. `AGENTS.md` is the long-form version of the same
rules. `.claude/ARCHITECTURE_MAP.md` explains how the three sources of truth relate.

Load `.claude/COMMON_MISTAKES.md` **before** touching Flux placement or labels, CNPG
Postgres, a Terragrunt leaf, a tick or cron schedule, a scanner suppression, or
anything pinned to a node. It records 30 real incidents and is not auto-loaded only
because of its size. Most review findings here are repeats of something in it.

`PROJECT_INDEX.json` maps modules, Terragrunt leaves and apps. Read it before
exploring unfamiliar directories.

## This repository is public

Every commit is world-visible. Some namespaces and some sibling repositories are
private. Work on them normally, but never name them, their workloads or their
contents in commit messages, PR text or code comments. Describe them generically,
for example "another workload on that node".

## Before proposing a change

- `kustomize build <path>` on anything under `kubernetes/`. A change that does not
  build is the finding, not a detail to mention in passing.
- `mkdocs build --strict` if you touched `./docs`. Warnings fail in strict mode.
- Branch names follow `<type>/<description>` using the Conventional Commit types:
  feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
- Keep terminal output short. Summarise build and test runs instead of pasting them,
  prefer targeted line-range reads over whole files, and do not re-read a file to
  confirm a write succeeded.

## Placement and storage

Placement is expressed as the `placement.sargeant.co/tier` label and turned into a
real nodeSelector by Kyverno at admission. Setting a nodeSelector by hand fights the
policy. The label does nothing on a HelmRelease, though Deployments beside it are
still affected, which makes that mistake hard to see.

Storage follows placement. The plain `longhorn` storage class has no node selector,
so a volume can end up with replicas on both sides of the OCI-to-home link, paying
that latency on every synchronous write. On-prem workloads use `longhorn-on-prem`.
