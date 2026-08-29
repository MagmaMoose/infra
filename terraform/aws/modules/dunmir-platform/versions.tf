# NO `provider` block and NO `backend` block, deliberately. Terragrunt's root.hcl generates
# both (`provider.tf` and `backend.tf`, each `if_exists = "overwrite"`), so anything declared
# here would be silently overwritten on the next run — see COMMON_MISTAKES #1. Region and
# credentials reach this module through the generated provider, not through a variable.
#
# `required_providers` IS allowed here and belongs here: it is the module's own contract about
# which providers it needs, and root.hcl's generated block declares a different set (oci), so
# the two merge rather than collide.
#
# ONE aws provider configuration, and that is a change worth noting: there used to be a
# `us.east_1` alias, needed for nothing but CloudFront's rule that it accepts ACM certificates
# from that region and no other. The edge is an API Gateway HTTP API now, whose custom domain
# takes a REGIONAL certificate from this region — so the alias, and the class of apply-time
# failure that comes from getting it wrong, are both gone.
#
# `http` is used once, at plan time, to read the Cognito pool's JWKS — see identity.tf for why
# that has to happen there rather than at runtime.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
