# Local development

<!-- sources: .pre-commit-config.yaml, requirements-docs.txt, .github/workflows, mkdocs.yml -->

Everything here is declarative. There's no application to build and no test suite to run:
"testing a change" means rendering it and diffing the result against what's live.

## Tools

```bash
brew install ansible terraform terragrunt helm kubectl kustomize flux sops pre-commit
```

`kustomize` and `flux` aren't in the historical README list but both appear in the commands
below, so install them too.

## Pre-commit

Pre-commit must pass before a commit lands. Two hook sets run:

| Repo | Hook | Covers |
| --- | --- | --- |
| `calebsargeant/pre-commit-hooks` | `all` | SHA pinning, branch-name hygiene, general checks |
| `MagmaMoose/chargate` | `chargate` | The security gate, on staged files |

```bash
pre-commit install
```

```bash
pre-commit run --all-files
```

!!! warning "`--all-files` samples when nothing is staged"
    A green run with an empty index doesn't prove the whole repo is clean. Stage the files
    you changed and run it again before you trust it.

## Rendering Kubernetes changes

Flux applies what `kustomize build` renders, so render it yourself first:

```bash
kustomize build kubernetes/clusters/firefly | head
```

After any change to a workload's `kind` or `name`, re-render and diff against the previous
output. A `patches:` target that matches nothing fails silently. See
[Troubleshooting](../operations/troubleshooting.md#a-kustomize-patch-silently-stopped-applying).

## Rendering Terraform changes

```bash
bash scripts/terragrunt-pipeline.sh discover changed <file-with-changed-paths>
```

```bash
cd terraform/oci/prod/eu-amsterdam-1/network
terragrunt plan
```

Don't edit `backend.tf` or `provider.tf`. Terragrunt generates both with
`if_exists = overwrite`. Change `terraform/root.hcl` instead.

## Ansible

Always dry-run against a real host first:

```bash
cd ansible && ansible-playbook -i hosts.yaml <playbook>.yml --check
```

## Docs

```bash
pip install -r requirements-docs.txt
```

```bash
mkdocs build --strict
```

```bash
mkdocs serve
```

Strict mode turns a broken internal link or a nav entry pointing at a missing file into a
build failure, which is what you want before you push.

## Conventions

- Branch names are `<type>/<description>`, using the Conventional Commits types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- This repository is **public**. Every commit is world-visible. Never commit a plaintext
  secret, and rotate immediately if one lands.
- Secrets go to OCI Vault first, 1Password second, and SOPS only as a last resort, in
  `.enc.yaml` files. See [Secrets management](../reference/secrets-management.md).
- One Terragrunt leaf is one project and one state file.

## What CI will check

| Check | Blocks a PR when |
| --- | --- |
| Placement | A `placement.sargeant.co` label can't reach a pod template |
| External Secrets | An `ExternalSecret` `remoteRef` doesn't resolve in OCI Vault |
| Security | The PR diff introduces a new finding |
| Terragrunt | A plan fails on any affected leaf |

See [GitHub Actions workflows](../reference/github-workflows.md).
