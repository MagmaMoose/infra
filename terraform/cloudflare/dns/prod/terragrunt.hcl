# Self-contained terragrunt config for the prod Cloudflare DNS records.
# Doesn't include ../../terragrunt.hcl because that parent hardcodes the state
# prefix to "terraform/gcp_project" and uses a different bucket — colocating
# everything under sargeant-prod-terraform-state keeps state in one place.

# The GCS backend below authenticates with the dedicated
# atlantis@magmamoose-terraform service-account key (OCI Vault secret
# atlantis-gcp-sa-key) — see kubernetes/apps/atlantis/base/atlantis/README.md.
remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "cloudflare/prod"
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

# Cloudflare API token lives in OCI Vault (vault-prod / cloudflare-api-token).
# Fetched at parse time via the oci CLI, then exported as CLOUDFLARE_API_TOKEN
# so the cloudflare provider picks it up via its built-in env-var fallback —
# avoids writing the secret into a generated .tf file in the cache.
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

# Source the OCI MikroTik public IPs from the edge module's state instead of
# hardcoding them here. Today the edge module's VNICs use ephemeral public IPs
# (`assign_public_ip = true`) — those would change on instance recreate, and
# the literal-IP version of this file would silently leave DNS pointing at
# nothing. With the dependency, the apply graph re-renders DNS whenever the
# edge module re-allocates an IP. Mock outputs let `terragrunt plan/validate`
# work without read access to the edge state.
#
# Follow-up: add reserved public IPs to the edge module so the IPs survive
# instance recreate in the first place — that turns this dependency from
# "DNS automatically follows the IP" into "the IP doesn't change at all".
dependency "edge" {
  config_path = "../../../oci/prod/eu-amsterdam-1/edge"

  mock_outputs = {
    instances = {
      fd1 = { public_ip = "0.0.0.0" }
      fd2 = { public_ip = "0.0.0.0" }
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

terraform {
  source = "${get_repo_root()}/terraform/cloudflare/modules/cloudflare-dns"

  extra_arguments "cloudflare_token" {
    commands = ["plan", "apply", "destroy", "import", "refresh", "validate"]
    env_vars = {
      CLOUDFLARE_API_TOKEN = local.cloudflare_api_token
    }
  }
}

# Provider config belongs in the caller, not the cloudflare-dns module
# (terraform module-development guidance). Generated into the working dir at
# parse time; api_token is read from CLOUDFLARE_API_TOKEN env (above).
generate "cloudflare_provider" {
  path      = "cloudflare_provider.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    provider "cloudflare" {}
  EOF
}

inputs = {
  # sargeant.co zone (the previous value here was actually the *account* ID).
  zone_id = "e25f6d9e2d13d9c04988e459587101b5"

  records = [
    # Individual records for each OCI MikroTik so you can target one
    {
      name  = "oci1.sargeant.co"
      type  = "A"
      value = dependency.edge.outputs.instances["fd1"].public_ip
    },
    {
      name  = "oci2.sargeant.co"
      type  = "A"
      value = dependency.edge.outputs.instances["fd2"].public_ip
    },

    # Two A records under the same name produce DNS round-robin between r1+r2
    {
      name  = "oci.sargeant.co"
      type  = "A"
      value = dependency.edge.outputs.instances["fd1"].public_ip
    },
    {
      name  = "oci.sargeant.co"
      type  = "A"
      value = dependency.edge.outputs.instances["fd2"].public_ip
    },

    # Routes through the `firefly` cloudflared tunnel to the in-cluster
    # radarr service (k8s service: radarr.media.svc.cluster.local:7878,
    # see kubernetes/_base/media/radarr/service.yaml). Pairs with the
    # tunnel ingress rule in terraform/cloudflare/zero-trust/prod/tunnels.tf
    # and the cloudflare_zero_trust_access_application.radarr
    # self_hosted entry (no longer a bookmark). Must be proxied so CF
    # recognises the cfargotunnel.com target and routes via the tunnel.
    {
      name    = "radarr.sargeant.co"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },

    # Routes through the `firefly` tunnel to in-cluster Atlantis
    # (k8s service: atlantis.automation.svc.cluster.local:80). Pairs with
    # the ingress_rule in terraform/cloudflare/zero-trust/prod/tunnels.tf
    # (added in #216). Must be proxied — without it CF returns the
    # cfargotunnel.com hostname directly to GitHub and webhook delivery
    # fails. GitHub webhooks are HTTPS-only, which is fine: the proxied
    # CNAME terminates TLS at Cloudflare's edge.
    {
      name    = "atlantis.sargeant.co"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },

    # Public Warp custom inference endpoint for LiteLLM. Pairs with the
    # path-scoped ingress rules in zero-trust/prod/tunnels.tf and must stay
    # proxied so Warp sees a public Cloudflare edge address, not the LAN
    # Traefik address used by litellm.sargeant.co.
    {
      name    = "litellm-warp.sargeant.co"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },


    # ── AppSec / dev tooling on firefly (#394) ───────────────────────────────
    # Each pairs with a tunnel ingress_rule in
    # terraform/cloudflare/zero-trust/prod/tunnels.tf. Must be proxied so
    # Cloudflare routes via the `firefly` tunnel (a grey-cloud CNAME would hand
    # the cfargotunnel.com target straight back to the client). Without these
    # the hosts don't resolve (same reason the atlantis record above must be
    # proxied).
    {
      name    = "defectdojo.sargeant.co"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },
    # dependency-track.sargeant.co and dependency-track-api.sargeant.co were
    # REMOVED: they resolved to the same tunnel and the same two Services as the
    # magmamoose.com hostnames, so they bypassed the Cloudflare Access apps added
    # in terraform/cloudflare/zero-trust/prod/access_apps.tf. Paired with the
    # ingress_rule removal in that leaf's tunnels.tf.
    # (The old comment here claimed the SPA calls the API host directly from the
    # browser — that is false: the frontend's /static/config.json API_BASE_URL is
    # the same-origin dependencytrack.magmamoose.com apex.)
    {
      name    = "pr-dashboard.sargeant.co"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },
  ]

  # These four records already exist in the dashboard (someone re-created
  # them outside terraform after the initial zone_id bug). Importing instead
  # of re-creating. Safe to delete this block after the first clean apply
  # lands in state.
  imports = [
    { key = "oci1.sargeant.co#A#134.98.139.9", record_id = "06e99fd7050e4fdda75047ae12e45bdf" },
    { key = "oci2.sargeant.co#A#193.123.39.172", record_id = "df6b1879c47625d404c68a4d31948898" },
    { key = "oci.sargeant.co#A#134.98.139.9", record_id = "f0cfcdff5ce214beae99477f3c87d839" },
    { key = "oci.sargeant.co#A#193.123.39.172", record_id = "b76a4a6f0be53e5908552f2072a87b5b" },
  ]
}
