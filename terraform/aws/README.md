# AWS

Two unrelated stacks share this directory and almost nothing else. **Nievah's webhook front
door** runs in `prd-nievah` (666802049426); the **daily cost report** runs in the organisation's
management account, `Root` (857256953358), because that is the only account Cost Explorer will
show the whole organisation from. Read the leaf before you apply it — path and account no
longer agree here, which is why the cost-report leaf pins `allowed_account_ids`.

## Nievah's webhook front door

GitHub POSTs each webhook delivery **exactly once** and never re-sends one it failed to
place. Nievah's ingest sat behind the firefly cluster's ingress, so a 5xx, a reset or a
flapping API server lost the event outright — and one loss strands a pull request silently
and permanently. This takes that hop and holds the delivery until firefly can take it.

The Lambda **code** lives in [MagmaMoose/nievah](https://github.com/magmamoose/nievah); this
owns the infrastructure and points at a published artifact.

```
GitHub ─┐
Slack ──┼─► API Gateway ─► nievah-producer ─► nievah-events.fifo ─► nievah-consumer
EventBr ┘   HTTP API        verify + park                           dedup + hand off
                                                                            │
                                                              nievah-jobs.fifo ── 14d
                                                                            │
                                    outbound HTTPS pull, no tunnel, no ingress
                                                                            ▼
                                                            nievah-worker (firefly)
```

**Nothing inbound reaches firefly.** The worker long-polls the jobs queue and replays each
delivery into the in-cluster ingest, so the cluster needs no public hostname, no tunnel route
and no ingress for Nievah at all.

## Layout

| | |
|---|---|
| `modules/artifacts` | the bucket nievah publishes into, and the GitHub OIDC role it publishes with |
| `modules/nievah-frontdoor` | queues, Lambdas, DynamoDB, S3 overflow, CloudFront, schedules, alarms |
| `prod/eu-west-1/artifacts` | leaf — **apply first** |
| `prod/eu-west-1/nievah-frontdoor` | leaf — `edge_artifact_version` here is the deployment |
| `localstack/` | a root that instantiates both front-door modules against LocalStack |
| `modules/cost-report` | daily per-account spend -> SNS -> Chatbot -> Slack `#finance` |
| `prod/eu-west-1/cost-report` | leaf — **the only one that applies into 857256953358** |

Each leaf generates its own `aws_provider.tf` rather than adding AWS to `root.hcl`. That
keeps a new cloud out of the file every OCI, GCP, Cloudflare and MikroTik leaf includes —
which, per COMMON_MISTAKES #6, Atlantis autoplan cannot see changes to anyway.

**The third leaf has arrived and the block is still not extracted.** This paragraph used to
say a third leaf was the point to extract it, so the deviation is deliberate and worth its
reasons. `cost-report`'s block is not a copy of the other two: it carries a different account,
a different tag set, and an `allowed_account_ids` guard that only it needs. A shared include
would therefore have to be parameterised on all three, which is a bigger object than the 14
lines it replaces — and extracting it means editing the generate block of two leaves that are
already applied and serving live webhook traffic, to change nothing about what they render.
Extract it when a **fourth** leaf appears, or when the front-door leaves are next touched for
their own reasons, whichever comes first.

## Local development

```bash
git clone git@github.com:magmamoose/nievah.git   # beside this repo
make -C terraform/aws dev
```

`up` + `edge-zip` + `apply-local` + `smoke`: starts LocalStack, builds the Lambda package with
**nievah's own script** (never a copy — a local run and a released artifact built differently
is a difference nobody finds until production), applies both modules as the leaves wire them,
and asserts 22 invariants — a signed delivery reaching the jobs queue, an unsigned one
refused, a redelivery landing once, a >256 KB body round-tripping through S3, the FIFO group
surviving both hops, and a tick that does not double-fire on retry.

### What a local run does NOT prove

- **API Gateway is LocalStack Pro-only.** Locally the front door is a Lambda Function URL
  instead. That substitution is honest rather than lossy — HTTP API payload format 2.0 is
  byte-for-byte the event shape a Function URL delivers, so the handler and everything
  downstream are the identical code path — but the gateway's OWN configuration (the throttle,
  the `$default` stage, the integration) is never exercised locally.

  This gap has already cost a live debugging session once. The first build of this stack put
  CloudFront with **origin access control** in front of a Lambda Function URL; it deployed
  clean, `GET /healthz` returned 200, the direct Function URL correctly returned 403 — and
  every **POST** returned `InvalidSignatureException`. AWS documents that OAC on a function URL
  requires the *caller* to send `x-amz-content-sha256` for PUT/POST, which GitHub and Slack
  never will. The health check passed the entire time. **Verify with a real signed POST after
  every change here, not with a GET.**
- **EventBridge Scheduler is mocked** and never fires, so no schedule is created locally.
  `smoke.py` invokes the producer with a tick payload directly instead.

## Cold start

There is a real chicken-and-egg on the first run: the front door points at
`edge/<version>.zip`, which does not exist until nievah publishes, and nievah cannot publish
until the bucket and role exist.

```bash
# 1. The artifact bucket and the OIDC publish role.
cd terraform/aws/prod/eu-west-1/artifacts && terragrunt apply
terragrunt output publish_role_arn   # -> nievah repo variable EDGE_PUBLISH_ROLE_ARN
terragrunt output artifact_bucket    # -> nievah repo variable EDGE_ARTIFACT_BUCKET

# 2. Secrets, by hand. Terraform deliberately does not create these — a secret in a resource
#    is a secret in state.
aws ssm put-parameter --name /nievah/prod/webhook-secret --type SecureString --value "…"
aws ssm put-parameter --name /nievah/prod/slack-signing-secret --type SecureString --value "…"

# 3. Run nievah's publish-edge workflow once, then set edge_artifact_version to what it made.
cd ../nievah-frontdoor && terragrunt apply

# 4. Prove it is up. MUST be 200.
curl -si "$(terragrunt output -raw healthz_url)" | head -1

# 5. Point one repo's webhook at it. Both paths end in the same place, so the blast radius is
#    one repo, and nievah's reconcile_tick catches anything that slips through either way.
terragrunt output webhook_url
```

Then wire the cluster: `cluster_access_key_id` / `cluster_secret_access_key` go to **OCI
Vault** (`nievah-aws-access-key-id`, `nievah-aws-secret-access-key`), and `jobs_queue_url` /
`overflow_bucket` into nievah's `k8s/base/configmap.yaml` alongside `SQS_JOBS_ENABLED: "true"`.
Both Vault entries must exist and be **ACTIVE** first — ESO resolves by name and fails the
whole nievah Secret sync on a missing key, which takes the running bot down rather than
merely leaving the consumer off.

**Ticks last, and in this order.** Suspend `nievah-planner-tick` and `nievah-standup-tick`
in nievah's `k8s/base/cronjob.yaml` **before** setting `enable_ticks = true`. Both firing
means two planner runs with different ARQ job ids that `unique=True` will not collapse —
duplicate issues.

## State holds a credential

The front-door leaf outputs the cluster IAM user's **secret access key**, so its state is a
credential. That is fine here — Terragrunt's `root.hcl` puts state in
`magmamoose-prod-terraform-state` on GCS, encrypted at rest and not in git — but it is the
reason `terraform.tfstate` must never be committed, and why the output is marked `sensitive`.

## What it costs

AWS says "free tier" for two offers that behave nothing alike:

| | what it is | when it ends |
|---|---|---|
| **Always Free** | a permanent monthly allowance that resets | **never** |
| **12-Month Free** | only the account's first year | silently, at month 13 |

Every service here is **Always Free** except S3. Measured against ~950 deliveries a day:

| service | free, per month | this stack uses | headroom |
|---|---|---|---|
| Lambda | 1M requests, 400,000 GB-s | ~58k requests, ~450 GB-s | ~900× |
| SQS | 1M requests | ~400k (mostly idle long polls) | 2.5× |
| CloudFront | 10M requests, 1 TB out | ~29k requests, <1 GB | ~340× |
| DynamoDB | 25 GB, 25 WCU, 25 RCU | a rolling day of ids, 2 WCU | 12× |
| EventBridge Scheduler | 14M invocations | ~180 | ~78,000× |
| SNS | 1M publishes | a handful of alarms | — |
| CloudWatch | 10 alarms, 5 GB logs | 4 alarms, 14-day retention | — |
| SSM Parameter Store | 10,000 standard params | 3 | — |
| **S3** (overflow + artifacts) | **5 GB — 12-MONTH** | see below | ~$0.005/mo |
| **API Gateway** (HTTP API) | **1M req — 12-MONTH** | ~29k requests | ~$0.03/mo |

**SQS has the least headroom**, and it is the idle long poll rather than the traffic: two
worker replicas at a 20-second wait spend ~260k requests a month finding nothing. It moves
with replica count, not with how busy the fleet is — which is why `SQS_WAIT_SECONDS` is
SQS's **maximum**. A 1-second poll would be 5.2M requests for identical behaviour.

**Two things here are not always-free: API Gateway and the two S3 buckets.** Together, about
four cents a month at real traffic.

### The cost ceiling, and why it is not just an alarm

AWS has **no spend cap** — Budgets report, they do not stop, and they can lag hours. So the
real control is enforced in real time at the door:

| control | value | what it bounds |
|---|---|---|
| API Gateway throttle | **2 req/s, burst 10** | the request rate, at the gateway. Over-limit requests get 429 and never reach Lambda |
| Lambda account concurrency | **10** (account default) | how many invocations can ever run at once, account-wide |
| DynamoDB | **provisioned 2/2**, not on-demand | cannot scale itself into a bill |
| S3 overflow | 1-day lifecycle | storage cannot accumulate |
| CloudWatch Logs | 14-day retention | log storage cannot accumulate |
| Budget alert | **$1**, plus FORECASTED at 50% | the backstop that notices anything the above missed |

Real traffic is ~950 deliveries/day — **0.011 req/s**, so the throttle is ~180x headroom.

**The worst case, stated honestly.** Someone who finds the URL and floods it at the full
throttle, 24/7, unnoticed for a whole month: roughly **$5 of API Gateway and under $1 of
Lambda**. It cannot touch SQS, DynamoDB or S3 at all — an unsigned request is refused **401
before anything is queued**, so no downstream resource is reachable without the webhook
secret. At ~$0.20/day the FORECASTED budget alert fires within a few days, long before it
matters.

**The two S3 buckets, separately.** Costed pessimistically — 20
oversized deliveries a day at 1 MB, plus every release's 18 KB artifact kept forever — that
is about **half a cent a month**, dominated by PUT requests rather than storage. Called out
rather than rounded away because the brief for this stack was "free". The producer logs
`producer.overflow` with a byte count on every use, so within a week the overflow rate is a
fact — and if it is zero, delete that bucket and the producer falls back to the 502 it
already handles.

**Secrets are SSM Parameter Store (`SecureString`), never Secrets Manager.** Both give KMS
encryption at rest and an IAM-scoped read; what Secrets Manager's $0.40/secret/month buys is
automatic rotation, and the webhook secret is a value typed into the GitHub App's settings
page that rotates approximately never. Lambda environment variables were rejected outright —
plaintext to anyone with `lambda:GetFunctionConfiguration`.

## Atlantis

Both leaves are Atlantis projects. `parallel_apply: false` is already set repo-wide, so they
cannot race. Note that `when_modified` globs are relative to each leaf's `dir` and cannot
reach `../../../modules/**` — so a change to a module alone does **not** autoplan. Comment
`atlantis plan -p aws-nievah-frontdoor-prod` on the PR when only the module changed.

Atlantis needs AWS credentials it does not have today; see
`kubernetes/apps/atlantis/base/externalsecret-aws.yaml`, and **read the warning at the top of
it** before minting them. It is the most powerful credential in the cluster — Terraform here
creates IAM roles and policies, so whatever it can assume it can also grant itself.

**And it may not be worth minting at all.** Atlantis is slated for replacement by Effusion
(CalebSargeant/agent-personal#9), which runs in GitHub Actions and would authenticate to AWS
by **OIDC** — a role assumed per run, nothing stored. That deletes this credential rather than
scoping it, which is the strongest single argument for the migration. These two leaves are the
first thing that should move when Effusion lands, precisely because they are what makes the
key necessary. If the AWS rollout is not urgent, waiting is the better trade.

---

## Daily cost + free-tier report

Two Slack messages in `#finance` every morning at 07:00 UTC: what was spent, per account and
per service, and how much of the organisation's free-tier allowance is left.

```
EventBridge Scheduler ─► mm-cost-report ─┬─► SNS ─► Chatbot ─► Slack #finance
   cron(0 7 * * ? *)          │           │   ▲
                              │           │   └── AWS Budgets (the backstop)
              reads ──────────┘           └── 2 messages: spend, free-tier headroom
                    │
        s3://mm-cost-report-857256953358/cur/…   ← CUR 2.0, written daily by AWS, free
                    +
        freetier:GetFreeTierUsage                ← org-wide allowances, free to call
```

**It runs in the management account and cannot run anywhere else.** A member account's cost
data covers only itself; the organisation-wide view exists only in `Root` (857256953358) or in
an account registered as a billing delegated administrator, and none is registered. Apply with
`AWS_PROFILE=mm-root`; the leaf's `allowed_account_ids` turns the wrong profile into a refusal
rather than a duplicate stack.

**No Slack token exists anywhere in this stack.** Chatbot already owns an authorised connection
to the workspace and renders a [documented custom-notification envelope][cn] into Slack
markdown, so delivery is `sns:Publish` on one topic and there is no secret to mint, store or
rotate. The function's role can read one S3 prefix, one free billing API and the account list;
it cannot spend money.

[cn]: https://docs.aws.amazon.com/chatbot/latest/adminguide/custom-notifs.html

### Why it reads a file instead of calling Cost Explorer

The obvious implementation is `ce:GetCostAndUsage`, and the first version of this was exactly
that. It was replaced because **the Cost Explorer API costs $0.01 per request with no free
allowance** — $0.30/month for a once-a-day report, against an organisation whose entire spend
is about **$0.00004/month**. The reporting would have cost roughly seven thousand times the
thing it reports on.

The free alternative was measured before it was rejected, not assumed: CloudWatch's
`AWS/Billing` `EstimatedCharges` is **rounded to whole cents**, so every datapoint for every
service in both accounts reads exactly `0.0`. It cannot express this organisation's spend at
all.

| source | sub-cent precision | cost/month |
|---|---|---|
| `ce:GetCostAndUsage` | yes | **$0.30** — $0.01/request, no free allowance |
| CloudWatch `AWS/Billing` | **no** — rounds to $0.01 | $0.00 |
| **CUR 2.0 export → S3** | yes | **~$0.000001** — export is free, S3 bytes only |

### Staying free is a design constraint, not an aspiration

Everything here sits inside a permanent always-free allowance — EventBridge Scheduler bills
after 14 million invocations/month against the 30 this makes, Lambda after 400,000 GB-seconds
against roughly 8, SNS after a million publishes against 60, and Chatbot, Data Exports,
Organizations and the Free Tier API are all free to call. The only thing that bills at all is
the S3 bucket, and it is capped **three independent ways** so that any one of them failing
still leaves the other two:

1. the export is `OVERWRITE_REPORT` — each delivery **replaces** the last rather than adding
   to a pile;
2. versioning is deliberately **off** — with it on, "overwrite" silently means "keep both",
   which turns control 1 into unbounded growth;
3. a lifecycle rule expires objects at `export_retention_days` regardless.

`aws_budgets_budget.org` is the backstop that assumes all of the above is wrong. Two budgets
are free per account and this account had none, so it costs nothing — **do not add a third
without meaning to**, since AWS charges $0.02/budget/day beyond two, which would itself be a
surprise bill. It reports rather than enforces: AWS Budgets cannot cap a bill, and nothing in
AWS can.

### The amounts are the point

Every figure rounds to `$0.00` at two decimals, so `_money()` keeps **three significant
figures** below a cent. That is the whole reason the report is legible rather than a wall of
zeros:

```
*Org total* — $0.0000000801 on 2026-08-17 · $0.0000447 month-to-date (1–18 Aug 2026)

*prd-nievah* · `666802049426`
$0.0000000801 yesterday · $0.0000396 MTD
        • AmazonS3 — $0.0000000801 yesterday · $0.0000396 MTD
```

The free-tier message answers a different question — not "what did this cost" but "what is
about to start costing", which at this scale is by far the more useful of the two, since
everything reads `$0.00` precisely because it sits inside an allowance:

```
*AWS Glue · Catalog-Request* (Always Free)
54 of 1,000,000 Request used · forecast 93 (<0.1% of the allowance)
        • prd-nievah — 40
        • Root — 14

_Free Tier allowances apply to the organisation as a whole, not per account._
```

**The allowance is org-wide and the API is not.** `GetFreeTierUsage` reports one number per
service for the whole organisation — correctly, since that is how AWS applies it — and offers
no account dimension. The per-account split therefore comes from the CUR file, which is why
`line_item_usage_type` and `line_item_usage_amount` are in the export query even though the
cost report never reads them.

**Matching the two is not string equality, and not substring either.** The Free Tier API says
`Request`; the CUR says `EU-Request-ARM` on an arm64 Lambda, and `EU-Requests-FIFO-Tier1` for
SQS's `Requests`. So the region prefix is optional and trailing variant tokens are allowed —
but comparison is on **whole tokens**, because `requests-tier1` *contains* `request`, and a
substring test would quietly file every S3 and SNS request count under Lambda's allowance.
That still leaves S3, SNS and SQS all publishing `EU-Requests-Tier1`, so the usage-type test is
paired with a **service** test that normalises `Amazon Simple Queue Service` against the CUR's
`AWSQueueService`. One allowance routinely spans several CUR types (regions, tiers, FIFO), so
all matches are **summed**, not picked between.

The check that this is right is arithmetic: the per-account splits reconcile against the
org-wide totals AWS reports independently — Lambda `1,786 = 1,785 + 1`, Glue `58 = 36 + 22`.
Where no match is found the report **says so** rather than showing a split that is quietly
wrong.

Sorted by proportion of the limit *forecast* to be consumed, so the line most likely to start
costing money is the first one read. Above 80% it warns; at 100% the title itself shouts.

### Cold start

**The Chatbot handshake comes first and Terraform cannot do it.** Chatbot authorises a Slack
workspace *per AWS account* through an OAuth flow in the console. The front door's
authorisation lives in 666802049426 and grants nothing here.

```bash
# 1. Authorise the workspace ONCE in 857256953358. Console only:
#    Amazon Q Developer in chat applications -> Chat clients -> Configure new client -> Slack
#    Applying before this fails on aws_chatbot_slack_channel_configuration, by design — a
#    cost report that reports to nobody should not apply clean.

# 2. Apply.
cd terraform/aws/prod/eu-west-1/cost-report
AWS_PROFILE=mm-root terragrunt apply

# 3. Wait. AWS writes the first export within 24 hours of it being created; until then the
#    cost message says "awaiting first export" rather than claiming $0.00. The free-tier
#    message is correct immediately — it does not depend on the export.

# 4. Prove it, without waiting for 07:00. Posts two real messages to #finance.
AWS_PROFILE=mm-root aws lambda invoke \
  --function-name "$(terragrunt output -raw function_name)" \
  --region eu-west-1 /dev/stdout
```

### Changing the report

`modules/cost-report/src/handler.py` is read at plan time by `archive_file`, so **editing it
and running apply is the deployment** — no build, no bucket, no version to bump, unlike the
front door next door.

**The export query and the handler are one contract.** Every column in `export.tf`'s
`query_statement` is a `COL_*` constant in `handler.py`. Removing one does not fail the apply
and does not fail the function — it produces a report of zeros, which is the one failure mode
a cost report must not have. Change them together, and run the tests:

```bash
python3 terraform/aws/modules/cost-report/tests/test_handler.py
```

Those tests exist because this could not be verified the way the Cost Explorer version was.
CUR's first file appears up to 24 hours after the export is created, so the parsing was
written before any real file existed to read it. They cover the ways a cost report goes wrong
*quietly*: columns read by name so a reordered export cannot silently transpose values, a
malformed row that must not cost the whole file, `$0.00` line items that must still count
toward free-tier usage, an account that spent nothing still appearing, and the first-of-month
case where yesterday belongs to the previous billing period's file.

### Silence is the failure mode

A daily report that stops arriving looks exactly like a quiet month — and on a stack whose
entire purpose is making sub-cent spend visible, "no message" is indistinguishable from the
good news it is supposed to be delivering. `mm-cost-report-failing` alarms on the function's
`Errors` metric from CloudWatch, outside the function, into the same channel. While it is
firing, silence in `#finance` means the report is broken, not that spend is zero.
