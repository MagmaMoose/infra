# Note what is NOT here: user_ocid, fingerprint, private_key_path. The older OCI modules
# (network, policy, ...) all declare that trio and nothing ever reads it — the provider takes
# its credentials from the generated provider.tf, so those variables are dead weight the leaves
# still have to fill in with empty strings. A new module is the one chance not to inherit that,
# so it does not.

variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy. Budget objects are always created in the root compartment, so this is where the budget itself lives regardless of what it targets."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "tenancy_ocid must be an OCI tenancy OCID (starting with ocid1.tenancy.)."
  }
}

variable "target_compartment_ocid" {
  description = "OCID of the compartment whose spend is tracked. Both tenancies keep everything in root, so this is the tenancy OCID; a compartment budget covers that compartment and all of its children."
  type        = string

  # Admits both forms because the root compartment's OCID is the tenancy OCID. The assert
  # exists so an empty string cannot reach the API and create a budget that tracks nothing.
  validation {
    condition     = can(regex("^ocid1\\.(?:compartment|tenancy)\\.", var.target_compartment_ocid))
    error_message = "target_compartment_ocid must be a compartment or tenancy OCID."
  }
}

variable "tenancy_name" {
  description = "Short human name of the tenancy (e.g. \"firefly\", \"cloudworkers\"). Goes into the alert body so an email identifies which Oracle account it came from."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., prod, dev)"
  type        = string
}

variable "monthly_budget_amount" {
  description = "Monthly budget, a whole number in the tenancy's rate-card currency."
  type        = number
  default     = 5

  # Why 5 and not a round number.
  #
  # Both tenancies are meant to bill zero: Always Free compute, default (shared) vaults,
  # software-protected keys. The one known item outside that allowance is the HSM-protected KMS
  # key the cloudworkers vpn leaf creates, and OCI's first HSM key versions are covered by a
  # free monthly allowance, so even that should land at zero. The threshold is therefore not
  # sizing real spend — it is picking how loud "unexpected" should be.
  #
  # Not 1 (the floor): the FORECAST rule trips at a tenth of this, and OCI extrapolates
  # linearly from month-to-date spend, so against a budget of 1 a few cents of accrual on day 2
  # forecasts past 0.10 and mails every month.
  # Not 10 or 100 (the obvious round ones): ACTUAL only speaks at the full amount, so a round
  # 100 means a hundred units of surprise before the loudest alert says anything.
  # 5 puts FORECAST at 0.50 and ACTUAL at 5 — clear of extrapolation noise, and small enough
  # that a single unexpected paid resource is caught in its first month.
  #
  # Currency is the tenancy's rate card, which was not verified for either account (EUR or USD).
  # It does not change the design: at this size the two are well under a unit apart.
  validation {
    condition     = var.monthly_budget_amount >= 1 && floor(var.monthly_budget_amount) == var.monthly_budget_amount
    error_message = "monthly_budget_amount must be a whole number of at least 1 — OCI expresses budgets as whole currency units."
  }
}

variable "alert_recipients" {
  description = "Delimited list of email addresses to receive the alerts. Email is the only channel OCI budget alert rules support."
  type        = string

  # Not marked sensitive: the value has to appear in `recipients` in state either way, and
  # marking it would only hide it from plan output while the leaves already keep it out of the
  # repo by reading it from OCI Vault. Hiding it in plan would remove the one place an operator
  # can see that the backstop is actually addressed to someone.
  #
  # The assert matters more than it looks. `recipients` is optional and OCI reads an empty
  # string as null, so an unset value applies cleanly and produces a budget whose alerts go
  # nowhere — a backstop that exists, reports green, and is mute. Fail here instead.
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+", var.alert_recipients))
    error_message = "alert_recipients must contain at least one email address; an alert rule with no recipient is silently mute."
  }
}
