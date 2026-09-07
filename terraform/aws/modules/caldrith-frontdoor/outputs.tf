locals {
  # The API's own hostname in production; the Function URL under LocalStack. Both end in a
  # trailing-slash-free base, so the routes append cleanly.
  #
  # GATED ON enable_custom_domain, NOT ON domain_name ALONE. The custom domain bootstraps in two
  # phases — the ACM cert is requested and validated before the domain is attached — and
  # `domain_name` is set throughout both. Keying off it alone made nievah's `webhook_url`
  # advertise a hostname that did not route yet during phase 1, which is a URL you would paste
  # into a GitHub App and then spend a while wondering about.
  base_url = var.localstack ? trimsuffix(aws_lambda_function_url.producer[0].function_url, "/") : (
    var.domain_name != "" && var.enable_custom_domain ? "https://${var.domain_name}" : aws_apigatewayv2_api.producer[0].api_endpoint
  )
}

# THE INGEST IS THE ROOT PATH. `caldrith.api.webhooks` mounts the receiver at `POST /` — there
# is no `/github` or `/webhook` suffix, unlike nievah's front door, and this is the single
# easiest thing to get wrong when copying that stack's runbook. A GitHub App pointed at
# `https://hooks-caldrith.magmamoose.com/github` gets a 404 on every delivery, which GitHub
# displays as a red tick in the App's Advanced tab and nowhere else.
output "webhook_url" {
  description = "Point the GitHub App's webhook URL here. NOTE the bare trailing slash: Caldrith's ingest is POST / and not a named path."
  value       = "${local.base_url}/"
}

# ONE URL PER REGISTRATION, because `webhook_url` above is only the DEFAULT registration's and
# there is now more than one App to point somewhere. The key is the slug; the default's is the
# bare root path (`registration.webhook_path` returns "/" for DEFAULT_REGISTRATION, not
# "/h/github"), and every extra is `/h/<slug>`.
#
# THE FAILURE MODE IS THE SAME ONE `webhook_url` WARNS ABOUT, ONE STEP WORSE. An App pointed at
# the wrong slug — or at "/" when it should be "/h/pinkroccade" — does not error visibly: at
# "/" the delivery is verified against github.com's webhook secret, fails, and returns 401
# "invalid signature", which reads as a rotated secret and sends the operator to fix something
# that was never broken. `registration_from_path` is deliberately built so an unknown slug 404s
# instead, but only the URL being wrong in the *slug* position gets that treatment.
#
# There is NO API Gateway route per slug and there must not be: api.tf routes `$default` and
# the producer dispatches on rawPath (`_INGEST_PREFIX = "/h/"`), so these URLs work with no
# gateway change at all.
output "registration_webhook_urls" {
  description = "Where each registration's GitHub App must point its webhook, keyed by slug. The default registration is the bare root path; every extra is /h/<slug>."
  value = merge(
    { (local.default_registration) = "${local.base_url}/" },
    { for slug, _ in local.extra_registrations : slug => "${local.base_url}/h/${slug}" },
  )
}

output "healthz_url" {
  description = "Liveness. No dependencies — it is useful precisely when everything behind it is broken."
  value       = "${local.base_url}/healthz"
}

# `/readyz` IS NOT OUTPUT, DELIBERATELY. In the service it pings Redis, and there is no Redis in
# this design (see lambda.tf) — so a route by that name either fails always or lies always,
# and both are worse than its absence. If the edge handler keeps a readiness probe at all, the
# honest serverless version answers "can I reach SSM and SQS", and it should be added here at
# the same time as it starts meaning that.

output "reconcile_url" {
  description = "Break-glass: POST here with `Authorization: Bearer <manual-trigger-token>` to reconcile every installation. Returns 404 while that parameter is unset, so the endpoint's existence is not advertised."
  value       = "${local.base_url}/reconcile"
}

output "api_endpoint" {
  description = "The API's own hostname. Not a CNAME target — a custom domain is native (see api.tf), and CNAMEing at this hostname fails the TLS handshake."
  value       = var.localstack ? "" : aws_apigatewayv2_api.producer[0].api_endpoint
}

# --- the moving parts, for debugging and for the console ------------------------------------

output "jobs_queue_url" {
  description = "Reconcile work awaiting a run. A backlog here is what `caldrith-jobs-not-being-reconciled` alarms on."
  value       = aws_sqs_queue.jobs.id
}

output "dedup_table" {
  description = "Delivery-id claims, 24h TTL. This is what replaced Redis SET NX."
  value       = aws_dynamodb_table.dedup.name
}

output "entitlement_table" {
  description = "Whether an account may be reconciled. Hash key `pk` = ent#<registration>#<account>, lowercased. Durable: no TTL (its `expires_at` is read, not a delete instruction) and PITR on. The reconcile function has GetItem and nothing else; rows are written by billing, or by hand with `aws dynamodb put-item`."
  value       = aws_dynamodb_table.entitlements.name
}

output "reconcile_function_name" {
  description = "For `aws lambda invoke` and for reading its log group directly."
  value       = aws_lambda_function.reconcile.function_name
}

# --- secrets: the paths, never the values ---------------------------------------------------
#
# Terraform deliberately does not CREATE any of these. A secret in a resource is a secret in
# state, and this stack's state holds the GitHub App private key nowhere — which is the point.
# `aws ssm put-parameter` them by hand once; see the cold start in the leaf.
#
# THERE IS NO `cluster_access_key_id` / `cluster_secret_access_key` HERE, and if you arrived
# from nievah's runbook looking for them: they do not exist by design. Those outputs exist there
# to hand a long-lived IAM user key to a Kubernetes worker outside AWS. Caldrith has no cluster
# and no such user (see iam.tf), so this module's state holds no credential at all.

output "secret_path" {
  description = "SSM prefix the functions read from."
  value       = local.secret_path
}

output "secret_parameter_names" {
  description = "Every SecureString this stack expects, and which function reads it. Create them by hand before the first real delivery."
  value = {
    webhook_secret       = local.ssm_webhook_secret
    manual_trigger_token = local.ssm_manual_trigger
    app_id               = local.ssm_app_id
    private_key          = local.ssm_private_key

    # THREE MORE PER EXTRA REGISTRATION, AND THIS OUTPUT IS THE CREATE-LIST. Nothing else
    # enumerates them: Terraform does not create the parameters, the leaf's runbook comment is
    # prose, and the Lambda environment holds the names but only after an apply nobody reads.
    # A parameter missing from here is therefore a parameter that never gets written — and the
    # symptom is a host whose every delivery 404s (missing webhook-secret) or whose every
    # reconcile job dies inside `_secret` (missing app-id or private-key), with no other
    # signal, because the default registration keeps working perfectly the whole time.
    #
    # The four above stay FLAT and unprefixed. They are live, and `registration.
    # DEFAULT_REGISTRATION = "github"` is unprefixed everywhere else in the codebase.
    registrations = {
      for slug, r in local.extra_registrations : slug => {
        webhook_secret = r.webhook_secret_param
        app_id         = r.app_id_param
        private_key    = r.private_key_param
      }
    }
  }
}

# --- what is deployed -----------------------------------------------------------------------

output "artifact_keys" {
  description = "The S3 keys this stack is running, both derived from artifact_version. Cross-check against what caldrith's publish workflow produced — a version whose reconcile zip failed to upload leaves the function pointed at a key that does not exist."
  value = {
    edge      = local.edge_key
    reconcile = local.reconcile_key
  }
}

# --- custom domain, phase by phase ----------------------------------------------------------

# Phase 1: the CNAME that proves domain ownership to ACM. Add it to
# terraform/cloudflare/dns-magmamoose/prod, DNS-only (grey cloud) — a proxied record answers
# with Cloudflare's own value and validation never completes.
output "certificate_validation_record" {
  description = "name/value CNAME to add to Cloudflare so ACM can issue the certificate. Grey cloud."
  value = var.localstack || var.domain_name == "" || var.certificate_arn != "" ? null : {
    name  = tolist(aws_acm_certificate.producer[0].domain_validation_options)[0].resource_record_name
    value = tolist(aws_acm_certificate.producer[0].domain_validation_options)[0].resource_record_value
    type  = tolist(aws_acm_certificate.producer[0].domain_validation_options)[0].resource_record_type
  }
}

output "certificate_arn" {
  description = "The requested certificate. Watch it reach ISSUED before setting enable_custom_domain."
  value       = var.localstack || var.domain_name == "" || var.certificate_arn != "" ? "" : aws_acm_certificate.producer[0].arn
}

# Phase 2: what the hostname itself should CNAME to. NOT the execute-api hostname — that one
# serves a certificate for *.execute-api.<region>.amazonaws.com and routes on the Host header,
# so pointing a custom name at it fails the TLS handshake before any request is made.
output "custom_domain_target" {
  description = "CNAME target for domain_name, DNS-only. Empty until enable_custom_domain is true."
  value = var.localstack || var.domain_name == "" || !var.enable_custom_domain ? "" : (
    aws_apigatewayv2_domain_name.producer[0].domain_name_configuration[0].target_domain_name
  )
}
