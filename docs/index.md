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

This repository contains a comprehensive infrastructure-as-code solution for managing:

- **Kubernetes deployments** on Raspberry Pi (k3s single-node cluster)
- **Helm charts** for application deployments
- **Terraform modules** for cloud infrastructure
- **Ansible playbooks** for system configuration
- **Docker configurations** for containerised applications

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
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-macos)

### Bootstrap a Raspberry Pi Kubernetes Cluster

1. Flash an SD card or NVME drive with the latest Raspberry Pi OS Lite image
2. Copy your SSH public key: `ssh-copy-id -i ~/.ssh/id_rsa.pub username@hostname`
3. Run the bootstrap playbook:

```bash
cd ansible
ansible-playbook -i hosts pi-k3s-bootstrap.yml
```

This will install k3s and set up necessary tools. The self-hosted GitHub runner
is no longer part of the Ansible bootstrap — it is deployed by Flux from
`kubernetes/apps/github-runner` using GitHub's actions-runner-controller (ARC).

### Deploy Applications

Once bootstrapped, deploy Helm charts using Terragrunt:

```bash
cd kubernetes
terragrunt run-all apply
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

### 🚀 Helm Charts
Production-ready Helm charts for common applications and services. [Learn more](reference/helm-charts.md)

## Documentation

Explore the full documentation:

- [Getting Started](getting-started/prerequisites.md) - Set up your environment
- [Guides](guides/deploying-applications.md) - Step-by-step tutorials
- [Operations](operations/nfs-setup.md) - Operational procedures
- [Reference](reference/helm-charts.md) - Technical reference
- [About](about/changelog.md) - Project information

## Contributing

Contributions are welcome! Please read the contributing guidelines before submitting pull requests.

## Licence

This project is licenced under the MIT Licence. See the [LICENSE file on GitHub](https://github.com/CalebSargeant/infra/blob/main/LICENSE) for details.
