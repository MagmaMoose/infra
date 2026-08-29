# Dün Mir's AWS leaves.
#
# `find_in_parent_folders("provider.hcl")` resolves to the NEAREST one, so this file shadows
# terraform/aws/provider.hcl for everything beneath it — the same mechanism chargate, nievah and
# caldrith use to hold one account per service.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# READ THIS BEFORE CREATING THE ACCOUNT. It is the single decision that determines whether this
# stack costs nothing or costs about $15 a month, and it cannot be changed afterwards.
#
# `terraform/aws/chargate/provider.hcl` records what magmamoose/infra#641 established the
# expensive way: **AWS applies the free tier across an ORGANIZATION, and eligibility dates from
# the MANAGEMENT account's creation.** A member account opened inside the existing MagmaMoose
# organisation therefore inherits an already-expired 12-month allowance and is billed from its
# first hour.
#
# Almost everything in the `dunmir-platform` module is on an *always*-free allowance and does not
# care: Lambda (1M requests, 400k GB-seconds), CloudFront (1 TB, 10M requests), Cognito (10,000
# monthly active users), EventBridge Scheduler, CloudWatch Logs. **RDS is the exception**, and
# it is the only one. `db.t4g.micro` + 20 GB is free for twelve months and about $15/month after.
#
# So:
#
#   * A **new standalone account**, outside the organisation, gets its own free plan and this
#     stack costs nothing. That is the recommendation, and it is why `account_id` below is
#     empty — nobody should be able to apply this into the wrong account by accident.
#   * A **member account** inside the organisation is fine too, as long as ~$15/month for the
#     database is a decision somebody made rather than a surprise. `enable_budget_alarm` fires
#     at the first dollar either way.
#
# There is no third option that keeps Postgres. The application is 200-odd hand-written SQL
# statements across nineteen tables with joins and aggregations; "port it to DynamoDB and be
# always-free" is a rewrite of the persistence layer, not a setting.
# ─────────────────────────────────────────────────────────────────────────────────────────────
#
# `provider = "aws"` is required by root.hcl, which reads it to suppress the OCI
# `required_providers` block for AWS leaves.
locals {
  provider = "aws"

  # The account these leaves must land in, rendered into each leaf's generated provider as
  # `allowed_account_ids` so a stale or mis-set credential fails the PLAN with a clear error
  # rather than quietly building Dün Mir's stack inside another product's account.
  #
  # DELIBERATELY EMPTY until the account exists. An empty list disables the check, which is the
  # honest state before there is an account id to check against — fill it in with the same
  # commit that first applies this.
  account_id = ""
}

inputs = {
  provider = local.provider
}
