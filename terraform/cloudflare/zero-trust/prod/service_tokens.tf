# Service tokens are non-human identities for hitting Access-protected
# services from automation. Caller sends:
#   CF-Access-Client-Id: <client_id>
#   CF-Access-Client-Secret: <client_secret>
# CF Access validates these against the service token and bypasses the
# normal IdP flow.
#
# Usage pattern:
#   1. Define the service token here.
#   2. Attach it to one or more Access policies via `include { service_token = [...] }`.
#   3. Pull the secret via (terragrunt — this module isn't run with bare tofu):
#        terragrunt output -raw service_token_<name>_client_secret
#        terragrunt output -raw service_token_<name>_client_id
#      and stash in OCI Vault. The client_secret is only readable at
#      create-time; rotating means destroy + recreate the resource.
#
# --- n8n-mcp -----------------------------------------------------------------
# Non-human identity for the n8n-mcp remote MCP endpoint (the /mcp path on
# n8n.magmamoose.com, kubernetes/apps/n8n-mcp). Claude Code / Claude Desktop send
# this token's CF-Access-Client-Id / CF-Access-Client-Secret headers (alongside
# the MCP's own Authorization: Bearer) so requests pass Cloudflare Access without
# a human SSO flow. Attached to the non_identity policy on the n8n_mcp Access app
# (access_apps.tf). The n8n REST API itself is NOT exposed — the MCP reaches it
# in-cluster — so this token only unlocks the MCP, which still enforces its bearer.
#
# After the first apply, pull the credentials and stash them in OCI Vault +
# the Claude client config (the secret is only readable at create-time; rotating
# means destroy + recreate this resource):
#   terragrunt output -raw service_token_n8n_mcp_client_id
#   terragrunt output -raw service_token_n8n_mcp_client_secret
resource "cloudflare_zero_trust_access_service_token" "n8n_mcp" {
  account_id = var.account_id
  name       = "n8n-mcp"
  # v4 only accepts these enum values: "8760h" (1y), "17520h" (2y), "43800h"
  # (5y), "87600h" (10y), or "forever". 1y is a sane default; recreate to rotate.
  duration = "8760h"
}

output "service_token_n8n_mcp_client_id" {
  value     = cloudflare_zero_trust_access_service_token.n8n_mcp.client_id
  sensitive = true
}

output "service_token_n8n_mcp_client_secret" {
  value     = cloudflare_zero_trust_access_service_token.n8n_mcp.client_secret
  sensitive = true
}

# --- dependency-track-api ----------------------------------------------------
# Non-human identity for dependencytrack-api.magmamoose.com, which has no known
# caller. Gating it with a token ONLY (no browser SSO policy) keeps it from
# becoming a UI back door while the hostname is retired.
# The secret is readable only at create time — after the first apply, stash it:
#   terragrunt output -raw service_token_dependency_track_api_client_id
#   terragrunt output -raw service_token_dependency_track_api_client_secret
# Rotating means destroy + recreate.
resource "cloudflare_zero_trust_access_service_token" "dependency_track_api" {
  account_id = var.account_id
  name       = "dependency-track-api"
  # v4 accepts only: 8760h (1y) | 17520h | 43800h | 87600h | forever
  # Expires approximately 2027-07 (one year after first apply ~2026-07).
  # Alert: check before then, especially if dependencytrack-api.magmamoose.com
  # is still alive — silently expired tokens leave the host unprotected.
  duration = "8760h"
}

output "service_token_dependency_track_api_client_id" {
  value     = cloudflare_zero_trust_access_service_token.dependency_track_api.client_id
  sensitive = true
}

output "service_token_dependency_track_api_client_secret" {
  value     = cloudflare_zero_trust_access_service_token.dependency_track_api.client_secret
  sensitive = true
}
