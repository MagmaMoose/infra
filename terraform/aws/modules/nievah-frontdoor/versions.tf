# NO `provider` block and NO `backend` block, deliberately. Terragrunt's root.hcl generates
# both (`provider.tf` and `backend.tf`, each `if_exists = "overwrite"`), so anything declared
# here would be silently overwritten on the next run — see COMMON_MISTAKES #1. Region and
# credentials reach this module through the generated provider, not through a variable.
#
# `required_providers` IS allowed here and belongs here: it is the module's own contract about
# which providers it needs, and root.hcl's generated block declares a different set (oci), so
# the two merge rather than collide.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to a major. This comment used to justify the pin by an OAC feature and a
      # CloudFront resource, neither of which survived the pivot to an API Gateway HTTP API —
      # a stale rationale is worse than none, because the next person trusts it. The real
      # reason to pin: `aws_apigatewayv2_*`, `aws_scheduler_schedule` and the S3 tag reads
      # (which go through S3 Control) all shift behaviour across majors, and an unpinned
      # major would rewrite them on the next `init`.
      version = "~> 6.0"
    }
  }
}
