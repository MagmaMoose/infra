# Self-contained terragrunt config for the prod Cloudflare Zero Trust setup.
# Does NOT include the broken ../../../terragrunt.hcl parent; defines its own
# backend so state stays under sargeant-prod-terraform-state alongside the
# rest of prod's terraform.

remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "cloudflare/zero-trust/prod"
    project  = "magmamoose-terraform"
    location = "europe-west4"
  }
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  backend "gcs" {}
}
EOF
}

# Cloudflare API token lives in OCI Vault as cloudflare-api-token-zero-trust.
# Has both DNS:Edit and Zero Trust:Edit, separate from the narrower
# cloudflare-api-token used by the dns module + cert-manager. Fetched at parse
# time via the oci CLI (uses ~/.oci/config).
#
# Access-group membership (family + friends email addresses) also lives in
# OCI Vault — the public repo intentionally doesn't list PII. JSON shape:
#   { "friends": ["…"], "caleb": ["…"], "household": ["…"], "caleb_personal": ["…"], "marc": ["…"] }
locals {
  cf_token_secret_ocid         = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aajtdkg5uwvfie4raijqushv4s3bep4feep6goh5hsnbpa"
  cf_access_groups_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aalypl7o6qeuuf3lk57oicmyt43uu5rknpurzczmrsv4mq"

  # Call the oci CLI directly (no shell) so this works on Windows/PowerShell as
  # well as Linux (Atlantis). base64 decoding happens in HCL instead of piping
  # to `base64 -d`, so there's no dependency on bash / WSL.
  cloudflare_api_token = base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.cf_token_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  )))

  cf_access_groups_membership = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.cf_access_groups_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))
}

terraform {
  extra_arguments "cloudflare_token" {
    commands = ["plan", "apply", "destroy", "import", "refresh", "validate"]
    env_vars = {
      CLOUDFLARE_API_TOKEN = local.cloudflare_api_token
    }
  }
}

inputs = {
  account_id                  = "6e26afa31c37dee1dc82ad2f214f9b3c"
  cf_access_groups_membership = local.cf_access_groups_membership
}
