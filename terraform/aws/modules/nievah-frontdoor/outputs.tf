locals {
  # The API's own hostname in production; the Function URL under LocalStack. Both end in a
  # trailing slash-free base, so the routes append cleanly.
  base_url = var.localstack ? trimsuffix(aws_lambda_function_url.producer[0].function_url, "/") : (
    var.domain_name != "" ? "https://${var.domain_name}" : aws_apigatewayv2_api.producer[0].api_endpoint
  )
}

output "webhook_url" {
  description = "Point the GitHub App's webhook URL here."
  value       = "${local.base_url}/webhooks/github"
}

output "slack_interactions_url" {
  description = "Point the Slack app's interactivity request URL here."
  value       = "${local.base_url}/slack/interactions"
}

output "healthz_url" {
  description = "Liveness. Says nothing about the cluster — this is useful precisely when that is down."
  value       = "${local.base_url}/healthz"
}

output "api_endpoint" {
  description = "The API's own hostname. CNAME target is not needed — a custom domain is native (see api.tf)."
  value       = var.localstack ? "" : aws_apigatewayv2_api.producer[0].api_endpoint
}

output "jobs_queue_url" {
  description = "AppConfig.sqs_jobs_queue_url for the worker."
  value       = aws_sqs_queue.jobs.id
}

output "overflow_bucket" {
  description = "AppConfig.sqs_overflow_bucket for the worker."
  value       = aws_s3_bucket.overflow.id
}

output "secret_path" {
  description = "SSM path the producer reads. Put webhook-secret and slack-signing-secret here."
  value       = local.secret_path
}

output "edge_artifact_key" {
  description = "The S3 key this stack is running. Cross-check against nievah's published artifacts."
  value       = local.artifact_key
}

output "cluster_access_key_id" {
  description = "Access key id for the worker's SQS consumer."
  value       = aws_iam_access_key.cluster.id
}

# Marked sensitive so it is not echoed by `terraform apply`, `terraform output`, or a CI log.
# Read it deliberately with `terraform output -raw cluster_secret_access_key` and put it
# straight into OCI Vault — see aws/README.md.
output "cluster_secret_access_key" {
  description = "Secret key for the worker's SQS consumer. Goes to OCI Vault, nowhere else."
  value       = aws_iam_access_key.cluster.secret
  sensitive   = true
}

# --- custom domain, phase by phase ----------------------------------------------------------

# Phase 1: the CNAME that proves domain ownership to ACM. Add it to
# terraform/cloudflare/dns-magmamoose/prod, DNS-only (grey cloud) — a proxied record answers
# with Cloudflare's own value and validation never completes.
output "certificate_validation_record" {
  description = "name/value CNAME to add to Cloudflare so ACM can issue the certificate."
  value = var.localstack || var.domain_name == "" ? null : {
    name  = tolist(aws_acm_certificate.producer[0].domain_validation_options)[0].resource_record_name
    value = tolist(aws_acm_certificate.producer[0].domain_validation_options)[0].resource_record_value
    type  = tolist(aws_acm_certificate.producer[0].domain_validation_options)[0].resource_record_type
  }
}

output "certificate_arn" {
  description = "The requested certificate. Watch it reach ISSUED before enable_custom_domain."
  value       = var.localstack || var.domain_name == "" ? "" : aws_acm_certificate.producer[0].arn
}

# Phase 2: what the hostname itself should CNAME to. NOT the execute-api hostname — that one
# serves a certificate for *.execute-api.<region>.amazonaws.com and routes on the Host header,
# so pointing a custom name at it fails the TLS handshake before any request is made.
output "custom_domain_target" {
  description = "CNAME target for domain_name. Empty until enable_custom_domain is true."
  value = var.localstack || var.domain_name == "" || !var.enable_custom_domain ? "" : (
    aws_apigatewayv2_domain_name.producer[0].domain_name_configuration[0].target_domain_name
  )
}
