output "api_url" {
  description = <<-EOT
    The API's public base URL — what `VITE_API_BASE` in the console's build must be set to, and
    what the RouterOS agents dial out to.

    Falls back to the CloudFront default hostname while the custom domain is in phase 1, so the
    stack is usable before DNS validation completes.
  EOT
  value = local.creates_api ? (
    local.attaches_domain
    ? "https://${var.api_domain_name}"
    : aws_apigatewayv2_api.api[0].api_endpoint
  ) : trimsuffix(aws_lambda_function_url.local[0].function_url, "/")
}

output "execute_api_endpoint" {
  description = <<-EOT
    The gateway's own `*.execute-api.<region>.amazonaws.com` hostname.

    Once `enable_custom_domain` is true the API sets `disable_execute_api_endpoint`, so this
    hostname stops answering — that is the post-apply check that the custom domain is the only
    way in:

        curl -si "$(terragrunt output -raw execute_api_endpoint)/v1/health" | head -1

    It must return 403 in phase 2, and 200 in phase 1 (when it is the only entrypoint there is).
  EOT
  value       = local.creates_api ? aws_apigatewayv2_api.api[0].api_endpoint : ""
}

output "api_domain_target" {
  description = <<-EOT
    What the `api.` record in Cloudflare must CNAME to — API Gateway's regional target domain
    for the custom domain, not the gateway's own hostname.

    It must be **DNS-only (grey cloud)**. Proxying it would put Cloudflare in front of a
    hostname whose TLS certificate ACM issued for that exact name, and it is also what keeps
    the two-label-hostname trap irrelevant: `api.dunmir.magmamoose.com` is two labels deep,
    which Cloudflare's Universal SSL does not cover, but here Cloudflare terminates nothing.

    Empty until `enable_custom_domain` is true (phase 2).
  EOT
  value       = local.attaches_domain ? aws_apigatewayv2_domain_name.api[0].domain_name_configuration[0].target_domain_name : ""
}

output "certificate_validation_record" {
  description = <<-EOT
    The DNS record that validates the ACM certificate — phase 1's whole output.

    Create it in Cloudflare (DNS-only), wait for ACM to report ISSUED, then set
    `certificate_arn` in the leaf and apply again. Empty when no custom domain is configured.
  EOT
  value = local.creates_api && local.wants_domain && var.certificate_arn == "" ? {
    name  = one(aws_acm_certificate.api[0].domain_validation_options).resource_record_name
    type  = one(aws_acm_certificate.api[0].domain_validation_options).resource_record_type
    value = one(aws_acm_certificate.api[0].domain_validation_options).resource_record_value
    arn   = aws_acm_certificate.api[0].arn
  } : null
}

output "cognito_user_pool_id" {
  description = "The pool operators authenticate against. Public — it travels in every browser request to Cognito."
  value       = local.cognito.user_pool_id
}

output "cognito_app_client_id" {
  description = <<-EOT
    The console's public app client. No secret exists for it, by design — a secret in a browser
    bundle is not a secret, and its mere presence would make every unauthenticated Cognito call
    require a SECRET_HASH the SPA cannot compute.
  EOT
  value       = local.cognito.client_id
}

output "cognito_issuer" {
  description = "Expected `iss` claim on every token this deployment accepts."
  value       = local.cognito_issuer
}

output "backups_bucket" {
  description = "S3 bucket holding encrypted device-backup bodies."
  value       = aws_s3_bucket.backups.bucket
}

output "lambda_function_name" {
  description = <<-EOT
    The function's name — needed to apply the schema, which is the one deploy step Terraform
    does not perform for you:

        aws lambda invoke --function-name "$(terragrunt output -raw lambda_function_name)" \
          --cli-binary-format raw-in-base64-out --payload '{"task":"migrate"}' /dev/stdout

    It has to run from in here because the database has no public address; this function is the
    only thing inside the VPC that can reach it. The schema is idempotent, so re-running is a
    no-op.
  EOT
  value       = aws_lambda_function.api.function_name
}

output "database_endpoint" {
  description = "RDS endpoint, or empty in `external`/LocalStack mode. Reachable only from the function's security group."
  value       = local.creates_database ? aws_db_instance.this[0].address : ""
}

output "console_env" {
  description = <<-EOT
    What the Cloudflare-hosted console needs at build time, and what its CSP must name.

    `VITE_API_BASE` is a BUILD-time constant in the SPA and CI asserts it appears in the bundle
    AND matches the `connect-src` in `public/_headers`. A mismatch is invisible: the console
    renders, and every call is blocked by the browser in a way indistinguishable from the API
    being down.

    The Cognito parameters are deliberately NOT here — the console fetches them at runtime from
    `GET /api/session/config`, so repointing it at another pool is a backend setting rather than
    a front-end release.

    PHASE 1 IS NOT USABLE BY THE CONSOLE. Before the custom domain exists this resolves to the
    `*.execute-api` hostname, which is neither what CI pins the bundle to nor what the CSP's
    `connect-src` allows — so the browser would block every call. Phase 1 is for `curl` and for
    an agent smoke test; deploy the console after phase 2.
  EOT
  value = {
    VITE_API_BASE = local.creates_api ? (
      local.attaches_domain
      ? "https://${var.api_domain_name}"
      : aws_apigatewayv2_api.api[0].api_endpoint
    ) : trimsuffix(aws_lambda_function_url.local[0].function_url, "/")
    csp_connect_src = local.cognito.endpoint
  }
}
