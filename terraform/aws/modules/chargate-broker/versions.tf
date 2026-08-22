# NO `provider` block and NO `backend` block, deliberately. Terragrunt's root.hcl generates
# both (`provider.tf` and `backend.tf`, each `if_exists = "overwrite"`), so anything declared
# here would be silently overwritten on the next run — see COMMON_MISTAKES #1. Region and
# credentials reach this module through the generated provider, not through a variable.
#
# `required_providers` IS allowed here and belongs here: it is the module's own contract about
# which providers it needs.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Same major as the nievah front door, for the same reason: `aws_apigatewayv2_*` shifts
      # behaviour across majors and an unpinned major would rewrite them on the next `init`.
      version = "~> 6.0"
    }
  }
}
