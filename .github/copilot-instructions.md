# Repository Copilot Instructions

## Project Overview

This is a monolithic infrastructure-as-code repository managing a home lab environment on Raspberry Pi hardware. It contains Terraform modules, Ansible playbooks, Kubernetes manifests, and Helm charts.

## Technology Stack

### Core Technologies
- **Terraform/Terragrunt**: Infrastructure as code (version: latest stable)
- **Ansible**: Configuration management and automation
- **Kubernetes (k3s)**: Container orchestration on Raspberry Pi
- **Helm**: Kubernetes package management
- **Docker**: Container runtime

### Target Environment
- Primary platform: Raspberry Pi 5
- Operating system: Linux-based (typically Raspberry Pi OS or Ubuntu)
- Kubernetes distribution: k3s (lightweight Kubernetes)

## Code Style and Standards

### Terraform
- Use Terragrunt for managing multiple Terraform modules
- Follow HashiCorp's style guide
- Use descriptive variable names
- Always include output values for important resources
- Organize code by provider (cloudflare, gcp, oci)
- Use the `modules/` directory for reusable components

### Ansible
- Follow YAML best practices (2-space indentation)
- Use descriptive playbook and task names
- Organize playbooks by function (docker-, pi-, server-, etc.)
- Store variables in the `vars/` directory
- Use roles in the `roles/` directory for complex tasks
- Host inventory should be in `hosts.yaml`

### Kubernetes
- Use Kustomize for manifest management
- Follow the directory structure: `_base/`, `_clusters/`, `_components/`
- Helm charts should specify clear values and dependencies
- Use namespaces to organize applications
- Include resource limits and requests

### Docker
- Keep Dockerfiles in the `dockerfiles/` directory
- Use multi-stage builds where appropriate
- Pin base image versions for reproducibility
- Follow security best practices (non-root users, minimal images)

## File Organization

```
/ansible        - Ansible playbooks and roles
/terraform      - Terraform/Terragrunt configurations
/kubernetes     - Kubernetes manifests and Kustomize files
/dockerfiles    - Custom Docker images
/scripts        - Utility scripts
/docs           - Documentation (published to GitHub Pages)
```

## Testing and Validation

### Pre-commit Hooks
- Pre-commit hooks are workstation-global (`core.hooksPath=~/.git-hooks`, config `~/.pre-commit-config.yaml`). This repo has no `.pre-commit-config.yaml`.
- Always run pre-commit checks before committing changes
- Fix any linting or formatting issues

### Terraform
- Run `terraform fmt` to format code
- Run `terraform validate` to check syntax
- Use `terragrunt validate-all` for multi-module validation
- Test with `terraform plan` before applying changes

### Ansible
- Use `ansible-playbook --check` for dry-run validation
- Test playbooks in a safe environment first
- Verify inventory and variable files are properly formatted

### Kubernetes
- Validate manifests with `kubectl apply --dry-run=client`
- Use `kubectl diff` to preview changes
- Check Helm charts with `helm lint`

## Architectural Guidelines

### Infrastructure as Code Principles
- Everything should be defined as code
- No manual changes to infrastructure
- Use version control for all changes
- Document infrastructure decisions in commit messages

### Security
- Never commit secrets or sensitive data
- Use environment variables or secret management tools
- Follow the principle of least privilege
- Keep dependencies up to date

### Home Lab Specifics
- Optimize for single-node k3s deployment
- Consider resource constraints of Raspberry Pi hardware
- Use NFS for shared storage when needed
- Implement auto-update mechanisms with appropriate notifications

## Documentation

- Primary documentation is in the `/docs` directory
- Documentation is published to https://calebsargeant.github.io/infra/
- Update documentation when making significant changes
- Use clear, concise language
- Include code examples where helpful

## Atlantis Integration

- This repository uses Atlantis for Terraform automation
- Configuration is in `atlantis.yaml`
- See `ATLANTIS_SETUP.md` for detailed setup information
- Atlantis runs on pull request comments

## Git Workflow

- Use descriptive commit messages
- Reference issue numbers in commits when applicable
- Keep commits focused and atomic
- Follow conventional commits format when possible

## Common Tasks

### Bootstrapping Kubernetes
```bash
cd ansible
ansible-playbook -i hosts pi-k3s-bootstrap.yml
```

### Deploying Applications
```bash
cd kubernetes
terragrunt run-all apply
```

### Running Pre-commit Checks
```bash
pre-commit run --config ~/.pre-commit-config.yaml --all-files
```

## Notes

- This is a personal home lab infrastructure
- Prioritize simplicity and maintainability
- Document unusual or complex configurations
- Consider resource limitations of Raspberry Pi hardware
