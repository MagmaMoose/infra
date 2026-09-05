# A LocalStack root that instantiates BOTH modules exactly as the two Terragrunt leaves do.
#
# It exists because the leaves cannot run locally: Terragrunt's root.hcl generates a GCS
# backend and a `google` provider that would try to reach real Google. This root supplies a
# local backend and the LocalStack-pointed provider in `localstack_provider.tf`, and otherwise
# calls the same module source the leaves call — so what is exercised here is the real module
# code, including the `artifact_bucket` handoff between them.
#
# WHAT A LOCAL RUN DOES NOT PROVE, both because the free LocalStack image cannot:
#
#   CloudFront            Pro-only, so `localstack = true` removes the distribution and the
#                         Function URL is reachable directly. The ORIGIN ACCESS CONTROL that
#                         makes that URL private in production is therefore NOT exercised.
#                         The check for it is a curl against `function_url_for_verification`
#                         after the first real apply, and it must return 403.
#   EventBridge Scheduler Accepted and never fired, so no schedule is created. smoke.py
#                         invokes the producer with a tick payload directly instead, which
#                         covers everything downstream of the schedule — the part this repo
#                         owns.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "edge_zip_path" {
  description = <<-EOT
    The built Lambda package. `make -C terraform/aws edge-zip` produces it by running
    nievah's own `scripts/build_edge_zip.py` from a sibling checkout — deliberately the same
    script CI publishes with, so the local run and the released artifact cannot be built
    differently.
  EOT
  type        = string
}

variable "edge_artifact_version" {
  description = "Version label for the locally-built zip."
  type        = string
  default     = "0.0.0-local"
}

module "artifacts" {
  source = "../modules/artifacts"

  # No `region` — the module has no such variable (it takes its region from the provider, and
  # builds no ARNs by hand). It was passed anyway, which meant this root could never validate,
  # let alone apply. That went unnoticed for the same reason the provider file went missing:
  # nothing could run this, so nothing did.
  publisher_repo = "MagmaMoose/nievah"
}

# Stands in for nievah's publish-edge workflow, which is the only thing that writes here in
# production. Present ONLY in this root — neither leaf uploads an artifact, because a
# Terraform run that could rewrite the code it deploys is a Terraform run that can deploy
# something nobody reviewed.
resource "aws_s3_object" "edge" {
  bucket = module.artifacts.artifact_bucket
  key    = "edge/${var.edge_artifact_version}.zip"
  source = var.edge_zip_path
  etag   = filemd5(var.edge_zip_path)
}

module "frontdoor" {
  source = "../modules/nievah-frontdoor"

  region      = "eu-west-1"
  environment = "local"
  localstack  = true

  artifact_bucket       = module.artifacts.artifact_bucket
  edge_artifact_version = var.edge_artifact_version

  # The Lambda reads its key at create time, so the object has to be there first. Terraform
  # cannot infer this: the module takes a bucket NAME and a version string, neither of which
  # references the object resource.
  depends_on = [aws_s3_object.edge]
}

output "webhook_url" { value = module.frontdoor.webhook_url }
output "slack_interactions_url" { value = module.frontdoor.slack_interactions_url }
output "jobs_queue_url" { value = module.frontdoor.jobs_queue_url }
output "overflow_bucket" { value = module.frontdoor.overflow_bucket }
output "artifact_bucket" { value = module.artifacts.artifact_bucket }
