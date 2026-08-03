# magmamoose.com (the apex) — DNS + the 301 to www.
#
# The site is www-canonical: every <link rel="canonical">, every og:url and every
# sitemap.xml entry in the website repo points at https://www.magmamoose.com. So
# www is the host that actually serves, and the apex exists only to forward to it.
#
# This stack owns the apex and nothing else. www itself — the Worker's custom
# domain, its DNS record and its certificate — is attached by `wrangler deploy`
# from the website repo, because attaching a custom domain provisions all three in
# one call. Declaring it here as well would put two systems on the same record.
#
# So: www = wrangler, apex = Terraform.

# The apex has to resolve to Cloudflare for the redirect rule to get a request to
# act on at all; without a record it is simply NXDOMAIN and the rule never runs.
# Proxied (orange cloud) for the same reason.
#
# CNAME at the zone root, which Cloudflare resolves via CNAME flattening. Pointed
# at www rather than the usual 100:: black-hole address used for redirect-only
# hostnames: if the rule below is ever disabled, the apex quietly serves the site
# instead of erroring. Duplicate content is a much softer failure than an outage on
# the domain people type.
resource "cloudflare_dns_record" "apex" {
  zone_id = var.zone_id
  name    = var.apex_domain
  type    = "CNAME"
  content = "www.${var.apex_domain}"
  proxied = true
  # 1 = "automatic". Required: a proxied record cannot carry a real TTL, because
  # Cloudflare is answering for it.
  ttl     = 1
  comment = "Managed by Terraform — redirects to www, see cloudflare_ruleset.dynamic_redirect"
}

# apex -> www redirect.
#
# Why this is not in the site's _redirects file: Cloudflare's _redirects supports
# path matching only — domain-level redirects are explicitly unsupported, on both
# Workers static assets and Pages. A dynamic redirect also runs at the edge before
# the request reaches the Worker, so apex traffic never invokes anything.
#
# IMPORTANT — ENTRYPOINT OWNERSHIP. A zone has exactly ONE
# http_request_dynamic_redirect entrypoint ruleset, and this resource takes it
# over. If redirect rules already exist in the dashboard for magmamoose.com, the
# Atlantis plan will show them being REMOVED — do not apply in that case; codify
# them into `rules` below first. Same hazard, same handling as the WAF entrypoint
# in cloudflare/zero-trust/prod/waf.tf.
resource "cloudflare_ruleset" "dynamic_redirect" {
  zone_id     = var.zone_id
  name        = "default"
  description = "Zone dynamic redirects (${var.apex_domain})"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "apex_to_www"
      description = "301 ${var.apex_domain} to www, preserving path and query"
      expression  = "(http.host eq \"${var.apex_domain}\")"
      action      = "redirect"
      enabled     = true

      action_parameters = {
        from_value = {
          # 301, not 302: www is the canonical host in the site's own metadata, so
          # this should be cached by clients and consolidate search ranking rather
          # than be re-resolved on every visit.
          status_code = 301
          target_url = {
            expression = "concat(\"https://www.${var.apex_domain}\", http.request.uri.path)"
          }
          preserve_query_string = true
        }
      }
    }
  ]
}
