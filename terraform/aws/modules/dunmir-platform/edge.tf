# The public entrypoint: an API Gateway HTTP API in front of the function.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THIS WAS CLOUDFRONT + ORIGIN ACCESS CONTROL IN FRONT OF A LAMBDA FUNCTION URL. That design
# cannot work for this API, and the reason is worth keeping so nobody re-derives it:
#
#   1. OAC with `signing_behavior = "always"` puts CloudFront's OWN SigV4 credential in the
#      `Authorization` header of every origin request, **overwriting the viewer's**. Every
#      credential this product accepts rides on that header — the Cognito ID token, the agent's
#      `dunmir_…` bearer, the shared `ADMIN_TOKEN` — so the function would have received a
#      SigV4 signature where it expected a bearer and answered 401 to literally everything.
#      Forwarding the header with `AllViewerExceptHostHeader` does not help: the override
#      happens at signing time, after the origin request policy has run.
#   2. OAC does not hash request bodies. AWS requires the CALLER to send
#      `x-amz-content-sha256` on any POST/PUT, because Lambda does not accept unsigned
#      payloads. Neither the browser nor a deployed RouterOS agent sends that header, and the
#      agent's wire contract is frozen — so every mutation and every backup upload would have
#      been rejected with a 403 before the function was entered, leaving nothing in its logs.
#   3. Since October 2025 a newly created function URL also requires `lambda:InvokeFunction`
#      alongside `lambda:InvokeFunctionUrl` in the resource policy.
#
# Any one of those is a total outage, and none is reproducible on LocalStack, whose community
# image has no CloudFront at all. The sibling `chargate-broker` and `caldrith-frontdoor` modules
# reached the same conclusion for the same reason; this now matches them.
#
# WHAT IT COSTS. HTTP API is $1.00 per million requests after a 1M/month tier that expires
# after twelve months. This is the second line item that is not permanently free (RDS is the
# other — see `db_mode`), and unlike RDS it is negligible: the default heartbeat interval is
# ONE HOUR (`DEFAULT_HEARTBEAT_INTERVAL_SECONDS=3600`), so a thousand devices generate ~720k
# requests a month, about $0.72. CloudFront's always-free tier bought a design that does not
# function, which is not a saving.
# ─────────────────────────────────────────────────────────────────────────────────────────────

locals {
  wants_domain = var.api_domain_name != ""
  creates_api  = !var.localstack

  # A certificate is requested as soon as a domain is named, but the custom domain is only
  # CREATED once `enable_custom_domain` is set — see the two-phase note on `api_domain_name`.
  # A domain cannot be created against a certificate still in PENDING_VALIDATION, and the
  # validation record cannot be written until the certificate exists, so a human breaks the
  # cycle in the middle.
  attaches_domain = local.creates_api && local.wants_domain && var.enable_custom_domain
}

resource "aws_apigatewayv2_api" "api" {
  count = local.creates_api ? 1 : 0

  name          = "${local.name}-api"
  description   = "Dun Mir operator console + agent ingest"
  protocol_type = "HTTP"

  # NO `cors_configuration` BLOCK, deliberately. The application does its own credentialed CORS
  # (`app/main.py` adds a CORSMiddleware that allow-lists the console origin and, critically,
  # sets `expose_headers` for the CSRF token). An HTTP API's own CORS handling INTERCEPTS
  # preflights and rewrites the CORS response headers, which would silently drop
  # `Access-Control-Expose-Headers` — and a hidden CSRF token means every cookie-mode mutation
  # 403s with nothing in the network tab looking wrong. Leaving it unset sends OPTIONS to the
  # function like any other method.

  # Closes the `*.execute-api.<region>.amazonaws.com` hostname once a custom domain is live, so
  # the custom domain is the only way in rather than merely the pretty way in. Off until then,
  # or phase 1 would create an API nothing can reach.
  disable_execute_api_endpoint = local.attaches_domain

  tags = { Name = "${local.name}-api" }
}

resource "aws_apigatewayv2_integration" "api" {
  count = local.creates_api ? 1 : 0

  api_id = aws_apigatewayv2_api.api[0].id

  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.api.invoke_arn
  integration_method = "POST"

  # 2.0 is the event shape Mangum's HTTPGateway handler parses (`event["version"] == "2.0"`),
  # and the one the local run exercises. 1.0 would still invoke the function and would still
  # be handled — by a different code path, with different header casing and a different
  # `sourceIp` location — so this is not a detail to leave to a default.
  payload_format_version = "2.0"

  # Matches the function's own timeout. API Gateway's ceiling is 30s and its default is 29s;
  # leaving them mismatched means the gateway gives up while the function goes on billing.
  timeout_milliseconds = var.lambda_timeout_seconds * 1000
}

# ONE route for everything. The application owns its URL space — the frozen `/v1/*` agent
# contract, Pro's `/api/*` reads, the SPA's deep links — and re-declaring any of it here would
# be a second routing table to keep in step, with a 404 from the gateway (which logs nothing
# useful) as the failure mode.
  # checkov:skip=CKV_AWS_309:No authorizer on the $default route. Authorization is done inside the Lambda function — the backend verifies Cognito JWTs against the JWKS passed in as configuration. Setting an authorizer here would add a second auth layer that duplicates work and cannot handle the function's own unauthenticated endpoints (health checks, invite acceptance).
resource "aws_apigatewayv2_route" "default" {
  count = local.creates_api ? 1 : 0

  api_id    = aws_apigatewayv2_api.api[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.api[0].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  count = local.creates_api ? 1 : 0

  api_id      = aws_apigatewayv2_api.api[0].id
  name        = "$default"
  auto_deploy = true

  # THE ONLY THING BOUNDING CONCURRENCY, and it is doing two jobs.
  #
  # Lambda's account default is 1000 concurrent executions. Each execution environment holds an
  # asyncpg pool, and a db.t4g.micro tops out near 112 connections — so unbounded concurrency
  # exhausts the DATABASE long before it exhausts Lambda, and the failure is 500s for everyone
  # rather than throttling for some. Throttling here is what keeps the two in proportion, and
  # it also caps the bill if the endpoint is ever scraped.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  # Access logs. Without these the edge is invisible: anything the gateway rejects before the
  # integration runs — a throttle, a payload over the limit, a bad path — produces no line in
  # the function's log group and no metric anyone watches, so "the console is broken" has no
  # first place to look.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api[0].arn
    format = jsonencode({
      requestId       = "$context.requestId"
      ip              = "$context.identity.sourceIp"
      requestTime     = "$context.requestTime"
      httpMethod      = "$context.httpMethod"
      routeKey        = "$context.routeKey"
      path            = "$context.path"
      status          = "$context.status"
      protocol        = "$context.protocol"
      responseLength  = "$context.responseLength"
      integrationErr  = "$context.integrationErrorMessage"
      integrationStat = "$context.integration.status"
      latency         = "$context.responseLatency"
    })
  }

  tags = { Name = "${local.name}-api" }
}

  # checkov:skip=CKV_AWS_158:No KMS CMK for the log group — same reasoning as the Lambda log group: a CMK bills per key per month and API Gateway access logs carry no secrets.
  # checkov:skip=CKV_AWS_338:Retention is set explicitly (var.log_retention_days); the one-year floor is a compliance requirement this home-lab product does not have.
resource "aws_cloudwatch_log_group" "api" {
  count = local.creates_api ? 1 : 0

  name              = "/aws/apigateway/${local.name}-api"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-api" }
}

# Lets THIS api, and only this api, invoke the function. `/*/*` is stage/route: one statement
# covers every route on every stage of this api and nothing else.
resource "aws_lambda_permission" "api_gateway" {
  count = local.creates_api ? 1 : 0

  statement_id  = "AllowInvokeFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api[0].execution_arn}/*/*"
}

# ── custom domain ───────────────────────────────────────────────────────────────────────────
#
# A REGIONAL certificate, in this region. No us-east-1 provider alias, which is one of the
# incidental simplifications of dropping CloudFront — that alias existed solely because
# CloudFront accepts certificates from nowhere else.

resource "aws_acm_certificate" "api" {
  count = local.creates_api && local.wants_domain && var.certificate_arn == "" ? 1 : 0

  domain_name       = var.api_domain_name
  validation_method = "DNS"

  lifecycle {
    # ACM cannot change a certificate's domain in place. Without this, editing `api_domain_name`
    # destroys the certificate the live custom domain is using before its replacement exists.
    create_before_destroy = true
  }

  tags = { Name = var.api_domain_name }
}

resource "aws_apigatewayv2_domain_name" "api" {
  count = local.attaches_domain ? 1 : 0

  # An EXPLICIT edge to the certificate, because the graph has none otherwise: the
  # ARN reaches this resource through `var.certificate_arn`, a string a human
  # pastes into the leaf, so Terraform cannot see that one depends on the other.
  # Destroys run leaf-first and in parallel, which means DeleteCertificate would
  # be issued while the domain still references it.
  depends_on = [aws_acm_certificate.api]

  domain_name = var.api_domain_name

  domain_name_configuration {
    certificate_arn = var.certificate_arn != "" ? var.certificate_arn : aws_acm_certificate.api[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = { Name = var.api_domain_name }
}

resource "aws_apigatewayv2_api_mapping" "api" {
  count = local.attaches_domain ? 1 : 0

  api_id      = aws_apigatewayv2_api.api[0].id
  domain_name = aws_apigatewayv2_domain_name.api[0].id
  stage       = aws_apigatewayv2_stage.default[0].id
}
