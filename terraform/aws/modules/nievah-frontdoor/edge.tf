# CloudFront, and what it is actually for.
#
# NOT caching — every request here is a signed POST that must reach the origin. It buys four
# things, all of them free:
#
#   1. A STABLE HOSTNAME with TLS. A Function URL's hostname contains a generated id and
#      changes if the function is ever recreated; GitHub App webhook URLs and Slack
#      interactivity URLs should not.
#   2. A PRIVATE ORIGIN. With origin access control the Function URL accepts only SigV4
#      requests signed by this distribution, so the guessable *.lambda-url.* hostname stops
#      being a second, unprotected front door. This is the reason authorization_type is
#      AWS_IAM in lambda.tf.
#   3. Shield Standard, automatically, against L3/L4 floods at the edge rather than at a
#      function that bills per invocation.
#   4. TLS termination and connection reuse close to GitHub, which takes a chunk out of the
#      handshake latency on the 3-second Slack budget.
#
# Free tier: 1 TB out, 10 million requests a month, permanently — against roughly 29,000
# requests and a few hundred megabytes here.
#
# NOT AVAILABLE IN LOCALSTACK. CloudFront is a paid LocalStack feature, so a local run talks
# to the Function URL directly with authorization_type NONE. What that does NOT exercise is
# precisely item 2 — the OAC signing. Treat "it worked locally" as saying nothing about
# whether the origin is private; the check for that is in aws/README.md and it is a curl.

data "aws_cloudfront_cache_policy" "disabled" {
  count = var.localstack ? 0 : 1
  name  = "Managed-CachingDisabled"
}

# Forwards every viewer header EXCEPT Host. That exception is load-bearing: SigV4 signs the
# Host header, so passing the viewer's Host through would sign the wrong hostname and the
# origin would reject every request with a 403.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = var.localstack ? 0 : 1
  name  = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "producer" {
  count = var.localstack ? 0 : 1

  name                              = "${var.name_prefix}-producer"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "producer" {
  count = var.localstack ? 0 : 1

  enabled         = true
  comment         = "${var.name_prefix} webhook front door"
  is_ipv6_enabled = true

  # US and Europe only. GitHub and Slack originate from a handful of well-known regions, and
  # a wider price class buys edge locations no caller of this distribution will ever use.
  price_class = "PriceClass_100"

  aliases = var.domain_name == "" ? [] : [var.domain_name]

  origin {
    origin_id = "producer"
    # The Function URL as a bare hostname — no scheme, no trailing slash, which is what
    # CloudFront wants and what the url attribute is not.
    domain_name              = replace(replace(aws_lambda_function_url.producer.function_url, "https://", ""), "/", "")
    origin_access_control_id = aws_cloudfront_origin_access_control.producer[0].id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "producer"
    viewer_protocol_policy = "https-only"

    # POST is the only method that matters; the rest are here because CloudFront requires
    # the read methods alongside the write ones in this set.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
    compress                 = false
  }

  restrictions {
    geo_restriction {
      # Deliberately none. A geo allowlist would have to enumerate every region GitHub and
      # Slack egress from, and a list that falls behind theirs drops deliveries silently —
      # which is the failure this whole stack exists to end.
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.domain_name == ""
    acm_certificate_arn            = var.domain_name == "" ? null : var.certificate_arn
    ssl_support_method             = var.domain_name == "" ? null : "sni-only"
    minimum_protocol_version       = var.domain_name == "" ? "TLSv1" : "TLSv1.2_2021"
  }
}

# The other half of origin access control. Without this the distribution signs its requests
# correctly and the function rejects them, because nothing has granted CloudFront the right
# to invoke the URL. Scoped to this one distribution by SourceArn.
resource "aws_lambda_permission" "cloudfront" {
  count = var.localstack ? 0 : 1

  statement_id           = "AllowCloudFront"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.producer.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.producer[0].arn
  function_url_auth_type = "AWS_IAM"
}
