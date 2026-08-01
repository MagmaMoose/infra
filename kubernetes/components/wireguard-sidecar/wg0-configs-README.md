# WireGuard Service Configuration Templates

These are the wg0.conf templates for each media service to connect to the MikroTik hub.

## Setup Steps

### 1. Get MikroTik Public Key

After applying the MikroTik config, get the `media_vpn` public key:

```bash
ssh sgt-router '/interface wireguard print proplist=public-key where name=media_vpn'
```

### 2. Generate Keypairs for Each Service

Generate 5 keypairs (one per service):

```bash
# Create directory for keys
mkdir -p wireguard-keys
cd wireguard-keys

# Generate keys for each service
for service in sabnzbd qbittorrent prowlarr nzbhydra2; do
  wg genkey | tee ${service}-private.key | wg pubkey > ${service}-public.key
  echo "Generated keys for $service"
done
```

### 3. Update MikroTik with Public Keys

For each service, update the peer on MikroTik:

```bash
ssh sgt-router '/interface wireguard peers set [find comment="sabnzbd"] public-key="<paste-public-key-here>"'
ssh sgt-router '/interface wireguard peers set [find comment="qbittorrent"] public-key="<paste-public-key-here>"'
ssh sgt-router '/interface wireguard peers set [find comment="prowlarr"] public-key="<paste-public-key-here>"'
ssh sgt-router '/interface wireguard peers set [find comment="nzbhydra2"] public-key="<paste-public-key-here>"'
```

### 4. Create wg0.conf Files

Create a wg0.conf for each service using the templates below. Replace:
- `<SERVICE_PRIVATE_KEY>` - from `${service}-private.key`
- `<MIKROTIK_PUBLIC_KEY>` - from step 1
- `<MIKROTIK_IP_OR_HOSTNAME>` - Your MikroTik's public IP or hostname

---

## sabnzbd - wg0.conf

```ini
[Interface]
PrivateKey = <SERVICE_PRIVATE_KEY>
Address = 10.99.0.10/32
DNS = 192.168.19.1

[Peer]
PublicKey = <MIKROTIK_PUBLIC_KEY>
Endpoint = <MIKROTIK_IP_OR_HOSTNAME>:51880
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

---

## qbittorrent - wg0.conf

```ini
[Interface]
PrivateKey = <SERVICE_PRIVATE_KEY>
Address = 10.99.0.11/32
DNS = 192.168.19.1

[Peer]
PublicKey = <MIKROTIK_PUBLIC_KEY>
Endpoint = <MIKROTIK_IP_OR_HOSTNAME>:51880
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

---

## prowlarr - wg0.conf

```ini
[Interface]
PrivateKey = <SERVICE_PRIVATE_KEY>
Address = 10.99.0.13/32
DNS = 192.168.19.1

[Peer]
PublicKey = <MIKROTIK_PUBLIC_KEY>
Endpoint = <MIKROTIK_IP_OR_HOSTNAME>:51880
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

---

## nzbhydra2 - wg0.conf

```ini
[Interface]
PrivateKey = <SERVICE_PRIVATE_KEY>
Address = 10.99.0.14/32
DNS = 192.168.19.1

[Peer]
PublicKey = <MIKROTIK_PUBLIC_KEY>
Endpoint = <MIKROTIK_IP_OR_HOSTNAME>:51880
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

---

## 5. Create Kubernetes Secret

Once you have all 5 wg0.conf files ready, create the secret:

```bash
kubectl create secret generic wireguard-config \
  --from-file=wg0.conf=sabnzbd-wg0.conf \
  --namespace=media \
  --dry-run=client -o yaml | kubectl apply -f -
```

Repeat for each service, or use a secretGenerator in kustomization.yaml:

```yaml
secretGenerator:
  - name: wireguard-config
    files:
      - wg0.conf
    options:
      disableNameSuffixHash: true
```

## Testing

### Check MikroTik

```bash
# View WireGuard peers
ssh sgt-router '/interface wireguard peers print detail'

# Check if peers are connected (look for "current-endpoint-address")
ssh sgt-router '/interface wireguard peers print'

# Monitor traffic
ssh sgt-router '/interface wireguard peers monitor [find comment="sabnzbd"]'
```

### Check from Pod

```bash
# Check VPN IP (should be Privado IP)
kubectl exec -n media <pod-name> -c <container> -- curl ifconfig.me

# Check routing
kubectl exec -n media <pod-name> -c <container> -- ip route

# Ping MikroTik
kubectl exec -n media <pod-name> -c <container> -- ping 10.99.0.1

# Test internal network (should NOT go through VPN)
kubectl exec -n media <pod-name> -c <container> -- curl 192.168.19.1
```

## Troubleshooting

### Peer not connecting
- Check firewall allows UDP 51880
- Verify public keys match
- Check MikroTik is reachable on specified endpoint

### Traffic not routing through VPN
- Check mangle rules: `ssh sgt-router '/ip firewall mangle print'`
- Verify routing table: `ssh sgt-router '/ip route print where routing-table=vpn_routing'`
- Check NAT rules: `ssh sgt-router '/ip firewall nat print'`

### DNS not working
- Verify DNS is set correctly in wg0.conf
- Test: `kubectl exec -n media <pod> -c <container> -- nslookup google.com`
