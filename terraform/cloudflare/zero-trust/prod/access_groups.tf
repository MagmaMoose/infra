# Reusable Access Groups so app policies don't need to re-inline the same
# email lists. Membership changes are then a single edit instead of one per
# app that allows that group.
#
# Email lists are loaded from an OCI Vault secret (see terragrunt.hcl
# `local.cf_access_groups_membership`) so this public repo doesn't enumerate
# family/friends' personal email addresses (PII). The Magma Moose group
# matches on email_domain rather than per-user email; that domain is
# already public so it stays inline.

resource "cloudflare_zero_trust_access_group" "friends" {
  account_id = var.account_id
  name       = "Friends"

  include {
    email = var.cf_access_groups_membership.friends
  }
}

resource "cloudflare_zero_trust_access_group" "caleb" {
  account_id = var.account_id
  name       = "Caleb"

  include {
    email = var.cf_access_groups_membership.caleb
  }
}

resource "cloudflare_zero_trust_access_group" "household" {
  account_id = var.account_id
  name       = "Household"

  include {
    email = var.cf_access_groups_membership.household
  }
}

# Caleb's personal (iCloud) address, currently the sole allowed identity
# for the WARP "Email domain policy". Carved out as a group so the
# policy include in access_apps.tf stays group-based and the address
# itself stays out of git.
resource "cloudflare_zero_trust_access_group" "caleb_personal" {
  account_id = var.account_id
  name       = "Caleb personal"

  include {
    email = var.cf_access_groups_membership.caleb_personal
  }
}

# Marc Vergunst (PinkRoccade manager) — email sourced from OCI Vault so it
# doesn't appear in this public repo. Used by the GitHub Timesheet policy.
resource "cloudflare_zero_trust_access_group" "marc" {
  account_id = var.account_id
  name       = "Marc"

  include {
    email = var.cf_access_groups_membership.marc
  }
}

resource "cloudflare_zero_trust_access_group" "magma_moose_domain" {
  account_id = var.account_id
  name       = "Magma Moose"

  include {
    email_domain = ["magmamoose.com"]
  }
}
