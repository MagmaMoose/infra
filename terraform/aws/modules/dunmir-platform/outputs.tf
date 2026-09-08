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
    **`enable_custom_domain = true`** in the leaf and apply again. Empty when no custom domain
    is configured.

    DO NOT SET `certificate_arn` TO THE ARN BELOW, however natural that reads — it destroys the
    certificate it just told you to validate. `certificate_arn` is the BYO input, and
    `aws_acm_certificate.api` is counted on it being empty (edge.tf), so filling it in takes the
    module's own certificate from count 1 to 0. Terraform then deletes it and points
    `aws_apigatewayv2_domain_name` at the ARN of something that no longer exists. The `arn`
    field is here to check status with `aws acm describe-certificate`, nothing else.
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
          --cli-binary-format raw-in-base64-out --payload '{"task":"migrate"}' \
          /tmp/migrate.json > /tmp/migrate-meta.json
        jq -e 'has("FunctionError") | not' /tmp/migrate-meta.json >/dev/null
        jq -e '.ok == true' /tmp/migrate.json

    **The assertions are not decoration.** `aws lambda invoke` exits 0 whenever the API CALL
    succeeded — a handler that raised is still a successful invocation, reported only in
    `FunctionError` with the traceback in the payload. Without checking, a migration that died
    (an unreachable DSN, a SQL error, a timeout) looks exactly like one that worked, and the
    next step proceeds against an empty database.

    **A RESPONSE FILE, NOT `/dev/stdout`**, and the earlier version of this command got that
    wrong in a way that failed on SUCCESS. `aws lambda invoke` writes the function's response to
    the named file AND its own invoke metadata to stdout, so `… /dev/stdout | jq -e '.ok == true'`
    fed jq two JSON documents: the payload, then `{"StatusCode": 200, …}`. jq evaluates both,
    `.ok` is null on the second, and `-e` takes its exit status from the LAST output — so a
    perfectly good migration exited 1. Separating the two streams is what makes each assertion
    mean what it says.

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
    # EVERY third-party origin the console must reach, space-separated, ready to drop into
    # `connect-src`. It is a LIST because listing only Cognito is what let the object store go
    # missing from the policy: presigning was added, the round trip was proved with a Python
    # HTTP client that enforces no CSP, and the browser refused the fetch in production.
    #
    # The bucket origin appears only when presigned downloads are actually on. Naming an origin
    # the console never calls is not free — it is a host the page is permitted to talk to.
    csp_connect_src = join(" ", compact([
      local.cognito.endpoint,
      local.presigned_downloads ? local.s3_public_origin : "",
    ]))
  }
}

# --------------------------------------------------------------------------- #
# Federated sign-in
# --------------------------------------------------------------------------- #

output "cognito_domain" {
  description = <<-EOT
    The pool's OAuth origin, or "" when this deployment does not federate.

    Goes to the backend as `COGNITO_DOMAIN` and to the console's CSP as a `connect-src` entry.
    Those two must agree: the SPA navigates to `/oauth2/authorize` (a top-level navigation, which
    connect-src does not govern) and then FETCHES `/oauth2/token`, so a missing CSP entry fails
    at the very last step — after the operator has already authenticated at their provider — with
    a bare TypeError that names neither CSP nor Cognito.
  EOT
  value       = local.federates ? "https://${aws_cognito_user_pool_domain.this[0].domain}.auth.${var.region}.amazoncognito.com" : ""
}

output "cognito_idp_response_url" {
  description = <<-EOT
    The redirect URI to register with Google, Microsoft and Amazon.

    Every one of their consoles asks for it under a slightly different name — "Authorised
    redirect URI", "Redirect URI (Web)", "Allowed Return URL" — and all three mean this. A
    mismatch is refused by the PROVIDER, not by Cognito, so the error appears on their page in
    their wording and looks like nothing this system produced.
  EOT
  value       = local.federates ? "https://${aws_cognito_user_pool_domain.this[0].domain}.auth.${var.region}.amazoncognito.com/oauth2/idpresponse" : ""
}

output "cognito_saml_acs_url" {
  description = <<-EOT
    Cognito's assertion consumer service: where a CUSTOMER's SAML identity provider POSTs.

    One URL for the whole pool rather than one per connection — Cognito routes an assertion by
    the RelayState it issued, not by the endpoint. The console shows this to the customer
    alongside the entity id, so it is here for support conversations rather than for a variable.
  EOT
  value       = local.federates ? "https://${aws_cognito_user_pool_domain.this[0].domain}.auth.${var.region}.amazoncognito.com/saml2/idpresponse" : ""
}

output "cognito_saml_entity_id" {
  description = "The SAML audience Cognito presents to a customer's identity provider."
  value       = local.creates_pool ? "urn:amazon:cognito:sp:${aws_cognito_user_pool.this[0].id}" : ""
}

output "cognito_social_providers" {
  description = <<-EOT
    What to set `COGNITO_SOCIAL_PROVIDERS` to on the backend.

    These names travel verbatim in the browser's `identity_provider=` parameter, so the backend's
    list has to be the pool's list: naming one that does not exist is a Cognito error page on
    click, and omitting one that does means a button nobody ever sees.
  EOT
  value       = join(",", local.social_providers)
}

output "sso_manager_user_name" {
  description = <<-EOT
    The IAM user whose credential lets the console create a customer's identity provider.

    Mint the key by hand — Terraform deliberately does not, because `aws_iam_access_key` writes
    the secret into the state file:

        aws iam create-access-key --user-name "$(terragrunt output -raw sso_manager_user_name)"

    Then put both halves in OCI Vault as `dunmir-pro-cognito-admin-access-key-id` and
    `dunmir-pro-cognito-admin-secret-access-key`, add them to the ExternalSecret, and only then
    set `SSO_MANAGEMENT_ENABLED=true`. In that order: the ExternalSecret has no per-key
    "optional", so a remoteRef for a secret that does not exist yet fails the WHOLE Secret and
    every pod with it.
  EOT
  value       = local.federates && var.create_sso_manager_user ? aws_iam_user.sso_manager[0].name : ""
}

output "sso_reconcile_hint" {
  description = <<-EOT
    How to add a newly enabled social provider to the app client.

    Terraform stops managing `supported_identity_providers` once the application has written to
    it (see the `ignore_changes` in identity.tf, and why removing that would strip every
    customer's connection on the next apply). So enabling one of the `enable_*` flags creates the
    provider but does not reach the client, and the button then answers with a Cognito error that
    says the provider is not supported by this client.

    This is the one command that closes the gap. It re-sends the client's whole configuration —
    Cognito's update is a full replace, so a partial one would blank the callback URLs.
  EOT
  value = local.federates ? join(" ", [
    "aws cognito-idp describe-user-pool-client",
    "--user-pool-id ${aws_cognito_user_pool.this[0].id}",
    "--client-id ${aws_cognito_user_pool_client.console[0].id}",
    "--query UserPoolClient --output json > client.json &&",
    "jq '.SupportedIdentityProviders = [\"COGNITO\"${join("", [for p in local.social_providers : ",\"${p}\""])}] | del(.CreationDate,.LastModifiedDate,.ClientSecret)' client.json > update.json &&",
    "aws cognito-idp update-user-pool-client --cli-input-json file://update.json",
  ]) : ""
}
