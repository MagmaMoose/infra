# Deploying Applications

This guide walks you through deploying applications to your Kubernetes cluster using Helm and Terragrunt.

## Overview

Applications are deployed using:
- **Helm charts** for packaging Kubernetes resources
- **Terragrunt** for managing Helm chart deployments and configuration

## Prerequisites

Before deploying applications, ensure you have:

1. A running Kubernetes cluster (see [Kubernetes Setup](../getting-started/kubernetes-setup.md))
2. `kubectl` configured to access your cluster
3. `helm` and `terragrunt` installed (see [Prerequisites](../getting-started/prerequisites.md))

## Deployment Process

### Using Terragrunt

Navigate to the Kubernetes directory and deploy all applications:

```bash
cd kubernetes
terragrunt run-all apply
```

This will deploy all configured Helm charts to your cluster.

### Deploying Individual Applications

To deploy a specific application:

```bash
cd kubernetes/apps/<app-name>
terragrunt apply
```

### Verifying Deployments

Check the status of your deployments:

```bash
# List all pods
kubectl get pods -A

# Check specific namespace
kubectl get pods -n <namespace>

# View pod logs
kubectl logs -n <namespace> <pod-name>
```

## Available Applications

Applications live under `kubernetes/apps/`. Each has a base kustomization and a Flux
Kustomization that points at it. For how Helm and Kustomize divide the work here, see the
[Helm and Kustomize analysis](../reference/helm-charts.md).

## Configuration

Application configurations are managed through Terragrunt. Each application has its own `terragrunt.hcl` file with:

- Chart repository and version
- Custom values overrides
- Dependencies on other services

## Troubleshooting

### Pod Not Starting

```bash
# Describe the pod to see events
kubectl describe pod -n <namespace> <pod-name>

# Check logs
kubectl logs -n <namespace> <pod-name>
```

### Helm Chart Issues

```bash
# List Helm releases
helm list -A

# Get release status
helm status -n <namespace> <release-name>

# Rollback a release
helm rollback -n <namespace> <release-name>
```

## Next Steps

- Configure [NFS storage](../operations/nfs-setup.md) for persistent data
- Set up [monitoring](../operations/observability-stack.md) with Prometheus
- Review [resource profiles](../reference/resource-profiles.md) for optimisation
