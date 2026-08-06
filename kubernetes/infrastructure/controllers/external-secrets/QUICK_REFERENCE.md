# Quick Reference - External Secrets with OCI Vault

## Essential Commands

### Check ESO Status
```bash
# Pods
kubectl get pods -n external-secrets

# Helm Release
kubectl get helmrelease -n external-secrets

# Logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50
```

### Check ClusterSecretStore
```bash
# Status
kubectl get clustersecretstore oci-vault

# Details
kubectl describe clustersecretstore oci-vault

# YAML
kubectl get clustersecretstore oci-vault -o yaml
```

### Manage ExternalSecrets
```bash
# List all ExternalSecrets
kubectl get externalsecret -A

# Check specific ExternalSecret
kubectl get externalsecret -n <namespace> <name>
kubectl describe externalsecret -n <namespace> <name>

# Watch sync status
kubectl get externalsecret -n <namespace> <name> -w
```

### Troubleshooting
```bash
# Check if secret was created
kubectl get secret -n <namespace> <secret-name>

# Decode secret value
kubectl get secret -n <namespace> <secret-name> -o jsonpath='{.data.username}' | base64 -d

# Force refresh
kubectl annotate externalsecret -n <namespace> <name> \
  force-sync=$(date +%s) --overwrite

# Check ESO events
kubectl get events -n external-secrets --sort-by='.lastTimestamp'
```

## Quick Create ExternalSecret

### Basic Secret
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: my-secret
  data:
    - secretKey: password
      remoteRef:
        key: my-oci-secret-name
        property: password
```

### Multiple Properties
```yaml
data:
  - secretKey: username
    remoteRef:
      key: app-credentials
      property: username
  - secretKey: password
    remoteRef:
      key: app-credentials
      property: password
  - secretKey: api-key
    remoteRef:
      key: app-credentials
      property: api-key
```

### Entire Secret as JSON
```yaml
dataFrom:
  - extract:
      key: app-credentials
```

### With Template
```yaml
target:
  name: my-secret
  template:
    type: kubernetes.io/dockerconfigjson
    data:
      .dockerconfigjson: |
        {
          "auths": {
            "https://index.docker.io/v1/": {
              "username": "{{ .username }}",
              "password": "{{ .password }}"
            }
          }
        }
data:
  - secretKey: username
    remoteRef:
      key: docker-creds
      property: username
  - secretKey: password
    remoteRef:
      key: docker-creds
      property: password
```

## OCI Vault Operations

### Create Secret (OCI CLI)
```bash
# Simple text secret
oci vault secret create-base64 \
  --compartment-id <compartment-ocid> \
  --secret-name my-secret \
  --vault-id <vault-ocid> \
  --key-id <key-ocid> \
  --secret-content-content "$(echo -n 'secret-value' | base64)"

# JSON secret
oci vault secret create-base64 \
  --compartment-id <compartment-ocid> \
  --secret-name app-credentials \
  --vault-id <vault-ocid> \
  --key-id <key-ocid> \
  --secret-content-content "$(echo -n '{"username":"user","password":"pass"}' | base64)"
```

### List Secrets
```bash
oci vault secret list \
  --compartment-id <compartment-ocid> \
  --region eu-amsterdam-1
```

### Get Secret Value
```bash
# Get secret OCID first
SECRET_OCID=$(oci vault secret list \
  --compartment-id <compartment-ocid> \
  --name my-secret \
  --query 'data[0].id' \
  --raw-output)

# Get secret bundle
oci secrets secret-bundle get \
  --secret-id $SECRET_OCID \
  --query 'data."secret-bundle-content".content' \
  --raw-output | base64 -d
```

### Update Secret
```bash
oci vault secret update-base64 \
  --secret-id <secret-ocid> \
  --secret-content-content "$(echo -n 'new-value' | base64)"
```

## SOPS Operations

### Encrypt File
```bash
sops -e -i oci-vault-secret-enc.yaml
```

### Decrypt File (view only)
```bash
sops -d oci-vault-secret-enc.yaml
```

### Edit Encrypted File
```bash
sops oci-vault-secret-enc.yaml
```

### Re-encrypt with New Key
```bash
sops updatekeys oci-vault-secret-enc.yaml
```

## Common Patterns

### Database Credentials
**OCI Vault:**
```json
{
  "host": "db.example.com",
  "port": "5432",
  "database": "mydb",
  "username": "dbuser",
  "password": "dbpass"
}
```

**ExternalSecret:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: db-credentials
  dataFrom:
    - extract:
        key: postgres-credentials
```

### API Keys
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: api-keys
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: api-keys
  data:
    - secretKey: STRIPE_API_KEY
      remoteRef:
        key: stripe-api-key
    - secretKey: SENDGRID_API_KEY
      remoteRef:
        key: sendgrid-api-key
```

### TLS Certificates
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: tls-cert
  namespace: my-app
spec:
  refreshInterval: 24h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: tls-cert
    template:
      type: kubernetes.io/tls
  data:
    - secretKey: tls.crt
      remoteRef:
        key: app-tls-cert
        property: certificate
    - secretKey: tls.key
      remoteRef:
        key: app-tls-cert
        property: private-key
```

## Validation Checklist

### Initial Setup
- [ ] ESO pods running in external-secrets namespace
- [ ] HelmRelease shows ready status
- [ ] ClusterSecretStore shows valid status
- [ ] OCI credentials secret exists and is decrypted
- [ ] Test ExternalSecret creates a secret successfully

### Per Application
- [ ] Secret exists in OCI Vault
- [ ] ExternalSecret resource created
- [ ] ExternalSecret shows synced status
- [ ] Kubernetes secret created with correct data
- [ ] Application can read the secret
- [ ] Secret refreshes on OCI Vault update

## Common Issues & Fixes

### "authentication failed"
```bash
# Verify credentials
kubectl get secret -n external-secrets oci-vault-credentials -o yaml | grep -E 'privateKey|fingerprint'

# Check ClusterSecretStore
kubectl describe clustersecretstore oci-vault | grep -A 10 Status
```
**Fix:** Verify OCIDs, fingerprint, and private key in secret-store.yaml and oci-vault-secret-enc.yaml

### "secret not found"
```bash
# List secrets in OCI
oci vault secret list --compartment-id <compartment-ocid>
```
**Fix:** Verify secret name matches exactly (case-sensitive)

### "permission denied"
```bash
# Test OCI CLI access
oci vault secret list --compartment-id <compartment-ocid>
```
**Fix:** Update IAM policies in OCI Console

### ExternalSecret stuck "Pending"
```bash
# Check ESO logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100
```
**Fix:** Usually indicates ClusterSecretStore not ready or authentication issue

## Useful Aliases

Add to `~/.bashrc` or `~/.zshrc`:
```bash
alias k=kubectl
alias kgp='kubectl get pods'
alias kges='kubectl get externalsecret'
alias kdes='kubectl describe externalsecret'
alias kgcss='kubectl get clustersecretstore'
alias keso='kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50'
```

## Emergency Procedures

### ESO Not Working - Use Manual Secret
```yaml
# Temporary fallback while fixing ESO
apiVersion: v1
kind: Secret
metadata:
  name: my-secret-fallback
  namespace: my-app
type: Opaque
stringData:
  password: "temporary-value"
```

### Rotate OCI API Key
1. Generate new API key in OCI Console
2. Update oci-vault-secret-enc.yaml with new key and fingerprint
3. Re-encrypt: `sops -e -i oci-vault-secret-enc.yaml`
4. Commit and push
5. Wait for Flux to sync (~1 minute)
6. Verify: ClusterSecretStore should remain valid
7. Delete old API key from OCI Console

### Disaster Recovery
If SOPS key is lost:
1. Create new AGE key pair
2. Update Flux SOPS configuration
3. Re-encrypt all secrets with new key
4. Redeploy

## Performance Tips

- Use `refreshInterval` wisely (default: 1h is good for most cases)
- Use `dataFrom.extract` for entire secrets instead of multiple `data` entries
- Create namespace-specific SecretStores if needed for isolation
- Monitor ESO pod resource usage and adjust resource profile if needed

## References

- Full docs: See README.md and OCI_VAULT_SETUP.md
- ESO Docs: https://external-secrets.io/
- OCI CLI: https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/
