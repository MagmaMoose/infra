# Secrets Management

This repository is **public**. Every commit is world-visible, so no secret value
may ever appear in plaintext in a manifest, a ConfigMap, or a comment.

Secrets come from three places, in this order of preference:

1. **OCI Vault** via external-secrets: the default for application secrets
2. **1Password** via 1Password Connect: where a human also needs the value
3. **SOPS** (age-encrypted, `.enc.yaml`): last resort, and now only for bootstrap

## OCI Vault (preferred)

An `ExternalSecret` names a vault entry and the properties to pull from it. One
vault entry backs one Kubernetes Secret, holding a JSON object whose keys are the
Secret's keys:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: excalidraw
  namespace: misc
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: excalidraw
    creationPolicy: Owner
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: excalidraw-credentials   # the vault entry
        property: DB_PASSWORD         # a key inside its JSON
```

!!! warning "`property` is a dotted path, not a literal key"
    external-secrets resolves `property` as a nested lookup, so a key containing a
    dot silently resolves to the wrong thing and fails with
    `could not get secret data from provider`. Escape it:

    ```yaml
    property: emails\.txt     # not emails.txt
    property: key\.pem        # not key.pem
    ```

Check that a secret is syncing:

```bash
kubectl get externalsecret -A | grep -v SecretSynced   # anything listed is broken
```

## SOPS: what still uses it, and why

Most application secrets moved to OCI Vault. Fourteen files remain on SOPS
deliberately, because they cannot use the thing that would replace them:

| file(s) | why it stays |
|---|---|
| `infrastructure/configs/flux/*` | the configs tier reconciles **before** the controllers tier that contains external-secrets |
| `external-secrets/oci-vault-secret-enc.yaml` | it *is* the credential external-secrets uses to reach the vault (circular) |
| `1password-connect/*`, `cert-manager/*` | same tier as external-secrets; ordering within a tier isn't guaranteed |
| `postgres/secret.enc.yaml` | CNPG's own bootstrap credential |
| loki / *arr `configmap.yaml`, headlamp Middlewares | not `Secret`s at all; external-secrets cannot produce them |

Encrypting a new file:

```bash
sops -e secret.yaml > secret.enc.yaml
```

!!! danger "Never edit an encrypted file as text"
    The SOPS MAC covers cleartext metadata such as `namespace:`. Editing those
    fields directly breaks decryption. Round-trip through `sops -d` → edit →
    `sops -e` instead.

!!! warning "Mixed documents break the sops CLI"
    A multi-document file where only *some* documents carry a `sops:` block cannot
    be decrypted or rekeyed by the CLI at all. It aborts on the first plaintext
    field matching `encrypted_regex`. Flux's own implementation decrypts
    per-document and doesn't notice, so this fails silently and only bites during
    a key rotation. **Keep ciphertext in single-document files.**

## Rotating the age key

Two phases, so there is never a window where the cluster cannot read its own
secrets.

**Phase 1: add the new recipient.** List both keys in `.sops.yaml`, then re-wrap
every encrypted file. Derive the file list from content, not from names:

```bash
git grep -l 'ENC\[AES256_GCM' -- '*.yaml' | while read -r f; do
  sops updatekeys -y "$f"
done
```

!!! warning "A `*.enc.yaml` glob is not the file list"
    `.sops.yaml` matches `\.ya?ml$`, and several encrypted files here are named
    `configmap.yaml` or `*-secret-enc.yaml`. A name-pattern glob misses them, and
    phase 2 then makes them permanently undecryptable.

    Check for **nested** `.sops.yaml` files too: a stale one doesn't break
    existing files, it silently encrypts *new* ones to a retired key.

Add the new private key to the cluster's `flux-system/sops-keys` Secret before
proceeding, so Flux can decrypt under either key.

**Phase 2: drop the old recipient.** Only once every consumer holds the new key.
Re-run `updatekeys`, prune the old key from `sops-keys`, and verify both
directions:

```bash
sops -d <file>   # with the new key: succeeds
sops -d <file>   # with the old key: must FAIL
```

Consumers here are Flux and one laptop. No CI workflow references an age key.
