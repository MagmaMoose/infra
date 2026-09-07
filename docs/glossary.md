# Glossary

<!-- sources: kubernetes, terraform, ansible, .claude/ARCHITECTURE_MAP.md -->

Terms that appear across this repo and mean something specific here.

| Term | What it means here |
| --- | --- |
| **firefly** | The primary k3s cluster. Four nodes today: a Raspberry Pi 5 control plane, one on-prem amd64 worker, and two arm64 OCI VMs. Two more arm64 OCI VMs (`ff-oci3`, `ff-oci4`) are declared in Terraform but not yet applied, which would take it to six. |
| **franklinhouse** | The second cluster, in a separate OCI tenancy in `af-johannesburg-1`. Folded into this repo on 2026-08-13 from a private repo. See [FranklinHouse](reference/franklinhouse.md). |
| **ff-pi1** | The Raspberry Pi 5 that runs the firefly control plane. |
| **ff-vm1** | The single on-prem amd64 worker. Anything amd64-only is pinned here, which makes it the fleet's bottleneck. |
| **ff-oci1**, **ff-oci2** | Two arm64 OCI VMs in the **caleb** tenancy, reachable over firefly's own FortiGate-to-OCI IPSec tunnels. |
| **ff-oci3**, **ff-oci4** | Two more arm64 OCI VMs, in the **traceysargeant** tenancy, for its separate Always Free allowance. Not applied yet. They are **not** on firefly's tunnels: that VPN terminates in the other tenancy, so these have their own DRG and their own IPSec to the same FortiGates, and traffic to ff-oci1/ff-oci2 hairpins through FG1. See [Cluster topology](reference/cluster-topology.md). |
| **cloudworkers** | The second OCI tenancy (traceysargeant, `eu-amsterdam-1`) and the Terraform stack under `terraform/oci/cloudworkers/` that builds it: a VCN on `192.168.240.0/24`, two CHR edge routers (`ff-chr3`, `ff-chr4`), an IPSec-attached DRG, and `ff-oci3`/`ff-oci4`. Its leaves read `OCI_CW_*` credentials rather than `OCI_*`. |
| **leaf** | A directory with its own `terragrunt.hcl` that isn't a shared include. One leaf is one Terraform state file and one unit of plan and apply. |
| **tier** | A node grouping used for scheduling, expressed as a `topology.sargeant.co/tier` label. A tier is a **set**, not a single node. |
| **placement label** | A `placement.sargeant.co/*` label that Kyverno policies turn into node affinity and priority. Only reaches `Deployment`, `StatefulSet`, `DaemonSet` and `CronJob`. |
| **resource profile** | AWS-style size names (`t.small`, `m.nano`, `c.pico`) used as shorthand for a request and limit pair. The kustomize components that applied them were deleted; the names survive in comments. See [Resource profiles](reference/resource-profiles.md). |
| **front door** | The AWS serverless entry point for a service: API Gateway, a producer Lambda, a FIFO queue, and a consumer Lambda. See [Terraform (AWS)](reference/terraform-aws.md). |
| **artifact version** | The published Lambda zip a front door runs, pinned by version string. Changing it is the deployment. |
| **ClusterSecretStore `oci-vault`** | The External Secrets Operator store that reads OCI Vault. Every `ExternalSecret` `remoteRef` in the repo is checked against it in CI. |
| **CNPG** | CloudNativePG. One shared `postgres` cluster lives in the `database` namespace. Add `Database` and `User` CRs to it rather than standing up a new `Cluster`. |
| **Atlantis** | The Terraform pull-request automation that used to gate this repo. Still deployed, now covers only part of the estate. See [Terraform delivery](operations/terraform-delivery.md). |
| **Terragrunt workflow** | `.github/workflows/terragrunt.yml`, the Atlantis replacement that plans and applies Terraform. |
| **ARC** | actions-runner-controller. Self-hosted GitHub runners in the cluster. Jobs match a scale set by **name**, not by label. |
| **Flux Kustomization** | A `kustomize.toolkit.fluxcd.io` object, not a plain kustomize `kustomization.yaml`. Health checks and `dependsOn` live here. |
