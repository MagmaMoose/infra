# External Secrets Operator - Documentation Index

Welcome! This directory contains everything you need to set up and use External Secrets Operator with OCI Vault on the firefly Kubernetes cluster.

## 📚 Documentation Files

### 🚀 Getting Started
**Start here if this is your first time:**

1. **[README.md](README.md)** - Overview and quick start guide
   - What is External Secrets Operator?
   - How it works
   - Quick examples
   - Basic usage

### 🔧 Setup Guide
**Follow this for initial configuration:**

2. **[OCI_VAULT_SETUP.md](OCI_VAULT_SETUP.md)** - Complete setup instructions
   - Part 1: Create OCI Vault
   - Part 2: Get OCI credentials
   - Part 3: Configure IAM policies
   - Part 4: Configure External Secrets
   - Part 5: Verification and testing
   - **Read this before configuring!**

### 📖 Reference Documentation
**For understanding the implementation:**

3. **[SUMMARY.md](SUMMARY.md)** - Architecture and details
   - Architecture diagram
   - Files created/modified
   - Security considerations
   - Migration paths
   - Benefits and trade-offs

### ⚡ Daily Operations
**Keep this handy for day-to-day work:**

4. **[QUICK_REFERENCE.md](QUICK_REFERENCE.md)** - Command cheat sheet
   - Essential kubectl commands
   - Creating ExternalSecrets (examples)
   - OCI Vault operations
   - SOPS operations
   - Troubleshooting tips
   - Common patterns

## 🛠️ Configuration Files

### Core Configuration
- **[kustomization.yaml](kustomization.yaml)** - Kustomize configuration
- **[secret-store.yaml](secret-store.yaml)** - ClusterSecretStore for OCI Vault
  - ⚠️ **You need to edit this** - Add OCIDs
- **[oci-vault-secret-enc.yaml](oci-vault-secret-enc.yaml)** - OCI credentials template
  - ⚠️ **You need to edit this** - Add private key and fingerprint
  - ⚠️ **Must be encrypted with SOPS before committing**

### Examples
- **[example-externalsecret.yaml](example-externalsecret.yaml)** - Example ExternalSecret

## 🔍 Verification

### Automated Verification Script
**[verify.sh](verify.sh)** - Run this to check your setup

```bash
./verify.sh
```

This script checks:
- ✓ Namespace exists
- ✓ HelmRelease deployed
- ✓ Pods running
- ✓ OCI credentials configured
- ✓ ClusterSecretStore ready
- ✓ ExternalSecrets syncing

## 📋 Quick Start Checklist

### Initial Setup (One-time)
- [ ] Read README.md for overview
- [ ] Follow OCI_VAULT_SETUP.md (all 5 parts)
- [ ] Edit secret-store.yaml with OCIDs
- [ ] Edit oci-vault-secret-enc.yaml with credentials
- [ ] Encrypt: `sops -e -i oci-vault-secret-enc.yaml`
- [ ] Commit and push
- [ ] Wait 2-3 minutes for Flux to deploy
- [ ] Run `./verify.sh` to confirm

### Creating a Secret (Repeatable)
- [ ] Create secret in OCI Vault
- [ ] Create ExternalSecret resource (see examples)
- [ ] Apply: `kubectl apply -f externalsecret.yaml`
- [ ] Verify: `kubectl get secret <name>`

## 🎯 Common Tasks

### View Your First Secret
```bash
# 1. Create in OCI Vault (via console or CLI)
# Name: test-secret
# Content: {"username": "test", "password": "pass123"}

# 2. Create ExternalSecret
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: test-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault
    kind: ClusterSecretStore
  target:
    name: test-secret
  dataFrom:
    - extract:
        key: test-secret
EOF

# 3. Verify
kubectl get secret test-secret
kubectl get secret test-secret -o yaml
```

### Troubleshoot Issues
```bash
# Check ESO logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50

# Check ClusterSecretStore
kubectl describe clustersecretstore oci-vault

# Check specific ExternalSecret
kubectl describe externalsecret -n <namespace> <name>
```

See [QUICK_REFERENCE.md](QUICK_REFERENCE.md) for more commands.

## 📞 Support & Resources

### Documentation Files (in order of importance)
1. README.md - Start here
2. OCI_VAULT_SETUP.md - Setup guide
3. QUICK_REFERENCE.md - Daily operations
4. SUMMARY.md - Deep dive
5. verify.sh - Automated checks

### External Resources
- [External Secrets Documentation](https://external-secrets.io/)
- [OCI Vault Documentation](https://docs.oracle.com/en-us/iaas/Content/KeyManagement/home.htm)
- [SOPS Documentation](https://github.com/mozilla/sops)

## 🔐 Security Notes

⚠️ **Important:**
- Never commit unencrypted credentials
- Always encrypt oci-vault-secret-enc.yaml with SOPS
- Rotate OCI API keys every 90 days
- Use read-only IAM policies
- Enable OCI audit logging

## 🎓 Learning Path

### Beginner
1. Read README.md
2. Follow OCI_VAULT_SETUP.md
3. Create a test secret
4. Review example-externalsecret.yaml

### Intermediate
1. Read SUMMARY.md
2. Review QUICK_REFERENCE.md
3. Create app-specific secrets
4. Set up secret rotation

### Advanced
1. Create namespace-specific SecretStores
2. Use secret templates
3. Implement rotation policies
4. Set up monitoring/alerting

## 📊 File Statistics

```
Total: 9 files
Documentation: 5 files (1,361 lines)
Configuration: 3 files (84 lines)
Scripts: 1 file (214 lines)
Examples: 1 file (43 lines)
```

## 🚦 Status Indicators

After setup, run `./verify.sh` to see:
- ✓ Green checkmarks = Working correctly
- ✗ Red X's = Needs attention
- ⚠ Yellow warnings = Optional or informational

## 💡 Tips

1. **Bookmark QUICK_REFERENCE.md** - You'll use it often
2. **Run verify.sh regularly** - Catch issues early
3. **Start with test secrets** - Verify setup before production
4. **Document your patterns** - Add examples for your team
5. **Monitor ExternalSecrets** - Set up alerts for failures

## 📝 Contributing

Found an issue or want to improve the docs?
- Update the relevant markdown file
- Test your changes
- Commit and push

---

**Ready to begin?** → Start with [OCI_VAULT_SETUP.md](OCI_VAULT_SETUP.md)

**Need help?** → Check [QUICK_REFERENCE.md](QUICK_REFERENCE.md) troubleshooting section

**Want details?** → Read [SUMMARY.md](SUMMARY.md)
