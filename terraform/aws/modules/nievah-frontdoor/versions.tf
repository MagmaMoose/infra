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
      # Pinned to a minor. The Lambda-function-URL origin access control this module depends
      # on landed in 5.x, and an unpinned major would silently rewrite the CloudFront resource
      # on the next `init`.
      version = "~> 6.0"
    }
  }
}
