# Delivery dedup, and the entitlement table.
#
# There was an overflow bucket here until 2026-09-03, for webhook bodies past SQS's 256 KB
# message limit. Nothing rides in an SQS message any more — the producer parses the body it
# already holds and sends only small job descriptors — so the ceiling that required it is
# gone. See queues.tf.

# THE TABLE THAT REPLACES REDIS. `caldrith.worker.queue.dedup_delivery` is a Redis `SET NX` with
# a 24-hour TTL; this is the same claim as a DynamoDB conditional write with a TTL attribute.
# Identical semantics, no server, and — unlike the cheapest ElastiCache node at roughly $12 a
# month — actually free.
#
# PROVISIONED, NOT ON-DEMAND, and that is a free-tier decision rather than a capacity one.
# DynamoDB's always-free allowance is 25 GB of storage plus 25 write and 25 read capacity
# units — PROVISIONED units. On-demand request pricing has NO always-free component, so the
# identical workload that costs nothing here would be billed per request there. It is the one
# switch in this file that looks like a modernisation and is actually a bill.
#
# THE HEADROOM, MEASURED RATHER THAN ASSUMED. `GetFreeTierUsage` reports the allowance as
# 18,600 capacity-unit-hours a month (25 units x 744 hours) with 12 consumed org-wide today.
# This table's 2+2 is 2,976 of those, and nievah's identical table is another 2,976 — so the
# two services together sit at about a third of an allowance that is ORGANISATION-wide, not
# per-account. There is room for a third service and not much more; a fourth is the point to
# look at this again rather than the point to discover it.
# trivy:ignore:AVD-AWS-0024
# trivy:ignore:AVD-AWS-0025
resource "aws_dynamodb_table" "dedup" { # nosemgrep: terraform.aws.security.aws-dynamodb-table-unencrypted.aws-dynamodb-table-unencrypted
  #checkov:skip=CKV_AWS_28:PITR off deliberately — every row is a 24h-TTL delivery id, nothing worth restoring
  #checkov:skip=CKV_AWS_119:No KMS CMK for DynamoDB — home lab; AWS managed key is sufficient
  #checkov:skip=CKV2_AWS_16:DynamoDB auto-scaling disabled deliberately — provisioned 2/2 to stay in always-free tier
  name         = "${var.name_prefix}-dedup"
  billing_mode = "PROVISIONED"

  # AUTO-SCALING IS OFF AND THAT IS THE COST CEILING, not an oversight. With it on, a flood
  # that got past the API Gateway throttle would scale this table up to meet it — turning a
  # fixed, free 2 units into a variable, billed number at exactly the moment nobody is
  # watching. A throttled write is the correct behaviour under attack: `_claim` FAILS OPEN,
  # so the delivery is processed without a claim rather than dropped, and the duplicate work
  # that risks is absorbed by every tier being idempotent.
  read_capacity  = 2
  write_capacity = 2

  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Expiry is the whole storage plan, and it is also what bounds Redis's replacement to one
  # rolling day of ids rather than a table that grows for ever and eventually leaves the 25 GB
  # allowance. TTL deletes are free — they do not consume write capacity. The window mirrors
  # `caldrith.worker.queue.DEDUP_TTL_SECONDS` (24 hours), which is comfortably longer than
  # GitHub's redelivery retry window; the two are a pair.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    # Off deliberately. Every row is a delivery id with a 24-hour TTL; there is no state here
    # worth restoring, and PITR is charged per GB. Losing this table entirely costs one day of
    # deduplication — some webhooks reconciled twice, which converges to the same place because
    # reconcile is idempotent. That is the cheapest disaster in the stack.
    enabled = false
  }
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# WHO CALDRITH IS ALLOWED TO RECONCILE, keyed by registration and account.
#
# DURABLE PRODUCT STATE, and that one word is what makes this a different table from `dedup`
# above rather than a second copy of it. Every decision below that differs from dedup's differs
# BECAUSE this data has to survive; the two that would be most tempting to copy — the TTL block
# and PITR-off — are the two that would do real damage here, so each carries its own reasoning
# rather than a pointer to the table above.
#
# THE KEY IS ONE `S` ATTRIBUTE CALLED `pk`, AND ITS SHAPE IS DICTATED BY THE READER RATHER
# THAN CHOSEN HERE. `caldrith.aws.entitlement` does a single `get_item` with
# `Key={"pk": {"S": ...}}`, where the value is built by `entitlement_key()` as
# `ent#<registration>#<account>`. A hash+range schema of (registration, account_login) is the
# obvious modelling and it is WRONG for this table: DynamoDB rejects a GetItem whose key does
# not match the schema exactly, so the table would apply clean and then fail every single
# lookup with a ValidationException — which `lookup()` catches, reports as
# SOURCE_UNAVAILABLE, and FAILS OPEN on. The result is a table that exists, an enforcement
# path that never enforces, and no error anywhere but a log line nobody is grepping for. If
# the key ever changes, it changes in that module first and here second.
#
# THE REGISTRATION IS IN THE KEY EVEN THOUGH ONLY ONE VALUE OF IT IS EVER LOOKED UP TODAY.
# `entitlement.needs_lookup` returns true for the DEFAULT `github` registration alone: every
# other slug is a GHE tenancy whose App was provisioned into SSM by hand under a negotiated
# agreement, so it is entitled by existing and `check_entitlement` short-circuits before any
# I/O. In practice every row here is `ent#github#…`. The segment is in the key anyway because
# a GitHub account name is unique per HOST and not globally — `caldrith.aws.consumer` makes
# the same point where it builds the FIFO group id — so without it "acme" on github.com and
# "acme" on pinkroccade.ghe.com would be one row, and the day that rule changes the table
# would already be wrong. The `ent#` prefix namespaces the row kind so a later row type
# cannot collide with an account called `billing`, and the account half is CASE-FOLDED by
# `entitlement_key`, because GitHub logins are case-preserving but case-insensitive and a
# row written as `Acme` is a row the lookup never finds.
#
# The item carries `plan` (S), `status` (S), `private_repo_limit` (N) and `expires_at` (N).
# None of them is declared below and none should be: DynamoDB is schemaless outside the key,
# and `attribute` blocks are for KEY attributes only — declaring a non-key attribute without
# an index is an apply error, not documentation.
#
# ── INCREMENTAL COST OF EVERYTHING THIS CHANGE ADDS ─────────────────────────────────────────
#
# Expected: $0.00/month, and the one line that is not exactly zero is named rather than hidden.
#
#   this table, capacity   $0.00  1 RCU + 1 WCU of PROVISIONED capacity, inside the always-free
#                                 25+25 allowance. See the headroom arithmetic below.
#   this table, storage    $0.00  Tens of rows of short strings against a 25 GB allowance.
#   this table, PITR       ~$0.00 THE ONE NON-FREE LINE. Continuous backups are $0.20 per
#                                 GB-month of table size with NO free allowance. At kilobytes
#                                 that is a small fraction of a cent and rounds to $0.00 on the
#                                 bill — but it is a real line item and it is chosen, not
#                                 inherited. It grows with the table, so it stays negligible
#                                 only while this holds a customer list rather than a log.
#   3 SSM SecureStrings    $0.00  Standard-tier parameters are free (10,000 per account) and
#                                 Standard throughput is free. DO NOT create them with
#                                 `--tier Advanced`: that is $0.05 per parameter per month, and
#                                 nothing here needs the 8 KB Advanced limit — a GitHub App PEM
#                                 is well under Standard's 4 KB. See docs/ghe-onboarding.md.
#   KMS decrypts           $0.00  SecureStrings use the account's AWS-managed SSM key, which
#                                 has no monthly charge. Decrypt requests are $0.03/10,000 and
#                                 both handlers cache per execution environment, so this is a
#                                 handful of calls a day against a 20,000/month free allowance.
#   IAM, env vars, JSON    $0.00  Not billable.
#
# NOT PAY_PER_REQUEST, AND THAT IS THE COST DECISION rather than a capacity one — it is the one
# switch here that looks like a modernisation and is actually a bill. DynamoDB's always-free
# allowance is 25 GB plus 25 write and 25 read capacity units, and those are PROVISIONED units;
# on-demand request pricing has NO always-free component whatsoever, so this exact workload,
# which costs nothing as written, would be billed per request there. On a stack whose entire
# expected spend is a few cents and whose budget guard is $1, an on-demand table would be the
# first thing in the design that bills simply for existing.
#
# THE HEADROOM, CONTINUED FROM `dedup`. The allowance is 18,600 capacity-unit-hours a month
# (25 units x 744 hours) and it is ORGANISATION-wide, not per-account. caldrith-dedup's 2+2
# takes 2,976 and nievah's identical table another 2,976; this table's 1+1 takes 1,488, so the
# three together sit at roughly 40% of it. dedup's comment says a FOURTH consumer is the point
# to look at this again rather than the point to discover it — this IS that fourth consumer,
# which is why it is deliberately half dedup's size. 1 RCU is two eventually-consistent reads a
# second and 1 WCU is ~86,000 writes a day, against a workload of one `get_item` per
# installation sync and a write when a customer is onboarded — and the write does not even
# come from this stack, since the reconcile role has GetItem only and rows are put by billing
# or by hand. If a real measurement ever demands more, raise the units WITH this arithmetic
# re-done; do not reach for the billing mode.
#
# AUTO-SCALING IS OFF, and here it is the cost ceiling exactly as it is on dedup: with it on, a
# runaway read loop would scale a fixed, free 1+1 into a variable, billed number at precisely
# the moment nobody is watching. A throttled read is the correct behaviour under that fault —
# the job fails, SQS holds it, and `jobs_stale` reports it within 15 minutes.
#
# NO `ttl` BLOCK, AND THE TRAP IS THAT BOTH TABLES HAVE AN `expires_at`. dedup's is a TTL
# attribute and the whole storage plan: DynamoDB deletes the row when the clock passes it.
# THIS TABLE'S `expires_at` IS THE OPPOSITE INSTRUCTION — a lapse date that
# `caldrith.entitlement` READS and compares against, so a renewal moves it forward and an
# absent value means "does not lapse". Enabling TTL on it, which is exactly what copying the
# block above would do, has DynamoDB silently erase a paying customer's record at renewal
# time, and what they see is Caldrith quietly ceasing to manage their repositories with
# nothing in any log saying why. Same attribute name, same type, opposite meaning; the module
# docstring in `caldrith/aws/entitlement.py` says so too. There is no expiry concept here that
# belongs to DynamoDB.
# ─────────────────────────────────────────────────────────────────────────────────────────────
#
# Only AVD-AWS-0025 (CMK encryption) is ignored here, where `dedup` also ignores AVD-AWS-0024:
# that one is point-in-time recovery, which is ENABLED below, so the ignore would be a stale
# claim rather than a suppression. Keep the trivy ignore on the line immediately above the
# resource and the nosemgrep marker trailing it — see the note in nievah's storage.tf about the
# commit that moved them and silently un-ignored both.
# trivy:ignore:AVD-AWS-0025
resource "aws_dynamodb_table" "entitlements" { # nosemgrep: terraform.aws.security.aws-dynamodb-table-unencrypted.aws-dynamodb-table-unencrypted
  #checkov:skip=CKV_AWS_119:No KMS CMK for DynamoDB — home lab; AWS managed key is sufficient
  #checkov:skip=CKV2_AWS_16:DynamoDB auto-scaling disabled deliberately — provisioned 1/1 to stay in always-free tier, and auto-scaling is what would turn a runaway read into a bill
  name         = "${var.name_prefix}-entitlements"
  billing_mode = "PROVISIONED"

  read_capacity  = 1
  write_capacity = 1

  # `ent#<registration>#<account>`, built by `caldrith.aws.entitlement.entitlement_key`. One
  # attribute, no range key: see the key note above for why the composite-schema version of
  # this table fails every read while looking correct.
  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  point_in_time_recovery {
    # ON, unlike dedup's, and dedup's justification does not transfer in any particular. That
    # one reads "every row is a delivery id with a 24-hour TTL; there is no state here worth
    # restoring" — true there. Here the table IS the record of who is entitled, the rows are
    # written by hand at onboarding and exist nowhere else in AWS, and a mistyped `delete-item`
    # or a `delete-table` is unrecoverable without this. Losing dedup costs one day of
    # deduplication and converges; losing this costs the customer list. See the cost block
    # above for what the continuous backup actually charges.
    enabled = true
  }
}

data "aws_caller_identity" "current" {}
