# Cloudflared DaemonSet

This configuration deploys Cloudflare Tunnel (cloudflared) as a DaemonSet on the firefly cluster, running on all node types (pi and mini).

## Token source

The tunnel token is **NOT** in this repo. It lives in **OCI Vault** under the secret name `cloudflared-tunnel-token-firefly` and is pulled into the cluster by `externalsecret.yaml` (in this directory) via the `oci-vault` `ClusterSecretStore`. Same flow as `cloudflare-credentials`, `mikrotik-credentials`, `slack-credentials`, etc.

## Rotating the token

1. **Get a new tunnel token** from the Cloudflare Zero Trust dashboard:
   - Networks → Tunnels → your tunnel → **Refresh token** (or recreate the tunnel)
2. **Update OCI Vault** — overwrite the value of secret `cloudflared-tunnel-token-firefly` with the new token.
3. **Force refresh** (optional — ExternalSecret syncs every 1h by default):
   ```bash
   kubectl annotate externalsecret cloudflared-token -n core \
     force-sync="$(date +%s)" --overwrite
   ```
4. **Roll the DaemonSet** so pods pick up the new token:
   ```bash
   kubectl rollout restart ds/cloudflared -n core
   ```

No code change or PR needed — the token lives in OCI Vault.

## Verification

```bash
kubectl get externalsecret cloudflared-token -n core   # READY=True, SecretSynced
kubectl get secret cloudflared-token -n core           # exists, key 'token'
kubectl get daemonset cloudflared -n core              # DESIRED=CURRENT=READY
kubectl logs ds/cloudflared -n core --tail=20          # "Connection registered"
```

## Architecture

- **Image**: `cloudflare/cloudflared:latest`
- **Namespace**: `core`
- **Scheduling**: no `nodeSelector` or tolerations — the DaemonSet lands on every schedulable node (pi + mini)
- **Resources**: 10m CPU request / no CPU limit, 100Mi RAM request and limit
- **Command**: `tunnel --no-autoupdate --protocol quic run --token $(TUNNEL_TOKEN)`
- **Secret source**: `Secret/core/cloudflared-token` materialized by `ExternalSecret` from OCI Vault key `cloudflared-tunnel-token-firefly`
