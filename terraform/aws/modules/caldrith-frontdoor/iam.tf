# Least privilege, resource-scoped throughout. No wildcards on resources, no managed policies
# beyond the one AWS publishes for Lambda logging.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# WHERE THIS DIFFERS FROM NIEVAH, AND IT IS THE SECURITY-RELEVANT DIFFERENCE IN THE WHOLE
# MODULE.
#
# Nievah's iam.tf opens by pointing out that no role in it can read a GitHub App private key,
# because that key is not in the account at all — the only secret AWS holds there authenticates
# INBOUND traffic and can mint nothing. THAT IS NO LONGER TRUE HERE, and pretending otherwise
# would be the worst kind of copied comment.
#
# Caldrith is full serverless: the reconciler runs in this account, so the App private key must
# live in this account. It is the most powerful credential in the design — it mints an
# installation token for every repository the App is installed on, and Caldrith's whole purpose
# is holding write access to repository configuration. A leak of it is a fleet-wide compromise,
# not a stolen webhook.
#
# Three things bound that, and all three are visible below:
#
#   1. ONLY ONE ROLE CAN READ IT. `aws_iam_role.reconcile`, which is not reachable from the
#      internet — it is invoked by an SQS event source mapping and by nothing else.
#   2. THE INTERNET-FACING ROLE CANNOT. `aws_iam_role.producer` is granted two NAMED
#      parameters, never the path, so no combination of calls reaches `private-key`.
#   3. IT IS NEVER AN ENVIRONMENT VARIABLE. Env vars are plaintext to anyone with
#      `lambda:GetFunctionConfiguration`, and they appear in plan output and therefore in
#      Atlantis PR comments. The functions receive PATHS. See lambda.tf.
#
# The consequence for the break-glass endpoint is worth stating because it looks like a
# limitation and is actually the design: `POST /reconcile` cannot resolve installation ids
# itself — that needs an App-JWT, which needs the key. So the producer AUTHORISES the request
# against `manual-trigger-token` and the reconcile function, which holds the key, does the
# resolution.
#
# AND IT GETS THERE VIA events.fifo, NOT BY WRITING TO jobs.fifo. That distinction is the whole
# reason this note is here rather than one line shorter. `data.aws_iam_policy_document.producer`
# below grants `sqs:SendMessage` on `aws_sqs_queue.events` and on nothing else, so a producer
# that tried to enqueue a `reconcile_all_installations` job directly would get AccessDenied — on
# the one path that is only ever exercised during an incident, which is the worst possible place
# to discover a policy gap. Widening the grant to jobs.fifo is the obvious repair and it is the
# wrong one: it would hand the internet-facing role write access to the queue the App-key
# function drains, which is exactly the separation this file exists to keep.
#
# So the manual trigger is a SYNTHETIC ENVELOPE on events.fifo, and the consumer turns it into
# the job. It carries no `X-GitHub-Delivery`, so the producer generates the FIFO deduplication
# id itself — a uuid4, or `manual:<epoch>`; events.fifo has `content_based_deduplication = false`
# — and it needs no DynamoDB claim, because there is no redelivering sender to deduplicate
# against. Exactly the same shape as the webhook path, one write target for the edge, and the
# key never moves toward it. See the consumer block in lambda.tf for the other half.
# ─────────────────────────────────────────────────────────────────────────────────────────────
#
# AND WHAT IS NOT HERE AT ALL: there is no `aws_iam_user`, no `aws_iam_access_key` and no
# `aws_iam_user_policy`. Nievah needs that trio because nievah-worker runs on Oracle Cloud and
# a Raspberry Pi — no instance profile, no OIDC provider to federate against — so a long-lived
# access key is the least-bad option there. Caldrith has no cluster to hand a key to. That
# credential was the largest unbounded surface in the design it inherited: it never expires, it
# is stored outside AWS, Terraform holds it in state, and a leak is permanent until somebody
# notices. Deleting the consumer deleted the credential. Do not reintroduce either half.

locals {
  # NOT terraform.workspace: Terragrunt runs every leaf in the "default" workspace, so that
  # would collapse every environment onto one SSM path. The environment comes from the leaf,
  # via prod/environment.hcl.
  secret_path = "/${var.name_prefix}/${var.environment}"

  # PER-PARAMETER ARNs, AND DELIBERATELY NO PATH ARN. Nievah grants both
  # `…:parameter/nievah/prod` and `…:parameter/nievah/prod/*`, because `GetParametersByPath`
  # authorises against the PATH ITSELF and not only against the parameters under it — granting
  # the `/*` form alone produces `not authorized to perform: ssm:GetParametersByPath on
  # resource: .../parameter/nievah/prod`, naming a resource the policy looks like it covers.
  # That is a real trap and it cost a live debugging session there.
  #
  # Caldrith cannot use the path idiom at all, because one path holds secrets of two very
  # different powers: the webhook secret authenticates inbound traffic and can mint nothing,
  # while the App private key can rewrite every repository in the fleet. Any grant broad enough
  # to be read by path is broad enough to hand the internet-facing function the private key.
  #
  # SO THE HANDLERS MUST READ BY NAME — `ssm:GetParameter` / `ssm:GetParameters`. A handler
  # that reaches for `GetParametersByPath` will fail with the AccessDenied above; that is the
  # policy working, not a bug in it. Add the parameter to the list here rather than widening
  # the grant.
  ssm_arn_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter"

  producer_secret_arns = [
    "${local.ssm_arn_prefix}${local.ssm_webhook_secret}",
    "${local.ssm_arn_prefix}${local.ssm_manual_trigger}",
  ]

  reconcile_secret_arns = [
    "${local.ssm_arn_prefix}${local.ssm_app_id}",
    "${local.ssm_arn_prefix}${local.ssm_private_key}",
  ]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- producer ---------------------------------------------------------------------------
#
# The internet-facing role. Everything it can do is one-way: send to a queue it cannot read,
# write to a prefix it cannot read back, read two parameters that authenticate callers and
# authorise nothing.

resource "aws_iam_role" "producer" {
  name               = "${var.name_prefix}-producer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "producer" {
  statement {
    sid       = "SendToEvents"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]
  }

  # PutObject only. The producer parks an oversized body and never reads one back — the
  # consumer does that — so a compromised edge cannot exfiltrate the deliveries it parked.
  statement {
    sid       = "ParkOverflow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.overflow.arn}/overflow/*"]
  }

  # Two named parameters. NOT the path — see the locals block above, and note that
  # `${local.secret_path}/private-key` is absent from this list on purpose and must stay
  # absent. This is the statement that keeps the App key away from the internet.
  statement {
    sid       = "ReadEdgeSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = local.producer_secret_arns
  }

  # SecureString parameters are encrypted under the account's default SSM key; without this the
  # read above returns ciphertext and every signature check fails closed — which at least fails
  # safe, but fails on every single delivery while `GET /healthz` keeps returning 200, because
  # health never reads a secret.
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "producer" {
  name   = "${var.name_prefix}-producer"
  role   = aws_iam_role.producer.id
  policy = data.aws_iam_policy_document.producer.json
}

resource "aws_iam_role_policy_attachment" "producer_logs" {
  role       = aws_iam_role.producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- consumer ---------------------------------------------------------------------------
#
# NO `ssm:` STATEMENT AT ALL, and that is the point rather than an omission. The consumer needs
# no secret: the producer already verified the signature, and re-verifying downstream of a
# trust boundary proves nothing it does not already know; and it makes no GitHub calls, so it
# has no use for the App key. A role with no secret access is the strongest statement available
# about what a component can leak.

resource "aws_iam_role" "consumer" {
  name               = "${var.name_prefix}-consumer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid = "DrainEvents"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.events.arn]
  }

  statement {
    sid       = "SendToJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # PutItem only — no GetItem, no Query, no Scan. The dedup claim is a CONDITIONAL WRITE and
  # never a read, so the narrower grant is also the complete one. A handler written to "check
  # then write" would need GetItem, would get AccessDenied, and would deserve to:
  # check-then-write is not atomic and two concurrent deliveries of the same id would both pass
  # the check.
  #
  # THE CONDITION IS NOT `attribute_not_exists(pk)` ALONE, AND THE DIFFERENCE IS A DROPPED
  # DELIVERY. The consumer claims the delivery and THEN sends jobs. If it dies between the two —
  # an SQS SendMessage throttle, the 30s timeout, a partially-sent batch — SQS redelivers the
  # same events message, the plain conditional write now fails, and a handler that reads
  # "already claimed" as "duplicate, skip" drops the delivery having produced ZERO jobs. GitHub
  # POSTs each delivery once and never re-sends it, so that is permanent loss, and PutItem-only
  # means the handler cannot distinguish its own previous attempt from a genuine duplicate.
  #
  # SO THE CLAIM CARRIES A CLAIM ID and the condition is
  # `attribute_not_exists(pk) OR claim_id = :me`, with `:me` the SQS messageId — which is stable
  # across every receive of the same message. A retry re-acquires its own claim and proceeds; a
  # genuinely different delivery of the same id is still rejected. That is still one conditional
  # PutItem, which is why this policy needs no widening. (The alternative is to claim AFTER the
  # jobs are sent — at-least-once, which the reconcile layer's idempotency tolerates by design.
  # Either is defensible; what is not is claim-first with a bare existence check.)
  statement {
    sid       = "ClaimDelivery"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.dedup.arn]
  }

  # GetObject only, and only under the one prefix. The consumer reads back a body the producer
  # parked because it exceeded SQS's 256 KB limit; it never writes one, and it never deletes
  # one — expiry is the lifecycle rule's job (storage.tf), which cannot be talked out of it by
  # a compromised function.
  statement {
    sid       = "ReadOverflow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.overflow.arn}/overflow/*"]
  }
}

resource "aws_iam_role_policy" "consumer" {
  name   = "${var.name_prefix}-consumer"
  role   = aws_iam_role.consumer.id
  policy = data.aws_iam_policy_document.consumer.json
}

resource "aws_iam_role_policy_attachment" "consumer_logs" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- reconcile ---------------------------------------------------------------------------
#
# The role that replaces nievah's IAM user, and the trade is worth naming: nievah hands a
# never-expiring access key to a machine outside AWS; this is a role assumed by a function
# inside the account, with credentials AWS rotates on its own and that exist only for the life
# of an invocation. Nothing to store, nothing to leak, nothing to rotate.
#
# It is also the ONLY role here that can read the App private key, and its power inside AWS is
# deliberately tiny by comparison — one queue and two parameters. The blast radius of this role
# is not what it can do in AWS; it is what the key it reads can do on GitHub, which is why
# `caldrith`'s own permission scoping on the App matters more than anything in this file.

resource "aws_iam_role" "reconcile" {
  name               = "${var.name_prefix}-reconcile"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "reconcile" {
  statement {
    sid = "DrainJobs"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # WRITES TO THE QUEUE IT READS, which is normally a smell and here is the fan-out:
  # `reconcile_installation` enqueues one `reconcile_repo` per managed repo, and one
  # `reconcile_org` for Organization accounts. Safe because the tree is finite and no job
  # enqueues its own type — the property is spelled out in lambda.tf and must be re-checked
  # before any new job type is added, because nothing in IAM can distinguish a fan-out from a
  # loop.
  statement {
    sid       = "FanOutJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # The App credentials, by name. Read once per cold start and cached for the life of the
  # execution environment — a read per job would be an SSM call per repo per reconcile, which
  # is both slower and closer to the (generous) Parameter Store throughput limits than it needs
  # to be.
  statement {
    sid       = "ReadAppCredentials"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = local.reconcile_secret_arns
  }

  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }

  # No S3 statement, and no DynamoDB statement. A job message is a small descriptor —
  # `{job, installation_id, owner, repo}` — so this function never touches an overflow body,
  # and the delivery claim was made by the consumer before the job ever existed. If a job
  # message ever needs to carry a payload large enough to overflow, that is a signal the
  # consumer is deciding too little, not that this role needs S3.
}

resource "aws_iam_role_policy" "reconcile" {
  name   = "${var.name_prefix}-reconcile"
  role   = aws_iam_role.reconcile.id
  policy = data.aws_iam_policy_document.reconcile.json
}

resource "aws_iam_role_policy_attachment" "reconcile_logs" {
  role       = aws_iam_role.reconcile.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
