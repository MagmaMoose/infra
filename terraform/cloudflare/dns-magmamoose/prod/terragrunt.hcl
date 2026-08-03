# Cloudflare DNS records on the magmamoose.com zone.
#
# Modelled on terraform/cloudflare/dns/prod/terragrunt.hcl (the sargeant.co
# zone) — both use the same cloudflare-dns module but a Cloudflare zone is a
# hard provider-level boundary, so each zone needs its own terragrunt config
# + state. We deliberately do NOT include the legacy ../../terragrunt.hcl
# parent for the same reason that file documents: it hardcodes a state prefix
# that doesn't fit the cloudflare/prod layout.

remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "cloudflare/magmamoose/prod"
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
# Same secret used by terraform/cloudflare/dns/prod — the token is scoped at
# the account level so it can write into either zone.
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
  source = "${get_repo_root()}/terraform/cloudflare/modules/cloudflare-dns"

  extra_arguments "cloudflare_token" {
    commands = ["plan", "apply", "destroy", "import", "refresh", "validate"]
    env_vars = {
      CLOUDFLARE_API_TOKEN = local.cloudflare_api_token
    }
  }
}

generate "cloudflare_provider" {
  path      = "cloudflare_provider.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    provider "cloudflare" {}
  EOF
}

inputs = {
  # magmamoose.com zone.
  zone_id = "f04a8d6c68daf6ba1430c5645ca70cb8"

  records = [
    # comment-commander / comment-commander-pro DNS is managed in the zero-trust
    # layer (cloudflared tunnel + Access, zero-trust/prod), NOT here — having it
    # in both places double-manages the record and breaks `terragrunt apply`.
    # Diatreme docs (MkDocs) on GitHub Pages for repo MagmaMoose/diatreme; the
    # custom domain is pinned by docs/CNAME in that repo. DNS-only (grey cloud)
    # on purpose — GitHub provisions the Let's Encrypt cert over ACME, which a
    # Cloudflare proxy would intercept and break. (Replaces the old
    # semver.calebsargeant.com Pages domain.)
    {
      name    = "docs.diatreme.magmamoose.com"
      type    = "CNAME"
      value   = "magmamoose.github.io"
      proxied = false
    },

    # AppSec / dev tooling on firefly. These hosts have no Kubernetes Ingress
    # for external-dns to watch, so Terraform owns their tunnel CNAMEs directly.
    # Ingress-backed hosts such as Dependency-Track and Caldrith are
    # published by external-dns from their Ingress annotations instead.
    {
      name    = "pullrequests.magmamoose.com"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },
    {
      name    = "defectdojo.magmamoose.com"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },
    # ── Platform2 — multi-tenant ANPR platform (tengen-systems/platform2) ────
    # The backend and the driver run on firefly and are published by the firefly
    # cloudflared tunnel; the ingress rules are in
    # terraform/cloudflare/zero-trust/prod/tunnels.tf and these two records are
    # their half of the pair.
    #
    # Terraform owns them rather than external-dns for the reason the AppSec
    # block above states: both Helm charts keep ingress.enabled=false, because
    # the tunnel dials the ClusterIP Services by cluster DNS. No Ingress means
    # nothing for external-dns to watch, so nothing would publish these.
    #
    # Proxied is load-bearing, not cosmetic — a grey-cloud CNAME hands the
    # cfargotunnel.com target straight back to the client and the host simply
    # does not resolve (see the atlantis.sargeant.co comment in dns/prod, which
    # records that failure).
    {
      name    = "api.platform2.magmamoose.com"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },
    {
      name    = "driver.platform2.magmamoose.com"
      type    = "CNAME"
      value   = "7694eb38-c35e-4905-bd2b-16ab7053080a.cfargotunnel.com"
      proxied = true
    },

    # NOTE: platform2.magmamoose.com is deliberately absent. The console is a
    # Cloudflare Worker attached by *custom domain*, not by route, so wrangler
    # creates the record and the certificate itself as part of attaching — the
    # same split as www.magmamoose.com (see cloudflare/website-magmamoose/prod).
    #
    # This began as a proxied `AAAA 100::` placeholder, because a Worker route
    # creates no DNS and would otherwise leave the hostname NXDOMAIN. That is
    # exactly what happened: the Worker deployed with a correct route against a
    # hostname this stack had never applied, and the site was dark. The app repo
    # moved to a custom domain so its deploy is self-sufficient, which makes a
    # record here not merely redundant but conflicting — do not add one back.

    # NOTE: dunmir.magmamoose.com (Dün Mir Pro UI) is a Cloudflare Pages custom
    # domain — its DNS is created by the Pages "Custom domains" flow, NOT here.
    # A hand-written proxied CNAME to *.pages.dev is rejected with error 1014
    # ("CNAME Cross-User Banned") even within the same account. (Reverts #287.)
  ]
}
