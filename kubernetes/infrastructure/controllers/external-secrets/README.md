# External Secrets Operator with OCI Vault

This setup configures External Secrets Operator (ESO) to sync secrets from Oracle Cloud Infrastructure (OCI) Vault in the eu-amsterdam-1 region to Kubernetes secrets.

## Overview

External Secrets Operator is installed in the `external-secrets` namespace and configured to connect to OCI Vault using API key authentication.

## Prerequisites

Before using this setup, you need:

1. **OCI Vault** - A vault created in OCI eu-amsterdam-1 region
2. **OCI API Credentials** - User credentials with permissions to access the vault
3. **SOPS encryption** - Ability to encrypt secrets with SOPS/AGE

## Configuration Steps

### 1. Create OCI Vault (if not exists)

In OCI Console (eu-amsterdam-1 region):
1. Go to Identity & Security > Vault
2. Create a new vault or use existing
3. Note the Vault OCID

### 2. Get OCI API Credentials

1. Go to Identity > Users > [Your User]
2. Under API Keys, add a new key or use existing
3. Download the private key (keep it secure!)
4. Copy the fingerprint (format: `aa:bb:cc:dd:ee:ff:...`)
5. Note your User OCID and Tenancy OCID

### 3. Configure the SecretStore

Edit `secret-store.yaml` and fill in:
- `spec.provider.oracle.vault`: Your Vault OCID
- `spec.provider.oracle.auth.tenancy`: Your Tenancy OCID
- `spec.provider.oracle.auth.user`: Your User OCID

Example:
```yaml
spec:
  provider:
    oracle:
      region: eu-amsterdam-1
      vault: "ocid1.vault.oc1.eu-amsterdam-1.xxxxx"
      auth:
        tenancy: "ocid1.tenancy.oc1..xxxxx"
        user: "ocid1.user.oc1..xxxxx"
```

### 4. Encrypt OCI Credentials

Edit `oci-vault-secret-enc.yaml` and fill in:
- `stringData.privateKey`: Paste your OCI API private key (entire PEM file content)
- `stringData.fingerprint`: Your API key fingerprint

Then encrypt the file:
```bash
# Make sure you have SOPS_AGE_RECIPIENTS set or .sops.yaml configured
sops -e -i oci-vault-secret-enc.yaml
```

The file will be encrypted in place with AGE encryption.

### 5. Deploy

Commit and push your changes. Flux CD will automatically:
1. Install External Secrets Operator from the Helm chart
2. Create the OCI credentials secret (decrypted by SOPS)
3. Configure the SecretStore to connect to OCI Vault

## Usage

### Creating an ExternalSecret

Once configured, you can create ExternalSecret resources to sync secrets from OCI Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: my-app-credentials  # Secret name in OCI Vault
        property: username       # Property within the secret
    - secretKey: password
      remoteRef:
        key: my-app-credentials
        property: password
```

### Creating Secrets in OCI Vault

1. Go to your Vault in OCI Console
2. Click "Create Secret"
3. Provide a name (this will be the `remoteRef.key`)
4. For structured secrets (JSON), use format:
   ```json
   {
     "username": "myuser",
     "password": "mypass"
   }
   ```
5. Use `remoteRef.property` to extract specific fields

## IAM Permissions

Your OCI user needs these permissions (create a policy in OCI):

```
Allow user <your-user> to read secret-family in compartment <compartment-name>
Allow user <your-user> to read vaults in compartment <compartment-name>
```

Or for a group:
```
Allow group <your-group> to read secret-family in compartment <compartment-name>
Allow group <your-group> to read vaults in compartment <compartment-name>
```

## Troubleshooting

### Check ESO Pod Logs
```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

### Check SecretStore Status
```bash
kubectl get secretstore -n external-secrets oci-vault -o yaml
```

### Check ExternalSecret Status
```bash
kubectl get externalsecret -n <namespace> <name> -o yaml
kubectl describe externalsecret -n <namespace> <name>
```

### Common Issues

1. **Authentication Failed**: Verify OCIDs, fingerprint, and private key are correct
2. **Permission Denied**: Check IAM policies in OCI
3. **Secret Not Found**: Verify secret exists in the specified vault and region
4. **Invalid OCID**: Ensure all OCIDs are complete and from the correct region

## References

- [External Secrets Operator Documentation](https://external-secrets.io/)
- [OCI Provider Documentation](https://external-secrets.io/latest/provider/oracle-vault/)
- [OCI Vault Documentation](https://docs.oracle.com/en-us/iaas/Content/KeyManagement/Concepts/keyoverview.htm)
