output "webhook_url" {
  description = "Point the GitHub App's webhook URL here."
  value = var.localstack ? (
    "${aws_lambda_function_url.producer.function_url}webhooks/github"
    ) : (
    "https://${var.domain_name != "" ? var.domain_name : aws_cloudfront_distribution.producer[0].domain_name}/webhooks/github"
  )
}

output "slack_interactions_url" {
  description = "Point the Slack app's interactivity request URL here."
  value = var.localstack ? (
    "${aws_lambda_function_url.producer.function_url}slack/interactions"
    ) : (
    "https://${var.domain_name != "" ? var.domain_name : aws_cloudfront_distribution.producer[0].domain_name}/slack/interactions"
  )
}

output "cloudfront_domain" {
  description = "CNAME target when domain_name is set. Empty under LocalStack."
  value       = var.localstack ? "" : aws_cloudfront_distribution.producer[0].domain_name
}

# The Function URL, exposed for ONE purpose: proving it is unreachable.
#
# LocalStack cannot emulate CloudFront, so the local run leaves origin access control
# completely unexercised — the single most important thing in edge.tf and the one thing
# "it worked locally" says nothing about. After the first deploy:
#
#     curl -si "$(tofu output -raw function_url_for_verification)" | head -1
#
# MUST be 403. A 202 means the OAC is not signing, the function is accepting unsigned
# callers, and there is a second unprotected front door on a guessable hostname.
output "function_url_for_verification" {
  description = "Direct Function URL. Expect 403 in production — see the note above."
  value       = "${aws_lambda_function_url.producer.function_url}healthz"
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
