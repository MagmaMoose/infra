# External-DNS Multi-Provider Setup - Implementation Summary

## What Was Implemented

This implementation adds support for multiple External-DNS providers to the Firefly Kubernetes cluster:

1. **CloudFlare Provider** - Manages DNS records for the `sargeant.co` domain (existing functionality preserved)
2. **MikroTik Provider** - Manages DNS records on a local MikroTik router via webhook provider

## Changes Made

### 1. Restructured External-DNS Configuration

**Before:**
- Single `external-dns` directory with CloudFlare configuration

**After:**
- `external-dns-cloudflare/` - Dedicated CloudFlare provider configuration
- `external-dns-mikrotik/` - Dedicated MikroTik webhook provider configuration

### 2. CloudFlare Provider (`kubernetes/_base/core/external-dns-cloudflare/`)

Files created:
- `helmrelease.yaml` - External-DNS Helm chart configured for CloudFlare
- `kustomization.yaml` - Kustomize configuration
- `README.md` - Documentation for CloudFlare provider

Configuration:
- Provider: `cloudflare`
- Domain Filter: `sargeant.co`
- Secret: `cloudflared-token` (existing secret, unchanged)
- TXT Owner ID: `firefly-k8s`

### 3. MikroTik Provider (`kubernetes/_base/core/external-dns-mikrotik/`)

Files created:
- `webhook-deployment.yaml` - Kubernetes Deployment and Service for the MikroTik webhook server
  - Image: `ghcr.io/mirceanton/external-dns-provider-mikrotik:v1.4.10`
  - Service: `external-dns-mikrotik-webhook` on port 8888
- `helmrelease.yaml` - External-DNS Helm chart configured for webhook provider
- `mikrotik-credentials-secret.enc.yaml` - Secret with MikroTik router credentials (needs encryption)
- `kustomization.yaml` - Kustomize configuration
- `README.md` - Comprehensive documentation for MikroTik provider setup

Configuration:
- Provider: `webhook`
- Webhook URL: `http://external-dns-mikrotik-webhook.core.svc.cluster.local:8888`
- Domain Filter: `local` (can be customized)
- TXT Owner ID: `firefly-mikrotik`

### 4. Updated Cluster Configuration

Modified:
- `kubernetes/clusters/firefly/core/kustomization.yaml` - Updated to reference both providers

Created:
- `kubernetes/clusters/firefly/core/external-dns-cloudflare/kustomization.yaml`
- `kubernetes/clusters/firefly/core/external-dns-mikrotik/kustomization.yaml`

## Next Steps Required

### 1. Configure MikroTik Router Credentials

The file `kubernetes/_base/core/external-dns-mikrotik/mikrotik-credentials-secret.enc.yaml` contains placeholder credentials. The `.enc.yaml` extension indicates this file must be encrypted with SOPS before deployment. You need to:

1. Update the credentials with your actual MikroTik router details:
   ```yaml
   baseurl: "https://<your-mikrotik-ip>:8729"  # Your router IP and API port
   username: "external-dns"  # Your MikroTik username
   password: "your-secure-password"  # Your MikroTik password
   ```

2. Encrypt the file in place with SOPS:
   ```bash
   cd kubernetes/_base/core/external-dns-mikrotik
   sops --encrypt --in-place mikrotik-credentials-secret.enc.yaml
   ```

3. Commit the encrypted file to the repository

### 2. Configure MikroTik Router

On your MikroTik router, you need to:

1. Create a dedicated user for External-DNS:
   ```routeros
   /user add name=external-dns password=your-secure-password group=full comment="External-DNS API user"
   ```

2. Ensure the HTTPS REST API is enabled:
   ```routeros
   /ip service print
   /ip service enable www-ssl
   ```

### 3. Customize Domain Filters (Optional)

Edit `kubernetes/_base/core/external-dns-mikrotik/helmrelease.yaml` to set your local domain:
```yaml
domainFilters:
  - home.arpa  # Or your preferred local domain
  - local
```

### 4. Deploy to Cluster

Once the credentials are encrypted and configured:
1. FluxCD will automatically detect and apply the changes
2. Monitor the deployment:
   ```bash
   kubectl get pods -n core -l app.kubernetes.io/name=external-dns-cloudflare
   kubectl get pods -n core -l app.kubernetes.io/name=external-dns-mikrotik
   kubectl get pods -n core -l app.kubernetes.io/name=external-dns-mikrotik-webhook
   ```

3. Check logs for any issues:
   ```bash
   kubectl logs -n core -l app.kubernetes.io/name=external-dns-cloudflare
   kubectl logs -n core -l app.kubernetes.io/name=external-dns-mikrotik
   kubectl logs -n core -l app.kubernetes.io/name=external-dns-mikrotik-webhook
   ```

## How It Works

### CloudFlare Provider
- Watches Kubernetes Ingress and Service resources
- Creates/updates/deletes DNS records in CloudFlare for the `sargeant.co` domain
- Uses the existing `cloudflared-token` secret for authentication

### MikroTik Provider
- **Webhook Server**: A deployment running the MikroTik webhook provider that communicates with the MikroTik router via REST API
- **External-DNS**: Watches Kubernetes resources and communicates with the webhook server
- The webhook server translates External-DNS requests into MikroTik API calls
- Creates/updates/deletes DNS static entries on the MikroTik router

### Usage Example

To create a DNS record managed by External-DNS, simply create an Ingress or Service:

**For CloudFlare (public DNS):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  rules:
    - host: my-app.sargeant.co
      # ... rest of config
```

**For MikroTik (local DNS):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-app.local
spec:
  type: LoadBalancer
  # ... rest of config
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Firefly Cluster                          │
│                                                               │
│  ┌──────────────────────┐       ┌──────────────────────┐   │
│  │ external-dns         │       │ external-dns         │   │
│  │ (CloudFlare)         │       │ (MikroTik)           │   │
│  │                      │       │                      │   │
│  │ - Watches Ingresses  │       │ - Watches Ingresses  │   │
│  │ - Watches Services   │       │ - Watches Services   │   │
│  └──────┬───────────────┘       └──────┬───────────────┘   │
│         │                              │                     │
│         │                              │                     │
│         │                        ┌─────▼─────────────────┐  │
│         │                        │ mikrotik-webhook      │  │
│         │                        │ :8888                 │  │
│         │                        │                       │  │
│         │                        │ - Translates requests │  │
│         │                        │ - MikroTik REST API   │  │
│         │                        └─────┬─────────────────┘  │
│         │                              │                     │
└─────────┼──────────────────────────────┼─────────────────────┘
          │                              │
          │                              │
          ▼                              ▼
   CloudFlare DNS                  MikroTik Router
   (sargeant.co)                   (local DNS)
```

## Benefits

1. **Automatic DNS Management**: No manual DNS record updates needed
2. **Multi-Environment**: Public DNS (CloudFlare) and local DNS (MikroTik) managed simultaneously
3. **GitOps Friendly**: All DNS records are declared in Kubernetes manifests
4. **Safe Operations**: TXT registry prevents accidental deletion of manually created records
5. **Flexible**: Each provider can have different domain filters and policies

## Troubleshooting

See the individual README files in each provider directory for detailed troubleshooting steps:
- `kubernetes/_base/core/external-dns-cloudflare/README.md`
- `kubernetes/_base/core/external-dns-mikrotik/README.md`

## References

- [External-DNS Documentation](https://github.com/kubernetes-sigs/external-dns)
- [Bitnami External-DNS Helm Chart](https://github.com/bitnami/charts/tree/main/bitnami/external-dns)
- [mirceanton/external-dns-provider-mikrotik](https://github.com/mirceanton/external-dns-provider-mikrotik)
