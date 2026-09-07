# Monthly spend backstop for the FIREFLY tenancy (the primary Oracle account, eu-amsterdam-1).
#
# The account's own email is not written here on purpose. It would be a third copy of a value
# this leaf goes out of its way to read from OCI Vault instead of the repo, and a comment that
# contradicts the code twenty lines below it is worse than no comment.
#
# This tenancy is PAYG, not Always Free — its service limits sit well above the free tier — so
# nothing here is protected by Oracle simply refusing to provision. That is precisely why it
# needs the budget: an accidental non-free shape applies successfully and bills quietly.
#
# Verified before writing this: the tenancy had NO budgets at all, so this is new coverage
# rather than a second opinion on an existing one.
#
# See modules/budget/main.tf for why alerts are email-only and why Slack coverage has to come
# from the daily cost report instead.
include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/budget"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # The operator's email is recon material in a PUBLIC repo — it is the account-recovery
  # address for both Oracle tenancies and a ready-made phishing target — so it lives in OCI
  # Vault beside the WAN IPs, in the same `infra-recon-blockers` secret ../vpn-fortigate reads.
  #
  # Chosen over an env var deliberately. This leaf autoplans (see atlantis.yaml), and an env
  # var would have to be injected into the Atlantis deployment as well as set on every operator
  # machine; miss either and the leaf becomes a permanently red check nobody can fix. The vault
  # path is already proven on Atlantis by ../network, which autoplans through the same run_cmd.
  # It also leaves one place to rotate instead of N.
  #
  # ONE-TIME SETUP, DO THIS BEFORE MERGING: add `contacts.budget_alert_email` to the
  # `infra-recon-blockers` secret. This leaf autoplans, so until that key exists Atlantis fails
  # here at parse time with `This object does not have an attribute named "contacts"`. That is
  # a self-clearing red check, not a permanent one, but it is red.
  #
  # Indexed directly rather than through try(), and that ordering pain is the price of it: a
  # try() fallback to "" would apply perfectly cleanly and produce a budget whose alerts go
  # nowhere. A mute backstop that reports green is the one outcome worse than no backstop.
  recon_blockers_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aa7mytuezgibzn4g36jxupsgy57zl4372uq47atgfra2ka"

  # Direct `oci` call + base64decode in HCL (no `bash -c`) so this parses on
  # Windows/PowerShell, which has no bash. Pattern: cloudflare/zero-trust/prod.
  recon_blockers = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.recon_blockers_secret_ocid,
    "--region", local.region_vars.locals.region,
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))
  budget_alert_email = local.recon_blockers.contacts.budget_alert_email
}

inputs = {
  tenancy_ocid = get_env("OCI_TENANCY_OCID", "")

  # The budget's target. Verified live rather than inferred from the cloudworkers case:
  # firefly's only child compartment is Oracle's own ManagedCompartmentForPaaS, and every real
  # resource (vcn-prod, ff-oci1, ff-oci2, prod-mikrotik-chr-fd1/fd2) is in root — so
  # OCI_COMPARTMENT_OCID is the tenancy OCID and this covers the whole bill.
  target_compartment_ocid = get_env("OCI_COMPARTMENT_OCID", "")

  tenancy_name = "firefly"
  environment  = local.environment_vars.locals.environment

  # Stated here rather than left to the module default so the number is visible in the place an
  # operator opens to change it. The reasoning for 5 is in modules/budget/variables.tf.
  monthly_budget_amount = 5

  alert_recipients = local.budget_alert_email
}
