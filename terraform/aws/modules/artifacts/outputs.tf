output "artifact_bucket" {
  description = "Feed this to the nievah-frontdoor leaf's artifact_bucket input."
  value       = aws_s3_bucket.artifacts.id
}

output "publish_role_arn" {
  description = "role-to-assume for nievah's publish-edge workflow."
  value       = aws_iam_role.publish.arn
}

output "github_oidc_provider_arn" {
  description = "Pass to any later stack that needs GitHub OIDC in this account."
  value       = local.oidc_arn
}
