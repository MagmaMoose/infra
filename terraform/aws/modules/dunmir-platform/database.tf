# PostgreSQL, and the one line item in this stack that can cost money.
#
# Dün Mir's data layer is 200-odd hand-written SQL statements across nineteen tables, with
# joins, correlated subqueries and aggregations. That is a Postgres application, not a
# key-value one, so "port it to DynamoDB and be always-free" is not a configuration change,
# it is a rewrite of the product's entire persistence layer with no behavioural upside. The
# honest answer is to run Postgres and be explicit about what it costs — see `db_mode` in
# variables.tf, which states the organisation-wide free-tier trap in full.
#
# WHAT MAKES THIS THE CHEAPEST HONEST POSTGRES ON AWS
#   db.t4g.micro   Graviton, the free-tier-eligible size, and the cheapest instance RDS sells.
#   single-AZ      Multi-AZ doubles the instance bill for a workload whose recovery objective
#                  is "restore from an automated backup".
#   20 GB gp3      The gp3 minimum AND the free-tier ceiling. gp2 at this size performs worse
#                  for the same money.
#   no public IP   Not a cost decision, but it is why there is no bastion and no NAT: the only
#                  thing that can reach this instance is the function's security group.
#
# MIGRATIONS ARE NOT RUN HERE, and nothing in this module runs them either — an earlier version
# of this comment claimed a `null_resource` does it, which was never true and would have sent
# somebody looking for a resource that does not exist.
#
# `schema/postgres.sql` is applied by invoking the function with `{"task": "migrate"}`, from
# inside the VPC, which is the only place that can reach this instance at all. It is a manual
# step in the runbook, deliberately: a `local-exec` would put the AWS CLI and working
# credentials on the critical path of every apply, and would make a failed migration a failed
# apply of the whole stack. The schema is idempotent, so a re-run is a no-op.
#
# Between the apply and that invocation the sweep schedule is already firing once a minute
# against an empty database. `lambda_handler._sweep` treats a missing schema as a no-op for
# exactly this window rather than erroring every 60 seconds and tripping the alarm.

locals {
  creates_database = var.db_mode == "rds" && !var.localstack

  # The DSN the application reads. Composed here in `rds` mode from the generated password, or
  # taken verbatim in `external` mode. `sslmode=require` is not decoration: RDS accepts
  # unencrypted connections unless the parameter group forbids it, and asyncpg will happily
  # negotiate one.
  database_url = local.creates_database ? format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    aws_db_instance.this[0].username,
    urlencode(random_password.database[0].result),
    aws_db_instance.this[0].address,
    aws_db_instance.this[0].port,
    aws_db_instance.this[0].db_name,
  ) : var.database_url
}

# Regenerated whenever the instance itself is replaced, so each generation of the database gets
# a distinct final-snapshot name.
resource "random_id" "snapshot" {
  count       = local.creates_database ? 1 : 0
  byte_length = 4
  keepers     = { identifier = local.name }
}

# Created HERE rather than left to RDS, for the same reason as the function's group: a
# service-created log group retains FOREVER, and by the time anyone notices the bill, changing
# the retention does not reclaim what is already stored. lambda.tf goes to some trouble over
# exactly this and then this group was left unmanaged.
resource "aws_cloudwatch_log_group" "database" {
  count = local.creates_database ? 1 : 0

  name              = "/aws/rds/instance/${local.name}/postgresql"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-postgresql" }
}

resource "random_password" "database" {
  count = local.creates_database ? 1 : 0

  length = 40
  # RDS rejects '/', '@', '"' and space in a master password. The DSN is built with
  # `urlencode` above, so everything that survives here is safe in a URL as well.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  count = local.creates_database ? 1 : 0

  name       = local.name
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = local.name }
}

# Force TLS. RDS's default `rds.force_ssl = 0` means an unencrypted connection is accepted, and
# a client that fails to negotiate TLS silently gets plaintext instead of an error — which is
# exactly the failure nobody notices, because everything works.
resource "aws_db_parameter_group" "this" {
  count = local.creates_database ? 1 : 0

  # `name_prefix`, NOT `name`, and it is what makes the `create_before_destroy` below usable.
  # A parameter-group name is unique per account per region, so with a fixed name the
  # replacement cannot be created while the original still holds the name — every
  # replacement-forcing change (chiefly `family`, the day the engine moves to 17) would fail at
  # apply with DBParameterGroupAlreadyExists.
  name_prefix = "${local.name}-"
  family      = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
    # Static: this one needs a reboot to take effect, which RDS handles on the next maintenance
    # window unless `apply_immediately` says otherwise.
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  count = local.creates_database ? 1 : 0

  identifier     = local.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  db_name  = "dunmir"
  username = "dunmir"
  password = random_password.database[0].result

  allocated_storage = var.db_allocated_storage
  # No autoscaling ceiling above the allocated size. Storage autoscaling is a bill that grows
  # without anyone deciding it should, and on a 20 GB free-tier allowance the correct response
  # to running out is to look at why, not to buy more.
  max_allocated_storage = 0
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.database[0].id]
  parameter_group_name   = aws_db_parameter_group.this[0].name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  # Minor versions apply themselves in the maintenance window; majors never do. A major upgrade
  # is a decision, and an automatic one would be a decision taken at 03:30 on a Sunday by
  # nobody.
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  # Both off, both because they cost money past the free allowances and neither earns it at this
  # size: Performance Insights is free only for 7 days of retention on some classes and this is
  # not one of them, and Enhanced Monitoring is billed per instance through CloudWatch Logs.
  performance_insights_enabled = false
  monitoring_interval          = 0

  # A final snapshot on destroy. `skip_final_snapshot = true` is the default and it means
  # `terraform destroy` silently and permanently deletes every tenant's data — the correct
  # behaviour for a scratch stack and a catastrophe here.
  #
  # The identifier carries a generation suffix because a snapshot name is unique per account per
  # region AND the snapshot outlives the destroy by design. A constant would let the FIRST
  # destroy succeed and every later one fail on a collision — at the worst possible moment,
  # since by then Terraform has already begun tearing the stack down.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final-${random_id.snapshot[0].hex}"
  deletion_protection       = true

  # Postgres logs to CloudWatch. `postgresql` only, not `upgrade`: the upgrade log is written
  # once per major version and would otherwise create a second log group that exists to hold
  # three lines a year.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # The log group must exist BEFORE the instance, or RDS creates its own with infinite
  # retention on first export and Terraform's is then a second, empty one.
  depends_on = [aws_cloudwatch_log_group.database]

  tags = { Name = local.name }
}
