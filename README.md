<!-- Quality & Security Overview -->
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Known Vulnerabilities](https://snyk.io/test/github/CalebSargeant/infra/badge.svg)](https://snyk.io/test/github/CalebSargeant/infra)
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)

# Monolithic Deployments

Embracing the simplicity of unified infrastructure management in a fragmented world.

## Overview

This repository contains a comprehensive infrastructure-as-code solution for managing Kubernetes clusters, Helm charts, Terraform modules, and Ansible playbooks. It's designed for running a complete home lab or small-scale production environment on a Raspberry Pi 5 or similar hardware.

## Quick Start

### Prerequisites

Install the required tools (macOS):

```bash
brew install ansible terraform terragrunt helm kubectl kustomize flux sops pre-commit
```

### Bootstrap a Kubernetes Cluster

Dry-run first. That's the convention for every playbook here.

```bash
cd ansible && ansible-playbook -i hosts.yaml pi-k3s-bootstrap.yaml --check
```

```bash
cd ansible && ansible-playbook -i hosts.yaml pi-k3s-bootstrap.yaml
```

### Deploy Applications

Applications are deployed by FluxCD, which reconciles `main`. You deploy by merging, not by
running a command. To render a change before you push it:

```bash
kustomize build kubernetes/clusters/firefly | head
```

To make Flux pick a change up immediately instead of waiting for its interval:

```bash
flux reconcile kustomization <name> -n flux-system
```

Terraform is applied by the Terragrunt workflow, not from a laptop. See
[Terraform delivery](https://calebsargeant.github.io/infra/operations/terraform-delivery/).

## 📚 Documentation

▶ **Full documentation:** https://calebsargeant.github.io/infra/

The complete documentation includes:

- **Getting Started** - Prerequisites and setup guides
- **Guides** - Step-by-step tutorials for common tasks
- **Operations** - Operational procedures (NFS, auto-updates, etc.)
- **Reference** - Terraform modules, AWS estate, workflows, scripts, and cluster topology

## Key Features

- 🎯 **k3s cluster** with a Raspberry Pi 5 control plane and on-prem plus OCI workers
- 🚀 **Helm charts** for 20+ applications
- 📁 **NFS server** for shared storage
- 🔄 **Auto-update system** with Slack notifications
- ☁️ **Terraform modules** for cloud infrastructure
- 🛡️ **Pre-commit hooks** for code quality

## Contributing

See [Local development](https://calebsargeant.github.io/infra/contributing/development/).

This repository is **public**. Every commit is world-visible, so never commit a plaintext
secret.

## Licence

This project is licenced under the MIT Licence - see the [LICENSE](LICENSE) file for details.
