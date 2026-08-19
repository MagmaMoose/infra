# The front door: an API Gateway HTTP API.
#
# WHY NOT CLOUDFRONT + A LAMBDA FUNCTION URL. This is not a road Caldrith has to walk again —
# nievah's front door was built that way first, deployed to a live account, and the flaw only
# showed under real traffic. Origin access control makes a Function URL private by having
# CloudFront sign each request with SigV4, and from the AWS docs for that exact setup, in an
# Important callout:
#
#     "If you use PUT or POST methods with your Lambda function URL, your users must compute
#      the SHA256 of the body and include the payload hash value of the request body in the
#      x-amz-content-sha256 header when sending the request to CloudFront. Lambda doesn't
#      support unsigned payloads."
#
# "Your users" is GitHub. It will never send that header. CloudFront signs the request but
# does not hash the body itself, so every POST came back 403 InvalidSignatureException — while
# `GET /healthz` returned 200 throughout, which is exactly how it hid from the health check
# written to catch it. Caldrith's ingest is POST / and nothing else; the failure would have
# been total and invisible.
#
# NO CLOUDFRONT AT ALL, THEN. Its remaining value would have been a stable hostname and edge
# TLS; the execute-api hostname is equally stable, Shield Standard covers AWS public endpoints
# either way, and Caldrith has no latency budget to defend — GitHub allows 10 seconds and this
# path does an HMAC and an SQS send.
#
# An HTTP API is the purpose-built answer: POST is native, throttling lives at the door rather
# than at the wallet, and a custom domain needs a REGIONAL ACM certificate rather than one in
# us-east-1. It is one of the two components here that are not always-free — $1.00 per million
# requests, billed from the FIRST request — and two things below make that a monitored number
# rather than a hope: the stage throttle, and `aws_cloudwatch_metric_alarm.api_flood` in
# notify.tf.
#
# THERE IS NO 12-MONTH ALLOWANCE HERE, AND THIS COMMENT USED TO SAY THERE WAS. It claimed API
# Gateway's 1M requests/month was the 12-month kind, scoped to the organisation, expiring
# 2026-09-18 with the payer's clock — and storage.tf said the same for S3's 5 GB. That is the
# PRE-2025-07-15 free tier. AWS replaced it, for every account created on or after that date,
# with a Free-plan/Paid-plan credits model: short-term trials plus always-free offers, and no
# 12-month S3 or API Gateway allowance at all. The payer signed up 2025-09-18, two months after
# the cutover, so this organisation never had the allowances the old comments were counting on.
#
# The money is unchanged and still trivial — ~950 deliveries a day is ~29k requests a month,
# about $0.03 at $1.00/million, plus pennies of S3 — but it is billed NOW rather than from a
# date, which is why the budget guard has to measure gross usage from day one (see the
# `cost_types` block on `aws_budgets_budget.guard`) and why "free until 2026-09-18" should not
# be repeated anywhere in this module.
#
# TWO THINGS TO CONFIRM IN THE PAYER ACCOUNT (857256953358), Billing -> Free Tier, and then
# record here rather than reason about again:
#
#   1. WHICH OFFERS actually show as active for API Gateway and for S3, so these two comments
#      state a fact rather than a reading of the pricing pages. The expected answer is "neither
#      — both bill from the first request".
#   2. WHICH ACCOUNT PLAN the payer is on, which is not a cost question at all. A Free account
#      plan ends after six months or when its credits are used, and the account STOPS rather
#      than bills — which would take this webhook front door offline, silently, on a date
#      nothing in this module tracks. If it is the Free plan, that expiry belongs in a calendar
#      and in this comment.
#
# The ALWAYS-FREE claims elsewhere in this stack survive the tier change and were each checked:
# Lambda 1M requests + 400,000 GB-seconds, DynamoDB 25 RCU/WCU + 25 GB, SQS 1M requests,
# CloudWatch 10 alarms + 5 GB of logs, SNS.

resource "aws_apigatewayv2_api" "producer" {
  count = var.localstack ? 0 : 1

  name          = "${var.name_prefix}-front-door"
  protocol_type = "HTTP"
  description   = "GitHub App webhooks for Caldrith"

  # No CORS block. Nothing browser-based calls this; GitHub is server-to-server, and the one
  # human-operated route (POST /reconcile) is a curl with a bearer token.
}

# A $default route rather than one per path, because the producer already routes on `rawPath`
# and duplicating that table here would create two lists that must agree forever. Caldrith's
# routes are `POST /` (the ingest — note it is the ROOT path, not `/github`), `POST /reconcile`
# (break-glass, bearer-token guarded), and `GET /healthz` / `GET /readyz`. A per-path route
# table would have to encode that the ingest is the root, which is the one entry a reader is
# most likely to get wrong.
#
# The payload format matters: 2.0 is byte-for-byte the shape a Lambda function URL delivers
# (rawPath, lowercased headers, body, isBase64Encoded, requestContext.http.method), so the
# handler needs no changes and the LocalStack harness — which uses a Function URL, because API
# Gateway is a paid LocalStack feature — exercises the identical code path.
#
# `isBase64Encoded` IS LOAD-BEARING HERE AND NOWHERE ELSE IN THIS STACK. The HMAC must be
# computed over the exact bytes GitHub hashed (COMMON_MISTAKES: "verify the signature over the
# RAW body, before any parse"). API Gateway hands the body as a string and may base64-encode
# it; decoding it back to bytes before hashing is the handler's job, and getting it wrong
# fails every signature while leaving the health checks green.
resource "aws_apigatewayv2_integration" "producer" {
  count = var.localstack ? 0 : 1

  api_id                 = aws_apigatewayv2_api.producer[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.producer.invoke_arn
  payload_format_version = "2.0"

  # Comfortably inside GitHub's 10s, and above the function's own 5s timeout so the function's
  # error surfaces rather than the gateway's.
  timeout_milliseconds = 10000
}

resource "aws_apigatewayv2_route" "producer" {
  count = var.localstack ? 0 : 1

  api_id    = aws_apigatewayv2_api.producer[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.producer[0].id}"
}

# The $default stage, so `rawPath` is the real path with no stage prefix to strip. A named
# stage would put `/prod` in front of every route — and since Caldrith's ingest is the ROOT
# path, the delivery would arrive at `/prod` and the producer would 404 its own front door.
resource "aws_apigatewayv2_stage" "producer" {
  count = var.localstack ? 0 : 1

  api_id      = aws_apigatewayv2_api.producer[0].id
  name        = "$default"
  auto_deploy = true

  # THE COST CEILING FOR THE GATEWAY ITSELF — not, as this used to say, for everything behind
  # it. Requests over the limit are rejected with a 429 and never reach Lambda, SQS, DynamoDB or
  # GitHub, so an abusive burst costs gateway requests rather than a full pass through the
  # stack; what does not follow is that admitted requests bound downstream WORK, since one
  # admin-repo push fans out one reconcile job per managed repo. The stack's real ceiling lives
  # on the jobs event source mapping (`var.reconcile_max_concurrency`). Real traffic is ~0.011
  # req/s, so 1/s is ~90x headroom. The full reasoning is in `variable "throttle_rate_limit"`.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  # No access_log_settings, and this is a cost decision with a stated tradeoff. Gateway access
  # logs are the only place a 429 is visible per-request — CloudWatch's `Count` metric tells
  # you a flood happened, not who sent it. But CloudWatch Logs INGESTION is $0.50/GB against a
  # 5 GB allowance shared org-wide with nievah, and a flood is exactly when the log volume
  # spikes: the diagnostic would bill hardest at the moment it is needed, which is a bad
  # shape. Turn it on temporarily while investigating, then turn it off.
}

resource "aws_lambda_permission" "api" {
  count = var.localstack ? 0 : 1

  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "apigateway.amazonaws.com"
  # Scoped to this API. `/*/*` is stage/route — the API id is what actually bounds it.
  source_arn = "${aws_apigatewayv2_api.producer[0].execution_arn}/*/*"
}

# --- custom domain (optional) ---------------------------------------------------------------
#
# REGIONAL certificate, in this region. That is the quiet win over the CloudFront design,
# which needed one in us-east-1 and therefore a second provider alias.
resource "aws_apigatewayv2_domain_name" "producer" {
  count = var.localstack || var.domain_name == "" || !var.enable_custom_domain ? 0 : 1

  domain_name = var.domain_name

  domain_name_configuration {
    # The certificate this module requested, unless one is supplied explicitly (an existing
    # certificate, or one managed elsewhere).
    certificate_arn = var.certificate_arn != "" ? var.certificate_arn : aws_acm_certificate.producer[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "producer" {
  count = var.localstack || var.domain_name == "" || !var.enable_custom_domain ? 0 : 1

  api_id      = aws_apigatewayv2_api.producer[0].id
  domain_name = aws_apigatewayv2_domain_name.producer[0].id
  stage       = aws_apigatewayv2_stage.producer[0].id
}

# --- the certificate for the custom domain ---------------------------------------------------
#
# TWO-PHASE ON PURPOSE, because DNS validation lives in a different Terraform state
# (terraform/cloudflare/dns-magmamoose/prod — a Cloudflare zone is a hard provider boundary).
# A single apply cannot create the certificate, write its validation record into another
# leaf's zone, and wait for issuance. So:
#
#   1. set `domain_name`, leave `enable_custom_domain` false -> the certificate is requested
#      and `certificate_validation_record` names the CNAME to add
#   2. add that CNAME to the Cloudflare leaf and apply it; ACM issues within minutes
#   3. set `enable_custom_domain` true -> the API Gateway domain and mapping are created
#   4. CNAME `hooks-caldrith.magmamoose.com` at `custom_domain_target` from the same
#      Cloudflare leaf
#
# BOTH CLOUDFLARE RECORDS MUST BE DNS-ONLY (grey cloud). A proxied validation record answers
# with Cloudflare's own value and ACM never issues; a proxied hostname record terminates TLS
# at Cloudflare and re-originates to a gateway that routes on the Host header, which fails the
# handshake — and, being an orange-cloud default, is the mistake that gets made by not
# thinking about it.
#
# Setting `enable_custom_domain` before the certificate reaches ISSUED fails the apply with a
# BadRequestException naming the certificate, which is a clear error rather than a broken
# endpoint — but it is still a wasted round trip, hence the flag rather than a guess.
#
# Public ACM certificates are free, and an API Gateway custom domain carries no additional
# charge, so none of this moves the bill.
#
# WORTH DOING FOR CALDRITH SPECIFICALLY, not just for tidiness: the webhook URL is configured
# once per GitHub App installation, and a stable hostname is what lets this stack be rebuilt —
# renamed, moved, re-created after a `destroy` — without every installation needing to be
# re-pointed by hand. The execute-api hostname is stable only as long as the API resource is.
resource "aws_acm_certificate" "producer" {
  count = var.localstack || var.domain_name == "" ? 0 : 1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    # ACM cannot change a certificate's domain in place. Without this, editing `domain_name`
    # destroys the certificate the live custom domain is using before the replacement exists.
    create_before_destroy = true
  }
}
