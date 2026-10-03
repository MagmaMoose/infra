# Terraform delivery

<!-- sources: .github/workflows/terragrunt.yml, scripts/terragrunt-pipeline.sh, .github/workflows/terrateam.yml -->

Terraform changes reach the clouds through the **Terragrunt GitHub Actions workflow**. It
plans on every pull request that touches `terraform/**` and applies from `main` behind a
protected environment.

Atlantis used to do this job and was removed on 2026-09-16.

## Which system actually runs

| System | Where it's defined | State today |
| --- | --- | --- |
| Terragrunt workflow | `.github/workflows/terragrunt.yml` + `scripts/terragrunt-pipeline.sh` | **The gate.** Runs on every pull request touching `terraform/**`, plus a weekday drift schedule and `workflow_dispatch`. |
| Terrateam | `.github/workflows/terrateam.yml` | `workflow_dispatch` only, driven by the Terrateam backend. Not part of the normal path. |

## Why the workflow replaced Atlantis

Atlantis decided what to plan from each project's `when_modified` globs, which only saw that
project's own subtree. Edits to `terraform/root.hcl`, a `region.hcl`, or anything under
`terraform/modules/` change the rendered config of leaves that don't contain the edited file,
so those leaves were silently **not** planned and had to be triggered by hand.

`scripts/terragrunt-pipeline.sh` closes that gap. When a changed file matches the root
include, a shared module, or the pipeline itself, it replans **every** leaf rather than
trying to reason about which ones are affected.

## The pipeline script

The workflow is a thin wrapper around one script, kept separate so you can run exactly what
CI runs. That reproducibility is most of what made Atlantis failures hard to debug.

```bash
bash scripts/terragrunt-pipeline.sh discover all
```

| Subcommand | Arguments | Output |
| --- | --- | --- |
| `discover all` | none | Every leaf, one repo-relative path per line |
| `discover changed` | `<changed-files-file>` | Only the leaves affected by those files |
| `lan-stacks` | none | The leaves that plan on the self-hosted pool, one per line. Fails if an entry isn't a leaf |
| `plan` | `<stack> <outdir>` | Writes `<outdir>/status` and `<outdir>/plan.txt` |
| `apply` | `<stack> <outdir>` | Writes `<outdir>/status` |
| `redact` | `<file>` | Strips sensitive-looking lines, to stdout |

`status` is one of `none`, `changes`, or `failed`.

A leaf is any directory with its own `terragrunt.hcl` that isn't the shared root include and
isn't inside a `.terragrunt-cache`. That cache exclusion matters: Terragrunt copies each
unit's `terragrunt.hcl` into the cache, so a naive `find` returns every leaf twice and CI
plans phantom stacks that vanish the moment the cache is cleared.

## Job flow

```mermaid
flowchart TD
    T[PR or push to main] --> D[discover]
    D -->|has_stacks == false| X[no stacks, workflow ends]
    D -->|matrix of leaves| P[plan, one job per leaf]
    P -->|pull request| CM[plan posted to the PR]
    P -->|push to main, all plans succeeded| A[apply]
    A -->|environment: all/deploy| H[human approval]
```

Three jobs:

- **`discover`** builds the matrix of leaves to plan, on `ubuntu-latest`. It carries a fork
  guard: pull requests from forks are skipped entirely, because the jobs after it hold private
  cloud credentials and some of them run on self-hosted runners.
- **`plan`** runs one job per leaf and posts the result to the pull request. Most leaves plan
  on `ubuntu-latest`; see [Where plans run](#where-plans-run).
- **`apply`** runs on the `firefly-amd64` runner scale set, only on `push` to `main`, only
  when every plan succeeded, and only inside the protected `all/deploy` environment, which is
  where the human approval lives. It runs `max-parallel: 1` with `fail-fast: false`.

!!! note "The runner name is not a label"
    `runs-on: firefly-amd64` is an actions-runner-controller **scale set name**, not a label
    array. ARC matches jobs to scale sets by name only, so `[self-hosted, Linux, X64]` would
    never be picked up even though those labels describe the runner accurately.

## Where plans run

A plan runs on GitHub-hosted `ubuntu-latest` unless its leaf is in `LAN_STACKS` in
`scripts/terragrunt-pipeline.sh`. This repository is public, so hosted minutes are free, and
the self-hosted amd64 pool is a single node shared with every repository in the organisation.
The listed leaves have a provider that connects to a device only the home network can reach,
so they plan on `firefly-amd64`:

| Leaf | What it connects to |
| --- | --- |
| `terraform/fortigate/prod` | `fortios`: the FortiGates' management addresses on the home LAN |
| `terraform/mikrotik/prod` | `routeros`: the CRS switches on the home LAN |
| `terraform/mikrotik/wireguard-mesh/prod` | `routeros`: ff-crs1 on the home LAN, plus the CHRs |
| `terraform/oci/prod/eu-amsterdam-1/mikrotik` | `routeros`: the CHRs' API port, which the OCI security list only opens to the operator management CIDRs |

Every other leaf only calls public cloud APIs. `terraform/oci/prod/eu-amsterdam-1/vpn-fortigate`
is one of them despite its name: it creates the OCI side of the VPN and never talks to a
FortiGate.

The plan matrix lists the `LAN_STACKS` leaves last. Plans run one at a time, so a LAN plan
waiting on a busy self-hosted runner can't hold up the hosted plans after it.

A new leaf whose provider talks to on-prem hardware has to be added to `LAN_STACKS`. On a
hosted runner its plan fails at provider connect, which looks like a network outage.
`discover` fails if a `LAN_STACKS` entry isn't a leaf, so renaming one breaks loudly rather
than quietly moving it to a hosted runner.

The `plan` job installs the pinned `tofu` and `terragrunt` versions on both runner types and
caches them with `actions/cache`, keyed on both versions.

## Running a plan yourself

```bash
bash scripts/terragrunt-pipeline.sh discover all
bash scripts/terragrunt-pipeline.sh plan terraform/oci/prod/eu-amsterdam-1/network /tmp/out
cat /tmp/out/status
cat /tmp/out/plan.txt
```

To plan a single leaf directly, without the pipeline:

```bash
cd terraform/oci/prod/eu-amsterdam-1/network
terragrunt plan
```

## Verify

After a merge to `main`, check the run and the approval:

```bash
gh run list --workflow Terragrunt --limit 5
```

An apply that's waiting shows as in progress with the `all/deploy` environment pending
review. Approve it from the run page.

## Rollback

Revert the pull request and let the workflow apply the reverted state. There's no
out-of-band apply path: the protected environment is the only place credentials are handed
out, and applying from a laptop bypasses the approval that the environment exists to
enforce.
