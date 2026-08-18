# AWS — Nievah's webhook front door

GitHub POSTs each webhook delivery **exactly once** and never re-sends one it failed to
place. Nievah's ingest sat behind the firefly cluster's ingress, so a 5xx, a reset or a
flapping API server lost the event outright — and one loss strands a pull request silently
and permanently. This takes that hop and holds the delivery until firefly can take it.

The Lambda **code** lives in [MagmaMoose/nievah](https://github.com/magmamoose/nievah); this
owns the infrastructure and points at a published artifact.

```
GitHub ─┐
Slack ──┼─► CloudFront ─► nievah-producer ─► nievah-events.fifo ─► nievah-consumer
EventBr ┘   (OAC/SigV4)    verify + park                            dedup + hand off
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
| `localstack/` | a root that instantiates both modules against LocalStack |

Each leaf generates its own `aws_provider.tf` rather than adding AWS to `root.hcl`. That
keeps a new cloud out of the file every OCI, GCP, Cloudflare and MikroTik leaf includes —
which, per COMMON_MISTAKES #6, Atlantis autoplan cannot see changes to anyway. A third AWS
leaf is the point to extract it into a shared include.

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

- **CloudFront is LocalStack Pro-only.** Locally the Function URL is `authorization_type =
  NONE` and requests hit it directly, so **origin access control is not exercised**. After the
  first real apply: `curl -si "$(terragrunt output -raw function_url_for_verification)"` — it
  **must** be 403. A 202 means the Function URL is a second, unprotected front door.
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

# 4. Prove the origin is private. MUST be 403.
curl -si "$(terragrunt output -raw function_url_for_verification)" | head -1

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

**SQS has the least headroom**, and it is the idle long poll rather than the traffic: two
worker replicas at a 20-second wait spend ~260k requests a month finding nothing. It moves
with replica count, not with how busy the fleet is — which is why `SQS_WAIT_SECONDS` is
SQS's **maximum**. A 1-second poll would be 5.2M requests for identical behaviour.

**The two S3 buckets are the only things not literally free.** Costed pessimistically — 20
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
