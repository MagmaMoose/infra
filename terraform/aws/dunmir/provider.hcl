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
# Most of the `dunmir-platform` module is on an *always*-free allowance and does not care:
# Lambda (1M requests, 400k GB-seconds), Cognito (10,000 monthly active users), EventBridge
# Scheduler, CloudWatch Logs. API Gateway, ECR and S3 are twelve-month tiers costing cents at
# this scale. **RDS is the one that matters**: `db.t4g.micro` + 20 GB is about $15/month once
# the allowance is gone.
#
# WHAT WAS ACTUALLY DECIDED, on 2026-08-30. 757868239591 is a MEMBER account of
# o-zipq67xej5 (management account 857256953358), so per the rule above its 12-month
# allowances are already spent — `aws freetier get-free-tier-usage` returns an empty list.
# RDS would therefore bill from its first hour.
#
# So this deployment runs `db_mode = "dynamodb"` and creates NO RDS instance. DynamoDB is the
# only AWS database with an always-free allowance (25 GB + 25 RCU + 25 WCU, provisioned,
# forever), and its VPC gateway endpoint is also free — so it is the one store that fits
# the no-NAT constraint this topology is built around. The stack DOES create a VPC; the
# function runs inside it with S3 and DynamoDB gateway endpoints and no NAT gateway.
#
# Changing `db_mode` back to "rds" is a deliberate ~$15/month decision, not a config
# tweak — do not make it casually. Changing to "external" would leave the function with
# no database at all.
#
# There is no third option that keeps Postgres without a bill. The application has a
# store abstraction layer (dunmir_control_plane/store/) that lets the Kubernetes topology
# keep Postgres while this topology uses DynamoDB; porting the SQL path to DynamoDB
# would be a rewrite of the persistence layer, not a setting.
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
  account_id = "757868239591"
}

inputs = {
  provider = local.provider
}
