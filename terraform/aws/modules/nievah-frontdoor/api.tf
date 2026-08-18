# The front door: an API Gateway HTTP API.
#
# WHY NOT CLOUDFRONT + A LAMBDA FUNCTION URL, which is what this was first built as and
# deployed to a live account before the flaw showed. Origin access control makes a Function
# URL private by having CloudFront sign each request with SigV4 — and from the AWS docs for
# that exact setup, in an Important callout:
#
#     "If you use PUT or POST methods with your Lambda function URL, your users must compute
#      the SHA256 of the body and include the payload hash value of the request body in the
#      x-amz-content-sha256 header when sending the request to CloudFront. Lambda doesn't
#      support unsigned payloads."
#
# "Your users" are GitHub and Slack. They will never send that header. CloudFront signs the
# request but does not hash the body itself, so every POST came back 403
# InvalidSignatureException — while `GET /healthz` returned 200 throughout, which is exactly
# how it hid from the health check written to catch it.
#
# The alternative was to drop OAC and leave the Function URL public. That is free and safe —
# every delivery is HMAC-verified regardless of the hostname it arrives on — but it leaves a
# guessable second entrance whose only cost control is the Lambda free tier.
#
# An HTTP API is the purpose-built answer instead: POST is native, throttling lives at the
# door rather than at the wallet, and a custom domain needs a REGIONAL ACM certificate rather
# than one in us-east-1. It is the one component here that is not always-free — $1.00 per
# million requests after a 12-month allowance, so about $0.03/month at this volume — and
# `aws_budgets_budget.guard` below makes that a monitored number rather than a hope.
#
# NO CLOUDFRONT AT ALL NOW. Its remaining value would have been a stable hostname and edge
# TLS; the execute-api hostname is equally stable, Shield Standard covers AWS public endpoints
# either way, and a transatlantic handshake is a small fraction of Slack's 3-second budget.
# One less layer, and the layer removed is the one that just failed.

resource "aws_apigatewayv2_api" "producer" {
  count = var.localstack ? 0 : 1

  name          = "${var.name_prefix}-front-door"
  protocol_type = "HTTP"
  description   = "GitHub webhooks and Slack interactions for Nievah"

  # No CORS block. Nothing browser-based calls this; GitHub and Slack are server-to-server.
}

# A $default route rather than one per path, because the producer already routes on `rawPath`
# and duplicating that table here would create two lists that must agree forever — the same
# drift argument that keeps event filtering out of the edge entirely.
#
# The payload format matters: 2.0 is byte-for-byte the shape a Lambda function URL delivers
# (rawPath, lowercased headers, body, isBase64Encoded, requestContext.http.method), so the
# handler needs no changes and the LocalStack harness — which still uses a Function URL,
# because API Gateway is a paid LocalStack feature — exercises the identical code path.
resource "aws_apigatewayv2_integration" "producer" {
  count = var.localstack ? 0 : 1

  api_id                 = aws_apigatewayv2_api.producer[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.producer.invoke_arn
  payload_format_version = "2.0"

  # Comfortably inside GitHub's 10s and Slack's 3s, and above the function's own 5s timeout so
  # the function's error surfaces rather than the gateway's.
  timeout_milliseconds = 10000
}

resource "aws_apigatewayv2_route" "producer" {
  count = var.localstack ? 0 : 1

  api_id    = aws_apigatewayv2_api.producer[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.producer[0].id}"
}

# The $default stage, so `rawPath` is the real path with no stage prefix to strip. A named
# stage would put `/prod` in front of every route and the producer would 404 its own endpoints.
resource "aws_apigatewayv2_stage" "producer" {
  count = var.localstack ? 0 : 1

  api_id      = aws_apigatewayv2_api.producer[0].id
  name        = "$default"
  auto_deploy = true

  # THE COST CEILING, and the main reason this design is calmer than a bare Function URL.
  # Real traffic is roughly one request a minute; these bound a runaway to something a budget
  # alarm can catch long before it matters. Requests over the limit are rejected by the
  # gateway with a 429 and never reach Lambda — so an abusive burst costs gateway requests
  # rather than gateway requests AND invocations.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  # No access_log_settings. Every decision the producer makes is already one JSON line in its
  # own log group with a 14-day retention; gateway access logs would double the log volume
  # against a 5 GB free allowance to restate what is already there.
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
  count = var.localstack || var.domain_name == "" ? 0 : 1

  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = var.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "producer" {
  count = var.localstack || var.domain_name == "" ? 0 : 1

  api_id      = aws_apigatewayv2_api.producer[0].id
  domain_name = aws_apigatewayv2_domain_name.producer[0].id
  stage       = aws_apigatewayv2_stage.producer[0].id
}
