include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/backups"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

inputs = {
  tenancy_ocid = get_env("OCI_TENANCY_OCID", "")
  # Fall back to the tenancy (root) if no working compartment is set.
  compartment_ocid = get_env("OCI_COMPARTMENT_OCID", get_env("OCI_TENANCY_OCID", ""))
  region           = local.region_vars.locals.region
  environment      = local.environment_vars.locals.environment

  # minio-backups is gone: its CronJob was removed in October 2026 and the bucket was
  # emptied by a one-off lifecycle rule before this list dropped it. Terraform cannot
  # destroy a bucket that still holds objects or object versions.
  bucket_names = ["postgres-backups", "plex-backups", "longhorn-backups"]

  # vault-prod + key-vpn-prod (eu-amsterdam-1) — store + encrypt the S3 creds.
  vault_id    = "ocid1.vault.oc1.eu-amsterdam-1.fruyd6i7aagf4.abqw2ljrzcituk5pndpbgsvhtkgenvf2ae7xnlbctmskmcfj2gw6xsjhbgfq"
  key_id      = "ocid1.key.oc1.eu-amsterdam-1.fruyd6i7aagf4.abqw2ljr2tquiix4j3greeqmtg3hxutkve2u5vrhk5umbz2w4drizdoqy3ca"
  secret_name = "backup-oci-s3-credentials"
}
