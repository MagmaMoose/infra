# A LocalStack root that instantiates the SAME module the Terragrunt leaf instantiates.
#
# It exists because the leaf cannot run locally: Terragrunt's root.hcl generates a GCS backend
# and providers that would try to reach real clouds. This root supplies a local backend and the
# LocalStack-pointed provider in `localstack_provider.tf`, and otherwise calls the same module
# source — so what is exercised here is the real module code.
#
# WHAT A LOCAL RUN PROVES, which is more than usual because the awkward parts were designed for
# it:
#
#   * the application, invoked as a Lambda through Mangum, answering real HTTP events;
#   * the whole Cognito flow — sign-up, confirm, sign-in, TOTP enrolment, token refresh —
#     against a pool minting REAL RS256 tokens, verified by the backend's own offline verifier;
#   * every SQL statement, against the same Postgres major RDS runs;
#   * the schema migration, run the way production runs it (a `{"task":"migrate"}` invocation);
#   * encrypted backup bodies going to S3 through the hand-rolled SigV4 signer;
#   * the dead-man sweep payload.
#
# WHAT IT DOES NOT PROVE, each because the community image cannot — the full list is in the
# module's `localstack` variable, and it is worth reading before treating a green run here as a
# validated production topology. The headline: **CloudFront and its Origin Access Control are
# absent, so the check that the Function URL is private is a curl against
# `function_url_for_verification` after the first real apply, and it must return 403.**

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
  }
}

variable "lambda_zip_path" {
  description = <<-EOT
    The built function package. `make -C aws dunmir-zip` produces it from a sibling dunmir
    checkout, installing the SAME `requirements.txt` the container image installs, for
    linux/aarch64 — so the dependency set under test is the one that ships.

    A zip rather than the image because container-image Lambdas are a LocalStack Pro feature.
    The image is proved separately, under AWS's own Runtime Interface Emulator
    (`make -C aws dunmir-image-test`).
  EOT
  type        = string
}

variable "cognito" {
  description = <<-EOT
    The moto-hosted pool, created by `seed.sh` BEFORE this root is applied.

    The ordering is forced and not incidental: the function needs the pool's signing keys as
    configuration (that is the whole reason it needs no egress in production), so the keys have
    to exist before the function is created. `seed.sh` writes this straight into
    `local.auto.tfvars.json`.
  EOT
  type = object({
    user_pool_id = string
    client_id    = string
    issuer       = string
    endpoint     = string
    jwks         = string
  })
}

module "platform" {
  source = "../modules/dunmir-platform"

  providers = {
    # The module declares an alias for CloudFront's us-east-1 certificate requirement. Nothing
    # here uses it (no distribution is created locally), but a module with a declared alias must
    # be passed one, so it is aliased onto the same LocalStack provider.
    aws           = aws
    aws.us_east_1 = aws
  }

  region      = "eu-west-1"
  environment = "local"
  localstack  = true

  # RDS is not emulated at all, so the database is a plain Postgres container on this compose
  # network. `postgres` resolves inside the Lambda container because LocalStack is told to
  # attach Lambda containers to this network — see LAMBDA_DOCKER_NETWORK in docker-compose.yml.
  db_mode      = "external"
  database_url = "postgresql://dunmir:dunmir@postgres:5432/dunmir"

  # By CONTAINER NAME, not localhost: the function runs in its own container on this compose
  # network, where `localhost` is itself. LocalStack is told to attach Lambda containers to this
  # network (LAMBDA_DOCKER_NETWORK), which is what makes both this and `postgres` resolve.
  s3_endpoint_override = "http://dunmir-localstack:4566" # DevSkim: ignore DS162092

  lambda_zip_path     = var.lambda_zip_path
  cognito_override    = var.cognito
  frontend_origin     = "http://localhost:5173"
  enable_budget_alarm = false
}

output "api_url" { value = module.platform.api_url }
output "function_name" { value = module.platform.lambda_function_name }
output "backups_bucket" { value = module.platform.backups_bucket }
output "cognito" { value = var.cognito }
output "console_env" { value = module.platform.console_env }
