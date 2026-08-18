variable "name_prefix" {
  description = "Prefix for every resource name here."
  type        = string
  default     = "nievah"
}

variable "publisher_repo" {
  description = <<-EOT
    The ONLY repository allowed to assume the publish role, as `owner/name`. Bound into the
    OIDC trust policy's `sub` condition — see the note there; without it every GitHub Actions
    workflow on github.com could publish here.
  EOT
  type        = string
  default     = "MagmaMoose/nievah"
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the account's GitHub OIDC provider. AWS permits exactly ONE per issuer per account,
    so set this false and pass `github_oidc_provider_arn` if something else already made it —
    otherwise the apply fails with EntityAlreadyExists.
  EOT
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing provider ARN, used when create_github_oidc_provider is false."
  type        = string
  default     = ""
}

variable "github_oidc_thumbprints" {
  description = <<-EOT
    Thumbprints for GitHub's OIDC issuer. AWS stopped verifying these for well-known IdPs in
    2023, so the value is vestigial rather than load-bearing — but the field is still required
    and an empty list is rejected.
  EOT
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
