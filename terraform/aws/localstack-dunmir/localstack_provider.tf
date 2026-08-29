# The provider that points every AWS call at LocalStack.
#
# Separate from main.tf so the difference between "this root" and "the Terragrunt leaf" is one
# file you can read in twenty seconds, rather than a flag threaded through a shared config.
#
# THE FILENAME IS LOAD-BEARING, and both obvious choices are booby-trapped by this
# repository's `.gitignore`:
#
#   provider_override.tf   matched by the stock HashiCorp `*_override.tf` rule (line 23);
#   provider.tf            matched by line 65, because Terragrunt GENERATES a provider.tf into
#                          every leaf and a generated file must not be committed.
#
# Either name is silently untracked. A fresh clone then gets this root with **no provider block
# at all**, and `terraform apply` falls back to the ambient AWS credentials and tries to build
# the stack in a real account. That is not hypothetical: the sibling
# `terraform/aws/localstack/` root refers to a `provider_override.tf` that is not in the
# repository, for exactly this reason.
#
# So: an ordinary name that no rule matches. The Terraform override semantics buy nothing here
# anyway — this is a standalone root with no base provider to override.

provider "aws" {
  region = "eu-west-1"

  # LocalStack accepts anything; these exist because the SDK refuses to sign without them.
  access_key = "test"
  secret_key = "test"

  # Without these the provider would try to reach the real AWS: verify an account id it cannot
  # see, validate credentials that are not real, and resolve a partition that does not apply.
  # Each one produces a slow, confusing failure rather than a clear one.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  # `s3_use_path_style` because LocalStack serves buckets at `localhost:4566/<bucket>` rather
  # than at a per-bucket virtual host, which is what the AWS endpoint does and what the
  # application is configured for in production (`S3_FORCE_PATH_STYLE=false` in lambda.tf).
  s3_use_path_style = true

  endpoints {
    cloudwatch = "http://localhost:4566" # DevSkim: ignore DS162092
    ec2        = "http://localhost:4566" # DevSkim: ignore DS162092
    events     = "http://localhost:4566" # DevSkim: ignore DS162092
    iam        = "http://localhost:4566" # DevSkim: ignore DS162092
    kms        = "http://localhost:4566" # DevSkim: ignore DS162092
    lambda     = "http://localhost:4566" # DevSkim: ignore DS162092
    logs       = "http://localhost:4566" # DevSkim: ignore DS162092
    s3         = "http://localhost:4566" # DevSkim: ignore DS162092
    s3control  = "http://localhost:4566" # DevSkim: ignore DS162092
    scheduler  = "http://localhost:4566" # DevSkim: ignore DS162092
    sns        = "http://localhost:4566" # DevSkim: ignore DS162092
    ssm        = "http://localhost:4566" # DevSkim: ignore DS162092
    sts        = "http://localhost:4566" # DevSkim: ignore DS162092
  }

  default_tags {
    tags = {
      ManagedBy = "localstack"
      Service   = "dunmir"
    }
  }
}
