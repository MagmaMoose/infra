output "api_url" {
  description = <<-EOT
    The API's public base URL — what `VITE_API_BASE` in the console's build must be set to, and
    what the RouterOS agents dial out to.

    Falls back to the CloudFront default hostname while the custom domain is in phase 1, so the
    stack is usable before DNS validation completes.
  EOT
  value = local.creates_distribution ? (
    local.attaches_certificate
    ? "https://${var.api_domain_name}"
    : "https://${aws_cloudfront_distribution.api[0].domain_name}"
  ) : trimsuffix(aws_lambda_function_url.api.function_url, "/")
}

output "function_url_for_verification" {
  description = <<-EOT
    The raw Function URL. **Not an entrypoint — a test target.**

    After the first real apply, curl it. It MUST return 403: the URL is `AWS_IAM`-authorised and
    only CloudFront's Origin Access Control can sign for it, so a 200 here means the origin is
    reachable without the edge and every control in front of it is one DNS lookup away from
    being bypassed. This is the single check a LocalStack run cannot perform, because the
    community image has no CloudFront.

        curl -si "$(terragrunt output -raw function_url_for_verification)" | head -1
  EOT
  value       = aws_lambda_function_url.api.function_url
}

output "cloudfront_domain_name" {
  description = <<-EOT
    The distribution's own hostname. The `api.` record in Cloudflare is a CNAME to this, and it
    must be **DNS-only (grey cloud)**: proxying it would put Cloudflare in front of CloudFront,
    terminating TLS for a certificate ACM issued and breaking the two-label hostname that
    Cloudflare's Universal SSL does not cover anyway.
  EOT
  value       = local.creates_distribution ? aws_cloudfront_distribution.api[0].domain_name : ""
}

output "certificate_validation_record" {
  description = <<-EOT
    The DNS record that validates the ACM certificate — phase 1's whole output.

    Create it in Cloudflare (DNS-only), wait for ACM to report ISSUED, then set
    `certificate_arn` in the leaf and apply again. Empty when no custom domain is configured.
  EOT
  value = local.creates_distribution && local.wants_domain ? {
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
  EOT
  value = {
    VITE_API_BASE = local.creates_distribution ? (
      local.attaches_certificate
      ? "https://${var.api_domain_name}"
      : "https://${aws_cloudfront_distribution.api[0].domain_name}"
    ) : trimsuffix(aws_lambda_function_url.api.function_url, "/")
    csp_connect_src = local.cognito.endpoint
  }
}
