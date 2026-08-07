# Single-Node Kubernetes Cluster

## Overview

This guide walks you through setting up a single-node Kubernetes cluster on a Raspberry Pi 5.

### Assumptions
* You're using a Raspberry Pi 5 (like I am at home) as your hardware of choice for your Kubernetes single-node cluster.
* You've purchased the Pironman5 case for your Raspberry Pi 5 (this case is kick-ass, [check it out](https://docs.sunfounder.com/projects/pironman5/en/latest/)!).
* The majority of companies use Helm for their Kubernetes deployments, and they use Terragrunt to manage the Helm chart deployments. So, we'll follow this methodology to stick with "industry standards". 

### Prerequisites
- Flash an SD card or NVME drive with the latest Raspberry Pi OS Lite image (with OS customizations).
- Set it and forget it (plug the pi into power and preferably ethernet).
- Copy the SSH public key to authorized keys: `ssh-copy-id -i ~/.ssh/id_rsa.pub username@hostname`
- Install the tools you need on your local machine (`kubectl`, `helm`, `terragrunt`, `ansible`, etc.). See the MacOs Tooling section above.
- SOPS - see the `k3s-sops-age-secret` ansible role (age, not GPG). Note most app secrets have since moved to external-secrets + OCI Vault; SOPS now covers cluster bootstrap and the credential external-secrets uses to reach OCI.

### Bootstrap

Run the following command to bootstrap your pi (You need to be inside `./ansible`):
```bash
ansible-playbook -i hosts pi-k3s-bootstrap.yml
```

The above will install k3s, deploy a GitHub Private Runner, and install the necessary tools on the pi. View the file to see what it does.
### Deploy
Now you can deploy your Helm charts using Terragrunt.
