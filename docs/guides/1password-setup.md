# 1Password Connect and Operator Setup

This guide walks you through setting up 1Password Connect server and the 1Password Kubernetes Operator on the firefly k8s cluster.

## Overview

1Password Connect provides a way to securely access and manage secrets from 1Password vaults within your Kubernetes cluster. The setup includes:

- **1Password Connect Server**: Provides a REST API for accessing 1Password items
- **1Password Operator**: Automatically syncs 1Password items to Kubernetes Secrets

## Prerequisites

- Access to a 1Password account (Business or Teams account required for Connect)
- SOPS installed locally with the age key for this repository
- kubectl configured to access the firefly cluster

## Step 1: Create 1Password Connect Server

1. Log in to your 1Password account via the web interface

2. Navigate to **Settings** → **Developer** → **Directory**

3. Click on **Infrastructure Secrets Management** and select **Other**

4. Create a new **Secrets Automation** workflow:
   - Give it a descriptive name (e.g., "Firefly K8s Cluster")
   - Select the vaults you want to make accessible to the cluster
   - Click **Create**

5. Download the following files:
   - **1password-credentials.json**: The credentials file for the Connect server
   - **Access Token**: Copy and save this token securely (you won't be able to see it again)

## Step 2: Prepare Secret Files

Create two temporary YAML files with your credentials. These will be encrypted in the next step.

### Create 1password-credentials-secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-credentials
  namespace: general-system
type: Opaque
stringData:
  1password-credentials.json: |
    {
      "verifier": {
        "salt": "...",
        "localHash": "..."
      },
      "encCredentials": {
        "kid": "...",
        "enc": "...",
        "cty": "...",
        "iv": "...",
        "data": "..."
      },
      "version": "...",
      "deviceUuid": "...",
      "uniqueKey": {
        "alg": "...",
        "ext": true,
        "k": "...",
        "key_ops": [...],
        "kty": "...",
        "kid": "..."
      }
    }
```

**Note**: Replace the entire JSON content with the actual content from your downloaded `1password-credentials.json` file.

### Create 1password-token-secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-token
  namespace: general-system
type: Opaque
stringData:
  token: <paste-your-access-token-here>
```

**Note**: Replace `<paste-your-access-token-here>` with the actual access token you saved earlier.

## Step 3: Encrypt the Secrets

Use SOPS to encrypt the secret files:

```bash
# Encrypt the credentials file
sops --encrypt \
  --age age1c5k0q4adlrst6t003whpek86c87ymkdh9num9ha22uhwftvanyds6v2ctc \
  --encrypted-regex '^(data|stringData)$' \
  1password-credentials-secret.yaml > 1password-credentials-secret.enc.yaml

# Encrypt the token file
sops --encrypt \
  --age age1c5k0q4adlrst6t003whpek86c87ymkdh9num9ha22uhwftvanyds6v2ctc \
  --encrypted-regex '^(data|stringData)$' \
  1password-token-secret.yaml > 1password-token-secret.enc.yaml
```

**Important**: Make sure you have the SOPS age key configured for the repository. If you don't have the key, contact the repository administrator.

## Step 4: Replace Placeholder Files

Replace the placeholder encrypted secret files in the repository:

```bash
# From the repository root
cp 1password-credentials-secret.enc.yaml kubernetes/_base/core/1password-connect/
cp 1password-token-secret.enc.yaml kubernetes/_base/core/1password-connect/
```

## Step 5: Clean Up

Delete the unencrypted temporary files:

```bash
rm 1password-credentials-secret.yaml
rm 1password-token-secret.yaml

# Also delete the encrypted files from your working directory
rm 1password-credentials-secret.enc.yaml
rm 1password-token-secret.enc.yaml
```

**Warning**: Do not commit the unencrypted files to the repository!

## Step 6: Commit and Deploy

Commit the changes:

```bash
git add kubernetes/_base/core/1password-connect/
git commit -m "Update 1Password Connect credentials"
git push
```

The changes will be automatically deployed to the firefly cluster via Flux CD.

## Step 7: Verify Deployment

Check that the pods are running:

```bash
# Check all 1Password Connect pods
kubectl get pods -n general-system -l app.kubernetes.io/name=1password-connect

# Expected output:
# NAME                                READY   STATUS    RESTARTS   AGE
# connect-api-xxxxxxxxxx-xxxxx        1/1     Running   0          1m
# connect-sync-xxxxxxxxxx-xxxxx       1/1     Running   0          1m
# 1password-operator-xxxxxxxxxx-xxxxx 1/1     Running   0          1m
```

Check the HelmRelease status:

```bash
kubectl get helmrelease -n general-system 1password-connect

# Expected output should show "Ready"
```

## Using 1Password Secrets in Kubernetes

### Create a OnePasswordItem Resource

Create a file `example-secret.yaml`:

```yaml
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: my-database-credentials
  namespace: default
spec:
  itemPath: "vaults/Production/items/database-credentials"
```

Apply it:

```bash
kubectl apply -f example-secret.yaml
```

### Verify the Secret

The operator will automatically create a Kubernetes Secret:

```bash
kubectl get secret my-database-credentials -n default

# View the secret (base64 decoded)
kubectl get secret my-database-credentials -n default -o jsonpath='{.data}' | jq 'map_values(@base64d)'
```

### Use the Secret in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: my-app:latest
    env:
    - name: DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: my-database-credentials
          key: password
```

## Troubleshooting

### Pods not starting

Check if secrets are properly created:

```bash
kubectl get secret -n general-system onepassword-credentials
kubectl get secret -n general-system onepassword-token
```

If the secrets don't exist, verify that SOPS decryption is working:

```bash
# Check the kustomization status
kubectl get kustomization -n flux-system core -o yaml
```

### Connect server logs

```bash
# API server logs
kubectl logs -n general-system -l app.kubernetes.io/name=connect-api

# Sync server logs
kubectl logs -n general-system -l app.kubernetes.io/name=connect-sync
```

### Operator logs

```bash
kubectl logs -n general-system -l app.kubernetes.io/name=1password-operator
```

### Common Issues

1. **"unauthorized" errors**: Check that the access token is correct and hasn't been revoked
2. **"vault not found" errors**: Verify the vault name in the itemPath matches exactly (case-sensitive)
3. **SOPS decryption failures**: Ensure the age key is properly configured in the flux-system namespace

## Security Considerations

- The `1password-credentials.json` file contains encryption keys and should be treated as sensitive
- Access tokens should be rotated periodically
- Only grant access to vaults that are needed by the cluster
- Use the principle of least privilege when creating OnePasswordItem resources
- Monitor operator logs for unauthorized access attempts

## Additional Resources

- [1Password Connect Documentation](https://developer.1password.com/docs/connect/)
- [1Password Operator Documentation](https://developer.1password.com/docs/k8s/operator/)
- [OnePasswordItem CRD Reference](https://developer.1password.com/docs/k8s/operator/reference/)
- [1Password Connect Helm Chart](https://github.com/1Password/connect-helm-charts)
