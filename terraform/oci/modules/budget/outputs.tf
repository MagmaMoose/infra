output "budget_id" {
  description = "OCID of the budget"
  value       = oci_budget_budget.tenancy.id
}

output "budget_display_name" {
  description = "Display name of the budget"
  value       = oci_budget_budget.tenancy.display_name
}

output "alert_rule_ids" {
  description = "OCIDs of the ACTUAL and FORECAST alert rules"
  value = {
    actual   = oci_budget_alert_rule.actual.id
    forecast = oci_budget_alert_rule.forecast.id
  }
}

# OCI computes these on the budget itself, so a plain `terragrunt output` answers "what is this
# tenancy costing right now" without opening the console or handing anyone a billing login.
# Refresh-time snapshots, not live values, and OCI recomputes them roughly daily — do not read a
# stale zero here as proof that nothing is running.
output "actual_spend" {
  description = "Month-to-date actual spend as OCI last computed it"
  value       = oci_budget_budget.tenancy.actual_spend
}

output "forecasted_spend" {
  description = "Forecast month-end spend as OCI last computed it"
  value       = oci_budget_budget.tenancy.forecasted_spend
}
