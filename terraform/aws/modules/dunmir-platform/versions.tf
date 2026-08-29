# NO `provider` block and NO `backend` block, deliberately. Terragrunt's root.hcl generates
# both (`provider.tf` and `backend.tf`, each `if_exists = "overwrite"`), so anything declared
# here would be silently overwritten on the next run — see COMMON_MISTAKES #1. Region and
# credentials reach this module through the generated provider, not through a variable.
#
# `required_providers` IS allowed here and belongs here: it is the module's own contract about
# which providers it needs, and root.hcl's generated block declares a different set (oci), so
# the two merge rather than collide.
#
# TWO aws provider CONFIGURATIONS are declared. `aws` is the stack's own region; `aws.us_east_1`
# exists solely because **CloudFront only accepts an ACM certificate from us-east-1**, wherever
# the rest of the stack lives. That is not a preference, it is a hard API constraint, and the
# error when you get it wrong ("The specified SSL certificate doesn't exist, isn't in
# us-east-1…") arrives at apply time after everything else has already been built.
#
# `http` is used once, at plan time, to read the Cognito pool's JWKS — see identity.tf for why
# that has to happen here rather than at runtime.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
