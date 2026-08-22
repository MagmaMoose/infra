# Caldrith's webhook front door: API Gateway HTTP API -> producer -> events.fifo -> consumer
# -> jobs.fifo -> reconcile. Full serverless; there is no cluster behind this one.
#
# Caldrith is a multi-tenant GitHub App that enforces configuration-as-code: install it, put
# `.github/settings.yml` in an admin repo, and it reconciles every repository to match. This
# stack is the whole runtime — the FastAPI service became the producer Lambda, the ARQ/Redis
# worker became the reconcile Lambda, Redis became a DynamoDB table and two SQS queues, and
# the Kubernetes deployment became nothing at all.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THIS LEAF DOES NOT APPLY INTO THE SAME ACCOUNT AS ITS SIBLINGS.
#
# `artifacts` and `nievah-frontdoor` apply into prd-nievah (666802049426); `cost-report` into
# Root (857256953358); this one into prd-caldrith (483461801743). Three accounts under one
# directory tree, and the path says nothing about which.
#
# `allowed_account_ids` below is what turns the wrong `AWS_PROFILE` into a refusal instead of a
# second, silently duplicated Caldrith stack inside somebody else's account — which is a
# genuinely bad outcome here rather than merely untidy, because that stack would hold a GitHub
# App private key and would start reconciling real repositories from an account nobody expects
# it in. The cost-report leaf added this guard for the same reason; follow it.
# ─────────────────────────────────────────────────────────────────────────────────────────────

include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/aws/modules/caldrith-frontdoor"
}

# See the note on the matching block in ../artifacts/terragrunt.hcl for why each leaf generates
# its own AWS provider instead of adding one to root.hcl. `allowed_account_ids` is the addition
# here, for the reason at the top of this file.
#
# THE FOURTH LEAF HAS ARRIVED AND THE BLOCK IS STILL NOT EXTRACTED. `terraform/aws/README.md`
# says a fourth leaf is the point to extract it into a shared `aws.hcl`, so the deviation is
# deliberate and owes its reasons: this block is not a copy of the other three either — it
# carries a third account and a third tag set — so the shared include would have to be
# parameterised on account id, tags AND whether an `allowed_account_ids` guard applies, which
# is a bigger object than the fourteen lines it replaces. The better trigger is the next time
# the front-door leaves are touched for their own reasons, when re-rendering two applied,
# live-traffic-serving leaves to change nothing is not a standalone risk.
generate "aws_provider" {
  path      = "aws_provider.tf"
  if_exists = "overwrite"
  contents  = <<TF
provider "aws" {
  region              = "${local.region_vars.locals.region}"
  allowed_account_ids = ["${local.caldrith_account_id}"]

  default_tags {
    tags = {
      ManagedBy = "terragrunt"
      Repo      = "magmamoose/infra"
      Service   = "caldrith"
      Component = "front-door"
    }
  }
}
TF
}

locals {
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("environment.hcl"))

  # prd-caldrith, a member of o-zipq67xej5 under payer 857256953358. The free-tier allowances
  # this stack is designed around are ORGANISATION-wide, not per account — so "caldrith has
  # plenty of Lambda headroom" is only true while nievah does too.
  caldrith_account_id = "483461801743"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# THIS LEAF CANNOT APPLY YET, AND NOT ONE OF ITS THREE PRECONDITIONS EXISTS. Read this before
# running it and mistaking the failure for a Terraform defect:
#
#   1. THE BUCKET. `inputs.artifact_bucket` names caldrith-artifacts-483461801743, and there is
#      no `prod/eu-west-1/caldrith-artifacts` leaf — the only `artifacts` leaf in this repo
#      applies into prd-nievah (666802049426). The bucket does not exist in 483461801743.
#   2. THE OBJECTS. No workflow in MagmaMoose/caldrith publishes `edge/<v>.zip` or
#      `edge/<v>-reconcile.zip`; `.github/workflows/` there holds chart-release, ci, release and
#      security. So `inputs.artifact_version` names a released app tag, not a published build.
#   3. THE HANDLERS. `caldrith.aws.producer`, `caldrith.aws.consumer` and
#      `caldrith.aws.reconcile` do not exist — `src/caldrith/` has no `aws/` package. Even with
#      the objects faked, this would deploy three functions that cannot import their handlers.
#
# The apply fails at the first `aws_lambda_function`. Land the three in order — the artifacts
# leaf (below), then the handler modules and the publish workflow, then this — and until the
# workflow has run once, `artifact_version` should name a version that is KNOWN PUBLISHED rather
# than whatever release tag is current, so the failure mode stays legible.
#
# COLD START, AND WHY THERE IS NO `dependency` BLOCK HERE.
#
# `../nievah-frontdoor` takes its `artifact_bucket` from `dependency "artifacts"`, so the apply
# ordering lives in the graph rather than in a runbook. This leaf cannot: that bucket is in
# prd-nievah, and a Lambda cannot take its code from a bucket in another account without a
# bucket policy granting it — which would put Caldrith's deploys inside Nievah's blast radius
# to save one string.
#
# So Caldrith needs its OWN artifacts leaf, and it does not exist yet. `modules/artifacts` needs
# no forking to provide it — it is already parameterised:
#
#   prod/eu-west-1/caldrith-artifacts/terragrunt.hcl
#     allowed_account_ids         = ["483461801743"]     (same guard as this leaf)
#     name_prefix                 = "caldrith"           -> bucket caldrith-artifacts-483461801743
#     publisher_repo              = "MagmaMoose/caldrith"
#     create_github_oidc_provider = true                 <- TRUE here, unlike the nievah leaf.
#         AWS permits exactly one provider per issuer per account and prd-nievah already had
#         one, which is why that leaf passes an existing ARN. prd-caldrith is a fresh account;
#         assume it has none, and if the apply fails with EntityAlreadyExists, flip this to
#         false and pass the ARN the error names rather than fighting it.
#
# Add that leaf, then a `dependency` block here, and delete `artifact_bucket` from `inputs`
# below. Until then the ordering is:
#
#   1. apply prod/eu-west-1/caldrith-artifacts        (bucket + OIDC publish role)
#   2. put the four SecureStrings in place, by hand   (see below)
#   3. run caldrith's publish workflow once           (uploads BOTH objects for one version)
#   4. set artifact_version to what step 3 produced, and apply this leaf
#   5. curl the healthz output; it MUST be 200
#   6. verify with a real signed POST, not a GET — see the warning in terraform/aws/README.md
#      about the CloudFront/OAC failure that passed every health check for days
#
# THE SECRETS, ALL FOUR, BY HAND. Terraform deliberately creates none of them: a secret in a
# resource is a secret in state, and the whole security argument in the module's iam.tf rests
# on this state holding no credential.
#
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/webhook-secret       --value '…'
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/app-id               --value '…'
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/private-key          --value "$(cat app.pem)"
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/manual-trigger-token --value '…'   # optional
#
# `private-key` is the whole PEM including its newlines. Caldrith's own AppConfig accepts the
# `\n`-escaped form as well, so either survives — but the literal file is the one that cannot
# be mangled by a shell. `manual-trigger-token` is optional: without it `POST /reconcile`
# answers 404 and the break-glass is simply off.
# ─────────────────────────────────────────────────────────────────────────────────────────────

inputs = {
  region      = local.region_vars.locals.region
  environment = local.environment_vars.locals.environment

  # Hand-written, not a dependency output — see the block above. This is exactly the name
  # `modules/artifacts` produces for `name_prefix = "caldrith"` in this account, so the string
  # and the future dependency output agree by construction.
  artifact_bucket = "caldrith-artifacts-483461801743"

  # ─────────────────────────────────────────────────────────────────────────────────────────
  # THIS LINE IS THE DEPLOYMENT.
  #
  # It resolves to TWO objects — `edge/<v>.zip` (producer + consumer, stdlib only) and
  # `edge/<v>-reconcile.zip` (the whole package plus githubkit, pydantic, PyNaCl, Jinja2,
  # PyYAML). Both must exist before this applies; a version whose second upload failed leaves
  # the reconcile function pointed at a key that is not there, and the apply fails naming the
  # S3 object rather than the workflow that should have made it.
  #
  # Caldrith's releases are cut by python-semantic-release from conventional commits, so the
  # version here is a released tag and never a hand-picked number. The publish workflow should
  # open the bump PR; merging it is what moves the front door.
  #
  # BUILD THE RECONCILE ZIP FOR aarch64. Both functions run arm64, and pydantic-core and PyNaCl
  # are compiled extensions — a plain `pip install -t` on an x86_64 runner packages, uploads and
  # applies perfectly and then dies on the first invocation. See the note in the module's
  # lambda.tf.
  #
  # COLD START: this must name a version that has actually been published. Until step 3 above
  # has run at least once, no value here is correct.
  # ─────────────────────────────────────────────────────────────────────────────────────────
  artifact_version = "1.15.2"

  # A clean hostname for the GitHub App's webhook URL. The module requests its own REGIONAL ACM
  # certificate (see api.tf); `certificate_arn` is only for reusing one managed elsewhere.
  #
  # TWO-PHASE, because the DNS validation record lives in another Terraform state
  # (terraform/cloudflare/dns-magmamoose/prod — a Cloudflare zone is a hard provider boundary).
  # PHASE 1 IS WHAT IS COMMITTED HERE: apply with `enable_custom_domain = false`, read
  # `certificate_validation_record`, add that CNAME to the Cloudflare leaf DNS-ONLY (grey
  # cloud), wait for ISSUED, then set this true and apply again — and finally CNAME
  # hooks-caldrith.magmamoose.com at `custom_domain_target`, grey cloud as well.
  #
  # Flipping it early is not dangerous, just wasted: the apply fails with a BadRequestException
  # naming the certificate.
  #
  # Until phase 2 completes, `webhook_url` correctly reports the execute-api hostname, and
  # pointing the App at that first is a perfectly good way to start receiving deliveries.
  # FLAT, not hooks.caldrith.magmamoose.com — one label deep on purpose.
  #
  # Cloudflare's Universal SSL certificate covers `magmamoose.com` and `*.magmamoose.com`
  # and NOTHING deeper. A proxied `hooks.caldrith.magmamoose.com` is two labels deep, so
  # the edge would present a certificate that does not match it and every GitHub delivery
  # would fail TLS before it reached anything. Verified on this zone: the one two-label
  # name that does work, api.platform2.magmamoose.com, only works because a dedicated cert
  # exists for it —
  #
  #   DNS:magmamoose.com, DNS:platform2.magmamoose.com, DNS:*.platform2.magmamoose.com
  #
  # Getting that for `*.caldrith.magmamoose.com` means Advanced Certificate Manager, which
  # is billed per zone per month and would cost more than this entire stack.
  #
  # A hyphen keeps it inside the free wildcard, so the record can be proxied (orange cloud)
  # and Cloudflare absorbs a flood before it reaches API Gateway — which is the layer that
  # actually bills. See MagmaMoose/infra for the matching issue on nievah, which declares
  # hooks.nievah.magmamoose.com and has the same problem, undeployed so far.
  domain_name          = "hooks-caldrith.magmamoose.com"
  certificate_arn      = ""
  enable_custom_domain = false

  # Name of the admin (config) repository. It is ALSO the repo Caldrith refuses to manage —
  # `selection.builtin_excludes` drops it from every target list — so this value decides both
  # where the config is read from and which repository is exempt. Wrong value, no error.
  admin_repo = "admin"

  # ── The cost controls are module DEFAULTS and are not restated here ─────────────────────
  #
  # Deliberately, so there is one place to change each of them rather than two that must agree:
  #
  #   throttle_rate_limit           1 req/s   (nievah uses 2)  — the gateway ceiling
  #   throttle_burst_limit          5         (nievah uses 10)
  #   api_flood_alarm_hourly_count  1000                       — the flood detector
  #   reconcile_max_concurrency     5                          — GitHub's limit as much as AWS's
  #   monthly_budget_usd            1                          — the backstop
  #
  # Every one of them has its reasoning, its arithmetic and its failure mode written out in the
  # module's variables.tf. Read `throttle_rate_limit` and `api_flood_alarm_hourly_count`
  # together before changing either — they are tied by a validation rule, and the flood alarm
  # becomes unreachable if the throttle drops below it.

  # ── Where the alarms and the budget go ──────────────────────────────────────────────────
  #
  # Email is set because an alarm nobody receives is worse than no alarm, and this stack's
  # budget guard is the thing standing between an abusive burst and a personally-funded bill.
  # AWS sends a confirmation link once; until it is clicked the subscription is pending and
  # delivers nothing, which Terraform reports as "created" either way.
  ops_email = "caleb@magmamoose.com"

  # SLACK IS OFF, AND IT IS ONE HANDSHAKE AWAY RATHER THAN ONE LINE AWAY. AWS Chatbot authorises
  # a workspace PER AWS ACCOUNT through an OAuth flow in the console that Terraform cannot
  # perform. The authorisation the front door uses lives in 666802049426 and the cost report's
  # in 857256953358; neither grants anything in 483461801743. To route Caldrith's alarms to
  # #finance alongside the others: do the handshake in prd-caldrith's own Chatbot console
  # first, then set these to T07C6KG3Y4A / C08BHHDGC0K. Setting them before the handshake fails
  # the apply, which is the right failure but a wasted round trip.
  slack_workspace_id = ""
  slack_channel_id   = ""
}
