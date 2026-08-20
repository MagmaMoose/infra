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
    # ── Email authentication ────────────────────────────────────────────────
    # magmamoose.com receives mail via iCloud custom email domain (MX ->
    # mx0{1,2}.mail.icloud.com). Cloudflare Security Insights flagged a weak
    # DMARC record; this brings DMARC under Terraform and adds aggregate
    # reporting so we can see who is sending as the domain.
    #
    # Policy stays p=none (monitor only) on purpose: it is the safe first step,
    # zero deliverability risk. Once the rua reports are clean, tighten to
    # p=quarantine in a follow-up.
    #
    # rua is a magmamoose.com address, so NO external _report authorisation
    # record is needed. The dmarc@ mailbox must exist to actually collect the
    # daily XML reports — add it as an iCloud alias, or change this to
    # hello@magmamoose.com. The record is valid either way.
    #
    # ⚠️ FIRST APPLY — the zone already has a dashboard-managed `_dmarc` TXT
    # (`v=DMARC1; p=none;`). This module keys records by name#type#value, so with
    # a different value it will try to CREATE a second `_dmarc` record, and two
    # DMARC records is an INVALID (ignored) DMARC. Before `atlantis apply`,
    # delete the existing `_dmarc` TXT in the Cloudflare dashboard — it is the
    # trivial p=none record, and the momentary gap changes nothing (p=none has no
    # enforcement). Same pre-existing-record handling as the apex in
    # cloudflare/website-magmamoose/prod. (Alternative: import it via this
    # module's `imports` input using its record_id.)
    #
    # NOT modelled here: the MX records (this module has no `priority` field) and
    # the existing SPF TXT (`v=spf1 include:icloud.com ~all`, which is already
    # the correct iCloud record — Cloudflare's SPF flag is a false positive).
    # Both stay dashboard-managed, matching how sargeant.co handles email too.
    {
      name    = "_dmarc.magmamoose.com"
      type    = "TXT"
      value   = "v=DMARC1; p=none; rua=mailto:dmarc@magmamoose.com;"
      proxied = false
    },

    # Diatreme docs (MkDocs) on GitHub Pages for repo MagmaMoose/diatreme; the
    # custom domain is pinned by docs/CNAME in that repo. DNS-only (grey cloud)
    # on purpose — GitHub provisions the Let's Encrypt cert over ACME, which a
    # Cloudflare proxy would intercept and break. (Replaces the old
    # semver.calebsargeant.com Pages domain.)
    # ── Nievah webhook front door (AWS) ─────────────────────────────────────
    # GitHub and Slack POST here; an API Gateway HTTP API in prd-nievah
    # (666802049426, eu-west-1) verifies the HMAC and parks the delivery on SQS,
    # and the firefly cluster pulls. See magmamoose/infra
    # terraform/aws/prod/eu-west-1/nievah-frontdoor.
    #
    # BOTH RECORDS ARE DNS-ONLY (grey cloud), for two different reasons:
    #
    #   the _acm one  a proxied record answers with Cloudflare's own value, so ACM
    #                 never sees the token and the certificate never leaves
    #                 PENDING_VALIDATION. Same class of trap as the docs.diatreme
    #                 record above, where a proxy would intercept the ACME challenge.
    #   the hooks one proxying would put Cloudflare back in the webhook path, seeing
    #                 every payload and adding a hop — which is precisely the
    #                 dependency moving this to AWS removed. It would also need
    #                 SSL mode set to Full (strict) to avoid a redirect loop.
    #
    # The target is the API Gateway CUSTOM DOMAIN, never the execute-api hostname:
    # that one serves a certificate for *.execute-api.eu-west-1.amazonaws.com and
    # routes on the Host header, so a custom name pointed at it fails the TLS
    # handshake before a request is ever made.
    # ── Caldrith webhook front door (AWS) ───────────────────────────────────
    # Same shape as nievah below, in prd-caldrith (483461801743, eu-west-1). See
    # terraform/aws/prod/eu-west-1/caldrith-frontdoor.
    #
    # THE NAME IS FLAT — hooks-caldrith, not hooks.caldrith. Cloudflare's Universal
    # SSL covers magmamoose.com and *.magmamoose.com and nothing deeper, so a
    # two-label name cannot be proxied without Advanced Certificate Manager, which
    # is billed per zone. A hyphen keeps the option of an orange cloud free.
    # nievah's hooks.nievah.magmamoose.com below has this problem — see
    # MagmaMoose/nievah#190.
    #
    # The _acm record is DNS-ONLY and must stay that way: a proxied record answers
    # with Cloudflare's own value, so ACM never sees the token and the certificate
    # never leaves PENDING_VALIDATION.
    {
      name    = "_c4642f6ed3fbe2411e167b468569d039.hooks-caldrith.magmamoose.com"
      type    = "CNAME"
      value   = "_23d294f538d7b65298130b308cbd64b8.jkddzztszm.acm-validations.aws"
      proxied = false
      ttl     = 1
    },

    # The webhook endpoint itself. The target is the API Gateway CUSTOM DOMAIN, never the
    # execute-api hostname — that one serves a cert for *.execute-api.eu-west-1.amazonaws.com
    # and routes on the Host header, so a custom name pointed at it fails the TLS handshake
    # before a request is made.
    #
    # GREY FOR NOW, ORANGE SHORTLY. Proxying is the whole reason the name is flat, and it is
    # what puts Cloudflare in front of the layer that actually bills. It is grey on the first
    # cut because deliveries were already failing and this is the shortest path back: an
    # orange record additionally needs the zone on SSL mode Full (strict), or the proxy and
    # API Gateway negotiate a redirect loop. Flip once a real reconcile has landed.
    #
    # Note nievah reaches the opposite conclusion for its own record below — proxying puts
    # Cloudflare back in the webhook path, seeing every payload, which is the dependency that
    # moving to AWS removed. That is a real trade, not an oversight: the counterweight here is
    # that API Gateway bills per request and Cloudflare absorbs a flood for free.
    {
      name    = "hooks-caldrith.magmamoose.com"
      type    = "CNAME"
      value   = "d-wqr6tt5298.execute-api.eu-west-1.amazonaws.com"
      proxied = false
      ttl     = 1
    },

    {
      name    = "_1315506cb658bc3f6612f54dc0c17f8b.hooks.nievah.magmamoose.com"
      type    = "CNAME"
      value   = "_32ff523bc625ac74d3e220ea2aa4e63c.jkddzztszm.acm-validations.aws"
      proxied = false
    },

    {
      name    = "hooks.nievah.magmamoose.com"
      type    = "CNAME"
      value   = "d-rbhug3v46l.execute-api.eu-west-1.amazonaws.com"
      proxied = false
    },

    # ── Chargate's token broker ────────────────────────────────────────────
    #
    # broker-chargate.magmamoose.com fronts an API Gateway HTTP API -> Lambda in chargate's
    # own AWS account (495408387666, eu-west-1). It exchanges a consumer's GitHub Actions
    # OIDC token for a repo-scoped Chargate[bot] installation token, so Chargate's PR
    # comments carry that byline. See magmamoose/infra terraform/aws/chargate.
    #
    # THE TWO RECORDS ARE DELIBERATELY DIFFERENT, and getting them the wrong way round is a
    # silent failure both times:
    #
    #   the _acm one  GREY. A proxied record answers with Cloudflare's own value, so ACM
    #                 never sees the token and the certificate never leaves
    #                 PENDING_VALIDATION. Same trap as the nievah and docs.diatreme records.
    #   the broker    ORANGE, unlike nievah's hooks record. The API Gateway throttle bounds
    #                 the LAMBDA bill deterministically but not the GATEWAY bill — AWS does
    #                 not document whether it charges for the 429s it issues — so proxying is
    #                 what keeps a flood from ever reaching the meter. It also hides the
    #                 origin, which `disable_default_endpoint = true` on the API then closes
    #                 properly.
    #
    # A FIRST-LEVEL SUBDOMAIN ON PURPOSE. Cloudflare's free Universal SSL covers the apex and
    # ONE label, so broker.chargate.magmamoose.com could not be proxied without Advanced
    # Certificate Manager. hooks.nievah and hooks.caldrith are both two deep and stuck for
    # exactly that reason.
    #
    # The target is the API Gateway CUSTOM DOMAIN, never the execute-api hostname: that one
    # serves a certificate for *.execute-api.eu-west-1.amazonaws.com and routes on the Host
    # header, so a custom name pointed at it fails the TLS handshake.
    {
      name    = "_bf0be45d232be0da6efc719a32fe9da8.broker-chargate.magmamoose.com"
      type    = "CNAME"
      value   = "_4ea71f052a53a751b7c10b12ff0dbaef.jkddzztszm.acm-validations.aws"
      proxied = false
    },

    # PROXIED, and it took a fight to get here — recorded so nobody "simplifies" it back to grey.
    #
    # Proxied, this returned Cloudflare 521 on every request while AWS saw NOTHING: API
    # Gateway's Count metric had no datapoints and a unique probe path never reached the
    # Lambda. The origin was healthy throughout — TCP/443 on every IP, correct certificate for
    # both plausible SNIs, no AAAA records so not the broken-IPv6-origin trap — and port 80 was
    # refused on every origin IP, which is the port a "Flexible" origin fetch dials. Setting the
    # zone's SSL/TLS mode to Full (strict) is what fixed it.
    #
    # Worth keeping proxied: it keeps an abusive flood off AWS's meter entirely, which matters
    # because the 2 rps stage throttle bounds the LAMBDA bill deterministically but not the API
    # GATEWAY bill — AWS does not document whether it charges for the 429s it issues.
    {
      name    = "broker-chargate.magmamoose.com"
      type    = "CNAME"
      value   = "d-um036cwvi6.execute-api.eu-west-1.amazonaws.com"
      proxied = true
    },

    # The OLD chargate broker hostname, kept alive for the migration window. ~23 repositories
    # pin chargate by SHA through a centrally-provisioned workflow, and `token_broker_url` is an
    # action input with a DEFAULT — so the old name is frozen into every tag released before the
    # rename and they cannot all be moved at once. Without these two records every one of them
    # silently falls back to `github-actions[bot]`.
    #
    # The _acm one stays GREY — a proxied record answers with Cloudflare's own value, so ACM
    # never sees the token and the certificate never leaves PENDING_VALIDATION. The hostname
    # itself is proxied, like broker-chargate.
    #
    # Remove both once no pinned consumer references chargate.magmamoose.com.
    {
      name    = "_ac7f3003f47fad3ba7709a917150f813.chargate.magmamoose.com"
      type    = "CNAME"
      value   = "_5c116c8ef24a1d60cc2d7005cffdc265.jkddzztszm.acm-validations.aws"
      proxied = false
    },

    # ── Brimyr's token broker ──────────────────────────────────────────────
    #
    # The same shape as chargate's above, in brimyr's own AWS account (202518311296,
    # eu-west-1), exchanging a caller's Actions OIDC token for a repo-scoped Brimyr[bot]
    # installation token so brimyr's patch-coverage comment carries that byline.
    # See magmamoose/infra terraform/aws/brimyr and MagmaMoose/brimyr#11.
    #
    # TWO BROKERS, NEVER ONE, and therefore two audiences: `aud=brimyr` here against
    # `aud=chargate` above. One minter holding both Apps' private keys would mean
    # compromising either surface yields both identities.
    #
    # PHASE 1 — only the _acm record exists yet. GREY, and it must stay grey: a proxied
    # validation record answers with Cloudflare's own value, ACM never sees the token, and
    # the certificate never leaves PENDING_VALIDATION. The ORANGE service record follows
    # once the certificate is ISSUED and the API Gateway custom domain exists to point at —
    # its target is `target_domain_name` (a d-xxxx.execute-api name), NEVER the plain
    # execute-api hostname, which serves a certificate for *.execute-api.eu-west-1.
    # amazonaws.com and would fail the TLS handshake for this name.
    {
      name    = "_1193f7e750e37befac82a4316b6e1d7d.broker-brimyr.magmamoose.com"
      type    = "CNAME"
      value   = "_adda14532e3947306ab5308f252f0eb1.jkddzztszm.acm-validations.aws"
      proxied = false
    },

    {
      name    = "broker-brimyr.magmamoose.com"
      type    = "CNAME"
      value   = "d-mwephkxe83.execute-api.eu-west-1.amazonaws.com"
      proxied = true
    },

    # PROXIED, and this is the one that matters most for cost: ~23 repositories are pinned to a
    # chargate SHA whose action.yml still defaults to THIS hostname, so it carries essentially
    # all consumer traffic while broker-chargate carries almost none.
    {
      name    = "chargate.magmamoose.com"
      type    = "CNAME"
      value   = "d-5w3egcz0s6.execute-api.eu-west-1.amazonaws.com"
      proxied = true
    },

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

  # Records that already exist in the dashboard, brought under management rather than
  # recreated — the provider refuses to create over an existing record ("expected DNS record
  # to not already be present"), which is what a plain apply hit here. Both were verified
  # against the live zone before importing: name, value and proxied all match the entries
  # above, so these import as a clean no-op rather than a diff.
  #
  # Can be emptied once the import has landed in state.
  imports = [
    {
      key       = "_c4642f6ed3fbe2411e167b468569d039.hooks-caldrith.magmamoose.com#CNAME#_23d294f538d7b65298130b308cbd64b8.jkddzztszm.acm-validations.aws"
      record_id = "599a2ffc0355234722f847f288e6b948"
    },
    {
      key       = "hooks-caldrith.magmamoose.com#CNAME#d-wqr6tt5298.execute-api.eu-west-1.amazonaws.com"
      record_id = "ec261cc60bea045f7eed37e342902bee"
    },
  ]
}
