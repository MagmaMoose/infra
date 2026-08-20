# Monolithic Deployments

Embracing the simplicity of unified infrastructure management in a fragmented world.

<!-- Quality & Security Overview -->
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Known Vulnerabilities](https://snyk.io/test/github/CalebSargeant/infra/badge.svg)](https://snyk.io/test/github/CalebSargeant/infra)

<!-- Code Quality & Maintainability -->
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Reliability Rating](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Technical Debt](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)

<!-- Code Metrics -->
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=coverage)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=bugs)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)

<!-- Project Stats -->
[![infracost](https://img.shields.io/endpoint?url=https://dashboard.api.infracost.io/shields/json/a160e93c-2b08-4d69-b714-28ff13449df0/repos/f87bb12c-cefc-4a81-8b99-fa8af676abc9/branch/2ee22093-5387-4cd3-b45c-afeef5628480)](https://dashboard.infracost.io/org/sargeant/repos/f87bb12c-cefc-4a81-8b99-fa8af676abc9?tab=branches)
[![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)
[![Duplicated Lines (%)](https://sonarcloud.io/api/project_badges/measure?project=CalebSargeant_infra&metric=duplicated_lines_density)](https://sonarcloud.io/summary/new_code?id=CalebSargeant_infra)

## Overview

This repository holds the infrastructure-as-code for two k3s clusters and the cloud estate
around them:

- **Kubernetes**, reconciled by FluxCD. `firefly` runs a Raspberry Pi 5 control plane with one
  on-prem amd64 worker and two arm64 OCI VMs. `franklinhouse` is a second cluster in a separate
  OCI tenancy. See [Cluster topology](reference/cluster-topology.md).
- **Terraform**, wrapped by Terragrunt, across GCP, OCI, AWS and Cloudflare. See
  [Terraform delivery](operations/terraform-delivery.md).
- **Ansible** for host configuration and cluster bootstrap. See [Ansible](reference/ansible.md).
- **Container images** built from `dockerfiles/`. See
  [GitHub Actions workflows](reference/github-workflows.md).

New here? Read [Local development](contributing/development.md), then
[Troubleshooting](operations/troubleshooting.md) when something doesn't behave. Unfamiliar term?
Try the [Glossary](glossary.md).

## Quick Start

### Prerequisites

You'll need these tools installed on your local machine:

- [Homebrew](https://brew.sh/) (macOS)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-ansible-on-macos)
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli)
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/)
- [Docker](https://docs.docker.com/docker-for-mac/install/)
- [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/)
- [Flux CLI](https://fluxcd.io/flux/installation/)
- [SOPS](https://github.com/getsops/sops)

### Bootstrap a Raspberry Pi Kubernetes Cluster

1. Flash an SD card or NVME drive with the latest Raspberry Pi OS Lite image
2. Copy your SSH public key: `ssh-copy-id -i ~/.ssh/id_rsa.pub username@hostname`
3. Run the bootstrap playbook:

```bash
cd ansible && ansible-playbook -i hosts.yaml pi-k3s-bootstrap.yaml --check
```

```bash
cd ansible && ansible-playbook -i hosts.yaml pi-k3s-bootstrap.yaml
```

This will install k3s and set up necessary tools. The self-hosted GitHub runner
is no longer part of the Ansible bootstrap — it is deployed by Flux from
`kubernetes/apps/github-runner` using GitHub's actions-runner-controller (ARC).

### Deploy Applications

Once bootstrapped, FluxCD deploys everything under `kubernetes/` by reconciling `main`. You
deploy by merging. Render a change before you push it:

```bash
kustomize build kubernetes/clusters/firefly | head
```

```bash
flux reconcile kustomization <name> -n flux-system
```

## Key Features

### 📁 NFS Server Setup
Share storage across Linux clients with integrated NFS server configuration. [Learn more](operations/nfs-setup.md)

### 🔄 Auto-Update System
Automated server updates with intelligent Slack notifications via GitHub Actions. [Learn more](operations/auto-update.md)

### 🎯 Pre-commit Hooks
Single-hook validation system for comprehensive code quality checks. [Learn more](guides/single-hook-implementation.md)

### ☁️ Cloud Infrastructure
Terraform modules for managing cloud resources on multiple providers. [Learn more](reference/terraform-modules.md)

### ☁️ AWS front doors
Serverless entry points on the AWS free tier: API Gateway, Lambda, SQS FIFO and DynamoDB.
[Learn more](reference/terraform-aws.md)

### 🧰 Scripts
Operator scripts for vault secrets, credentials and cluster bootstrap.
[Learn more](reference/scripts.md)

## Documentation

Explore the full documentation:

- [Getting Started](getting-started/prerequisites.md) - Set up your environment
- [Guides](guides/deploying-applications.md) - Step-by-step tutorials
- [Operations](operations/nfs-setup.md) - Operational procedures
- [Reference](reference/cluster-topology.md) - Technical reference
- [Contributing](contributing/development.md) - Local development and conventions
- [Glossary](glossary.md) - Terms that mean something specific here
- [About](about/changelog.md) - Releases

## Contributing

See [Local development](contributing/development.md) for tooling, pre-commit, and the branch
and commit conventions.

This repository is **public**. Every commit is world-visible, so never commit a plaintext
secret. Secrets go to OCI Vault first, 1Password second, and SOPS only as a last resort. See
[Secrets management](reference/secrets-management.md).

## Licence

This project is licenced under the MIT Licence. See the [LICENSE file on GitHub](https://github.com/CalebSargeant/infra/blob/main/LICENSE) for details.
