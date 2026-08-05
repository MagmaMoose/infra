# External Secret vault guard

Fails a pull request when an `ExternalSecret` names an OCI Vault secret that
does not exist, or exists but is not `ACTIVE`.

## Why

External Secrets Operator has **no per-key `optional`**. It aborts the whole
`ExternalSecret` at the first key it cannot resolve, so one wrong name leaves
the *entire* target Secret unwritten and every pod that mounts it sitting
`Pending`/`ImagePullBackOff` behind a single opaque `SecretSyncedError`.

Nothing surfaces that at pull-request time. It has cost two outages:

1. **`b5da0e6`** named two `finance` vault secrets that had never been
   provisioned. That one was *not* in a `kind: ExternalSecret` document — it was
   a HelmRelease `spec.values.externalSecret.data` map, which is why this guard
   parses those too. A guard that walked only ExternalSecret CRs would have
   missed it.
2. **dunmir-pro** was renamed from `mikrotik-minder-pro`, its remoteRefs were
   updated to `dunmir-pro-*`, and the vault entries never were. All eight refs
   404'd and the namespace was down for days.

## What it checks

| | |
|---|---|
| Sources | `kind: ExternalSecret` CRs, and HelmRelease `spec.values.**.externalSecret` blocks |
| Fields | `spec.data[].remoteRef.key`, `spec.dataFrom[].extract.key`, and HelmRelease `data` maps |
| Verdict | key absent from the vault, **or** present with a non-`ACTIVE` lifecycle state |
| Stores | allowlist, default `ClusterSecretStore/oci-vault` |

Discovery uses `git ls-files`, which excludes gitignored `.old/` and
`.claude/worktrees/` (hundreds of ExternalSecret docs across checked-out copies
of this same repo) and the docs whose fenced examples hold fictional keys.

## What it does NOT check

Stated plainly, because a guard that overpromises is worse than none:

- **Secret values.** The credential is granted `SECRET_INSPECT` only. A green
  result proves the *name* exists, not that ESO can read it.
- **`remoteRef.property`.** The parent key is verified; the property within it
  is not — that needs `GetSecretBundle`, which the credential is deliberately
  denied. Property-bearing refs are annotated in the output.
- **`dataFrom.find`.** Names no specific key, so existence is unanswerable.
  Reported as `SKIPPED`, never silently dropped. `--fail-on-unverifiable`
  promotes those to failures.
- **Keys a Helm chart hardcodes in its own templates.** Only keys named in
  values are visible; the chart itself is an external artifact and this guard
  will not do an unpinned network fetch to read it.
- **Post-merge deletion.** This is a merge-time gate. The daily scheduled run is
  what catches a secret deleted from the vault after merge.

## Running it locally

```bash
python3 .github/actions/external-secret-vault-guard/check_external_secret_refs.py \
  --path kubernetes --list
```

`--list` prints every discovered reference and exits 0 without contacting OCI —
the fastest way to see whether your manifest is being parsed as you expect.

For a full check you need the six `OCI_*` environment variables below. Without
them the guard prints `VAULT COMPARISON SKIPPED` and exits 0.

## Behaviour without credentials

Fork PRs and Dependabot do not receive secrets. The guard must never fail closed
(that reds every fork PR) and never pass silently (that makes a check look green
while doing nothing). So:

- exit code `0`
- the word `PASS` is **never** printed on this path; `SKIPPED` is never printed
  on a real pass. Two green outcomes, two distinct words.
- every reference that *would* have been checked is still listed
- a `::notice` annotation and a job-summary banner say so on every run

This is also the state before the one-time OCI setup below is done. The workflow
is safe to merge first — it just is not verifying anything yet, and says so.

## One-time OCI setup

**Read this trap first.** The obvious-looking policy is catastrophically wrong:

```
Allow group ci-vault-secret-name-reader to read secret-family in tenancy where ...   # DO NOT USE
```

`secret-family` is an aggregate over `secrets`, `secret-versions` **and
`secret-bundles`**, so `read secret-family` expands to `GetSecretBundle` — CI
could decrypt every secret value. It reads as safe to anyone skimming for
"read, not manage". Use the narrow noun `secrets`, on which no verb — not even
`manage` — can reach a bundle read, because `secret-bundles` is a separate
resource type.

1. **User.** Identity → Domains → Default → Users → Create `ci-vault-guard`.
   Under User Capabilities leave **API keys** ticked and untick everything else
   (auth tokens, SMTP credentials, console password, customer secret keys,
   OAuth client credentials).
2. **Group.** Create `ci-vault-secret-name-reader`, with `ci-vault-guard` as its
   only member.
3. **Policy.** In the root compartment, name `ci-vault-guard-secret-inspect`,
   with exactly one statement:

   ```
   Allow group 'Default'/'ci-vault-secret-name-reader' to inspect secrets in tenancy where target.vault.id = '<vault OCID>'
   ```

   That maps to one permission (`SECRET_INSPECT`) and one API (`ListSecrets`).
   Do not add statements for `vaults`, `secret-versions` or `secret-bundles`.

   Blast radius of a total leak of this credential: enumerate the secret
   **names** in one vault. Every read of a value, every write, every other
   vault and service — denied.

4. **API key.** On `ci-vault-guard` → API Keys → Add. Keep the private key.
5. **GitHub secrets** on `magmamoose/infra`:

   | Secret | Value |
   |---|---|
   | `OCI_TENANCY_OCID` | tenancy OCID |
   | `OCI_GUARD_USER_OCID` | the `ci-vault-guard` user OCID |
   | `OCI_GUARD_FINGERPRINT` | API key fingerprint |
   | `OCI_GUARD_KEY_CONTENT` | the full PEM, `BEGIN`/`END` lines included |
   | `OCI_VAULT_OCID` | vault OCID |
   | `OCI_COMPARTMENT_OCID` | OCID of the compartment that contains the vault's secrets |

   `OCI_COMPARTMENT_OCID` is required whenever the vault's secrets live in a
   sub-compartment rather than the tenancy root. `ListSecrets` is scoped to one
   compartment and is **not recursive**: if this is wrong or absent the listing
   returns zero or too few secrets, trips the `min-vault-secrets` floor, and the
   guard exits 2 on every real run. Set it to the compartment shown in
   Vault → Secrets in the OCI console.

   Optional repo variable `OCI_REGION` (defaults to `eu-amsterdam-1`).

## Verifying the guard actually works

Point it at a deliberately wrong reference and confirm a red build:

```bash
# from a scratch branch
sed -i '' 's/key: authentik-secret-key/key: authentik-secret-key-TYPO/' \
  kubernetes/apps/authentik/base/externalsecret.yaml
python3 .github/actions/external-secret-vault-guard/check_external_secret_refs.py --path kubernetes
# expect exit 1, and "nearest in vault authentik-secret-key (0.9x)"
```

The `nearest in vault` suggestion is the part that turns "a name is wrong" into
"here is the name you renamed away from".

To exercise the comparison logic with no OCI access at all, build a fixture and
pass `--vault-names-from`:

```bash
oci vault secret list --compartment-id "$TENANCY" --vault-id "$VAULT" --all \
  --output json | python3 -c 'import json,sys; [print(f"{s[chr(34)]}") for s in []]'
# TSV of: <secret-name><TAB><LIFECYCLE_STATE>
```

## Reuse from dunmir-pro

`MagmaMoose/dunmir-pro` ships its own ExternalSecret against the same vault and
was the second outage. Consume this action directly rather than copying it:

```yaml
- uses: magmamoose/infra/.github/actions/external-secret-vault-guard@<sha>
  with:
    paths: k8s
  env:
    OCI_TENANCY_OCID: ${{ secrets.OCI_TENANCY_OCID }}
    # ... same five
```
