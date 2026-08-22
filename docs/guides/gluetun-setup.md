# Gluetun VPN Setup Guide

This guide explains how to set up Gluetun as a VPN sidecar for routing pod traffic through a VPN provider. This implementation uses Privado VPN but can be adapted for any VPN provider supported by Gluetun.

## Overview

Gluetun is a lightweight VPN client container that:
- Routes all pod traffic through a VPN tunnel
- Provides automatic killswitch functionality
- Supports multiple VPN providers (including Privado, Mullvad, NordVPN, etc.)
- Allows selective routing (cluster traffic vs. internet traffic)
- Automatically reconnects on connection drops

## Architecture

The Gluetun sidecar pattern uses a shared network namespace where:

```text
Pod: application (e.g., sabnzbd)
├── Container: gluetun (VPN client)
│   ├── Creates VPN tunnel
│   ├── Manages iptables firewall rules
│   └── Routes traffic
└── Container: application
    └── Shares network namespace with gluetun
```

All traffic from the application container passes through Gluetun's network stack, which routes it either:
- Through the VPN tunnel (internet traffic)
- Directly to the cluster network (RFC1918 addresses)

## Prerequisites

1. A Kubernetes cluster (this guide assumes the firefly k3s cluster)
2. Credentials for your VPN provider (e.g., Privado VPN username and password)
3. `kubectl` configured to access your cluster

## Setup Steps

### 1. Create VPN Credentials Secret

Create a Kubernetes secret containing your VPN provider credentials:

```bash
kubectl create secret generic privado-vpn-credentials \
  --from-literal=username=<your-username> \
  --from-literal=password=<your-password> \
  --namespace=media
```

Or create a YAML file `privado-credentials.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: privado-vpn-credentials
  namespace: media
type: Opaque
stringData:
  username: your-privado-username
  password: your-privado-password
```

Apply it:

```bash
kubectl apply -f privado-credentials.yaml
```

**Important**: Keep this file secure and do not commit it to version control.

### 2. Apply to Your Deployment

The Gluetun sidecar is implemented as a Kustomize component that can be added to any deployment.

Update your application's `kustomization.yaml` to include the component:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../../components/gluetun-sidecar

resources:
  - deployment.yaml
  - service.yaml
```

### 3. Deploy the Application

From your cluster-specific directory:

```bash
cd kubernetes/clusters/firefly/media/<your-app>
kubectl apply -k .
```

Or let Flux handle the deployment if you're using GitOps.

## Configuration Options

The Gluetun component supports various configuration options through environment variables.

### Changing VPN Server Location

Default is Netherlands. To change the location, add a strategic merge patch to your kustomization:

```yaml
patches:
  - target:
      kind: Deployment
      name: your-app
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: your-app
      spec:
        template:
          spec:
            containers:
              - name: gluetun
                env:
                  - name: SERVER_COUNTRIES
                    value: "United States"
```

### Multiple Location Filters

You can use multiple filters for more precise server selection:

```yaml
patches:
  - target:
      kind: Deployment
      name: your-app
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: your-app
      spec:
        template:
          spec:
            containers:
              - name: gluetun
                env:
                  - name: SERVER_REGIONS
                    value: "California"
                  - name: SERVER_CITIES
                    value: "Los Angeles"
```

### Adjusting Firewall Rules

By default, RFC1918 subnets are allowed for cluster networking. To add additional allowed subnets:

```yaml
patches:
  - target:
      kind: Deployment
      name: your-app
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: your-app
      spec:
        template:
          spec:
            containers:
              - name: gluetun
                env:
                  - name: FIREWALL_OUTBOUND_SUBNETS
                    value: "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10"
```

## Verification

### Check Pod Status

```bash
kubectl get pods -n media -l app=<your-app>
```

The pod should show `2/2` containers running.

### Check Gluetun Connection

```bash
# View Gluetun logs
kubectl logs -n media <pod-name> -c gluetun

# Look for successful connection
kubectl logs -n media <pod-name> -c gluetun | grep -i "ip getter"
```

You should see messages indicating successful connection and public IP retrieval.

### Verify VPN is Active

Test that traffic is going through the VPN:

```bash
# Check external IP (should be VPN IP, not your home IP)
kubectl exec -n media <pod-name> -c <app-container> -- curl -s ifconfig.me

# Or use a more verbose IP check service
kubectl exec -n media <pod-name> -c <app-container> -- curl -s ipinfo.io
```

### Verify Cluster Networking

Ensure internal cluster services are still accessible:

```bash
# Test connectivity to another service in the cluster
kubectl exec -n media <pod-name> -c <app-container> -- \
  curl -s http://overseerr.media.svc.cluster.local:5055

# Check DNS resolution
kubectl exec -n media <pod-name> -c <app-container> -- \
  nslookup overseerr.media.svc.cluster.local
```

## Killswitch

The Gluetun container includes an automatic killswitch that:

1. **Blocks all outbound internet traffic** when the VPN is disconnected
2. **Only allows traffic** through the VPN tunnel when connected
3. **Preserves cluster networking** via the `FIREWALL_OUTBOUND_SUBNETS` setting
4. **Prevents DNS leaks** by routing DNS queries through the VPN

The killswitch is enabled by default and requires no additional configuration.

To verify the killswitch is active:

```bash
# Check firewall rules in the Gluetun container
kubectl exec -n media <pod-name> -c gluetun -- iptables -L -n -v

# Look for REJECT rules that block non-VPN traffic
```

## Troubleshooting

### VPN Not Connecting

**Symptoms**: Pod starts but no VPN connection is established

**Solutions**:
1. Check credentials are correct:
   ```bash
   kubectl get secret privado-vpn-credentials -n media -o yaml
   ```
2. View Gluetun logs for error messages:
   ```bash
   kubectl logs -n media <pod-name> -c gluetun
   ```
3. Verify VPN provider is accessible from your network

### Application Can't Access Internet

**Symptoms**: Application cannot reach external sites

**Solutions**:
1. Verify VPN is connected (check logs)
2. Check if killswitch is blocking traffic (VPN not connected)
3. Restart the pod to re-establish VPN connection:
   ```bash
   kubectl delete pod -n media <pod-name>
   ```

### Cluster Services Not Accessible

**Symptoms**: Application cannot reach other pods/services in the cluster

**Solutions**:
1. Verify `FIREWALL_OUTBOUND_SUBNETS` includes your cluster's CIDR
2. Check your cluster's pod network CIDR:
   ```bash
   kubectl cluster-info dump | grep -i cidr
   ```
3. Update the subnets if needed in the component configuration

### High Memory Usage

**Symptoms**: Gluetun container using excessive memory

**Solutions**:
1. Check for connection/reconnection loops in logs
2. Adjust resource limits in the component patch
3. Consider using a different VPN server

### DNS Resolution Issues

**Symptoms**: DNS lookups fail or timeout

**Solutions**:
1. Gluetun uses its own DNS to prevent leaks (this is normal)
2. For cluster DNS, ensure `FIREWALL_OUTBOUND_SUBNETS` includes cluster network
3. Check DNS configuration:
   ```bash
   kubectl exec -n media <pod-name> -c <app-container> -- cat /etc/resolv.conf
   ```

## Using with Other Applications

The Gluetun sidecar component can be used with any application that needs VPN routing. Examples:

- **SABnzbd**: Usenet download client (default implementation)
- **qBittorrent**: Torrent client
- **Prowlarr**: Indexer manager

Simply add the component to the application's kustomization file.

## Switching VPN Providers

Gluetun supports many VPN providers. To use a different provider:

1. Update the `VPN_SERVICE_PROVIDER` environment variable in `gluetun-patch.yaml`
2. Update the secret to contain the appropriate credentials
3. Adjust server selection variables as needed for the provider

Supported providers include:
- Privado (default)
- Mullvad
- NordVPN
- ProtonVPN
- Surfshark
- And many more (see [Gluetun Wiki](https://github.com/qdm12/gluetun-wiki))

## Security Considerations

1. **Secret Management**: Store VPN credentials securely, never commit them to Git
2. **Killswitch**: Always verify the killswitch is working before trusting it
3. **DNS Leaks**: Gluetun prevents DNS leaks by default
4. **IP Leaks**: Test your VPN IP regularly to ensure it's working
5. **Updates**: Keep Gluetun image updated for security patches

## Advanced Configuration

### Port Forwarding

Some VPN providers support port forwarding. Add to environment variables:

```yaml
- name: VPN_PORT_FORWARDING
  value: "on"
```

### Custom DNS

To use custom DNS servers:

```yaml
- name: DOT
  value: "on"
- name: DOT_PROVIDERS
  value: "cloudflare"
```

### IPv6 Support

To enable IPv6:

```yaml
- name: FIREWALL_VPN_INPUT_PORTS
  value: "1194"
- name: VPN_TYPE
  value: "openvpn"
```

## References

- [Gluetun GitHub Repository](https://github.com/qdm12/gluetun)
- [Gluetun Wiki](https://github.com/qdm12/gluetun-wiki)
- [Privado VPN](https://privadovpn.com/)
- [Component source](https://github.com/CalebSargeant/infra/tree/main/kubernetes/components/gluetun-sidecar)

## Related Documentation

- [Deploying Applications](./deploying-applications.md)
- [Kubernetes Setup](../getting-started/kubernetes-setup.md)
