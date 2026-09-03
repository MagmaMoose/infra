# Caldrith's webhook front door: API Gateway HTTP API -> producer -> jobs.fifo -> reconcile.
# Full serverless; there is no cluster behind this one.
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
# THIS LEAF IS APPLIED AND SERVING. All three of its former preconditions now hold. The list is
# kept because the ORDER still matters if this is ever rebuilt from nothing:
#
#   1. THE BUCKET. `prod/eu-west-1/caldrith-artifacts` creates caldrith-artifacts-483461801743
#      and the OIDC publish role. Apply it FIRST — this leaf takes the bucket by name rather
#      than by `dependency`, for the cross-account reason spelled out below.
#   2. THE OBJECTS. `.github/workflows/publish-edge.yml` in MagmaMoose/caldrith uploads
#      `edge/<v>.zip` and `edge/<v>-reconcile.zip` together, on a v* tag push or by dispatch.
#      Its gate compares a tag against the PREVIOUS TAG, not against S3 — so a version whose
#      predecessor was never published reports `changed=false` and silently skips. Dispatch
#      with `force: true` for a cold start, or nothing is ever written.
#   3. THE HANDLERS. `caldrith.aws.{producer,consumer,reconcile}` exist and are what the three
#      functions import.
#
# `artifact_version` must still name a version that is KNOWN PUBLISHED rather than merely a
# released tag: the apply fails at the first `aws_lambda_function`, naming the S3 object rather
# than the workflow that should have made it.
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
#   2. put the SecureStrings in place, by hand       (see below; four, plus three per
#                                                     extra registration)
#   3. run caldrith's publish workflow once           (uploads BOTH objects for one version)
#   4. set artifact_version to what step 3 produced, and apply this leaf
#   5. curl the healthz output; it MUST be 200
#   6. verify with a real signed POST, not a GET — see the warning in terraform/aws/README.md
#      about the CloudFront/OAC failure that passed every health check for days
#
# THE SECRETS, ALL SEVEN, BY HAND. Terraform deliberately creates none of them: a secret in a
# resource is a secret in state, and the whole security argument in the module's iam.tf rests
# on this state holding no credential. That applies to the second registration exactly as it
# applies to the first — adding `aws_ssm_parameter` resources "just for the new ones" would put
# the GHE tenancy's private key in state while github.com's stays out, which is worse than
# either consistent choice.
#
# The default registration, FLAT AND UNPREFIXED — these four are live; do not re-path them:
#
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/webhook-secret       --value '…'
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/app-id               --value '…'
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/private-key          --value "$(cat app.pem)"
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/manual-trigger-token --value '…'   # optional
#
# The `pinkroccade` registration, one extra path segment per slug — three more, and there is
# NO manual-trigger-token per registration because the break-glass is per DEPLOYMENT:
#
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/pinkroccade/webhook-secret --value '…'
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/pinkroccade/app-id         --value '…'
#   aws ssm put-parameter --type SecureString --name /caldrith/prod/pinkroccade/private-key    --value "$(cat pinkroccade.pem)"
#
# `terragrunt output secret_parameter_names` prints all seven and is the authoritative list;
# this comment is a convenience copy of it and can go stale.
#
# `private-key` is the whole PEM including its newlines. Caldrith's own AppConfig accepts the
# `\n`-escaped form as well, so either survives — but the literal file is the one that cannot
# be mangled by a shell, and a BASE64 blob is not a PEM however much it looks like one when
# printed. `manual-trigger-token` is optional: without it `POST /reconcile` answers 404 and the
# break-glass is simply off.
#
# AND THEN FORCE A COLD START, WHICH IS THE STEP THAT GETS MISSED. `aws/reconcile.py` reads
# Parameter Store once per execution environment and `AppConfig` sits behind an `lru_cache`, so
# a warm container keeps serving whatever credential it booted with — correcting a parameter
# changes nothing until the environment recycles, and the symptom is indistinguishable from the
# fix not having worked. Any `update-function-configuration` recycles them all. The whole
# procedure, including the GitHub App's permission set and its webhook URL, is
# docs/ghe-onboarding.md in MagmaMoose/caldrith.
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
  artifact_version = "1.19.1"

  # A clean hostname for the GitHub App's webhook URL. The module requests its own REGIONAL ACM
  # certificate (see api.tf); `certificate_arn` is only for reusing one managed elsewhere.
  #
  # TWO-PHASE, because the DNS validation record lives in another Terraform state
  # (terraform/cloudflare/dns-magmamoose/prod — a Cloudflare zone is a hard provider boundary).
  # BOTH PHASES ARE DONE: the certificate is ISSUED, the custom domain is AVAILABLE, and the
  # `true` below is what matches the account.
  #
  # IT IS COMMITTED `true` DELIBERATELY — DO NOT "RESET" IT TO `false`. This file sat at
  # `false` for days after phase 2 had been completed on the account, and a plan from that
  # state DESTROYS `aws_apigatewayv2_domain_name.producer` and its api mapping. That is the
  # hostname every GitHub App delivery is pointed at, for every registration, so the apply
  # that "just flips a feature flag off" takes webhook ingest down until DNS is rebuilt.
  #
  # Rebuilding from nothing is the two-phase dance: apply with `enable_custom_domain = false`,
  # read `certificate_validation_record`, add that CNAME to the Cloudflare leaf DNS-ONLY (grey
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
  enable_custom_domain = true

  # Name of the admin (config) repository. It is ALSO the repo Caldrith refuses to manage —
  # `selection.builtin_excludes` drops it from every target list — so this value decides both
  # where the config is read from and which repository is exempt. Wrong value, no error.
  #
  # ONE VALUE FOR EVERY REGISTRATION. `ADMIN_REPO` is a single env var on the consumer and the
  # reconcile function, not a per-registration field, so the pinkroccade tenancy's admin repo
  # must be called `admin` too. If a host ever needs a different name, that is a schema change
  # in `caldrith.settings`, not something to fake from here.
  admin_repo = "admin"

  # ── The pinkroccade GHE registration ────────────────────────────────────────────────────
  #
  # A SECOND GitHub App on a SECOND host, with its own App id, its own private key and its own
  # webhook secret. It is not a variant of the github.com App and shares nothing with it: an
  # installation id is unique per host, so `42` there and `42` on github.com are different
  # tenants (see `caldrith.aws.consumer`).
  #
  # SLUG AND URL ONLY — NEVER A SECRET, and the variable's type is written so that a secret
  # cannot be expressed here at all. The three SecureStrings are created by hand; the module
  # derives their NAMES from this slug and grants IAM on those names, splitting them exactly as
  # it splits the default registration's — webhook-secret to the internet-facing producer,
  # app-id and private-key to the reconcile function and to nothing else.
  #
  # THE WEBHOOK URL IS NOT THE ROOT PATH FOR THIS ONE. The App must point at
  # https://hooks-caldrith.magmamoose.com/h/pinkroccade — `terragrunt output
  # registration_webhook_urls` prints it. Pointing it at `/` instead is the nastiest available
  # mistake: the delivery is verified against GITHUB.COM's webhook secret, fails, and returns
  # 401 "invalid signature", which reads as a rotated secret and sends the operator to re-issue
  # something that was never broken. No API Gateway change is needed for the new path — the
  # stage routes `$default` and the producer dispatches on rawPath.
  #
  # api_url IS THE ghe.com DATA-RESIDENCY FORM, `https://api.<subdomain>.ghe.com`, and NOT
  # `https://pinkroccade.ghe.com/api/v3` — that second shape is GHES (a self-hosted appliance),
  # a different product with a different base path. Getting it wrong is a 404 from githubkit on
  # every call, per repo, after the token was already minted.
  #
  # `var.github_api_url` stays github.com's and is NOT repurposed: it is the DEFAULT
  # registration's api_url, and every extra carries its own inside EXTRA_REGISTRATIONS.
  extra_registrations = [
    {
      slug    = "pinkroccade"
      api_url = "https://api.pinkroccade.ghe.com"
    },
  ]

  # ── The cost controls are module DEFAULTS and are not restated here ─────────────────────
  #
  # Deliberately, so there is one place to change each of them rather than two that must agree:
  #
  #   throttle_rate_limit           1 req/s   (nievah uses 2)  — the gateway ceiling
  #   throttle_burst_limit          5         (nievah uses 10)
  #   api_flood_alarm_hourly_count  1000                       — the flood detector
  #   reconcile_max_concurrency     2                          — GitHub's limit as much as AWS's
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
