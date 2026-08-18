variable "name_prefix" {
  description = "Prefix for every resource this module creates."
  type        = string
  default     = "mm-cost-report"
}

variable "region" {
  description = "Region the schedule, function and topic live in. Cost Explorer itself is always called through us-east-1 regardless of this."
  type        = string
}

variable "environment" {
  description = "Terragrunt environment name, used only for tagging and naming."
  type        = string
}

variable "schedule_expression" {
  description = "When the report fires. Defaults to 07:00 daily in var.schedule_timezone."
  type        = string
  default     = "cron(0 7 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone the schedule is interpreted in."
  type        = string
  default     = "UTC"
}

variable "slack_workspace_id" {
  description = <<-DESC
    Slack workspace (team) id, from the AWS Chatbot console.

    MUST BE AUTHORISED IN THIS ACCOUNT FIRST. Chatbot's workspace authorisation is a one-time
    OAuth handshake performed per AWS account in the console, and Terraform cannot perform it.
    The same workspace being authorised in 666802049426 for the front door does nothing here.
    Empty disables Slack delivery entirely, which leaves the report publishing into a topic
    with no subscriber.
  DESC
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack channel id to post into. #finance is C08BHHDGC0K."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. A log group Lambda creates for itself never expires, which quietly converts a free stack into a billed one."
  type        = number
  default     = 30
}

variable "export_prefix" {
  description = "Key prefix inside the export bucket. AWS appends <export>/data/BILLING_PERIOD=YYYY-MM/ beneath it."
  type        = string
  default     = "cur"
}

variable "export_retention_days" {
  description = <<-DESC
    Lifecycle expiry for export objects. The report never looks back further than the previous
    billing period, so this only has to outlive that — but it is the backstop that stops the
    bucket growing if the export's OVERWRITE_REPORT setting is ever changed, so it is not
    merely tidiness.
  DESC
  type        = number
  default     = 95
}

variable "monthly_budget_usd" {
  description = <<-DESC
    Budget guard for the whole organisation's consolidated spend, in USD.

    AWS Budgets cannot cap a bill — nothing in AWS can — so this reports rather than enforces.
    Set low: the organisation's actual spend is a fraction of a cent a month, so a budget of a
    few dollars is already a very loud alarm rather than a tight one.
  DESC
  type        = number
  default     = 5
}
