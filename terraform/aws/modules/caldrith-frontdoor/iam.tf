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
# THE PRODUCER NOW WRITES TO jobs.fifo DIRECTLY, AND UNTIL 2026-09-03 THIS PARAGRAPH SAID THE
# OPPOSITE. The old grant was `sqs:SendMessage` on events.fifo and nothing else, so a producer
# that tried to enqueue a `reconcile_all_installations` job got AccessDenied, and the manual
# trigger travelled as a synthetic envelope that a separate `consumer` function turned into the
# job. That was a real boundary and it is worth being honest about losing it.
#
# WHY IT WENT: the queue behind it cost ~80% of this account's SQS usage in EMPTY long-poll
# receives, to carry deliveries that routed to nothing 99.3% of the time (queues.tf has the
# measurements). And the boundary was thinner than it read — a compromise of this function also
# holds `manual-trigger-token`, so it could already reach `reconcile_all_installations` through
# events.fifo. The indirection made that one hop longer, not impossible.
#
# WHAT DID NOT MOVE, AND MUST NOT: points 1-3 above. The producer still holds NAMED parameters
# and never the path, still cannot read `private-key`, and still receives paths rather than
# values. A compromise of the edge forges deliveries and triggers reconciles of repositories
# Caldrith already manages; it does not become Caldrith. That is the property this file exists
# to keep, and the fold does not touch it. Recorded in caldrith's
# .claude/decisions/0001-fold-consumer-into-producer.md.
# ─────────────────────────────────────────────────────────────────────────────────────────────
#
# AND WHAT IS NOT HERE AT ALL: there is no `aws_iam_user`, no `aws_iam_access_key` and no
# `aws_iam_user_policy`. Nievah needs that trio because nievah-worker runs on Oracle Cloud and
# a Raspberry Pi — no instance profile, no OIDC provider to federate against — so a long-lived
# access key is the least-bad option there. Caldrith has no cluster to hand a key to. That
# credential was the largest unbounded surface in the design it inherited: it never expires, it
# is stored outside AWS, Terraform holds it in state, and a leak is permanent until somebody
# notices. Retiring the cluster deleted the credential. Do not reintroduce either half.

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

  # EVERY EXTRA REGISTRATION SPLITS THE SAME WAY, AND KEEPING IT SPLIT IS MANDATORY RATHER
  # THAN TIDY. The separation above is real today — the producer holds the webhook secret and
  # the manual-trigger token, the reconcile role holds the App credentials, and no combination
  # of calls from the internet-facing function reaches a private key. A second registration
  # does not get to relax that: a GHE tenancy's App key is exactly as powerful over that
  # tenancy as the github.com key is over github.com, so granting it to the producer would
  # undo the property for one host while the comments above still claimed it for all of them.
  #
  #   <slug>'s webhook-secret ARN  -> producer ONLY.
  #   <slug>'s app-id + private-key ARNs -> reconcile ONLY.
  #   the reconcile role needs the App credentials and never a webhook secret.
  #
  # STILL PER-PARAMETER, STILL NEVER A `/*` PATH ARN — and a slug directory is exactly where
  # that temptation reappears. `/caldrith/prod/<slug>/*` looks safe now that each registration
  # has a directory of its own; it is not, because that directory holds that slug's
  # private-key too, and `GetParametersByPath` authorises against the PATH rather than the
  # parameters beneath it. Add ARNs to these lists. Never widen the grant.
  #
  # NOR ONE BLOB PARAMETER HOLDING EVERY REGISTRATION'S SECRETS, for the reason producer.py
  # states where it declares REGISTRATION_SECRET_PARAMS: kms:Decrypt is authorised per
  # parameter, so a single blob makes every registration's secret readable to anyone holding
  # any one of them.
  extra_producer_secret_arns = [
    for r in values(local.extra_registrations) : "${local.ssm_arn_prefix}${r.webhook_secret_param}"
  ]

  extra_reconcile_secret_arns = flatten([
    for r in values(local.extra_registrations) : [
      "${local.ssm_arn_prefix}${r.app_id_param}",
      "${local.ssm_arn_prefix}${r.private_key_param}",
    ]
  ])

  # `concat`, with the default registration's two entries FIRST and byte-identical. With
  # `var.extra_registrations` empty — which is every deployment until a leaf opts in — both
  # lists evaluate to exactly what they were before, so this is a no-op plan against the live
  # stack rather than a policy rewrite on a stack that is serving traffic.
  producer_secret_arns = concat([
    "${local.ssm_arn_prefix}${local.ssm_webhook_secret}",
    "${local.ssm_arn_prefix}${local.ssm_manual_trigger}",
  ], local.extra_producer_secret_arns)

  reconcile_secret_arns = concat([
    "${local.ssm_arn_prefix}${local.ssm_app_id}",
    "${local.ssm_arn_prefix}${local.ssm_private_key}",
  ], local.extra_reconcile_secret_arns)
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
  # jobs.fifo DIRECTLY, WHICH THIS FILE USED TO ARGUE AGAINST AT LENGTH. Until 2026-09-03 the
  # grant was `sqs:SendMessage` on events.fifo and nothing else, and the header above still
  # explains what that bought: a producer that tried to enqueue a `reconcile_all_installations`
  # job got AccessDenied, and the break-glass trigger had to travel as a synthetic envelope a
  # separate consumer function turned into a job.
  #
  # The queue is gone (queues.tf says why — 80% of this account's SQS usage was empty polling
  # for a hop that routed 99.3% of deliveries to nothing), so the boundary went with it. It was
  # thinner than it read: anyone holding code execution here also holds the manual-trigger
  # token, and could already reach `reconcile_all_installations` THROUGH events.fifo. Recorded
  # rather than quietly dropped — caldrith's
  # .claude/decisions/0001-fold-consumer-into-producer.md.
  #
  # WHAT DID NOT CHANGE IS THE ONE THAT MATTERS: this role still cannot read the App private
  # key, so a compromise forges deliveries and triggers reconciles, and does not become
  # Caldrith. See the ReadEdgeSecrets statement below and the header at the top of this file.
  statement {
    sid       = "SendToJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # PutItem only, so the durable delivery claim can be written and never read back. A
  # conditional write needs no `GetItem` — that is the whole reason the claim is a conditional
  # PutItem rather than a check-then-write, and a handler written the other way would get
  # AccessDenied here and would deserve to.
  statement {
    sid       = "ClaimDelivery"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.dedup.arn]
  }

  # Named parameters. NOT the path — see the locals block above, and note that
  # `${local.secret_path}/private-key` is absent from this list on purpose and must stay
  # absent. This is the statement that keeps the App key away from the internet.
  #
  # With extra registrations configured the list also carries each slug's WEBHOOK-SECRET
  # parameter and nothing more: `${local.secret_path}/<slug>/private-key` and
  # `…/<slug>/app-id` are absent for precisely the same reason as the default's, and must
  # stay absent. Adding one here is the single change that would break this module's security
  # argument, and it would do so for one host at a time while every comment still claimed
  # otherwise.
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

  # The App credentials, by name — the default registration's, plus each extra registration's
  # app-id and private-key. Read once per cold start and cached for the life of the execution
  # environment: a read per job would be an SSM call per repo per reconcile, which is both
  # slower and closer to the (generous) Parameter Store throughput limits than it needs to be.
  #
  # NO WEBHOOK-SECRET PARAMETER IS IN THIS LIST, the extras' included, and that is deliberate
  # in both directions. This function verifies no signatures; withholding the secrets means a
  # compromise of the most privileged role in the account still cannot forge a delivery into
  # its own front door. `_load_extra_registrations` fills the field with the literal
  # "unused-by-reconcile" and says so in its docstring.
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

  # The entitlement table: WHETHER an account may be reconciled at all. See storage.tf for why
  # it is a different table from `dedup` rather than a second copy of it.
  #
  # GetItem AND NOTHING ELSE, AND THE MISSING VERBS ARE THE WHOLE STATEMENT.
  #
  #   NO PutItem, NO UpdateItem, NO DeleteItem. Nothing in Caldrith writes an entitlement —
  #   the billing system does — so this is the function that CHECKS whether a customer has
  #   paid, denied the ability to answer that question in its own favour. That is the most
  #   valuable line in this policy and the easiest one to give away later while adding a
  #   feature; `caldrith/aws/entitlement.py` states the same requirement from the other side.
  #   If self-service enrolment ever ships, it belongs in something that is not the
  #   repository reconciler.
  #
  #   NO Query, NO Scan. Every read is a single-key `get_item` on a `pk` this function
  #   already knows (`entitlement_key(registration, account)`), so the narrow grant is also
  #   the complete one — and a role that cannot Scan cannot enumerate the customer list even
  #   if the code is talked into trying.
  #
  # AND THE READ FAILING IS SAFE, WHICH IS WHY A MISTAKE HERE IS QUIET RATHER THAN LOUD.
  # `lookup()` never raises: an AccessDenied becomes SOURCE_UNAVAILABLE, the bounded
  # last-known-good cache answers if it can, and the decision FAILS OPEN. So a policy error
  # does not refuse the fleet, it stops enforcing. Do not read a working reconcile as proof
  # this statement is right — read the `reconcile.entitlement` log line.
  statement {
    sid       = "ReadEntitlements"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.entitlements.arn]
  }

  # NO STATEMENT ON `aws_dynamodb_table.dedup`, which is the distinction the line above must
  # not be allowed to blur. The delivery claim is the PRODUCER's and was made before this job
  # existed; two roles writing claims to one table is how a claim gets re-issued and a
  # delivery processed twice. This role's DynamoDB access is the entitlements table and
  # nothing else.
  #
  # And no S3 statement. A job message is a small descriptor — `{job, installation_id, owner,
  # repo}` — so this function never needs a body at all. If a job message ever grew big
  # enough to need one, that is a signal the producer is deciding too little, not that this
  # role needs S3.
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
