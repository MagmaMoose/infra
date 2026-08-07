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

  # minio-backups: offsite mirror of the in-cluster MinIO buckets (thanos-metrics,
  # loki-chunks, loki-ruler) written daily by the minio-backup CronJob.
  bucket_names = ["postgres-backups", "plex-backups", "minio-backups", "longhorn-backups"]

  # vault-prod + key-vpn-prod (eu-amsterdam-1) — store + encrypt the S3 creds.
  vault_id    = "ocid1.vault.oc1.eu-amsterdam-1.fruyd6i7aagf4.abqw2ljrzcituk5pndpbgsvhtkgenvf2ae7xnlbctmskmcfj2gw6xsjhbgfq"
  key_id      = "ocid1.key.oc1.eu-amsterdam-1.fruyd6i7aagf4.abqw2ljr2tquiix4j3greeqmtg3hxutkve2u5vrhk5umbz2w4drizdoqy3ca"
  secret_name = "backup-oci-s3-credentials"
}
