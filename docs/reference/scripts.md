# Scripts

<!-- sources: scripts -->

Operator scripts live in `scripts/`. Run them from the repository root unless a script says
otherwise. The ones that touch real hosts follow the repo convention and take `--check`.

| Script | Purpose |
| --- | --- |
| `terragrunt-pipeline.sh` | Plan and apply driver for the Terragrunt workflow. See [Terraform delivery](../operations/terraform-delivery.md). |
| `oci-vault-secrets.py` | Read and write OCI Vault secrets for either cluster, without the console. |
| `rebuild-oci-credentials.sh` | Regenerate the SOPS-encrypted OCI API credentials Secret for a cluster. |
| `bootstrap-franklinhouse-k3s.sh` | Bootstrap the franklinhouse k3s cluster. |
| `aws-sso-auto-login.sh` | Configure and manage AWS SSO login on a workstation. |
| `oci-inspect.sh` | Gather OCIDs for existing OCI resources, to prepare Terraform imports. |
| `terraform-import-commands.sh` | Generated `terraform import` commands for OCI resources. |
| `setup-auto-shutdown.sh` | Set up automatic shutdown after 30 minutes of inactivity, on macOS. See [Auto shutdown](../operations/auto-shutdown.md). |
| `1password-ssh-config-editor-key-merger.sh` | Merge 1Password SSH keys into an SSH config. |

`scripts/Linux` and `scripts/Windows` hold platform-specific helpers.

## `oci-vault-secrets.py`

Manages secrets in the two OCI tenancies without needing an OCI profile on the machine. It
fetches each tenancy's API signing credentials from 1Password at run time into a `0700` temp
directory that's removed on exit. Nothing is written into the repo.

```bash
scripts/oci-vault-secrets.py -c <cluster> [-V <vault>] <command> [args]
```

| Flag | Required | Values | Effect |
| --- | --- | --- | --- |
| `-c`, `--cluster` | yes | `firefly`, `franklinhouse` | Which tenancy to talk to |
| `-V`, `--vault` | no | vault name | Override the cluster's default vault |

| Cluster | Region | Default vault |
| --- | --- | --- |
| `firefly` | `eu-amsterdam-1` | `vault-prod` |
| `franklinhouse` | `af-johannesburg-1` | `vault-franklinhouse` |

These are two separate OCI accounts, not two regions of one account.

| Command | Arguments | Effect |
| --- | --- | --- |
| `vaults` | none | List vaults in the tenancy |
| `list` | none | List secret names in the vault |
| `get` | `<name>` | Print a secret's value to stdout |
| `set` | `<name> [value]` | Create or update a secret. Reads stdin when `value` is omitted |
| `delete` | `<name> [days]` | Schedule deletion, default 30 days |

```bash
scripts/oci-vault-secrets.py -c franklinhouse list
cat id_ed25519 | scripts/oci-vault-secrets.py -c franklinhouse set access-control-deploy-key
```

Requires the `oci` CLI and an authenticated `op` (1Password CLI). It deliberately uses no
third-party Python packages, so it runs anywhere the `oci` CLI already does.

!!! warning "`get` prints the secret to stdout"
    Redirect it to a file or a pipe rather than letting it land in your shell history or a
    CI log. See [Secrets management](secrets-management.md) for where secrets are supposed
    to live.

## `rebuild-oci-credentials.sh`

The OCI API private keys in 1Password are stored flattened: their PEM line breaks are
spaces. Pasting one straight into a YAML block scalar produces a Secret that decrypts
cleanly but that the OCI SDK rejects with:

```text
bad configuration: PEM data was not found in buffer
```

That reads like an auth problem and isn't one. The script strips the markers, discards all
whitespace from the body, re-wraps at 64 characters, and writes the result base64-encoded
into `data:` so no YAML round-trip can reflow it. It verifies the key parses and that its
public fingerprint matches before writing.

## `bootstrap-franklinhouse-k3s.sh`

Bootstraps the franklinhouse cluster against this repo's shared `ansible/hosts.yaml`
inventory. Dry-run first, as with every playbook here:

```bash
scripts/bootstrap-franklinhouse-k3s.sh --check
```

```bash
scripts/bootstrap-franklinhouse-k3s.sh
```

!!! warning "It caches a cluster-admin token"
    First run generates a `K3S_TOKEN` and writes it to `ansible/.k3s_token`. That token is
    cluster-admin-equivalent and this repository is public. The path is gitignored. Never
    commit it.

## `aws-sso-auto-login.sh`

```bash
scripts/aws-sso-auto-login.sh [setup|login|status|startup|install|uninstall|logs|cleanup|help]
```

Configures and manages AWS SSO login with browser cleanup. Run `help` for the current
subcommand list.
