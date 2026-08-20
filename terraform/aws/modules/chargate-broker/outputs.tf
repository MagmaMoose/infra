output "api_endpoint" {
  description = <<-EOT
    The API's own execute-api URL. Smoke-test against this BEFORE any DNS exists — and note it
    stops answering once `disable_default_endpoint` is true, which is the point of that flag.
  EOT
  value       = aws_apigatewayv2_api.broker.api_endpoint
}

output "api_id" {
  description = "API id, for `aws apigatewayv2 get-api` and for correlating CloudWatch metrics."
  value       = aws_apigatewayv2_api.broker.id
}

output "certificate_validation_record" {
  description = <<-EOT
    The CNAME to add to the Cloudflare leaf, GREY CLOUD, to validate the certificate. A proxied
    record answers with Cloudflare's own value, ACM never sees the token, and the certificate
    stays PENDING_VALIDATION forever.
  EOT
  value = var.domain_name == "" ? null : {
    name  = tolist(aws_acm_certificate.broker[0].domain_validation_options)[0].resource_record_name
    type  = tolist(aws_acm_certificate.broker[0].domain_validation_options)[0].resource_record_type
    value = tolist(aws_acm_certificate.broker[0].domain_validation_options)[0].resource_record_value
  }
}

output "custom_domain_target" {
  description = <<-EOT
    CNAME `domain_name` at this, PROXIED (orange cloud). Only exists once
    `enable_custom_domain` is true.

    This `d-*` value changes if the API Gateway DOMAIN is destroyed and recreated, and the record
    pointing at it lives in another Terraform state behind a hard provider boundary — so avoid
    `destroy` on this leaf. Replacing the API itself does not touch it.
  EOT
  value       = var.domain_name == "" || !var.enable_custom_domain ? null : aws_apigatewayv2_domain_name.broker[0].domain_name_configuration[0].target_domain_name
}

output "secret_path" {
  description = "SSM path the function reads its App credentials from. Seed these BY HAND — a secret in Terraform state is a secret in a public repo."
  value       = local.secret_path
}

output "function_name" {
  description = "For `aws logs tail /aws/lambda/<name>`."
  value       = aws_lambda_function.broker.function_name
}

output "ops_topic_arn" {
  description = "SNS topic every alarm and both budget notifications publish to."
  value       = aws_sns_topic.ops.arn
}

output "additional_certificate_validation_records" {
  description = "Per additional hostname, the CNAME to add to the Cloudflare leaf GREY to validate its certificate."
  value = {
    for d, c in aws_acm_certificate.additional :
    d => {
      name  = tolist(c.domain_validation_options)[0].resource_record_name
      type  = tolist(c.domain_validation_options)[0].resource_record_type
      value = tolist(c.domain_validation_options)[0].resource_record_value
    }
  }
}

output "additional_domain_targets" {
  description = "Per additional hostname, the target to CNAME it at once its certificate is ISSUED."
  value = {
    for d, n in aws_apigatewayv2_domain_name.additional :
    d => n.domain_name_configuration[0].target_domain_name
  }
}
