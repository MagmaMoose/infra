# The control-plane store on the AWS topology.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# WHY DYNAMODB AND NOT THE RDS INSTANCE NEXT DOOR IN database.tf
#
# Because it is the only database on AWS that is free FOREVER, and this organisation has no
# 12-month allowances at all. AWS replaced that free tier on 2025-07-15 with a credits model and
# the payer signed up 2025-09-18, two months after the cutover — recorded at length in
# `modules/caldrith-frontdoor/api.tf` after two modules had confidently counted on allowances
# that never existed. A db.t4g.micro therefore bills ~$15/month from its first hour.
#
# DynamoDB's always-free allowance survives that change: 25 GB of storage plus 25 read and 25
# write capacity units. It also has a FREE VPC gateway endpoint, unlike the interface endpoints
# that bill by the hour — so it is the one store that fits the no-NAT constraint this topology
# is built around, rather than merely being affordable.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE CAPACITY BUDGET IS THE BINDING CONSTRAINT, AND IT IS SHARED
#
# The allowance is PROVISIONED capacity, aggregated across every table AND every index, and it
# is pooled across the whole ORGANISATION rather than per account. 25 + 25 units is 18,600
# capacity-unit-hours a month (25 x 744). Sibling services already hold about 8,900 of them:
# caldrith's dedup 2+2, nievah's dedup 2+2, caldrith's entitlements 1+1, diatreme's jwks_cache
# 1+1. `modules/caldrith-frontdoor/storage.tf` measured this and warned that there was "room for
# a third service and not much more; a fourth is the point to look at this again". Dün Mir is
# the fifth.
#
# So the whole allocation below has to fit in about 13 units, and it does, exactly:
#
#     base table   4 write + 4 read   =  8
#     gsi1 queue   1 write + 1 read   =  2
#     gsi2 agent   1 write + 2 read   =  3
#                                       --
#                                       13
#
# ON-DEMAND BILLING HAS NO FREE COMPONENT AT ALL. Switching `billing_mode` is the one change in
# this file that looks like a modernisation and is simply a bill.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THERE IS NO LIVENESS INDEX, AND ITS ABSENCE IS WHAT MAKES THE BUDGET WORK
#
# The obvious design gives the sweep a third index keyed on `last_seen_at` so "everything not
# seen since X" is a Query. It was in the first draft and taking it out is the single biggest
# improvement in this file, for two reasons.
#
# COST: an index keyed on a value that changes on every write is REWRITTEN on every write —
# delete the old entry, insert the new one — so it costs 2 write units per heartbeat on top of
# the 1 the table itself costs. That is 3 units per heartbeat instead of 1, which cuts the
# fleet-wide ceiling to a THIRD of what it is without the index.
#
# BACK-PRESSURE: an under-provisioned GSI throttles writes to the BASE table. A starved liveness
# index would stall heartbeats, and the symptom is agents timing out — not an index alarm, and
# nothing pointing at the index.
#
# What replaces it: the sweep Queries each tenant's `DEVSTAT#` prefix and compares in memory.
# Those items are ~200 bytes and hold nothing else, precisely so this read is cheap. It is
# O(devices) per sweep rather than O(stale devices), which is the right trade at this scale and
# is worth revisiting only if a fleet gets large enough for the read to matter — at which point
# the answer is a bucketed sweep, not an index on a hot attribute.
#
# The saving is not marginal: at 1 write unit per heartbeat, 4 provisioned write units support
# 4 heartbeats per second fleet-wide, which is exactly what `MAX_HEARTBEATS_PER_SECOND` in
# lambda.tf is set to. Those two numbers are one number written twice — change either and
# re-derive the other.
# ─────────────────────────────────────────────────────────────────────────────────────────────

# trivy:ignore:AVD-AWS-0024
# trivy:ignore:AVD-AWS-0025
resource "aws_dynamodb_table" "control_plane" { # nosemgrep: terraform.aws.security.aws-dynamodb-table-unencrypted.aws-dynamodb-table-unencrypted
  # checkov:skip=CKV_AWS_119:No KMS CMK — the AWS-owned key is sufficient here and a CMK bills
  # checkov:skip=CKV2_AWS_16:Auto-scaling disabled DELIBERATELY — see below; it is the cost ceiling
  count = var.db_mode == "dynamodb" ? 1 : 0

  name         = local.name
  billing_mode = "PROVISIONED"

  # AUTO-SCALING IS OFF AND THAT IS THE COST CEILING, not an oversight. With it on, a flood that
  # got past the gateway throttle would scale this table to meet it — turning a fixed, free
  # allocation into a variable, billed one at exactly the moment nobody is watching. Throttled
  # writes are the correct behaviour under attack: the agent retries on its next interval, and
  # a heartbeat that arrives a minute late is not an incident.
  read_capacity  = 4
  write_capacity = 4

  # `hash_key`/`range_key`, which the provider marks deprecated in favour of a `key_schema` this
  # version does not actually accept as a block. Left as-is, consistent with the four sibling
  # DynamoDB tables in this repo; revisit when the replacement exists.
  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = "gsi1pk"
    type = "S"
  }
  attribute {
    name = "gsi1sk"
    type = "S"
  }
  attribute {
    name = "gsi2pk"
    type = "S"
  }
  attribute {
    name = "gsi2sk"
    type = "S"
  }

  # The pending-command queue, per agent.
  #
  # SPARSE, and that is what makes it cheap: an item carries these attributes only while it is
  # pending, and claiming a command REMOVES them. So the index holds exactly the backlog rather
  # than the whole command history, and a poll needs no filter expression — which would have
  # been charged for every item it read and then discarded.
  global_secondary_index {
    name            = "gsi1"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
    read_capacity   = 1
    write_capacity  = 1
  }

  # "This agent's devices, by name" — the device upsert key and the config poll.
  #
  # Two read units rather than one because the config poll reads a whole agent's device set at
  # once, and this is the only read in the system that is not a single item.
  #
  # PROJECTION IS ALL, and that is a decision to revisit if the sealed-credential feature is
  # ever adopted fleet-wide: `credential_sealed` is capped at 10,000 characters and lives on its
  # own item precisely so it does NOT appear here, but a projection change that pulled it in
  # would turn a ~50 KB poll into a ~1 MB one and blow this allocation by an order of magnitude.
  global_secondary_index {
    name            = "gsi2"
    hash_key        = "gsi2pk"
    range_key       = "gsi2sk"
    projection_type = "ALL"
    read_capacity   = 2
    write_capacity  = 1
  }

  # Expiry for sessions, email tokens and login attempts — the three things that are genuinely
  # just "delete this later".
  #
  # TTL DELETION IS ASYNCHRONOUS and AWS promises only ~48 hours, so a row can outlive its
  # stated retention. That is fine for a session (it is checked against its own expiry on every
  # read, so an unswept row is not a valid session) and it is NOT fine as the sole mechanism for
  # anything with a compliance-visible retention promise. The audit log's 90-day prune is
  # therefore still a sweep, not a TTL.
  # `ttl`, and the NAME has to match what every domain in
  # `dunmir_control_plane/store/` stamps — a table has exactly one TTL attribute,
  # table-wide. Two domains originally disagreed (audit wrote `expires_at`,
  # identity wrote `ttl`), and whichever name had been configured here, the other
  # domain's rows would never have been collected. Nothing errors; the table just
  # grows, on a deployment whose premise is a 25 GB allowance.
  #
  # NOT `expires_at`, which is a DOMAIN field the application compares against —
  # a session's own expiry, which `load_session` refuses on. Collecting on it would
  # tie "when the row is deleted" to "when the credential stops working".
  # `tests/test_store_ttl_attribute.py` asserts this file and the code agree.
  #
  # TTL DOES NOT FILTER READS: an expired-but-uncollected item is still returned,
  # so the application's expiry checks stay where they are. This bounds storage; it
  # enforces nothing. Collection is asynchronous, "typically within 48 hours".
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # ~$0.20/GB-month with no free allowance — about $0.16 at this size, and the only line in this
  # file that is not free. Kept because the alternative to a point-in-time restore, for a table
  # holding every tenant's device inventory and the pointers to their encrypted backups, is a
  # conversation nobody wants to have.
  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = { Name = local.name }
}
