# Zone-level configuration supporting magmamoose.com (repo: MagmaMoose/website).
#
# The site is a Cloudflare Worker serving static assets, deployed by that repo's
# GitHub Actions workflow. It is www-canonical, and `wrangler deploy` attaches
# www.magmamoose.com as the Worker's custom domain, provisioning its DNS record and
# certificate in the same call — so the Worker and www are deliberately NOT modelled
# here. This stack owns only what wrangler cannot: the apex record and its 301 to
# www.
#
# Self-contained, like cloudflare/zero-trust/prod and cloudflare/dns-magmamoose/prod:
# it deliberately does NOT include the legacy ../../terragrunt.hcl parent, which
# hardcodes a state prefix that doesn't fit the cloudflare/<stack>/prod layout.

remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "cloudflare/website-magmamoose/prod"
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

# Reuses the account-scoped `cloudflare-api-token` secret that
# cloudflare/dns-magmamoose/prod uses.
#
# IMPORTANT — TOKEN SCOPE. That token carries DNS permissions, which covers the
# apex record. The redirect ruleset additionally needs "Zone → Transform Rules →
# Edit" on magmamoose.com. Add it to the token in the Cloudflare dashboard and
# re-stash the token in OCI Vault, or the first apply fails with an authz error.
#
# The token the WEBSITE repo uses is a different one (an org-level GitHub Actions
# secret) — it needs Workers permissions and is documented in that repo's README.
locals {
  cf_token_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aawodbynrquyvlohrzze2uipxvxawsaqqe3sykv5owulfa"

  # Direct `oci` call + base64decode in HCL (no `bash -c`) so this parses on
  # Windows/PowerShell, which has no bash. Pattern: cloudflare/zero-trust/prod.
  cloudflare_api_token = base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.cf_token_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  )))
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
  # magmamoose.com zone (same zone_id as cloudflare/dns-magmamoose/prod).
  zone_id     = "f04a8d6c68daf6ba1430c5645ca70cb8"
  apex_domain = "magmamoose.com"

  # Matches `name` in the website repo's wrangler.toml. Recorded for traceability
  # only — no resource here references the Worker.
  worker_name = "magmamoose-website"
}
