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
  networked = !var.localstack && var.db_mode == "rds"
}

data "aws_availability_zones" "available" {
  count = local.networked ? 1 : 0
  state = "available"
}

resource "aws_vpc" "this" {
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

  # Egress to the database and nowhere else. There is nowhere else to go — no NAT, no interface
  # endpoints — but saying so explicitly means an added route cannot silently become an added
  # capability. S3 traffic leaves via the gateway endpoint, which needs its own rule because
  # gateway endpoints are matched by prefix list, not by an address the group would recognise.
  egress {
    description     = "Postgres"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.database[0].id]
  }

  egress {
    description     = "S3 via the gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3[0].prefix_list_id]
  }

  tags = { Name = "${local.name}-lambda" }
}

resource "aws_security_group" "database" {
  count = local.networked ? 1 : 0

  name        = "${local.name}-db"
  description = "Dun Mir Postgres"
  vpc_id      = aws_vpc.this[0].id

  tags = { Name = "${local.name}-db" }
}

# Declared as a standalone rule rather than inline, because the two groups reference each other
# and an inline pair would be a cycle Terraform cannot resolve.
resource "aws_vpc_security_group_ingress_rule" "database_from_lambda" {
  count = local.networked ? 1 : 0

  description                  = "Postgres from the API function only"
  security_group_id            = aws_security_group.database[0].id
  referenced_security_group_id = aws_security_group.lambda[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
