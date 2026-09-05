# The provider that points every AWS call at LocalStack.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THIS FILE WAS MISSING FROM THE REPOSITORY, and its absence was dangerous rather than merely
# inconvenient. `main.tf`'s header described it, `make -C terraform/aws dev` depended on it, and
# `git ls-files terraform/aws/localstack/` returned only four files — none of them this one.
#
# On a fresh clone the local root therefore had NO provider block at all. Terraform falls back
# to the ambient credentials, so `make dev` would have attempted to build nievah's entire front
# door — Lambda, SQS, S3, DynamoDB, EventBridge Scheduler, an API Gateway — in whatever real AWS
# account the operator happened to be authenticated to. A command whose whole purpose is "run
# this locally, touch nothing real" was one `aws sso login` away from doing the opposite.
#
# THE FILENAME IS LOAD-BEARING, and both obvious choices are booby-trapped by this repository's
# `.gitignore`:
#
#   provider_override.tf   matched by the stock HashiCorp `*_override.tf` rule (line 23);
#   provider.tf            matched by line 65, because Terragrunt GENERATES a provider.tf into
#                          every leaf and a generated file must not be committed.
#
# Either name is silently untracked — which is exactly how the original went missing. So: an
# ordinary name that no rule matches. Verify with `git check-ignore -v <path>` after any rename.
# The Terraform "override" semantics buy nothing here anyway: this is a standalone root with no
# base provider to override.
# ─────────────────────────────────────────────────────────────────────────────────────────────

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

  # LocalStack serves buckets at `localhost:4566/<bucket>` rather than at a per-bucket virtual
  # host, which is what the real endpoint does.
  s3_use_path_style = true

  # Every service the two modules touch, plus `s3control`: AWS provider v6 reads a bucket's tags
  # through the S3 Control API rather than the S3 API, so `default_tags` makes an
  # `aws_s3_bucket` apply fail with a 501 without it.
  endpoints {
    apigatewayv2 = "http://localhost:4566" # DevSkim: ignore DS162092
    cloudwatch   = "http://localhost:4566" # DevSkim: ignore DS162092
    dynamodb     = "http://localhost:4566" # DevSkim: ignore DS162092
    events       = "http://localhost:4566" # DevSkim: ignore DS162092
    iam          = "http://localhost:4566" # DevSkim: ignore DS162092
    kms          = "http://localhost:4566" # DevSkim: ignore DS162092
    lambda       = "http://localhost:4566" # DevSkim: ignore DS162092
    logs         = "http://localhost:4566" # DevSkim: ignore DS162092
    s3           = "http://localhost:4566" # DevSkim: ignore DS162092
    s3control    = "http://localhost:4566" # DevSkim: ignore DS162092
    scheduler    = "http://localhost:4566" # DevSkim: ignore DS162092
    sns          = "http://localhost:4566" # DevSkim: ignore DS162092
    sqs          = "http://localhost:4566" # DevSkim: ignore DS162092
    ssm          = "http://localhost:4566" # DevSkim: ignore DS162092
    sts          = "http://localhost:4566" # DevSkim: ignore DS162092
  }

  default_tags {
    tags = {
      ManagedBy = "localstack"
      Service   = "nievah"
    }
  }
}
