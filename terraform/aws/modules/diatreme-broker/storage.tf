# Last-known-good JWKS snapshots — the AWS replacement for the Cloudflare KV store
# added in MagmaMoose/diatreme#150.
#
# WHY THIS EXISTS. When GitHub's JWKS endpoint is unreachable the broker would otherwise
# reject every token it is asked to verify. That is not hypothetical: in #147 a Cloudflare
# TLS handshake failure to token.actions.githubusercontent.com blocked releases across every
# consumer repository for hours, and the key set the broker needed had been in memory minutes
# earlier. This table is what makes that outage survivable.
#
# WHY DYNAMODB, having rejected the alternatives:
#   /tmp  — scoped to one execution environment, and empty on exactly the cold start where the
#           rescue is needed. The in-process cache already covers the warm case.
#   SSM   — free, but Standard-tier values cap at 4 KB: a silent failure the day GitHub
#           publishes another key. It would also pollute the secret path the IAM policy above
#           is deliberately scoped to.
#   S3    — no always-free tier past the first 12 months, and 20-40 ms on the success path.
#
# PROVISIONED, NOT ON-DEMAND. The always-free allowance is 25 RCU / 25 WCU / 25 GB and applies
# to PROVISIONED capacity only; PAY_PER_REQUEST is billed from the first request. One item of
# 1-2 KB written at most once per execution environment per 5 minutes fits inside 1/1 with room
# to spare. Do not "simplify" this to on-demand.
resource "aws_dynamodb_table" "jwks_cache" {
  name         = "${var.name_prefix}-broker-cache"
  billing_mode = "PROVISIONED"

  read_capacity  = 1
  write_capacity = 1

  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Mirrors KV's `expirationTtl`, so an abandoned issuer's snapshot ages out on its own
  # rather than being carried forever. The application enforces a much tighter 24h
  # usability ceiling; this is only garbage collection.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # The snapshot is a cache of PUBLIC keys and is rebuilt by the next successful
  # verification, so point-in-time recovery would be paid backup of derivable data.
  point_in_time_recovery {
    enabled = false
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "${var.name_prefix}-broker-cache"
  }
}
