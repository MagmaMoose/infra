output "redirect_hostname" {
  description = "The redirect-only hostname this stack manages (the apex)"
  value       = cloudflare_dns_record.apex.name
}

output "canonical_url" {
  description = "Where the apex 301s to, and the host the site is actually served on. Its custom domain is attached by wrangler on deploy, from the Worker named in var.worker_name."
  value       = "https://www.${var.apex_domain}"
}
