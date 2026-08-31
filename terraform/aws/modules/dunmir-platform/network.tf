# The VPC, and the deliberate absence of a way out of it.
#
# WHAT IS NOT HERE, AND WHY THAT IS THE DESIGN
#   There is no NAT gateway and there are no interface endpoints. Both are billed **per hour**
#   — a NAT gateway is ~$32/month before a single byte moves, an interface endpoint ~$7.30 —
#   and this stack's whole premise is that it costs nothing. So the function has no route to
#   the internet at all, and the application was built around that rather than in spite of it:
#
#     * Operator identity  the BROWSER talks to Cognito; the backend only verifies the JWT,
#                          offline, against a JWKS passed in as configuration (identity.tf).
#     * Backup bodies      S3, through the GATEWAY endpoint below, which is free.
#     * Email              none. Cognito sends its own verification and reset mail from the
#                          browser's request; invitations are handed back to the inviter as a
#                          link (see `EMAIL_PROVIDER=none` in lambda.tf).
#     * Sweeps             EventBridge Scheduler invokes the function; the function calls out
#                          to nothing.
#
#   The one genuine casualty is Stripe billing and the GitHub config browser, both of which
#   need egress. They stay off on this topology — see the `BILLING_ENABLED` note in lambda.tf.
#
#   If egress ever becomes necessary, the cheap way in is a **dual-stack subnet plus an
#   egress-only internet gateway**, which unlike a NAT gateway carries no hourly charge. It is
#   not done here because IPv6-only egress fails silently against any IPv4-only endpoint, and
#   an intermittently-unreachable dependency is worse than an absent one.

locals {
  name = "${var.name_prefix}-${var.environment}"

  # Two AZs, because an RDS subnet group requires subnets in at least two of them even for a
  # single-AZ instance. The instance itself is single-AZ: Multi-AZ doubles the bill.
  azs = local.networked ? slice(data.aws_availability_zones.available[0].names, 0, 2) : []

  # Private /24s inside a /16. No public subnets exist at all — nothing in this stack needs an
  # address the internet can reach, and a public subnet that exists is a public subnet
  # something eventually gets put in.
  subnet_cidrs = ["10.42.1.0/24", "10.42.2.0/24"]

  # LocalStack executes Lambdas as sibling containers on the host's Docker network, so a
  # `vpc_config` there attaches the function to a VPC that has no meaning for its networking.
  # The whole network is therefore skipped locally, and the security-group path between
  # function and database is one of the things a local run does not prove (see `localstack`).
  # BOTH real stores get a VPC, and for DynamoDB that is a security choice rather than a
  # connectivity one.
  #
  # RDS needs it: the instance has no public address and the function is the only thing that can
  # reach it.
  #
  # DynamoDB does NOT need it — its public endpoint is reachable from a Lambda on the AWS-managed
  # network, free, with no NAT. But a function outside a VPC has unrestricted internet egress,
  # and the whole `AUTH_MODE=cognito` design rests on the backend making NO outbound calls: the
  # browser drives Cognito, the JWKS arrives as configuration, S3 URLs are signed locally,
  # alert delivery is off. Putting it in a subnet with no internet gateway and only the two FREE
  # gateway endpoints (S3, DynamoDB) turns that from a property of the code into a property of
  # the network — so a compromised dependency has nowhere to send anything, rather than merely
  # no reason to.
  #
  # This costs nothing. A VPC, its subnets and gateway endpoints are free; it is the NAT gateway
  # (~$32/month) and interface endpoints (~$7.30 each) that bill, and there are none of either.
  networked = !var.localstack && contains(["rds", "dynamodb"], var.db_mode)
}

data "aws_availability_zones" "available" {
  count = local.networked ? 1 : 0
  state = "available"
}

resource "aws_vpc" "this" {
  # checkov:skip=CKV2_AWS_11:No VPC flow logs. They bill per GB ingested into CloudWatch, on a topology whose entire brief is free-tier only, and there is very little to see: this VPC has no internet gateway, no NAT, and exactly two destinations reachable through gateway endpoints. "What did it talk to" is answered by the design rather than by a log.
  count = local.networked ? 1 : 0

  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_subnet" "private" {
  count = local.networked ? length(local.subnet_cidrs) : 0

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Explicit, though it is also the default. A subnet that hands out public IPs while having no
  # route to an internet gateway is the confusing middle state: instances look internet-facing
  # and are not.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-private-${count.index + 1}" }
}

# The main route table, carrying ONLY the VPC-local route AWS creates implicitly. Declared
# rather than left to the default so that "there is no way out of this VPC" is a visible,
# reviewable fact in the code instead of an absence somebody later fills in.
resource "aws_route_table" "private" {
  count = local.networked ? 1 : 0

  vpc_id = aws_vpc.this[0].id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = local.networked ? length(local.subnet_cidrs) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# S3 over a GATEWAY endpoint. Gateway endpoints are free — this is the one AWS service the
# function reaches from inside the VPC, and the reason encrypted backup bodies can live in S3
# without a NAT gateway. It works by injecting prefix-list routes into the route table above,
# which is why the association is explicit.
resource "aws_vpc_endpoint" "s3" {
  count = local.networked ? 1 : 0

  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]

  # THE ENDPOINT NEEDS ITS OWN POLICY, because the default is full access: `Principal: *`,
  # `Action: *`, `Resource: *`. Without this, the one network destination the function has
  # besides Postgres is *all of S3* — including buckets in other AWS accounts.
  #
  # The IAM role bounds what the ROLE may do; it does not bound where code running in this
  # subnet may send bytes. iam.tf withholds `s3:ListBucket` specifically to limit a stolen
  # credential, and leaving this wide open was the hole in that reasoning: exfiltration to an
  # attacker's own bucket needs no permission of ours at all.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource  = ["${aws_s3_bucket.backups.arn}/*"]
    }]
  })

  tags = { Name = "${local.name}-s3" }
}

# ── security groups ─────────────────────────────────────────────────────────────────────────
#
# Referenced by group rather than by CIDR. Lambda ENIs draw addresses from the whole subnet and
# are recycled, so a CIDR rule would have to allow the entire subnet — which is every ENI that
# will ever exist there, not just ours.

resource "aws_security_group" "lambda" {
  count = local.networked ? 1 : 0

  name        = "${local.name}-lambda"
  description = "Dun Mir API function"
  vpc_id      = aws_vpc.this[0].id

  # Egress to the store and nowhere else. There IS nowhere else to go — no NAT, no internet
  # gateway, no interface endpoints — but saying so explicitly means an added route cannot
  # silently become an added capability. Both stores leave via a prefix-list or group rule
  # rather than an address, which is why each needs its own.
  dynamic "egress" {
    for_each = local.creates_database ? [1] : []
    content {
      description     = "Postgres"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.database[0].id]
    }
  }

  egress {
    description     = "S3 via the gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3[0].prefix_list_id]
  }

  dynamic "egress" {
    for_each = var.db_mode == "dynamodb" ? [1] : []
    content {
      description     = "DynamoDB via the gateway endpoint"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      prefix_list_ids = [aws_vpc_endpoint.dynamodb[0].prefix_list_id]
    }
  }

  tags = { Name = "${local.name}-lambda" }
}

resource "aws_security_group" "database" {
  # `creates_database`, not `networked`: the VPC now also exists for the DynamoDB topology,
  # which has no Postgres for this group to protect. Counting it on `networked` would create a
  # security group named "-db" guarding nothing, and a lambda egress rule permitting 5432 to an
  # empty group — configuration that reads as a database being present.
  count = local.creates_database ? 1 : 0

  name        = "${local.name}-db"
  description = "Dun Mir Postgres"
  vpc_id      = aws_vpc.this[0].id

  tags = { Name = "${local.name}-db" }
}

# Declared as a standalone rule rather than inline, because the two groups reference each other
# and an inline pair would be a cycle Terraform cannot resolve.
resource "aws_vpc_security_group_ingress_rule" "database_from_lambda" {
  count = local.creates_database ? 1 : 0

  description                  = "Postgres from the API function only"
  security_group_id            = aws_security_group.database[0].id
  referenced_security_group_id = aws_security_group.lambda[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# DynamoDB over a GATEWAY endpoint — the second and last of them, and the reason the control
# plane's own store can live inside the VPC with no NAT gateway.
#
# THIS IS WHY DYNAMODB AND NOT SOMETHING ELSE. Most AWS services are reachable from a private
# subnet only through an INTERFACE endpoint, which is an ENI billed at ~$7.30/month whether or
# not a byte moves — on a topology whose whole brief is "free", that is the same problem as the
# NAT gateway this VPC exists to avoid. S3 and DynamoDB are the two services with gateway
# endpoints, which are route-table entries and cost nothing. The choice of store and the choice
# not to have a NAT are therefore the same decision.
resource "aws_vpc_endpoint" "dynamodb" {
  count = local.networked && var.db_mode == "dynamodb" ? 1 : 0

  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]

  # SCOPED, for the same reason the S3 endpoint above is. The default endpoint policy is
  # `Principal: *`, `Action: *`, `Resource: *` — which would make every DynamoDB table in every
  # AWS account a reachable network destination from this subnet. The IAM role bounds what the
  # role may DO; it does not bound where code in this subnet may send bytes, and exfiltration to
  # an attacker's own table needs no permission of ours.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:BatchGetItem",
        "dynamodb:Query",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:BatchWriteItem",
        "dynamodb:TransactGetItems",
        "dynamodb:TransactWriteItems",
      ]
      Resource = [
        aws_dynamodb_table.control_plane[0].arn,
        "${aws_dynamodb_table.control_plane[0].arn}/index/*",
      ]
    }]
  })

  tags = { Name = "${local.name}-dynamodb" }
}

# The VPC's default security group, closed.
#
# NOT A SUPPRESSION — the scanner is right, and this is cheap. Every new VPC comes
# with a default security group that allows ALL traffic between anything assigned
# to it, and AWS attaches it to anything created without an explicit group. Nothing
# here does that today, which is exactly why it is worth closing now: the day
# something is added without a `vpc_security_group_ids`, it would silently land in
# an allow-all group rather than failing.
#
# `aws_default_security_group` ADOPTS the existing group rather than creating one,
# and declaring it with no rules removes the ones AWS ships. Destroying this
# resource does not delete the group — it only stops Terraform managing it — so
# there is nothing here that a teardown can strand.
resource "aws_default_security_group" "closed" {
  count = local.networked ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  # No ingress and no egress blocks: that is the point. Anything that needs to talk
  # gets its own group, which is then a decision somebody made rather than one AWS
  # made for them.

  tags = { Name = "${local.name}-default-closed" }
}
