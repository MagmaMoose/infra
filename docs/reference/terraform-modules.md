# Terraform Modules: Consolidate or Keep Separate?

> **Note (post-reorg):** `calebsargeant/infra` now uses `terraform/<provider>/modules/`
> per provider (e.g. `terraform/oci/modules/server`, `terraform/cloudflare/modules/cloudflare-dns`)
> instead of a single top-level `terraform/modules/`. The old `terraform/modules/gcp/project/`
> module described below was deleted as unused. The "consolidate to shared terraform-modules
> repo" thesis below is still relevant — this doc is the planning artifact for that.

## The Problem You've Identified

You maintain three infra repos, each with provider-scoped module trees:

```text
calebsargeant/infra/terraform/
├── cloudflare/modules/cloudflare-dns/
└── oci/modules/                       # network, server, edge, mikrotik, …

magmamoose/infra/terraform/_modules/
├── gcp/
│   ├── instance/
│   └── project/
├── hcloud/
│   ├── chr/
│   ├── edge/
│   ├── network/
│   └── server/

tengensystems/platform1-infra/terraform/aws/_modules/
├── amg/
├── amp/
├── cache/
├── eks/
├── rds/
├── vpc/
└── ... (18 modules)

And Azure modules too!
```

Looking at `gcp/project/` across repos: **They're 80% identical** but with slight variations (labels, deletion_policy, variable handling). The calebsargeant copy was deleted (unused locally); the magmamoose one is the candidate for promoting to the shared repo.

**Question:** Shouldn't these be in a shared `terraform-modules/` repo like `helm-charts/` or `reusable-workflows/`?

---

## Answer: **YES, but with a catch.**

The logic IS the same as Helm charts + reusable-workflows, **BUT** Terraform modules have a critical difference that changes the strategy.

### Why Separate Makes Sense

**Shared `terraform-modules/` repo:**
```text
terraform-modules/                     # Public repo
├── gcp/
│   ├── project/
│   ├── instance/
│   └── compute-instance/
├── aws/
│   ├── vpc/
│   ├── eks/
│   ├── rds/
│   └── ...
├── hcloud/
│   ├── server/
│   ├── network/
│   └── ...
└── azure/
    └── ...

calebsargeant/infra/                   # Uses modules from terraform-modules/
└── terraform/
    └── oci/

magmamoose/infra/                      # Uses modules from terraform-modules/
└── terraform/
    └── gcp/

tengensystems/platform1-infra/         # Uses modules from terraform-modules/
└── terraform/
    └── aws/
```

**Benefits:**
1. **DRY** - One `gcp/project/` module instead of three
2. **Single source of truth** - Bug fixes propagate everywhere
3. **Public consumption** - ArtifactHub, Terraform Registry
4. **Independent versioning** - Module v2.1.0 works with any calling infrastructure
5. **Cleaner infra repos** - No module duplication mental load

---

## The Critical Difference: Module State vs Chart State

### Helm Charts (Stateless)
```yaml
# Chart doesn't care about cluster state
# Just templating → outputs YAML
# Kustomize applies it
helmCharts:
  - chart: ./charts/homebridge
    version: 1.0.0
```

✅ **Chart version can be independent of app deployment version**

### Terraform Modules (Stateful)
```hcl
# Module creates real AWS resources
# Linked to terraform.tfstate file
# Versioning affects infrastructure state
module "vpc" {
  source = "git::https://github.com/calebsargeant/terraform-modules.git//aws/vpc?ref=v2.0.0"
}
```

⚠️ **Module version MUST coordinate with state version**

---

## Why This Matters: The State Problem

### Scenario 1: Module in Same Repo ✅ EASIER
```bash
# calebsargeant/infra/terraform/
cd aws/prod/us-east-1/
terraform init    # Reads local modules/
terraform apply   # State lives here
# No cross-repo coordination needed
```

### Scenario 2: Module in Separate Repo ⚠️ MORE COMPLEX
```bash
# calebsargeant/infra/terraform/
cd aws/prod/us-east-1/
# main.tf references:
module "vpc" {
  source = "git::https://github.com/calebsargeant/terraform-modules.git//aws/vpc?ref=v2.0.0"
}

terraform init    # Clones module from external repo
terraform apply   # State still lives here, but module is external
```

**The problem:** If you have a **breaking change** in the shared module, all three repos are affected:
- `calebsargeant/infra` uses v2.0.0
- `magmamoose/infra` uses v2.0.0
- `platform1-infra` uses v2.0.0

If you need to upgrade only one repo to v2.1.0 due to a bug fix, the others are stuck on v2.0.0. If the bug is critical, you have to **coordinate three repos to upgrade together**.

---

## Comparison: Helm vs Terraform

| Aspect | Helm Charts | Terraform Modules |
|--------|---|---|
| **State** | Stateless (just manifests) | Stateful (.tfstate) |
| **Cross-repo coordination** | Low (Flux syncs independently) | High (state ties versions together) |
| **Update strategy** | Can deploy v1.0.0 and v1.1.0 in same cluster | All consumers must use same module version |
| **Testing** | Test chart, deploy anywhere | Test module in one repo, changes affect all consumers |
| **Rollback** | Easy (helm rollback) | Complex (terraform state management) |
| **Version drift** | Acceptable | Risky |

---

## My Recommendation: Hybrid Approach

**Do it, but with a caveat: Use conservative versioning.**

### Structure

**terraform-modules/ repo (public):**
```text
terraform-modules/
├── aws/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── README.md
│   ├── eks/
│   ├── rds/
│   └── ...
├── gcp/
│   ├── project/
│   ├── instance/
│   └── ...
├── hcloud/
│   ├── server/
│   ├── network/
│   └── ...
├── azure/
│   ├── vm/
│   ├── vnet/
│   └── ...
├── .github/workflows/
│   ├── test-modules.yml          # Run terraform validate, tflint
│   └── tag-release.yml            # Tag on merge to main
├── CHANGELOG.md
├── README.md
└── .gitignore
```

**calebsargeant/infra/terraform/aws/prod/vpc/main.tf:**
```hcl
module "vpc" {
  source = "git::https://github.com/calebsargeant/terraform-modules.git//aws/vpc?ref=v1.0.0"
  
  vpc_cidr     = "10.0.0.0/16"
  region       = "us-east-1"
  env_name     = "prod"
}
```

---

## The Safe Migration Path

### Phase 1: Audit Modules
1. **Identify duplicates** across repos:
   - `gcp/project/` exists in `calebsargeant/` and `magmamoose/` ← consolidate
   - `hcloud/network/` in `magmamoose/` ← move to shared
   - `aws/vpc/` in `platform1-infra/` ← move to shared
   
2. **Find variations:**
   - Same module, different variables or behaviors?
   - Document differences (they matter for consolidation!)

3. **Decide: consolidate or keep separate?**
   - If >90% identical → consolidate to `terraform-modules/`
   - If significantly different → keep local, document why

### Phase 2: Create terraform-modules/ Repo
1. Copy baseline modules to new repo
2. **Pin versions in old repos to current commit hash** (safest):
   ```hcl
   source = "git::https://github.com/calebsargeant/terraform-modules.git//aws/vpc?ref=abc123def456"
   ```
3. Tag first release: `v1.0.0`

### Phase 3: Test & Validate
```bash
# In terraform-modules/
terraform validate aws/vpc/
terraform validate gcp/project/
# Run tflint, security checks, etc.
```

### Phase 4: Gradual Migration
- Start with **low-risk, stable modules** (e.g., `gcp/project`)
- Don't migrate modules that are actively changing
- Once working, migrate other repos to use shared version

### Phase 5: Ongoing
- New module features → terraform-modules/ repo
- Tag releases (v1.0.0, v1.1.0, etc)
- Use version pinning: `ref=v1.1.0` (not `ref=main`)

---

## What NOT to Consolidate

**Keep modules in their repos if:**

1. **Highly specialized** - Infrastructure-specific logic that doesn't generalize
   - Example: `platform1-infra/aws/_modules/config-mikrotik/` (network-specific)
   
2. **Still experimental** - Module API unstable, changing frequently
   - Example: Early-stage modules with backwards-incompatible changes
   
3. **Very small** - Wrapper around 1-2 resources (not worth managing)
   - Example: Simple `instance/` module that's just a thin wrapper

4. **Secret-heavy** - Contains infrastructure-specific values
   - Example: Module hardcoded with company-specific security groups
   - **Solution:** Parameterize it first, then move

---

## Example: Migrating `gcp/project/`

### Step 1: Create terraform-modules/ repo on GitHub
```bash
git init terraform-modules
cd terraform-modules/
mkdir -p gcp/project
```

### Step 2: Copy harmonized module
```bash
# Start with magmamoose version (more complete)
cp ../magmamoose/infra/terraform/_modules/gcp/project/* gcp/project/

# Add variables from calebsargeant version if missing
# Ensure all are parameterized (no defaults = local references)
```

### Step 3: Update each consuming repo to reference the shared module
```hcl
# Before: local module (e.g. magmamoose still uses this pattern)
module "gcp_project" {
  source = "../_modules/gcp/project"  # Local path inside the repo
}

# After: remote module from the shared terraform-modules repo
module "gcp_project" {
  source = "git::https://github.com/calebsargeant/terraform-modules.git//gcp/project?ref=v1.0.0"  # Remote
}
```

(Historical note: calebsargeant/infra used to have its own
`terraform/modules/gcp/project/`, but it was deleted as unused before the
shared-repo strategy was actioned. The step above applies to any repo that
still carries a local copy of `gcp/project`.)

### Step 4: Verify
```bash
cd calebsargeant/infra/terraform/gcp/prod/europe-west4/project/
terraform init    # Clones from terraform-modules/
terraform validate
terraform plan
```

---

## Version Pinning Strategy

**NEVER use `ref=main`** in production:
```hcl
# ❌ BAD - breaks when main changes
source = "git::https://github.com/calebsargeant/terraform-modules.git//aws/vpc?ref=main"

# ✅ GOOD - predictable, reviewable upgrades
source = "git::https://github.com/calebsargeant/terraform-modules.git//aws/vpc?ref=v1.2.3"
```

**Upgrade strategy:**
1. Bump `ref=v1.2.3` → `ref=v1.3.0` in one repo
2. Run `terraform plan` to see what changes
3. If OK, commit and apply
4. Update other repos only after successful deploy

---

## CI/CD for terraform-modules/

Add GitHub Actions to validate all modules:

```yaml
# .github/workflows/test.yml
name: Test Modules
on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        module_path:
          - aws/vpc
          - aws/eks
          - gcp/project
          - hcloud/server
          - azure/vm
    steps:
      - uses: actions/checkout@v3
      - uses: hashicorp/setup-terraform@v2
      - run: terraform -chdir=${{ matrix.module_path }} validate
      - run: terraform -chdir=${{ matrix.module_path }} fmt -check
      - run: tflint ${{ matrix.module_path }}
```

---

## Final Checklist

- [ ] Audit modules across repos, identify duplicates
- [ ] Decide which modules to consolidate (>80% identical?)
- [ ] Create `terraform-modules/` public repo
- [ ] Migrate baseline modules to new repo
- [ ] Add CI/CD for module validation
- [ ] Tag v1.0.0 release
- [ ] Update source references in consuming repos (use version refs!)
- [ ] Document versioning strategy (semver)
- [ ] Test one repo end-to-end before migrating others
- [ ] Keep specialized modules local (config-mikrotik, etc)

---

## TL;DR

**Yes, move shared modules to `terraform-modules/` repo, but:**

1. **Only consolidate truly generic modules** (>80% identical across repos)
2. **Always use version pins** (`ref=v1.0.0`), never `ref=main`
3. **Keep infrastructure-specific modules local** (config-mikrotik, etc)
4. **Coordinate upgrades** if shared module has breaking changes
5. **This is different from Helm**: Terraform state makes coordination harder

The payoff: Single source of truth, cleaner infra repos, public reusability. The cost: Must be disciplined about versioning and testing.
