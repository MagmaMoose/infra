# OCI Vault Setup Guide

This guide walks you through setting up OCI Vault and configuring it for use with External Secrets Operator.

## Part 1: OCI Vault Setup

### 1.1 Create a Vault in OCI Console

1. Log in to OCI Console: https://cloud.oracle.com/
2. Navigate to: **Identity & Security** > **Vault**
3. Select **eu-amsterdam-1** region (top right corner)
4. Click **Create Vault**
5. Fill in:
   - **Name**: `firefly-secrets` (or your preferred name)
   - **Compartment**: Select your compartment
   - **Make it a virtual private vault**: Leave unchecked (unless you need VCN-private access)
6. Click **Create Vault**
7. Once created, copy the **Vault OCID** - you'll need this for the SecretStore config

### 1.2 Create Test Secret in Vault

1. Open your newly created vault
2. Click **Secrets** in the left menu
3. Click **Create Secret**
4. Fill in:
   - **Name**: `test-secret`
   - **Description**: Test secret for ESO
   - **Encryption Key**: Select the master encryption key for your vault
   - **Secret Type Template**: Plain-Text
   - **Secret Contents**: Enter JSON like:
     ```json
     {
       "username": "testuser",
       "password": "testpass123"
     }
     ```
5. Click **Create Secret**

## Part 2: OCI User and API Key Setup

### 2.1 Get Your User OCID

1. In OCI Console, click your profile icon (top right)
2. Click your username
3. Copy your **User OCID** (format: `ocid1.user.oc1..xxxxx`)

### 2.2 Get Your Tenancy OCID

1. Click the hamburger menu (top left)
2. Go to **Governance & Administration** > **Tenancy Details**
3. Copy the **Tenancy OCID** (format: `ocid1.tenancy.oc1..xxxxx`)

### 2.3 Create API Key

1. Go back to your user profile: Profile Icon > Your Username
2. In the left menu, click **API Keys**
3. Click **Add API Key**
4. Choose **Generate API Key Pair**
5. Click **Download Private Key** - save this file securely!
6. Click **Add**
7. Copy the **Fingerprint** that appears (format: `aa:bb:cc:dd:...`)

**Important**: Keep the private key file safe! You'll need its contents for the Kubernetes secret.

## Part 3: IAM Policy Setup

### 3.1 Create Policy for Secret Access

1. In OCI Console, go to **Identity & Security** > **Policies**
2. Select your compartment
3. Click **Create Policy**
4. Fill in:
   - **Name**: `firefly-external-secrets-policy`
   - **Description**: Policy for External Secrets Operator to read vault secrets
   - **Policy Builder**: Toggle to **Show manual editor**
   - **Policy Statements**:
     ```
     Allow user [YOUR_USER_EMAIL] to read secret-family in compartment [COMPARTMENT_NAME]
     Allow user [YOUR_USER_EMAIL] to read vaults in compartment [COMPARTMENT_NAME]
     ```

     Or if using a group:
     ```
     Allow group firefly-admins to read secret-family in compartment [COMPARTMENT_NAME]
     Allow group firefly-admins to read vaults in compartment [COMPARTMENT_NAME]
     ```
5. Click **Create**

### 3.2 Verify Permissions

To verify your user has the correct permissions, you can use the OCI CLI:

```bash
oci vault secret list \
  --compartment-id <compartment-ocid> \
  --region eu-amsterdam-1
```

If this works, your permissions are correctly configured.

## Part 4: Configure External Secrets Operator

### 4.1 Update secret-store.yaml

Edit `kubernetes/infrastructure/controllers/external-secrets/secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: oci-vault
spec:
  provider:
    oracle:
      region: eu-amsterdam-1
      # Replace with your Vault OCID from Part 1.1
      vault: "ocid1.vault.oc1.eu-amsterdam-1.amaaaaaa..."
      auth:
        # Replace with your Tenancy OCID from Part 2.2
        tenancy: "ocid1.tenancy.oc1..aaaaaaaaa..."
        # Replace with your User OCID from Part 2.1
        user: "ocid1.user.oc1..aaaaaaaaa..."
        secretRef:
          privatekey:
            name: oci-vault-credentials
            namespace: external-secrets
            key: privateKey
          fingerprint:
            name: oci-vault-credentials
            namespace: external-secrets
            key: fingerprint
```

### 4.2 Update oci-vault-secret-enc.yaml

1. Open the private key file you downloaded in Part 2.3
2. Copy its entire contents (including BEGIN/END lines)
3. Edit `kubernetes/infrastructure/controllers/external-secrets/oci-vault-secret-enc.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: oci-vault-credentials
  namespace: external-secrets
type: Opaque
stringData:
  privateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEA... (paste your actual private key here)
    ...
    -----END RSA PRIVATE KEY-----
  fingerprint: "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"  # Your actual fingerprint
```

### 4.3 Encrypt the Secret

```bash
cd kubernetes/infrastructure/controllers/external-secrets
sops -e -i oci-vault-secret-enc.yaml
```

The file will be encrypted with AGE and safe to commit to Git.

### 4.4 Commit and Deploy

```bash
git add .
git commit -m "Configure OCI Vault for External Secrets"
git push
```

Flux CD will automatically deploy the changes within a few minutes.

## Part 5: Verification

### 5.1 Check ESO Installation

```bash
# Check namespace
kubectl get ns external-secrets

# Check helm release
kubectl get helmrelease -n external-secrets

# Check pods
kubectl get pods -n external-secrets

# Check logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

### 5.2 Check ClusterSecretStore

```bash
kubectl get clustersecretstore oci-vault

kubectl describe clustersecretstore oci-vault
```

Look for status indicating it's ready and can connect to OCI.

### 5.3 Test with ExternalSecret

Create a test ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: test-oci-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: test-oci-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: test-secret
        property: username
    - secretKey: password
      remoteRef:
        key: test-secret
        property: password
```

Apply it:
```bash
kubectl apply -f test-external-secret.yaml
```

Check if the secret was created:
```bash
kubectl get secret test-oci-secret -o yaml
kubectl get externalsecret test-oci-secret
kubectl describe externalsecret test-oci-secret
```

The secret should contain the values from your OCI Vault!

## Troubleshooting

### Error: "authentication failed"

- Verify User OCID, Tenancy OCID are correct
- Verify fingerprint matches the API key
- Verify private key is complete and unmodified
- Check that the secret was decrypted correctly by Flux (check sops-keys secret exists)

### Error: "permission denied"

- Verify IAM policy is created and active
- Verify user/group has the policy applied
- Try listing secrets via OCI CLI to confirm permissions

### Error: "secret not found"

- Verify the secret exists in the specified vault
- Verify the vault OCID is correct
- Verify you're using the correct region (eu-amsterdam-1)
- Check that the secret name matches exactly (case-sensitive)

### Error: "invalid OCID"

- Verify OCIDs are complete (not truncated)
- Verify OCIDs are from the correct region
- Ensure no extra spaces or quotes in the YAML

## Best Practices

1. **Rotate API Keys Regularly**: Create new API keys every 90 days
2. **Use Groups**: Instead of user-level policies, use groups for better access management
3. **Audit Access**: Enable OCI audit logs to track secret access
4. **Separate Vaults**: Use different vaults for different environments (dev/staging/prod)
5. **Version Secrets**: OCI Vault supports secret versioning - use it!
6. **Monitor ExternalSecrets**: Set up alerts for failed syncs
7. **Backup SOPS Keys**: Ensure your AGE private key is backed up securely

## Next Steps

Once verified, you can:
1. Create additional secrets in OCI Vault
2. Create ExternalSecrets in your application namespaces
3. Migrate existing SOPS-encrypted secrets to OCI Vault
4. Set up rotation policies in OCI Vault
5. Configure multiple ClusterSecretStores for different vaults/regions
