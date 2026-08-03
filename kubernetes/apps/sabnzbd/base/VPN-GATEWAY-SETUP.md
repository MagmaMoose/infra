# VPN Gateway Proxy Setup

This deployment routes internet traffic through a centralized VPN gateway proxy in the `core` namespace.

## How It Works

1. **VPN Gateway**: A centralized Gluetun deployment runs in `core` namespace with HTTP/SOCKS5 proxy enabled
2. **Proxy Environment Variables**: Applications are configured via HTTP_PROXY/HTTPS_PROXY environment variables
3. **Cluster Traffic Preserved**: NO_PROXY ensures internal cluster traffic bypasses the VPN
4. **Single VPN Connection**: Multiple applications share one VPN connection, reducing resource usage

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                   │
│                                                             │
│  ┌─────────────────┐      ┌─────────────────────────────┐  │
│  │  core namespace │      │       media namespace        │  │
│  │                 │      │                              │  │
│  │  ┌───────────┐  │      │  ┌─────────┐  ┌──────────┐  │  │
│  │  │vpn-gateway│◄─┼──────┼──│ sabnzbd │  │  radarr  │  │  │
│  │  │ (gluetun) │  │      │  └─────────┘  └──────────┘  │  │
│  │  └─────┬─────┘  │      │       │             │       │  │
│  │        │        │      │       └──────┬──────┘       │  │
│  └────────┼────────┘      └──────────────┼──────────────┘  │
│           │                              │                  │
│           │  HTTP_PROXY/HTTPS_PROXY      │                  │
│           │◄─────────────────────────────┘                  │
└───────────┼─────────────────────────────────────────────────┘
            │
            ▼
      ┌───────────┐
      │ Privado   │
      │ VPN       │
      └───────────┘
            │
            ▼
      ┌───────────┐
      │ Internet  │
      └───────────┘
```

## Setup Instructions

### 1. Create Privado VPN Credentials Secret

Create a secret in the `core` namespace:

```bash
kubectl create secret generic privado-vpn-credentials \
  --from-literal=username=<your-privado-username> \
  --from-literal=password=<your-privado-password> \
  --namespace=core
```

Or create a file `privado-credentials.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: privado-vpn-credentials
  namespace: core
type: Opaque
stringData:
  username: your-privado-username
  password: your-privado-password
```

Then apply it:

```bash
kubectl apply -f privado-credentials.yaml
```

### 2. Deploy VPN Gateway

The VPN gateway is part of the core namespace. Deploy it:

```bash
kubectl apply -k kubernetes/_base/core/vpn-gateway
```

### 3. Deploy Applications

Applications that use the `vpn-routed-proxy` component will automatically route through the VPN:

```bash
kubectl apply -k kubernetes/_base/media/sabnzbd
```

## Verification

### Check VPN Gateway Status

```bash
# Check pod status
kubectl get pods -n core -l app=vpn-gateway

# Check Gluetun logs and connection status
kubectl logs -n core -l app=vpn-gateway

# Look for successful connection message
kubectl logs -n core -l app=vpn-gateway | grep -i "ip getter"
```

### Test Application Traffic

```bash
# Check external IP from sabnzbd (should be VPN IP)
kubectl exec -n media -it deploy/sabnzbd -- curl -s ifconfig.me

# Verify proxy is being used
kubectl exec -n media -it deploy/sabnzbd -- env | grep -i proxy

# Internal cluster traffic should still work (bypasses proxy)
kubectl exec -n media -it deploy/sabnzbd -- curl -s http://overseerr.media.svc.cluster.local:5055
```

## Configuration

The VPN gateway is configured with:

- **VPN Provider**: Privado
- **Server Location**: Netherlands (default)
- **HTTP Proxy Port**: 8888
- **SOCKS5 Proxy Port**: 8388
- **Killswitch**: Enabled (blocks traffic if VPN disconnects)

### Adding VPN Routing to Other Applications

To route another application through the VPN, add the component to its kustomization.yaml:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../_components/vpn-routed-proxy

resources:
  - deployment.yaml
  # ... other resources
```

### Changing VPN Server Location

Create a patch in your cluster overlay:

```yaml
# kubernetes/clusters/firefly/core/vpn-gateway/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../../_base/core/vpn-gateway

patches:
  - target:
      kind: Deployment
      name: vpn-gateway
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: vpn-gateway
      spec:
        template:
          spec:
            containers:
              - name: gluetun
                env:
                  - name: SERVER_COUNTRIES
                    value: "United States"
```

## Troubleshooting

### VPN Gateway not connecting

```bash
# Check the secret exists
kubectl get secret privado-vpn-credentials -n core

# Check Gluetun logs
kubectl logs -n core -l app=vpn-gateway

# Verify credentials are correct
kubectl logs -n core -l app=vpn-gateway | grep -i error
```

### Application not using VPN

```bash
# Verify proxy environment variables are set
kubectl exec -n media deploy/sabnzbd -- env | grep -i proxy

# Test proxy connectivity
kubectl exec -n media deploy/sabnzbd -- curl -x http://vpn-gateway.core.svc.cluster.local:8888 ifconfig.me

# Check VPN gateway service is reachable
kubectl exec -n media deploy/sabnzbd -- nc -zv vpn-gateway.core.svc.cluster.local 8888
```

### Cluster networking broken

- Verify NO_PROXY includes all cluster CIDRs
- Check that internal services are accessible without proxy

### DNS issues

If DNS isn't resolving through the VPN:

```bash
# Test DNS resolution
kubectl exec -n media deploy/sabnzbd -- nslookup google.com

# DNS should still use cluster DNS, only HTTP traffic goes through proxy
```

## Benefits of Proxy Approach

1. **Resource Efficient**: Single VPN connection for multiple applications
2. **Kubernetes Native**: Uses standard HTTP_PROXY environment variables
3. **No Special Privileges**: Applications don't need NET_ADMIN capability
4. **Easy to Debug**: Standard HTTP proxy troubleshooting
5. **Selective Routing**: Applications opt-in via component inclusion
6. **Cluster Networking Preserved**: Internal traffic uses cluster network
7. **Centralized Management**: One place to update VPN configuration

## Advanced: SOCKS5 Proxy

For applications that support SOCKS5 (like some torrent clients):

```yaml
env:
  - name: ALL_PROXY
    value: "socks5://vpn-gateway.core.svc.cluster.local:8388"
```

