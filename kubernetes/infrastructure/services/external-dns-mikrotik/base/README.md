# External-DNS MikroTik Provider

This directory contains the configuration for the External-DNS MikroTik webhook provider, which enables automatic DNS record management in MikroTik routers for Kubernetes resources.

## Overview

The MikroTik provider consists of two components:

1. **Webhook Provider**: A deployment running the `external-dns-provider-mikrotik` webhook server
2. **External-DNS**: A HelmRelease that connects to the webhook to manage DNS records

## Prerequisites

- MikroTik router running RouterOS 7.16 or later
- A dedicated RouterOS user with **read** and **write** permissions for DNS
- MikroTik REST API enabled (typically on port 8729 for HTTPS)

## Configuration

### 1. MikroTik Router Setup

Create a dedicated user on your MikroTik router:

```routeros
/user add name=external-dns password=your-secure-password group=full comment="External-DNS API user"
```

Ensure the REST API is enabled:

```routeros
/ip service print
# If HTTPS API (www-ssl) is disabled, enable it:
/ip service enable www-ssl
```

### 2. Update the Secret

The `mikrotik-credentials-secret.enc.yaml` file contains placeholder credentials. The `.enc.yaml` extension indicates this file must be encrypted with SOPS before deployment.

1. Update the values with your actual MikroTik router details:
   - `baseurl`: Your MikroTik router URL and API port (e.g., `https://192.168.1.1:8729`)
   - `username`: RouterOS username with DNS permissions
   - `password`: RouterOS password

2. Encrypt the file in place with SOPS:

```bash
# From the repository root
cd kubernetes/_base/core/external-dns-mikrotik
sops --encrypt --in-place mikrotik-credentials-secret.enc.yaml
```

### 3. Configure Domain Filters

Edit `helmrelease.yaml` and update the `domainFilters` section to match your local domain(s):

```yaml
domainFilters:
  - home.arpa  # Replace with your actual local domain
  - local
```

## Components

### Webhook Deployment (`webhook-deployment.yaml`)

- **Image**: `ghcr.io/mirceanton/external-dns-provider-mikrotik:v1.4.10`
- **Port**: 8888 (HTTP)
- **Health Endpoints**: `/health` and `/ready`
- **Resources**: 50m CPU / 64Mi memory (requests), 200m CPU / 128Mi memory (limits)

### External-DNS HelmRelease (`helmrelease.yaml`)

- **Provider**: webhook
- **Webhook URL**: `http://external-dns-mikrotik-webhook.core.svc.cluster.local:8888`
- **Sources**: Ingress and Service resources
- **Policy**: sync (creates, updates, and deletes DNS records)
- **Registry**: TXT records with owner ID `firefly-mikrotik`

## Usage

Once deployed, External-DNS will automatically create DNS records in your MikroTik router for:

1. **Ingress resources** with hostnames
2. **Service resources** with `external-dns.alpha.kubernetes.io/hostname` annotation

Example Service annotation:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-app.local
spec:
  type: LoadBalancer
  # ... rest of service spec
```

## Troubleshooting

### Check Webhook Logs

```bash
kubectl logs -n core -l app.kubernetes.io/name=external-dns-mikrotik-webhook
```

### Check External-DNS Logs

```bash
kubectl logs -n core -l app.kubernetes.io/name=external-dns-mikrotik
```

### Verify DNS Records

On your MikroTik router:

```routeros
/ip dns static print
```

## References

- [external-dns-provider-mikrotik GitHub](https://github.com/mirceanton/external-dns-provider-mikrotik)
- [ExternalDNS Documentation](https://github.com/kubernetes-sigs/external-dns)
- [Bitnami External-DNS Helm Chart](https://github.com/bitnami/charts/tree/main/bitnami/external-dns)
