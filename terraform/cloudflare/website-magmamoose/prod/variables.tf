variable "zone_id" {
  description = "Cloudflare zone ID for the site's apex domain (magmamoose.com)"
  type        = string
}

variable "apex_domain" {
  description = "The zone's apex. The site is www-canonical, so the apex only 301s to www.<apex_domain>; www itself is the Worker's custom domain and is attached by wrangler, not here."
  type        = string
}

variable "worker_name" {
  description = "Name of the Worker serving the site, as set in the website repo's wrangler.toml. Not referenced by any resource — recorded so the two repos can be tied together from either side."
  type        = string
}
