variable "account_id" {
  description = "Cloudflare account ID (Zero Trust org)"
  type        = string
}

variable "cf_access_groups_membership" {
  description = "Email member lists for each Access group, sourced from OCI Vault by the terragrunt parse-time run_cmd (see terragrunt.hcl). Kept out of git so the public repo doesn't list family/friends' personal addresses (PII)."
  type = object({
    friends        = list(string)
    caleb          = list(string)
    household      = list(string)
    caleb_personal = list(string)
    marc           = list(string)
  })
  sensitive = true
}

provider "cloudflare" {}
