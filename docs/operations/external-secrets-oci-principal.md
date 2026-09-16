# External Secrets: a least-privilege OCI principal

Each cluster's `oci-vault` `ClusterSecretStore` should authenticate as a principal
that can read secret bundles from **its one vault** and nothing else. Today both
stores sign in with an API key that belongs to a personal user whose permissions
go far beyond that, so a leak of the in-cluster credential is worth much more
than it needs to be. This runbook replaces it without any `ExternalSecret`
losing its synced `Secret`.

Nothing in this page changes the cluster until you follow a step.

## Current state (checked 2026-09-16)

| | firefly | franklinhouse |
|---|---|---|
| Store manifest | `kubernetes/infrastructure/controllers/external-secrets/secret-store.yaml` | `kubernetes/clusters/franklinhouse/infrastructure/services/stack/external-secrets/secret-store.yaml` |
| Flux Kustomization | `infrastructure-controllers` | `infrastructure-services` |
| Tenancy / region | firefly's, `eu-amsterdam-1` | franklinhouse's own, `af-johannesburg-1` |
| Vault | `vault-prod`, tenancy root compartment (one of four active vaults there) | `vault-franklinhouse` |
| ESO runs on | `ff-pi2` (on-prem Pi) | a franklinhouse Proxmox VM |
| Credential `Secret` | `external-secrets/oci-vault-credentials` | `external-secrets/oci-vault-credentials` |
| Created by | Flux, from SOPS file `oci-vault-secret-enc.yaml` | Flux, from SOPS file `oci-vault-credentials.enc.yaml` |
| Generated with | `scripts/rebuild-oci-credentials.sh firefly` | `scripts/rebuild-oci-credentials.sh franklinhouse` |

Both generator targets read the same 1Password item that
`scripts/oci-vault-secrets.py` uses to **write** vault secrets. That shared item
is the root of the problem: the key ESO needs for reads is the key the tooling
needs for writes.

What ESO v0.11.0 actually calls (read from its Oracle provider source, and seen
in OCI Audit on firefly):

| Call | When | Permission |
|---|---|---|
| `GetSecretBundleByName` | every sync (about 5,300 a day on firefly) | `SECRET_BUNDLE_READ` |
| `GetVault` | store validation | `VAULT_READ` (optional, see below) |

Neither cluster uses `PushSecret` or `dataFrom.find`, so ESO needs no
`ListSecrets` and no write permission at all.

## Decision: a dedicated user per cluster, not instance principals

Recommended for both clusters: **(a) a dedicated IAM user, a group of one, and a
policy scoped to the vault.**

Instance principals (b) were considered and rejected:

- **ESO does not run on an OCI instance** on either cluster. An instance principal
  token only exists on OCI compute, so this would first mean pinning ESO to
  `ff-oci1`/`ff-oci2` (`ff-oci3`/`ff-oci4` are in a different tenancy) and making
  secret sync depend on the cloud nodes.
- **The existing dynamic group is far too wide.** `k3s-prod-servers` matches every
  instance in firefly's root compartment, which includes both MikroTik CHR
  routers. Its current policy is safe only because it names one secret.
- **An instance principal is shared by every pod on the node.** Any pod that can
  reach the metadata service gets the node's token, and the OCI nodes run CI
  runners that execute pull-request code. A user key in one `Secret` is readable
  by far fewer things.

Workload identity is OKE-only, so it is not available on k3s.

## The policy

In the tenancy root, for firefly (replace the domain and group for franklinhouse):

```
Allow group 'Default'/'eso-firefly-secret-readers' to read secret-bundles in tenancy where target.vault.id = '<vault OCID>'
Allow group 'Default'/'eso-firefly-secret-readers' to read vaults in tenancy where target.vault.id = '<vault OCID>'
```

- `read secret-bundles` is exactly `SECRET_BUNDLE_INSPECT` + `SECRET_BUNDLE_READ`.
  Do not write `read secret-family`: it adds secret and secret-version metadata
  ESO never uses. (`.github/actions/external-secret-vault-guard/README.md`
  documents the reverse trap: there `read secret-family` would add bundle reads
  a name-listing credential must not have.)
- `read vaults` is metadata only. ESO treats a denied `GetVault` as validation
  "Unknown" and keeps syncing, so the second statement is optional. It keeps the
  store status honest and stops a denied call every few minutes in Audit.

**The one uncertainty, and why Phase 2 exists.** OCI documents `target.vault.id`
for vaults, and `target.secret.name` / `target.secret.id` explicitly for secret
bundles. It does not say whether `target.vault.id` is populated on a bundle read.
A condition on a variable the request does not carry evaluates false, which
means **deny**. Phase 2 proves the condition before anything depends on it.

If Phase 2 is denied, do **not** fall back to `in tenancy` with no condition:
firefly's tenancy holds other vaults. Instead move the vault and its secrets into
a compartment of their own and scope by compartment, which OCI documents for
every resource type:

```
Allow group 'Default'/'eso-firefly-secret-readers' to read secret-bundles in compartment <eso-vault-compartment>
Allow group 'Default'/'eso-firefly-secret-readers' to read vaults in compartment <eso-vault-compartment>
```

Moving a vault or secret keeps its OCID, so ESO (which uses the vault OCID and the
secret name) is unaffected. The External Secrets vault guard lists one
compartment, so set its `OCI_COMPARTMENT_OCID` secret after such a move.

## Phase 1: create the principal (no cluster impact)

Run with your normal administrator OCI CLI profile. For firefly, `TENANCY` and
`VAULT` are the `auth.tenancy` and `vault` values in the store manifest.

```bash
TENANCY='<auth.tenancy from secret-store.yaml>'
VAULT='<vault from secret-store.yaml>'

# --email is required in tenancies with identity domains, and must be unique
USER_ID=$(oci iam user create --name eso-firefly --email '<unique address you control>' \
  --description 'External Secrets Operator on firefly: reads secret bundles from one vault' \
  --query data.id --raw-output)

oci iam user update-user-capabilities --user-id "$USER_ID" \
  --can-use-api-keys true --can-use-console-password false \
  --can-use-auth-tokens false --can-use-smtp-credentials false \
  --can-use-customer-secret-keys false --can-use-db-credentials false \
  --can-use-o-auth2-client-credentials false

GROUP_ID=$(oci iam group create --name eso-firefly-secret-readers \
  --description 'Only member: eso-firefly' --query data.id --raw-output)
oci iam group add-user --group-id "$GROUP_ID" --user-id "$USER_ID"

oci iam policy create --compartment-id "$TENANCY" --name eso-firefly-secret-read \
  --description 'External Secrets on firefly: read bundles from one vault' \
  --statements "[\"Allow group 'Default'/'eso-firefly-secret-readers' to read secret-bundles in tenancy where target.vault.id = '$VAULT'\", \"Allow group 'Default'/'eso-firefly-secret-readers' to read vaults in tenancy where target.vault.id = '$VAULT'\"]"
```

Generate the key locally, upload only the public half:

```bash
umask 077
openssl genrsa -out eso-firefly.pem 2048
openssl rsa -in eso-firefly.pem -pubout -out eso-firefly.pub.pem
oci iam user api-key upload --user-id "$USER_ID" --key-file eso-firefly.pub.pem \
  --query data.fingerprint --raw-output
```

Store the private key, the fingerprint and the user OCID in a **new** 1Password
item. Do not overwrite the existing item: the vault-writing tooling still needs it.

## Phase 2: prove it before anything uses it

Policies take a minute or two to propagate; retry before concluding anything.

### 2a. From the CLI

Create a throwaway secret to read, so no real value is involved:

```bash
printf canary | scripts/oci-vault-secrets.py -c firefly set eso-canary
```

Then call OCI as the new user through a temporary config:

```bash
T=$(mktemp -d) && cat > "$T/config" <<EOF
[DEFAULT]
user=$USER_ID
fingerprint=<fingerprint from the upload>
tenancy=$TENANCY
region=eu-amsterdam-1
key_file=$PWD/eso-firefly.pem
EOF
chmod 600 "$T/config"

# must succeed (prints only the content type, not the value)
oci --config-file "$T/config" secrets secret-bundle get-secret-bundle-by-name \
  --vault-id "$VAULT" --secret-name eso-canary \
  --query 'data."secret-bundle-content"."content-type"'

# must be denied: any other vault in the tenancy
oci --config-file "$T/config" secrets secret-bundle get-secret-bundle-by-name \
  --vault-id '<a different vault OCID>' --secret-name '<a secret in it>'

# must be denied: listing (ESO never needs it)
oci --config-file "$T/config" vault secret list --compartment-id "$TENANCY" --vault-id "$VAULT"

rm -rf "$T"
```

If the first call is denied while your admin profile succeeds, the
`target.vault.id` condition is not honoured for bundles: switch to the
compartment policy above and repeat.

### 2b. Through ESO, beside the live store

Apply these by hand (not through Flux). They add a second store and touch nothing
the existing `ExternalSecret`s use.

```bash
kubectl -n external-secrets create secret generic oci-vault-eso-credentials \
  --from-file=privateKey=eso-firefly.pem --from-literal=fingerprint='<fingerprint>'
```

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: oci-vault-canary
spec:
  provider:
    oracle:
      region: eu-amsterdam-1
      vault: "<vault OCID>"
      auth:
        tenancy: "<tenancy OCID>"
        user: "<eso-firefly user OCID>"
        secretRef:
          privatekey:
            name: oci-vault-eso-credentials
            namespace: external-secrets
            key: privateKey
          fingerprint:
            name: oci-vault-eso-credentials
            namespace: external-secrets
            key: fingerprint
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: oci-vault-canary
  namespace: external-secrets
spec:
  refreshInterval: 1m
  secretStoreRef:
    kind: ClusterSecretStore
    name: oci-vault-canary
  target:
    name: oci-vault-canary
  data:
    - secretKey: value
      remoteRef:
        key: eso-canary
```

Pass when the store reads `Valid` and the `ExternalSecret` reads `SecretSynced`:

```bash
kubectl get clustersecretstore oci-vault-canary
kubectl -n external-secrets get externalsecret oci-vault-canary
```

Then remove all of it. Deleting the `ExternalSecret` also deletes the `Secret` it
created; the hand-made credential `Secret` goes too, because Phase 3 recreates it
from Git:

```bash
kubectl -n external-secrets delete externalsecret oci-vault-canary
kubectl delete clustersecretstore oci-vault-canary
kubectl -n external-secrets delete secret oci-vault-eso-credentials
```

Once the key is in 1Password, delete `eso-firefly.pem` and `eso-firefly.pub.pem`.

## Phase 3: cut over in two pull requests

### 3a. Add the new credential (safe, nothing reads it)

- Add a SOPS-encrypted `Secret` named `oci-vault-eso-credentials` (keys
  `privateKey` and `fingerprint`) beside `secret-store.yaml` and list it in that
  directory's `kustomization.yaml`.
- Point `scripts/rebuild-oci-credentials.sh` at the new 1Password item for this
  target, and make the `Secret` name it writes a variable instead of the
  hard-coded `oci-vault-credentials`. Leave `scripts/oci-vault-secrets.py` on the
  old item: it writes secrets.

Merge, reconcile, and confirm the `Secret` exists.

### 3b. Switch the store

Record the baseline first. `ExternalSecret`s that already fail keep failing and
are not a regression:

```bash
kubectl get externalsecret -A -o json | jq '[.items[]
  | select(.spec.secretStoreRef.name == "oci-vault")
  | ([.status.conditions[]? | select(.type == "Ready")][0].status // "None")]
  | group_by(.) | map({(.[0]): length}) | add'
```

In **one commit**, change `secret-store.yaml`: `auth.user` to the new user OCID,
and both `secretRef.*.name` to `oci-vault-eso-credentials`. It is one object, so
ESO sees a single spec change rather than a new user paired with the old key.

After merge:

```bash
flux reconcile kustomization infrastructure-controllers -n flux-system
kubectl get clustersecretstore oci-vault
kubectl get externalsecret -A -o json \
  | jq -r '.items[] | select(.spec.secretStoreRef.name == "oci-vault") | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r ns name; do
      kubectl -n "$ns" annotate externalsecret "$name" force-sync="$(date +%s)" --overwrite
    done
```

Re-run the baseline query: the `True` count must match. In OCI Audit, the
`GetSecretBundleByName` calls should now come from `eso-firefly`.

**Why nothing loses its `Secret`:** a failed sync leaves the last synced target
`Secret` in place, and the old key stays valid until Phase 4, so `git revert` of
the store commit is a complete rollback.

## Phase 4: clean up (after a clean day or two)

- Remove the old SOPS file and its `kustomization.yaml` entry; Flux prunes the old
  `oci-vault-credentials` `Secret`.
- Before deleting the old API key, search OCI Audit for its fingerprint in
  `data.identity.credentials` over at least 30 days. If anything else still signs
  with it, move that consumer to its own principal first. Rotate any key that was
  shared with a cluster.

## franklinhouse

Same four phases, with these differences:

- Use a CLI profile for **franklinhouse's tenancy**; firefly's credentials cannot
  see it. Check what the store uses today:

  ```bash
  oci iam user list-groups --user-id '<auth.user from its secret-store.yaml>' --profile franklinhouse
  ```

- Check the identity domain name before writing the policy (`'Default'` above is
  firefly's): `oci iam domain list --compartment-id <tenancy> --profile franklinhouse`.
- Names: `eso-franklinhouse`, `eso-franklinhouse-secret-readers`; region
  `af-johannesburg-1`; vault `vault-franklinhouse`; canary via
  `scripts/oci-vault-secrets.py -c franklinhouse set eso-canary`.
- The store lives in `infrastructure-services`, so reconcile that Kustomization.
- It has two `ExternalSecret`s; record the baseline all the same.
