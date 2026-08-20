# Quick Start

```bash
# Terraform (in a leaf dir, e.g. terraform/oci/prod/eu-amsterdam-1/network)
terragrunt plan && terragrunt apply

# Kustomize validate
kustomize build kubernetes/clusters/firefly | head

# Flux reconcile
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization <name> -n flux-system

# Ansible (always --check first)
cd ansible && ansible-playbook -i hosts.yaml <playbook>.yml [--check]

# Pre-commit (must pass)
pre-commit run --all-files

# SOPS encrypt (fallback only)
sops -e secret.yaml > secret.enc.yaml

# Docs (what CI runs — .github/workflows/docs.yml)
pip install -r requirements-docs.txt
mkdocs build --strict
mkdocs serve
```
