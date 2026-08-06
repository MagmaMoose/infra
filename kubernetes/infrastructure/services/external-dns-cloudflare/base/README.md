# External-DNS CloudFlare Provider

This directory contains the configuration for the External-DNS CloudFlare provider, which enables automatic DNS record management in CloudFlare for Kubernetes resources.

## Overview

This External-DNS instance manages DNS records in CloudFlare for the `sargeant.co` domain.

## Configuration

The CloudFlare provider uses:

- **Provider**: cloudflare
- **Secret**: `cloudflared-token` (contains CloudFlare API credentials)
- **Domain Filter**: `sargeant.co`
- **Sources**: Ingress and Service resources
- **Policy**: sync (creates, updates, and deletes DNS records)
- **Registry**: TXT records with owner ID `firefly-k8s`

## Usage

External-DNS will automatically create DNS records in CloudFlare for:

1. **Ingress resources** with hostnames under `sargeant.co`
2. **Service resources** with `external-dns.alpha.kubernetes.io/hostname` annotation

Example Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  rules:
    - host: my-app.sargeant.co
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

## Troubleshooting

### Check External-DNS Logs

```bash
kubectl logs -n core -l app.kubernetes.io/name=external-dns-cloudflare
```

## References

- [ExternalDNS Documentation](https://github.com/kubernetes-sigs/external-dns)
- [CloudFlare Provider](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/cloudflare.md)
- [Bitnami External-DNS Helm Chart](https://github.com/bitnami/charts/tree/main/bitnami/external-dns)
