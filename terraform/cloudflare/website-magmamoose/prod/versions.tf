# Provider v5, not the v4 that cloudflare/zero-trust/prod and the cloudflare-dns
# module pin. v4 is legacy (manually maintained, superseded); v5 is the current,
# OpenAPI-generated major. This stack is new and has its own state and lock file,
# so it can start on v5 without forcing a migration on the older stacks.
#
# The practical consequence when copying code between Cloudflare stacks in this
# repo: v5 uses ATTRIBUTE syntax for nested config (`rules = [{ ... }]`), while the
# v4 stacks use BLOCK syntax (`rules { ... }`). They are not interchangeable.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
  }
}

# Credentials come from CLOUDFLARE_API_TOKEN, injected at parse time by
# terragrunt.hcl from OCI Vault.
provider "cloudflare" {}
