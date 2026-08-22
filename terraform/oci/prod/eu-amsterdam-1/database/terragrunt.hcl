include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/database"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    data_subnet_id = "mock-data-subnet-id"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  tenancy_ocid     = get_env("OCI_TENANCY_OCID", "")
  compartment_ocid = get_env("OCI_COMPARTMENT_OCID", "")
  region           = local.region_vars.locals.region
  environment      = local.environment_vars.locals.environment

  # Use data subnet from network module
  subnet_id = dependency.network.outputs.data_subnet_id

  # MySQL configuration
  shape_name              = "MySQL.Free" # Free tier shape
  data_storage_size_in_gb = 50           # Free tier includes 50GB
  # MUST match the live DB system. It reports 26.7.0; this said 9.6.0, a version
  # OCI no longer offers. mysql_version forces replacement, and prevent_destroy is
  # false on this resource, so a plan run against the stale pin would have proposed
  # DESTROYING the DB system and creating a new one — losing its data — rather than
  # failing. That was survivable only while nothing could run terragrunt here; the
  # org runner group now permits this public repo, so CI can reach this leaf.
  #
  # Verified against the live system with `oci mysql db-system get`, not assumed.
  mysql_version = "26.7.0"

  # Admin credentials. OCI_MYSQL_ADMIN_PASSWORD MUST be set in the environment
  # for any terragrunt invocation on this stack (parse-time fetch — plan,
  # apply, refresh, destroy all evaluate it). The DB system is in the
  # private `data` subnet (`prohibit_public_ip_on_vnic = true`) so a weak
  # password isn't directly internet-reachable, but in-VCN compromise +
  # a guessable admin password is still a credible escalation path.
  #
  # 2-arg `get_env(name, "")` matches the repo's convention; the explicit
  # `regex("^.+$", ...)` is an HCL-level assert that fails the parse with
  # "regexp pattern did not match" when the env is empty/unset — fail-
  # closed without depending on the downstream OCI provider catching it
  # later. A follow-up should migrate this to OCI Vault to match the
  # rest of the repo's secret pattern (would require a coordinated live
  # password rotation, so not bundled here).
  admin_username = "admin"
  admin_password = regex("^.+$", get_env("OCI_MYSQL_ADMIN_PASSWORD", ""))

  # Backup configuration
  backup_enabled           = false
  backup_retention_days    = 7
  backup_window_start_time = "02:00"

  # Maintenance window (Sunday 3 AM UTC)
  maintenance_window_start_time = "SUNDAY 03:00"

  # Fault domain
  fault_domain = 0 # FD-1

  # Deletion protection (set to true in production)
  is_delete_protected = false

  # Crash recovery
  crash_recovery = "ENABLED"
}
