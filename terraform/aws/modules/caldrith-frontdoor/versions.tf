# NO `provider` block and NO `backend` block, deliberately. Terragrunt's root.hcl generates
# both (`provider.tf` and `backend.tf`, each `if_exists = "overwrite"`), so anything declared
# here would be silently overwritten on the next run — see COMMON_MISTAKES #1. Region and
# credentials reach this module through the generated provider, not through a variable.
#
# `required_providers` IS allowed here and belongs here: it is the module's own contract about
# which providers it needs, and root.hcl's generated block declares a different set (oci), so
# the two merge rather than collide. root.hcl suppresses its OCI half for `provider = "aws"`
# leaves precisely so this declaration can exist.
terraform {
  # >= 1.9 is a HARD floor, not a habit. `variable "api_flood_alarm_hourly_count"` validates
  # itself against `var.throttle_rate_limit`, and cross-variable references in a `validation`
  # block landed in Terraform 1.9. On 1.8 that validation is a parse error, not a silent
  # no-op — which is the good failure, but it is still a floor worth naming. root.hcl pins
  # `terraform_version = "1.11.3"`, comfortably above it.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to a major. The behaviours this module depends on that DO shift across majors:
      # `aws_apigatewayv2_*` (the whole front door), `aws_lambda_event_source_mapping`'s
      # `scaling_config` block, and `aws_budgets_budget`'s notification schema. An unpinned
      # major would rewrite all three on the next `init`, and two of them are the cost
      # controls.
      version = "~> 6.0"
    }
  }
}
