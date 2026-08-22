terraform {
  source = "${get_repo_root()}/terraform/oci/modules/iam-policy"
}

# Cross-tenancy DRG remote-peering trust. Sargeant is the ACCEPTOR; FranklinHouse
# (the requestor) initiates the RPC `connect`, so its admin group is admitted to
# `remote-peering-to` here. The peer tenancy + admin-group OCIDs are recon-grade
# (they enumerate cross-tenant trust) and live in OCI Vault as `infra-recon-blockers`
# (vault-prod); fetched at parse time via the operator's ~/.oci/config and decoded
# as JSON. Only the iam_peers.* sub-keys are consumed here.
locals {
  recon_blockers_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aa7mytuezgibzn4g36jxupsgy57zl4372uq47atgfra2ka"

  # Direct `oci` call + base64decode in HCL (no `bash -c`) so this parses on
  # Windows/PowerShell, which has no bash. Pattern: cloudflare/zero-trust/prod.
  recon_blockers = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.recon_blockers_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))

  franklinhouse_tenancy_ocid      = local.recon_blockers.iam_peers.franklinhouse_tenancy_ocid
  franklinhouse_admins_group_ocid = local.recon_blockers.iam_peers.franklinhouse_admins_group_ocid
}

inputs = {
  tenancy_ocid     = get_env("OCI_TENANCY_OCID", "")
  compartment_ocid = get_env("OCI_TENANCY_OCID", "") # Root-level policy
  region           = "eu-amsterdam-1"
  environment      = "prod"

  policy_name = "drg-cross-tenancy-peering-acceptor"
  description = "Allow Sargeant (acceptor) to peer with FranklinHouse"

  # Sargeant is the ACCEPTOR. `Define group` binds the peer admin group name to
  # its OCID so `Admit` can reference it; `Admit ... remote-peering-to` lets the
  # FranklinHouse requestor establish the RPC against Sargeant's DRG; the final
  # `Allow` lets Sargeant's own admins manage the RPC resource. Mirrors the
  # requestor-side `Endorse ... remote-peering-to in tenancy sargeant` in the
  # FranklinHouse tenancy (MagmaMoose/franklinhouse repo).
  #
  # NOTE: this policy already exists live (created by hand to bring the peering
  # up). Import it into state before the first apply, or the create 409s on the
  # duplicate name — see the PR description for the exact import command.
  statements = [
    "Define tenancy franklinhouse as ${local.franklinhouse_tenancy_ocid}",
    "Define group FranklinHouseAdmins as ${local.franklinhouse_admins_group_ocid}",
    "Admit group FranklinHouseAdmins of tenancy franklinhouse to manage remote-peering-to in tenancy",
    "Allow group Administrators to manage remote-peering-connections in tenancy",
  ]
}

remote_state {
  backend = "gcs"
  config = {
    bucket   = "sargeant-prod-terraform-state"
    prefix   = "oci/iam-policy"
    project  = "magmamoose-terraform"
    location = "europe-west4"
  }
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  backend "gcs" {}
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "google" {
  project         = "magmamoose-terraform"
  region          = "europe-west4"
  impersonate_service_account = "deployer@magmamoose-terraform.iam.gserviceaccount.com"
}

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = "${get_env("OCI_TENANCY_OCID", "")}"
  user_ocid        = "${get_env("OCI_USER_OCID", "")}"
  private_key_path = "${get_env("OCI_PRIVATE_KEY_PATH", "")}"
  fingerprint      = "${get_env("OCI_FINGERPRINT", "")}"
  region           = "eu-amsterdam-1"
}
EOF
}
