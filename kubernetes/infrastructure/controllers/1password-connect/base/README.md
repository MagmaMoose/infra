# 1Password Connect and Operator

This directory contains the configuration for deploying 1Password Connect server and the 1Password Kubernetes Operator on the firefly k8s cluster.

## Overview

- **1Password Connect**: A server that provides a REST API for accessing 1Password items
- **1Password Operator**: A Kubernetes operator that syncs 1Password items to Kubernetes Secrets

## Prerequisites

Before deploying, you need to:

1. **Create a 1Password Connect Server in your 1Password account**:
   - Go to your 1Password account settings
   - Navigate to Developer > Directory
   - Select "Other" under Infrastructure Secrets Management
   - Create a new Secrets Automation workflow (Connect server)
   - Download the `1password-credentials.json` file
   - Generate and save an access token

2. **Prepare the credential files**:

   Create a temporary file `1password-credentials-secret.yaml` (unencrypted):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: onepassword-credentials
     namespace: general-system
   type: Opaque
   stringData:
     1password-credentials.json: |
       <paste-the-entire-content-of-1password-credentials.json-here>
   ```

   Create a temporary file `1password-token-secret.yaml` (unencrypted):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: onepassword-token
     namespace: general-system
   type: Opaque
   stringData:
     token: <your-1password-connect-token-here>
   ```

3. **Encrypt the credentials using SOPS**:

   You need to have SOPS installed and configured with the age key used in this repository.

   ```bash
   # Encrypt the credentials file
   sops --encrypt \
     --age age1yj3wdeleng98w9rv46yh40ettc78r9k4r4wgnx7ja5zxmyt8qe7snjg0a0 \
     --encrypted-regex '^(data|stringData)$' \
     1password-credentials-secret.yaml > 1password-credentials-secret.enc.yaml

   # Encrypt the token file
   sops --encrypt \
     --age age1yj3wdeleng98w9rv46yh40ettc78r9k4r4wgnx7ja5zxmyt8qe7snjg0a0 \
     --encrypted-regex '^(data|stringData)$' \
     1password-token-secret.yaml > 1password-token-secret.enc.yaml
   ```

4. **Replace the placeholder files**:

   Copy the encrypted files to this directory:
   ```bash
   cp 1password-credentials-secret.enc.yaml kubernetes/_base/core/1password-connect/
   cp 1password-token-secret.enc.yaml kubernetes/_base/core/1password-connect/
   ```

5. **Clean up temporary files**:

   ```bash
   # Delete the unencrypted temporary files (IMPORTANT!)
   rm 1password-credentials-secret.yaml
   rm 1password-token-secret.yaml
   ```

## Components Deployed

- **1Password Connect Server**: Two pods (connect-api and connect-sync)
  - API server provides REST API for accessing 1Password items
  - Sync server keeps the local cache in sync with 1Password
- **1Password Operator**: Watches for OnePasswordItem CRDs and creates Kubernetes Secrets

## Configuration

The deployment includes:
- Node selector set to `type: pi` to run on Raspberry Pi nodes
- Resource limits configured for small footprint:
  - Connect API/Sync: 100m CPU request, 500m CPU limit, 256Mi-512Mi memory
  - Operator: 50m CPU request, 200m CPU limit, 128Mi-256Mi memory
- Polling interval: 600 seconds (10 minutes)
- Auto-restart enabled for the operator

## Usage

After deployment, you can create Kubernetes Secrets from 1Password items:

```yaml
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: my-secret
  namespace: default
spec:
  itemPath: "vaults/<vault_id_or_title>/items/<item_id_or_title>"
```

Apply this resource:
```bash
kubectl apply -f onepassworditem.yaml
```

The Operator will create a corresponding Kubernetes Secret:
```bash
kubectl get secret my-secret -n default
```

## Verification

After deployment, check the status:

```bash
# Check the Connect server pods
kubectl get pods -n general-system -l app.kubernetes.io/name=1password-connect

# Check the Operator pod
kubectl get pods -n general-system -l app.kubernetes.io/name=1password-operator

# Check the HelmRelease
kubectl get helmrelease -n general-system 1password-connect
```

## Troubleshooting

- **Pods not starting**: Check if secrets are properly encrypted and decrypted by SOPS
  ```bash
  kubectl get secret -n general-system onepassword-credentials
  kubectl get secret -n general-system onepassword-token
  ```

- **Connect server logs**:
  ```bash
  kubectl logs -n general-system -l app.kubernetes.io/name=connect-api
  kubectl logs -n general-system -l app.kubernetes.io/name=connect-sync
  ```

- **Operator logs**:
  ```bash
  kubectl logs -n general-system -l app.kubernetes.io/name=1password-operator
  ```

## Resources

- [1Password Connect Documentation](https://developer.1password.com/docs/connect/)
- [1Password Operator Documentation](https://developer.1password.com/docs/k8s/operator/)
- [Helm Chart Repository](https://github.com/1Password/connect-helm-charts)
