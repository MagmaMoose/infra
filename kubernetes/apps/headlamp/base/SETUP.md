# Headlamp Setup - Quick Start

## What This Fixes

✅ **No more ID token prompts** - Headlamp uses kubeconfig files with embedded service account tokens  
✅ **Username/password login** - Basic auth at ingress level  
✅ **Scalable to unlimited clusters** - Just edit one file to add new clusters

## First-Time Setup

### Step 1: Create Basic Auth

```bash
./create-basic-auth.sh
```

Enter your desired username and password. This creates `basic-auth.enc.yaml`.

### Step 2: Update Kustomization

Add to `kustomization.yaml`:

```yaml
resources:
  # ... existing resources ...
  - basic-auth.enc.yaml
```

### Step 3: Deploy

```bash
git add .
git commit -m "Configure Headlamp authentication"
git push
```

Wait ~10 seconds for Flux to apply.

### Step 4: Access Headlamp

Go to https://headlamp.sargeant.co

- Enter your username/password (from Step 1)
- You'll see all clusters immediately
- **No ID token prompts!**

## How It Works

**Before:**
- Headlamp asks for ID tokens per cluster
- Manual token fetching every session
- Not scalable

**After:**
- Basic auth login (once per session)
- Kubeconfigs with embedded tokens mounted in pod
- Headlamp reads tokens automatically from files
- OIDC disabled via `HEADLAMP_CONFIG_NO_OIDC=true`

## Adding More Clusters

See main [README.md](README.md) for detailed instructions.

Quick version:
1. Create ServiceAccount on target cluster
2. Run `./extract-cluster.sh cluster-name` on target cluster
3. Edit `sops headlamp-kubeconfigs.enc.yaml` and paste output
4. Commit and push

New cluster appears in Headlamp within seconds!

## Troubleshooting

**Still seeing ID token prompts:**
```bash
kubectl logs -n misc -l app.kubernetes.io/name=headlamp
kubectl rollout restart deployment/headlamp -n misc
```

**Basic auth not working:**
```bash
kubectl get secret headlamp-basic-auth -n misc
kubectl get ingress -n misc
```

**Cluster not appearing:**
```bash
kubectl -n misc exec deploy/headlamp -- ls /home/headlamp/.config/Headlamp/kubeconfigs/
```
