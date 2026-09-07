# Self-contained leaf (its terragrunt.hcl does NOT include root.hcl), so there is
# no Terragrunt-generated provider.tf to collide with — required_providers lives
# here normally. Same arrangement as terraform/mikrotik/modules/crs.
terraform {
  required_version = ">= 1.9.0" # provider for_each (one instance per router) is OpenTofu 1.9+

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.1" # matches the version the other two mikrotik leaves pin
    }
  }
}
