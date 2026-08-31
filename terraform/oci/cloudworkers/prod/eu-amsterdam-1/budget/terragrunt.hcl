# Monthly spend backstop for the SECOND OCI tenancy (traceysargeant, eu-amsterdam-1) — the
# "cloudworkers" stack that hosts ff-oci3/ff-oci4 and ff-chr3/ff-chr4.
#
# Deliberately a mirror of terraform/oci/prod/eu-amsterdam-1/budget so the two can be diffed
# line-for-line. The differences that matter:
#   1. credentials come from OCI_CW_* (see ../../../provider.hcl `env_prefix`)
#   2. the OCI_CW_* inputs are regex-asserted, because getting the tenancy wrong here would
#      silently put tracey's budget on caleb's bill
#   3. tenancy_name = "cloudworkers", so the alert email says which account it came from
#
# This tenancy needs a budget MORE than firefly does, not less. It was Always Free until a
# payment method was added on 2026-08-31; before that, Oracle refusing to provision was itself
# the spend cap. That protection is now gone and nothing has replaced it, so anything beyond
# the Always Free allowance now bills instead of failing. The vpn leaf's HSM-protected KMS key
# is the one item already outside that allowance.
include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/budget"
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # The operator's email lives in OCI Vault rather than this PUBLIC repo — same reasoning and
  # same secret as the firefly leaf, see there for why vault beats an env var.
  #
  # This is FIREFLY's vault OCID, read at parse time with the operator's ~/.oci/config, and
  # that is correct for the same reason ../network reads operator-mgmt-cidrs from it: the value
  # is plain contact data being passed INTO the tracey tenancy, not a credential scoped to it.
  # One secret, one place to rotate — and the alerts should reach the same human either way.
  #
  # Same caveat as ../network: unlike the OCI_CW_* inputs below, this call has no assert. It
  # authenticates as whatever the ambient ~/.oci/config DEFAULT profile is, so it resolves to
  # nothing useful if that profile is not firefly's. Pin `--profile` here if a second profile
  # ever lands on an operator's machine.
  #
  # ONE-TIME SETUP: the secret must gain `contacts.budget_alert_email` before this first plans.
  # Less urgent here than on the firefly side only because this leaf does not autoplan.
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
  # The regex() calls are asserts, not cosmetics. get_env(...,"") returns "" when the variable
  # is unset, and an empty tenancy_ocid makes the OCI provider fall through to ~/.oci/config's
  # DEFAULT profile — FIREFLY's — so a forgotten env var would create tracey's budget in
  # caleb's tenancy, watching the wrong bill while reporting green. Failing at parse time is the
  # only safe outcome. `(?:...)` must stay NON-capturing: HCL's regex() returns the capture
  # groups instead of the match when a group is present.
  #
  # traceysargeant has no child compartments, so OCI_CW_COMPARTMENT_OCID is the tenancy OCID
  # itself; the alternation admits both. Targeting root is what makes this cover the whole
  # tenancy rather than one corner of it.
  tenancy_ocid            = regex("^ocid1\\.tenancy\\..+$", get_env("OCI_CW_TENANCY_OCID", ""))
  target_compartment_ocid = regex("^ocid1\\.(?:compartment|tenancy)\\..+$", get_env("OCI_CW_COMPARTMENT_OCID", ""))

  tenancy_name = "cloudworkers"
  environment  = local.environment_vars.locals.environment

  # Same 5 as firefly, and same expected steady state of zero. Kept identical on purpose: two
  # tenancies with different trip points would mean two mental models for one operator. The
  # reasoning for the number is in modules/budget/variables.tf.
  monthly_budget_amount = 5

  alert_recipients = local.budget_alert_email
}
