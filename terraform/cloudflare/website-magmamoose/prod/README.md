# magmamoose.com — zone-level configuration

Supports the static site in
[`MagmaMoose/website`](https://github.com/MagmaMoose/website), which is served by a
Cloudflare **Worker** (static assets), not Cloudflare Pages.

The site is **www-canonical**: every `<link rel="canonical">`, every `og:url` and
every `sitemap.xml` entry in the website repo points at `https://www.magmamoose.com`.
So `www` is the host that serves, and the apex exists only to forward to it.

## What this stack owns — and what it deliberately does not

| Owned here (Terraform)      | Owned by the website repo (wrangler)     |
| --------------------------- | ---------------------------------------- |
| `magmamoose.com` (apex) DNS | The Worker itself                        |
| The apex → `www` 301 rule   | `www`, its DNS record and its certificate |
|                             | `_headers` (CSP, HSTS, caching)          |

Attaching a custom domain is part of `wrangler deploy`, and Cloudflare provisions
that DNS record and certificate in the same call. Modelling `www` here as well would
put two systems on the same record, so the split is: **www = wrangler,
apex = Terraform.**

The apex is not a Worker route at all. The redirect below runs in the
`http_request_dynamic_redirect` phase, which is earlier than Workers — so apex
traffic never invokes anything.

## Why the redirect is not in the site's `_redirects` file

Cloudflare's `_redirects` matches on path only; domain-level redirects are
explicitly unsupported, on both Workers static assets and Pages. A zone rule is
also the cheaper place for it.

## Before the first apply

1. **Extend the API token.** This stack reuses the account-scoped
   `cloudflare-api-token` OCI Vault secret shared with `../../dns-magmamoose/prod`.
   Its DNS permissions cover the apex record; the redirect rule additionally needs
   `Zone → Transform Rules → Edit` on `magmamoose.com`. Grant it in the Cloudflare
   dashboard, then re-stash the token in OCI Vault.

   The token the *website repo* uses is a different one (an org-level Actions
   secret) with Workers permissions — see that repo's README.

2. **Check for existing redirect rules on the zone.** `cloudflare_ruleset` takes
   ownership of the zone's single `http_request_dynamic_redirect` entrypoint. If
   any dynamic redirects were created in the dashboard, the plan will show them
   being **removed** — codify them into `main.tf` first rather than applying.

3. **Clear the stale apex record.** As of 2026-07-24 the apex still carries a
   dashboard-managed record pointing at GitHub Pages (it answers 404 with
   `x-github-request-id` headers), left over from a previous hosting attempt. It is
   not in any Terraform state, so `cloudflare_dns_record.apex` will collide with it.
   Delete it in the dashboard first, or `terraform import` it into this stack.

## Ordering

This stack is independent of the Worker and can be applied before the site has ever
been deployed — the apex will 301 to `www` either way.

It is also **not required to get the site online.** `wrangler deploy` attaches `www`
by itself, and `www` is the canonical host. Without this stack the site is fully
live; the bare apex is just NXDOMAIN, so `magmamoose.com` without the `www.` does
not resolve.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | ~> 5.22 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | ~> 5.22 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [cloudflare_dns_record.apex](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_ruleset.dynamic_redirect](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_apex_domain"></a> [apex\_domain](#input\_apex\_domain) | The zone's apex. The site is www-canonical, so the apex only 301s to www.<apex\_domain>; www itself is the Worker's custom domain and is attached by wrangler, not here. | `string` | n/a | yes |
| <a name="input_worker_name"></a> [worker\_name](#input\_worker\_name) | Name of the Worker serving the site, as set in the website repo's wrangler.toml. Not referenced by any resource — recorded so the two repos can be tied together from either side. | `string` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Cloudflare zone ID for the site's apex domain (magmamoose.com) | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_canonical_url"></a> [canonical\_url](#output\_canonical\_url) | Where the apex 301s to, and the host the site is actually served on. Its custom domain is attached by wrangler on deploy, from the Worker named in var.worker\_name. |
| <a name="output_redirect_hostname"></a> [redirect\_hostname](#output\_redirect\_hostname) | The redirect-only hostname this stack manages (the apex) |
<!-- END_TF_DOCS -->
