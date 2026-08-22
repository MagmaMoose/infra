# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Overview

This is the Kubernetes configuration subdirectory of the monolithic infrastructure repository. It manages a single-node K3s cluster ("firefly") using a Kustomize-based GitOps architecture with Flux v2 for continuous deployment.

## Directory Structure

```text
kubernetes/
├── clusters/
│   ├── firefly/       # Main single-node K3s cluster (Raspberry Pi 5)
│   │   ├── flux-system/
│   │   └── kustomization.yaml
│   └── franklin/      # Secondary cluster configuration
├── apps/              # Application configurations organized by app
│   ├── media/         # Media stack (Plex, Radarr, Sonarr, etc.)
│   │   └── base/
│   │       └── media/
│   ├── automation/    # Home automation apps (Home Assistant, Homebridge, n8n)
│   ├── backup/        # Backup solutions (Timemachine)
│   ├── core/          # Core cluster services (cert-manager, etc.)
│   ├── database/      # Database workloads (PostgreSQL)
│   ├── miscellaneous/ # Other applications
│   └── observability/ # Monitoring and logging
├── infrastructure/    # Infrastructure components
├── components/        # Kustomize components for cross-cutting concerns
│   ├── node-selectors/
│   └── resource-profiles/  # AWS-style resource allocation profiles
└── .kusomization.workings.yaml  # Development/debugging file
```

## Architecture

### GitOps with Flux v2

The cluster uses Flux v2 for declarative GitOps-based deployments. Configurations are applied through a hierarchy:

1. **Application bases** (`apps/<app>/base/<app>`): Generic, reusable workload definitions
2. **Cluster overlays** (`clusters/firefly/`): Cluster-specific customizations via Kustomize
3. **Flux sync**: Flux monitors this repository and applies changes automatically

### Kustomize Layering

- Each base namespace/application has its own kustomization
- Cluster overlays reference base resources and apply patches/customizations
- Components provide reusable transformations (resource profiles, node selectors)

### Resource Profiles

Standardized resource allocation profiles following AWS naming conventions:
- **P-type**: Processing intensive (2:1 CPU:Memory) - video transcoding, ML inference
- **T-type**: Burstable/Transactional (1:1) - web servers, APIs
- **C-type**: Compute optimized (1:2 CPU:Memory) - high-traffic services
- **M-type**: Memory optimized (1:4 CPU:Memory) - moderate memory apps
- **R-type**: Memory intensive (1:8 CPU:Memory) - in-memory databases, caches

See [Resource profiles](../reference/resource-profiles.md) for the full table. The
component itself was deleted in #569; the size names survive as a naming convention.

## Common Commands

### Validate and Build

```bash
# Validate Kustomize structure for a cluster
kustomize build clusters/firefly > /tmp/firefly-manifest.yaml

# Validate specific namespace/component
kustomize build clusters/firefly > /tmp/media-manifest.yaml

# Dry-run apply to verify what would be deployed
kubectl apply -k clusters/firefly --dry-run=client --output yaml
```

### Deploy

```bash
# Apply cluster configuration (if Flux is not auto-syncing)
kubectl apply -k clusters/firefly

# Force Flux reconciliation
flux reconcile kustomization firefly-root --with-source
```

### Debugging

```bash
# Check Flux sync status
flux get kustomization

# View Flux logs for specific kustomization
flux logs --kustomization=firefly-media --all-namespaces

# Inspect rendered manifests for a specific kustomization
kustomize build clusters/firefly
```

### Working with Bases and Overlays

```bash
# Add new application base
mkdir -p apps/myapp/base/myapp
# Create kustomization.yaml with resources

# Reference in cluster overlay
# clusters/firefly/kustomization.yaml
resources:
  - ../../apps/myapp/base/myapp
```

## Key Development Notes

### Sops + GPG Integration

The repository uses SOPS (Secrets Operations) with GPG for encrypting sensitive values. See parent repo's `k3s-sops-gpg-secret` Ansible role for setup.

### Cluster Bootstrap

The main cluster is bootstrapped via Ansible. Refer to `/ansible/pi-k3s-bootstrap.yml` in the parent repository for the full bootstrap procedure, which installs:
- K3s
- Flux v2
- SOPS/GPG secrets support

The self-hosted GitHub runner is deployed by Flux (not Ansible) from
`kubernetes/apps/github-runner`, using GitHub's actions-runner-controller (ARC).

### NFS Storage

Firefly provides NFS storage at `/mnt/raid` for shared access across workloads. See parent repo README for NFS client mount instructions.

### Naming Conventions

- Bases organized by workload type/function (not namespace)
- Cluster overlays mirror base structure for easy correlation
- Kustomization files always named `kustomization.yaml`
- Kubernetes manifests use `.yaml` extension
