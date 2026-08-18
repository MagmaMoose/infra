# The daily per-account cost report, posted to Slack #finance.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THIS LEAF IS THE ONLY ONE IN terraform/aws THAT TARGETS THE MANAGEMENT ACCOUNT.
#
# Its siblings (artifacts, nievah-frontdoor) apply into prd-nievah (666802049426). This one
# applies into Root (857256953358), and it has to: Cost Explorer in a member account can only
# see that member's own spend, so the grouped-by-linked-account view this whole report is
# built on does not exist anywhere else in the organisation. There is no billing delegated
# administrator registered, which would be the other way to get it.
#
# Apply it with `AWS_PROFILE=mm-root`. `allowed_account_ids` below turns the wrong profile
# into a refusal instead of a second, silently duplicated stack in the wrong account — the
# failure this directory layout invites, since path and account no longer agree here.
# ─────────────────────────────────────────────────────────────────────────────────────────────

include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/cost-report"
}

# See the note on the matching block in ../artifacts/terragrunt.hcl. `allowed_account_ids` is
# the one addition: the sibling leaves can afford to omit it because every one of them targets
# the same account, and this one cannot.
generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TF
provider "aws" {
  region              = "${local.region_vars.locals.region}"
  allowed_account_ids = ["${local.management_account_id}"]

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "finops"
      Component = "cost-report"
    }
  }
}

# The billing plane is single-region: Data Exports has only a us-east-1 endpoint, and the
# export bucket is put beside it. This cannot collapse into the provider above, because
# Chatbot has no us-east-1 endpoint at all — the two halves of this module genuinely have to
# live in different regions.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = ["${local.management_account_id}"]

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "finops"
      Component = "cost-report"
    }
  }
}
TF
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # MagmaMoose org management account (o-zipq67xej5).
  management_account_id = "857256953358"
}

inputs = {
  region      = local.region_vars.locals.region
  environment = local.environment_vars.locals.environment

  # 07:00 UTC daily. The report covers the previous day, and Cost Explorer has settled the
  # prior day well before this — CE finalises within a few hours of midnight UTC, and the
  # figures are marked Estimated until the bill closes either way.
  schedule_expression = "cron(0 7 * * ? *)"
  schedule_timezone   = "UTC"

  # The backstop, in dollars. AWS Budgets cannot cap a bill — nothing in AWS can — so this
  # reports rather than enforces. $5 against an organisation spending a fraction of a cent a
  # month is a very loud alarm, not a tight one: FORECASTED fires at 10% of it, so anything
  # trending past fifty cents in a month says so while there is still a month left to act.
  monthly_budget_usd = 5

  # Slack #finance. Same workspace the front door posts to, but the Chatbot authorisation is
  # PER ACCOUNT — the one done in 666802049426 does not carry over, so this needs its own
  # one-time OAuth handshake in the Chatbot console of 857256953358 before the first apply.
  slack_workspace_id = "T07C6KG3Y4A"
  slack_channel_id   = "C08BHHDGC0K"
}
