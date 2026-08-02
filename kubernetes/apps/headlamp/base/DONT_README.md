# Headlamp Multi-Cluster Setup

Scalable Kubernetes dashboard for managing unlimited clusters without manual token input.

## Current Clusters

- **firefly** - Local cluster (uses in-cluster ServiceAccount auth)
- **p1-staging-eks** - Remote EKS cluster in AWS

## Architecture

**Scalable Design:**
- One aggregated Secret (`headlamp-kubeconfigs`) mounted as a directory
- Each cluster = one key/file in the Secret
- Add unlimited clusters by editing one file (no deployment changes)
- Service account tokens never expire
- Fully GitOps: edit → commit → push → Flux applies

**Components:**
- Service Account: `headlamp-admin` in `misc` namespace with `cluster-admin`
- Kubeconfig Directory: `/home/headlamp/.config/Headlamp/kubeconfigs/`
- Secret: `headlamp-kubeconfigs.enc.yaml` (SOPS encrypted)

**Authentication:**
- Basic auth at ingress level (username/password)
- No OIDC/ID token prompts - uses kubeconfig files directly
- Clusters authenticated via service account tokens in kubeconfigs

## Initial Setup

### 1. Create Basic Auth Credentials

Run the helper script:

```bash
./create-basic-auth.sh
```

This creates `basic-auth.enc.yaml` with your username/password.

Add it to kustomization.yaml:

```yaml
resources:
  # ...
  - basic-auth.enc.yaml
```

Commit and push:

```bash
git add basic-auth.enc.yaml kustomization.yaml
git commit -m "Add Headlamp basic auth"
git push
```

### 2. Apply Configuration

Flux will automatically apply the changes. You'll now:
- See a login prompt at https://headlamp.sargeant.co (username/password)
- No ID token prompts when accessing clusters
- All clusters available immediately after login

## How to Add a New Cluster

### Step 1: Create Service Account on Target Cluster

Switch to the target cluster:

```bash
kubectl config use-context <target-cluster>
```

Apply this manifest:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: misc
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: headlamp-admin
    namespace: misc
---
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-admin-token
  namespace: misc
  annotations:
    kubernetes.io/service-account.name: headlamp-admin
type: kubernetes.io/service-account-token
```

```bash
kubectl apply -f headlamp-sa.yaml
```

Wait 5 seconds for token generation.

### Step 2: Extract Token and Cluster Info

```bash
# Get token
TOKEN=$(kubectl get secret headlamp-admin-token -n misc -o jsonpath='{.data.token}' | base64 -d)

# Get cluster CA certificate
CA_CERT=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Get API server URL
SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')

# Print (you'll copy these in step 3)
echo "Server: $SERVER"
echo "CA: $CA_CERT"
echo "Token: $TOKEN"
```

### Step 3: Add Cluster to Secret

Switch back to firefly:

```bash
kubectl config use-context firefly
cd /path/to/headlamp
```

Edit the encrypted secret:

```bash
sops headlamp-kubeconfigs.enc.yaml
```

Add a new key under `stringData:`:

```yaml
stringData:
  # Existing clusters...
  
  # Your new cluster (key name = cluster name in UI)
  my-new-cluster: |
    apiVersion: v1
    kind: Config
    clusters:
    - name: my-new-cluster
      cluster:
        server: https://paste-server-from-step-2
        certificate-authority-data: paste-ca-cert-from-step-2
    contexts:
    - name: my-new-cluster
      context:
        cluster: my-new-cluster
        user: headlamp-admin
    current-context: my-new-cluster
    users:
    - name: headlamp-admin
      user:
        token: "paste-token-from-step-2"
```

Save and exit (SOPS re-encrypts automatically).

### Step 4: Deploy

```bash
git add headlamp-kubeconfigs.enc.yaml
git commit -m "Add my-new-cluster to Headlamp"
git push
```

Flux applies within seconds. The new cluster appears in Headlamp immediately.

### Step 5: Verify

```bash
kubectl -n misc exec deploy/headlamp -- ls /home/headlamp/.config/Headlamp/kubeconfigs
```

Should show your new cluster file.

## Quick Script for Extracting Kubeconfig

Save as `extract-cluster.sh`:

```bash
#!/bin/bash
CLUSTER_NAME=$1
NS=${2:-misc}

if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <cluster-name> [namespace]"
  exit 1
fi

TOKEN=$(kubectl get secret headlamp-admin-token -n "$NS" -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')

cat <<EOF
  ${CLUSTER_NAME}: |
    apiVersion: v1
    kind: Config
    clusters:
    - name: ${CLUSTER_NAME}
      cluster:
        server: ${SERVER}
        certificate-authority-data: ${CA}
    contexts:
    - name: ${CLUSTER_NAME}
      context:
        cluster: ${CLUSTER_NAME}
        user: headlamp-admin
    current-context: ${CLUSTER_NAME}
    users:
    - name: headlamp-admin
      user:
        token: "${TOKEN}"
EOF
```

Usage:

```bash
chmod +x extract-cluster.sh
kubectl config use-context target-cluster
./extract-cluster.sh my-cluster-name

# Copy output into headlamp-kubeconfigs.enc.yaml
sops headlamp-kubeconfigs.enc.yaml
```

## Troubleshooting

### Cluster Not Appearing

Check the secret:

```bash
kubectl get secret headlamp-kubeconfigs -n misc
kubectl -n misc exec deploy/headlamp -- ls -la /home/headlamp/.config/Headlamp/kubeconfigs/
```

Check logs:

```bash
kubectl logs -n misc -l app.kubernetes.io/name=headlamp
```

Force restart:

```bash
kubectl rollout restart deployment/headlamp -n misc
```

### Token Issues

Test kubeconfig locally:

```bash
# Extract cluster kubeconfig
kubectl get secret headlamp-kubeconfigs -n misc -o jsonpath='{.data.my-cluster}' | base64 -d > /tmp/test.yaml

# Test it
kubectl get nodes --kubeconfig=/tmp/test.yaml
```

Regenerate token on target cluster:

```bash
kubectl delete secret headlamp-admin-token -n misc
kubectl apply -f headlamp-sa.yaml
# Extract new token and update headlamp-kubeconfigs.enc.yaml
```

### SOPS Issues

Check age key:

```bash
ls -la ~/.sops.agekey
cat .sops.yaml
```

Test decryption:

```bash
sops -d headlamp-kubeconfigs.enc.yaml
```

## Naming Conventions

For many clusters, use consistent naming:

```yaml
stringData:
  # Work clusters
  work-prod-us-east: |...
  work-staging-eu: |...
  
  # Personal
  homelab: |...
  pi-cluster: |...
  
  # Customer clusters
  acme-prod: |...
  acme-staging: |...
```

## Security

**RBAC:** ServiceAccount uses `cluster-admin`. For production, use restrictive roles:
- View-only: `view` ClusterRole
- Namespace-scoped: RoleBindings instead of ClusterRoleBindings

**Encryption:** SOPS encrypts tokens with age. Only those with `~/.sops.agekey` can decrypt.

**Network:** 
- Ensure Headlamp ingress uses TLS
- Add authentication (oauth2-proxy, etc.)

**Token Rotation:** Periodically regenerate tokens:
1. Delete Secret on target cluster
2. Recreate Secret
3. Update headlamp-kubeconfigs.enc.yaml
4. Commit and push

## Scaling Limits

- Kubernetes Secret max size: ~1MiB
- Typical kubeconfig: ~2-3KB
- **Practical limit: ~300-400 clusters per Secret**

For more clusters:
- Split into multiple Secrets (e.g., `headlamp-kubeconfigs-1`, `headlamp-kubeconfigs-2`)
- Mount all Secrets in configmap.yaml
