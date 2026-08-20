# The front door: an API Gateway HTTP API.
#
# WHY NOT A BARE LAMBDA FUNCTION URL, which is free where this is not. A Function URL has NO
# throttle. The stage throttle below is what deterministically caps invocations, compute, logs
# and egress at every load; without it the only bound is the account's Lambda concurrency quota,
# and Lambda's own limit of 10 requests/second per concurrent execution puts the ceiling at
# ~100 rps — around $6/day of Lambda and logs, indefinitely, with nothing to stop it.
#
# The nievah front door also records, in this same organization, that a Function URL behind a
# CDN with origin access control returned InvalidSignatureException on every POST while
# `GET /healthz` stayed green — because CloudFront signs the request but does not hash the body,
# and Lambda does not accept unsigned payloads. This service cannot afford that class of failure:
# its client fails soft, so a broken POST path is silent.
#
# An HTTP API is the purpose-built answer: POST is native, throttling lives at the door rather
# than at the wallet, and a custom domain needs a REGIONAL ACM certificate rather than one in
# us-east-1. It is the one component here that is not always-free — and note that this account
# has NO 12-month allowance at all, because free-tier eligibility dates from the ORGANIZATION's
# management account, so gateway requests are billed from the first one at $1.00/million. At a
# few hundred requests a month that is fractions of a cent.

resource "aws_apigatewayv2_api" "broker" {
  name          = "${var.name_prefix}-front-door"
  protocol_type = "HTTP"
  description   = "GitHub Actions OIDC -> Diatreme[bot] installation token"

  # Turning this off makes the custom domain the only way in, which is what gives the Cloudflare
  # proxy any meaning at all — see the variable's own note. False on the first apply so there is
  # something to smoke-test before DNS exists.
  disable_execute_api_endpoint = var.disable_default_endpoint

  # No CORS block. Nothing browser-based calls this; it is a GitHub Actions runner talking to a
  # token minter.
}

# A $default route rather than one per path, because `app/lambda_handler.py` already routes on
# `rawPath` and duplicating that table here would create two lists that must agree forever.
#
# Payload format 2.0 specifically: that is what the handler parses (rawPath, lowercased headers,
# body, isBase64Encoded, requestContext.http.method), and it is byte-identical to what a Function
# URL delivers, so a local harness can exercise the same handler with no gateway in front.
resource "aws_apigatewayv2_integration" "broker" {
  api_id                 = aws_apigatewayv2_api.broker.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.broker.invoke_arn
  payload_format_version = "2.0"

  # Above the function's own timeout, so the FUNCTION's error surfaces rather than the gateway's.
  timeout_milliseconds = 20000
}

resource "aws_apigatewayv2_route" "broker" {
  # checkov:skip=CKV_AWS_309:Authorization is handled by the Lambda handler (OIDC JWT validation); no gateway-level authorizer needed for this design
  api_id    = aws_apigatewayv2_api.broker.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.broker.id}"
}

# The $default stage, so `rawPath` is the real path with no stage prefix to strip. A named stage
# would put `/prod` in front of every route and the handler would 404 its own endpoints.
# trivy:ignore:AVD-AWS-0001
resource "aws_apigatewayv2_stage" "broker" {
  # checkov:skip=CKV_AWS_76:Lambda already emits structured request logs; gateway access logs would duplicate that against a shared org-wide 5 GB CloudWatch allowance
  api_id      = aws_apigatewayv2_api.broker.id
  name        = "$default"
  auto_deploy = true

  # THE DETERMINISTIC HALF OF THE COST CEILING. Requests over the limit are rejected by the
  # gateway with 429 and never reach Lambda, so an abusive burst costs gateway requests rather
  # than gateway requests AND invocations.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  # No access_log_settings. The function already emits a structured line per request into its own
  # log group with a 14-day retention; gateway access logs would double the volume against a 5 GB
  # allowance that is shared organization-wide, to restate what is already there.
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.broker.function_name
  principal     = "apigateway.amazonaws.com"
  # Scoped to this API. `/*/*` is stage/route — the API id is what actually bounds it.
  source_arn = "${aws_apigatewayv2_api.broker.execution_arn}/*/*"
}

# --- custom domain (optional, two-phase) ----------------------------------------------------
#
# REGIONAL certificate, in this region — no us-east-1 provider alias needed.
#
# TWO-PHASE ON PURPOSE, because DNS validation lives in a different Terraform state
# (terraform/cloudflare/dns-magmamoose/prod — a Cloudflare zone is a hard provider boundary).
# A single apply cannot create the certificate, write its validation record into another leaf's
# zone, and wait for issuance. So:
#
#   1. set `domain_name`, leave `enable_custom_domain` false -> the certificate is requested and
#      `certificate_validation_record` names the CNAME to add
#   2. add that CNAME to the Cloudflare leaf, GREY CLOUD, and apply; ACM issues within minutes.
#      A proxied validation record answers with Cloudflare's own value, ACM never sees the token,
#      and the certificate sits in PENDING_VALIDATION forever.
#   3. set `enable_custom_domain` and `disable_default_endpoint` true -> domain + mapping created
#      and the execute-api door closed in one apply
#   4. CNAME the hostname at `custom_domain_target` from the Cloudflare leaf — PROXIED this time
#
# Public ACM certificates are free, and an API Gateway custom domain carries no charge, so none
# of this moves the bill.
resource "aws_acm_certificate" "broker" {
  count = var.domain_name == "" || var.certificate_arn != "" ? 0 : 1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    # ACM cannot change a certificate's domain in place. Without this, editing `domain_name`
    # destroys the certificate the live custom domain is using before the replacement exists.
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_domain_name" "broker" {
  count = var.domain_name == "" || !var.enable_custom_domain ? 0 : 1

  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = var.certificate_arn != "" ? var.certificate_arn : aws_acm_certificate.broker[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "broker" {
  count = var.domain_name == "" || !var.enable_custom_domain ? 0 : 1

  api_id      = aws_apigatewayv2_api.broker.id
  domain_name = aws_apigatewayv2_domain_name.broker[0].id
  stage       = aws_apigatewayv2_stage.broker.id
}

# --- additional hostnames (the migration window) ---------------------------------------------
#
# Ported from modules/chargate-broker (magmamoose/infra#657), which learned this the hard way.
#
# Deliberately SEPARATE resources rather than folding `domain_name` and these into one
# `for_each`. Doing that would change the primary domain's resource address from `[0]` to
# `["broker-diatreme.magmamoose.com"]`, and Terraform reads a changed address as destroy-and-
# recreate — taking the live custom domain, and therefore the `d-*` target the Cloudflare record
# points at, down with it. Additive is worth a little duplication here.
resource "aws_acm_certificate" "additional" {
  for_each = toset(var.additional_domain_names)

  domain_name       = each.value
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_domain_name" "additional" {
  for_each = var.enable_custom_domain ? toset(var.additional_domain_names) : toset([])

  domain_name = each.value

  domain_name_configuration {
    certificate_arn = aws_acm_certificate.additional[each.value].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "additional" {
  for_each = var.enable_custom_domain ? toset(var.additional_domain_names) : toset([])

  api_id      = aws_apigatewayv2_api.broker.id
  domain_name = aws_apigatewayv2_domain_name.additional[each.value].id
  stage       = aws_apigatewayv2_stage.broker.id
}
