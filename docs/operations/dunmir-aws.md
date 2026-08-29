# Dün Mir on AWS

Dün Mir's backend runs on AWS free-tier services: a Lambda behind an API Gateway HTTP API, a
Cognito user pool the browser talks to directly, an RDS Postgres nothing outside the VPC can
reach, and an S3 bucket for encrypted device backups. **The console stays on Cloudflare** — only
the API is here.

- Module: `terraform/aws/modules/dunmir-platform`
- Leaf: `terraform/aws/dunmir/prod/eu-west-1/platform`
- Local proving ground: `terraform/aws/localstack-dunmir` (`make -C terraform/aws dunmir-dev`)

---

## Read this before creating the account

One decision determines whether this stack costs nothing or about **$15 a month**, and it
cannot be changed afterwards.

`terraform/aws/chargate/provider.hcl` records what magmamoose/infra#641 established the
expensive way: **AWS applies the free tier across an organization, and eligibility dates from
the MANAGEMENT account's creation.** A member account opened inside the existing MagmaMoose
organisation inherits an already-expired 12-month allowance and is billed from its first hour.

Almost everything here is on an *always*-free allowance and does not care:

| Service | Allowance | Expires? |
| --- | --- | --- |
| Lambda | 1M requests, 400,000 GB-seconds / month | never |
| Cognito | 10,000 monthly active users | never |
| EventBridge Scheduler | 14M invocations / month | never |
| CloudWatch Logs | 5 GB ingest | never |
| API Gateway HTTP API | 1M requests / month | **12 months**, then $1.00/M |
| ECR | 500 MB | **12 months** |
| S3 | 5 GB | **12 months** |
| **RDS** | db.t4g.micro, 20 GB, 750 h/month | **12 months** |

RDS is the one that matters — it is ~$15/month once the tier lapses. The other
three are cents: the default heartbeat interval is **one hour**, so a thousand
devices generate ~720k API requests a month (~$0.72), the ECR lifecycle policy
keeps ten images, and the S3 lifecycle expires backup bodies after a year.

So:

- **A new standalone account**, outside the organisation, gets its own free plan and this
  stack costs nothing. This is the recommendation.
- **A member account** is fine too, as long as ~$15/month for the database is a decision
  somebody made rather than a surprise.

There is no third option that keeps Postgres. The application is 200-odd hand-written SQL
statements across nineteen tables with joins and aggregations; "port it to DynamoDB and be
always-free" is a rewrite of the persistence layer, not a setting.

A $1 budget alarm and three CloudWatch alarms are created either way. A dollar is not an
operating budget — the premise is that this costs nothing, so any charge is news.

---

## The shape, and why it is that shape

The function sits in a VPC with **no NAT gateway and no interface endpoints**. Both are
billed by the hour (~$32 and ~$7.30 a month), which is the whole thing this topology avoids.
So the function has no route to the internet, and the application was built around that:

| Concern | How it works without egress |
| --- | --- |
| Operator identity | The **browser** calls Cognito directly. The backend only *verifies* the JWT — offline, against a JWKS Terraform reads once at apply time and passes in as configuration. |
| Backup bodies | S3, through a **gateway** VPC endpoint, which is free. |
| Confirmation + reset email | **Cognito sends it**, from the browser's request. Nothing here has a mail path. |
| Invitations | The link is handed back to the inviter to pass on. See below. |
| Sweeps | EventBridge Scheduler invokes the function; the function calls out to nothing. |

Two consequences worth stating plainly:

- **Stripe billing and the GitHub config browser do not work on this topology.** Both need
  egress. `BILLING_ENABLED=false` is set explicitly rather than left to a default.
- **Invitations are copy-and-paste.** `POST /api/members/invite` returns an `invite_url` and
  the console shows it with a Copy button. This is a deliberate product decision, not a
  degraded mode: it removes an entire class of silent deliverability failure from the one
  flow that gates onboarding.

If egress ever becomes necessary, the cheap way in is a **dual-stack subnet plus an
egress-only internet gateway**, which carries no hourly charge. It is not done here because
IPv6-only egress fails silently against any IPv4-only endpoint.

---

## First deploy

### 1. The account and the role

Create the AWS account (see above), then create an ECR repository and a GitHub OIDC role for
the product repository. The role's trust policy must name `repo:MagmaMoose/dunmir:*`; its
permissions need only ECR push.

Set three **variables** (none are secret) on `MagmaMoose/dunmir`:

```bash
gh variable set AWS_REGION --repo MagmaMoose/dunmir --body eu-west-1
gh variable set ECR_REPOSITORY --repo MagmaMoose/dunmir --body dunmir-backend
gh variable set AWS_ROLE_TO_ASSUME --repo MagmaMoose/dunmir --body arn:aws:iam::<account>:role/dunmir-github-actions
```

Fill in `account_id` in `terraform/aws/dunmir/provider.hcl`. It is empty until then, which
disables the account guard — nobody should be able to apply this into the wrong account by
accident.

### 2. Publish an image

Run **Publish backend image (AWS ECR)** in the product repository. It builds
`docker-bake.hcl`'s `lambda` target for arm64, pushes it, and prints the exact `image_uri`
line for the leaf. Paste it in.

The image must be in ECR **in this account and region** — Lambda cannot pull from GHCR, which
is why the `lambda` bake target is outside the `default` group that publishes there. Pin a
digest, not a tag: Lambda resolves a tag once at update time, so re-pushing the same tag does
not redeploy.

### 3. Apply, phase 1 — no custom domain yet

```bash
cd terraform/aws/dunmir/prod/eu-west-1/platform && AWS_PROFILE=mm-dunmir terragrunt apply
```

RDS takes about ten minutes. The API comes up on its own `*.execute-api` hostname and is usable
immediately.

Read the validation record and create it in Cloudflare, **DNS-only (grey cloud)**:

```bash
terragrunt output -json certificate_validation_record
```

The API is already usable on its `*.execute-api.<region>.amazonaws.com` hostname
(`terragrunt output -raw execute_api_endpoint`). **That is for `curl` and for an
agent smoke test, not for the console** — CI pins the SPA bundle to the custom
domain and the CSP's `connect-src` allows only that, so a console built now would
have every call blocked by the browser. Deploy the console after phase 2.

### 4. Apply the schema

Terraform does not do this, and nothing outside the VPC can — the database has no public
address, and this function is the only thing inside the VPC that can reach it:

```bash
aws lambda invoke --function-name "$(terragrunt output -raw lambda_function_name)" \
  --cli-binary-format raw-in-base64-out --payload '{"task":"migrate"}' /dev/stdout
```

Expect `{"ok": true, "seeded": false}`. The schema is idempotent, so re-running is a no-op.

### 5. Apply, phase 2 — attach the custom domain

Once ACM reports `ISSUED`, set `enable_custom_domain = true` in the leaf and apply again. The
domain cannot be created against a certificate still `PENDING_VALIDATION`, which is why this is
two phases.

Then point `api.dunmir.magmamoose.com` at the gateway in Cloudflare — a CNAME to
`api_domain_target`, **DNS-only (grey cloud)**. Proxying it would put Cloudflare in front of a
hostname whose certificate ACM issued for that exact name. It also sidesteps the two-label
hostname trap entirely: Cloudflare's Universal SSL covers one label and
`api.dunmir.magmamoose.com` is two, but here Cloudflare terminates nothing.

Phase 2 also sets `disable_execute_api_endpoint`, so the gateway's own hostname stops
answering and the custom domain becomes the only way in.

### 6. Verify the custom domain is the only way in

**This is the one check the local run cannot perform**, because LocalStack gates
`apigatewayv2` behind its Pro licence:

```bash
curl -si "$(terragrunt output -raw execute_api_endpoint)/v1/health" | head -1
```

After phase 2 it **must** return `403`. A `200` means the gateway's own hostname still answers,
so the custom domain is decorative and anything attached to it can be bypassed with one DNS
lookup.

Then confirm the real path works end to end:

```bash
curl -s https://api.dunmir.magmamoose.com/api/session/config | jq .auth_mode   # -> "cognito"
```

### 7. Point the console at it

The API origin is a **build-time** constant in the SPA. CI asserts it reaches the bundle and
matches the CSP's `connect-src`, because a mismatch is invisible — the console renders and
every call is blocked by the browser in a way indistinguishable from the API being down.

`API_BASE` in `.github/workflows/deploy-frontend.yml` is already
`https://api.dunmir.magmamoose.com`. If the region ever changes, update the Cognito origin in
`frontend/public/_headers` and `COGNITO_REGION` in `.github/workflows/ci.yml` together.

The pool and client ids are **not** baked in: the console fetches them at runtime from
`GET /api/session/config`, so repointing it at another pool is a backend setting rather than a
front-end release.

---

## Onboarding the first client

1. **They sign up.** `https://dunmir.magmamoose.com/signup` — Cognito emails a six-digit code,
   they type it into our own screen, then sign in and enrol an authenticator. Signing up
   founds *their own* workspace and they own it; it touches nobody else's data.
2. **Or you invite them.** Members → invite → **copy the link** and send it however you
   already talk to them. The link works once, expires in seven days, and is bound to the
   address it was raised for — a different mailbox accepting it is refused.
3. **They create an agent** and point it at `https://api.dunmir.magmamoose.com`. Devices
   appear on their first heartbeat; nothing is installed on a router.

To close self-serve sign-up, set `signup_allowed_domains` on the leaf, or `SIGNUP_OPEN=false`.
A closed deployment still lets the *first* account through on an empty database, so a fresh
install can always create its founding operator.

---

## Operating it

**Deploying a change** is one line. Publish an image, bump `image_uri`, apply.

**Logs**: `aws logs tail /aws/lambda/dunmir-prod-api --follow` for the application, and
`/aws/apigateway/dunmir-prod-api` for the edge — the second is where a request that never
reached the function (a throttle, an oversized payload, a bad path) leaves its only trace.
Retention is 14 days on both.

**Alarms**: three, and they watch different things on purpose. `API 5xx` is the one that sees an
application error, because Mangum returns a 500 *payload* rather than failing the invocation —
so Lambda's own `Errors` metric stays at zero while the API is broken. `Errors` is still there
because it is the only thing that sees the **sweep** fail (the scheduler invokes the function
directly and never touches the gateway). `CPUCreditBalance` is a cost alarm: RDS runs T4g in
Unlimited mode, so sustained CPU is billed rather than throttled.

**The database** has no public address by design. To reach it, invoke the function — add a
task to `lambda_handler.py` rather than opening a hole in the security group.

**Payload limits.** API Gateway caps a request at 10 MB and base64 inflates a binary body into
the event, so the largest backup an agent can upload is about 7 MiB. The application's own
ceiling is set to 6 MiB (`MAX_BACKUP_BYTES`) so the agent gets *our* 413, naming the real limit,
rather than an opaque rejection from the gateway with nothing in our logs.

**A lost authenticator** is an administrator action on this topology: Cognito has no
self-service TOTP reset. In the AWS console, User pools → the user → *Reset MFA*. The console
says so on the sign-in screen rather than offering a recovery-code path that does not exist
here.

**Rotating the Cognito signing keys** is not a thing you do — AWS does not rotate them. But if
the pool is ever recreated, `terraform apply` re-reads the JWKS in the same run that changes
the issuer, so the two cannot drift.

---

## The local proving ground

```bash
make -C terraform/aws dunmir-dev          # up, seed, zip, apply, migrate, smoke
make -C terraform/aws dunmir-image-test   # the REAL container image, under AWS's own RIE
```

`dunmir-dev` runs LocalStack + Postgres + `moto` (for Cognito) and drives 39 assertions
through the whole stack: sign-up, sign-in against real RS256 tokens, offline verification,
forged-token rejection, agent heartbeat, a backup body through the SigV4 signer to S3, the
sweep, and an invitation redeemed into the inviter's workspace.

**Two proofs, and both are needed.** `dunmir-dev` exercises the *wiring* but runs a zip,
because container-image Lambdas are a LocalStack Pro feature. `dunmir-image-test` exercises
the *artefact* production actually deploys — it is the only check that catches a package the
application imports that was never `COPY`'d into the image, which produces an image that
builds, pushes and deploys cleanly and then dies at startup. Six releases of this product
shipped in exactly that state.

### What a local run does not prove

| | Why |
| --- | --- |
| API Gateway | `apigatewayv2` is Pro-only in LocalStack, so the local root runs a Lambda Function URL instead. The edge itself is untested locally — but unlike the CloudFront+OAC design it replaced, its behaviour is derivable from documentation: API Gateway forwards `Authorization` untouched and signs nothing. Step 6 is the check. |
| RDS | Not emulated. Locally it is a plain Postgres container — same engine, same schema, so the SQL is genuinely exercised, but nothing about subnet groups, backups or failover is. |
| VPC attachment | The function runs unattached locally, so the security-group path between function and database is untested. |
| Cognito MFA + email | `moto` mints real RS256 tokens against a real JWKS and honours the password policy, but does not model the MFA challenge sequence or deliver mail. |
| EventBridge Scheduler | Accepted, never fired. The smoke test invokes the sweep payload directly, which covers everything downstream of the schedule. |

---

## Why there is no Atlantis project

Atlantis holds one AWS credential and it is nievah's. Dün Mir is expected to live in a
standalone account **outside the organisation**, so this is not a credential that could be
granted — it is one that cannot exist in the current design. The leaf is applied by hand with
`AWS_PROFILE=mm-dunmir`; the deployment it exists to serve is a one-line bump of `image_uri`.

Effusion's per-run OIDC role is the real answer, and this is another argument for it.
