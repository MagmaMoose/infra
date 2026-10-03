# Prerequisites

This page outlines the tools and dependencies needed to work with this infrastructure repository.

## Required Tools (macOS)

The following tools are required for managing the infrastructure:

- [Homebrew](https://brew.sh/) - Package manager for macOS
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-ansible-on-macos) - Configuration management
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli) - Infrastructure as code
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) - Terraform wrapper
- [Helm](https://helm.sh/docs/intro/install/) - Kubernetes package manager
- [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/) - Kubernetes CLI
- [Docker](https://docs.docker.com/docker-for-mac/install/) - Container runtime
- [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) - Kubernetes manifest customization
- [Flux CLI](https://fluxcd.io/flux/installation/) - GitOps continuous delivery
- [SOPS](https://github.com/getsops/sops) - Secrets encryption

## Installation

### Using Homebrew (Recommended)

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install core tools
brew install ansible terraform terragrunt helm kubectl docker kustomize flux sops
```

## Hardware Requirements (for Kubernetes)

If you're setting up a Raspberry Pi Kubernetes cluster:

- **Raspberry Pi 5** - Recommended hardware platform
- **Pironman5 Case** - Optional but recommended ([details](https://docs.sunfounder.com/projects/pironman5/en/latest/))
- **SD Card or NVME Drive** - For the operating system
- **Ethernet Connection** - Recommended for stability

## Next Steps

Once you have the prerequisites installed:

1. [Set up a Kubernetes Cluster](kubernetes-setup.md)
2. [Configure NFS Storage](../operations/nfs-setup.md)
3. [Deploy Applications](../guides/deploying-applications.md)
