# CloudFront in front of the Function URL, and the ACM certificate for the custom domain.
#
# WHY CLOUDFRONT AT ALL, ON A FREE-TIER STACK
#   Two reasons, and neither is caching.
#
#   1. A Function URL cannot have a custom domain. RouterOS agents dial out to a hostname baked
#      into their configuration, so `api.dunmir.magmamoose.com` is not cosmetic — it is what
#      makes the backend movable without touching every device in every fleet.
#   2. It is what makes the origin private. The Function URL is `AWS_IAM`-authorised, and
#      CloudFront's Origin Access Control signs each request with SigV4. Without the
#      distribution the URL would have to be `NONE`, i.e. open to anyone who learns the
#      hostname.
#
#   CloudFront's free tier is one of the ALWAYS-free ones: 1 TB out and 10M requests a month,
#   permanently. This costs nothing.
#
# WHY NOT CLOUDFLARE, GIVEN THE CONSOLE IS ALREADY THERE
#   Cloudflare could proxy `api.` to the Function URL just as well, but it could not make the
#   origin private: the `*.lambda-url.*.on.aws` hostname would still answer directly, so every
#   edge control would be one DNS lookup away from being bypassed. OAC is the reason this is
#   CloudFront.
#
# THE CACHE IS DISABLED, DELIBERATELY. Every path here is either an authenticated read or a
# mutation. `CachingDisabled` plus an origin request policy that forwards everything means the
# distribution is a signing proxy and nothing else — a cached `/api/session/me` would serve one
# operator's identity to the next.

locals {
  wants_domain         = var.api_domain_name != ""
  creates_distribution = !var.localstack

  # A certificate is requested as soon as a domain is named, but ATTACHED only once an ARN is
  # supplied — see the two-phase note on `api_domain_name`. A distribution cannot be created
  # with a certificate still in PENDING_VALIDATION, and the validation record cannot be created
  # until the certificate exists, so the cycle has to be broken by a human in the middle.
  attaches_certificate = local.wants_domain && var.certificate_arn != ""
}

# us-east-1, always. CloudFront accepts certificates from no other region, whatever region the
# rest of the stack is in — and the failure ("The specified SSL certificate doesn't exist, isn't
# in us-east-1…") arrives at apply time, after everything else is already built.
resource "aws_acm_certificate" "api" {
  count    = local.creates_distribution && local.wants_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.api_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.api_domain_name }
}

resource "aws_cloudfront_origin_access_control" "api" {
  count = local.creates_distribution ? 1 : 0

  name                              = "${local.name}-api"
  description                       = "SigV4-signs CloudFront's requests to the Lambda Function URL"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "api" {
  count = local.creates_distribution ? 1 : 0

  enabled = true
  comment = "${local.name} API"
  # IPv6 costs nothing and a growing share of mobile networks are v6-only.
  is_ipv6_enabled = true
  # PriceClass_100 (North America + Europe) rather than All. The free 1 TB is global, but the
  # per-GB rate past it is far higher in South America and Asia-Pacific, and every operator and
  # every device this serves is in Europe.
  price_class = "PriceClass_100"

  aliases = local.attaches_certificate ? [var.api_domain_name] : []

  origin {
    # The Function URL, as a hostname. `regex` rather than `replace` on "https://" so a change
    # in the attribute's shape fails loudly instead of silently producing a malformed origin.
    domain_name              = regex("^https://([^/]+)/?$", aws_lambda_function_url.api.function_url)[0]
    origin_id                = "lambda"
    origin_access_control_id = aws_cloudfront_origin_access_control.api[0].id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      # 30s, matching the function's own timeout. Longer and CloudFront waits on a function that
      # has already given up; shorter and a slow-but-succeeding request is cut off at the edge
      # while the function goes on billing.
      origin_read_timeout = var.lambda_timeout_seconds
    }
  }

  default_cache_behavior {
    target_origin_id       = "lambda"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS-managed `CachingDisabled`. Every path is authenticated or a mutation; a cached
    # response here would serve one operator's data to another.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # AWS-managed `AllViewerExceptHostHeader`. Forwards every header, cookie and query string —
    # which the API needs, because `Authorization`, `X-CSRF-Token` and `Origin` all carry
    # meaning — while replacing `Host` with the origin's own.
    #
    # THE HOST HEADER IS NOT OPTIONAL. SigV4 signs it, so forwarding the viewer's `Host` makes
    # every signature invalid and every request a 403. This exact policy exists because that is
    # the mistake everyone makes with OAC in front of a Function URL.
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # Falls back to the default `*.cloudfront.net` certificate during phase 1, so the stack is
    # deployable and testable before DNS validation has completed.
    cloudfront_default_certificate = local.attaches_certificate ? null : true
    acm_certificate_arn            = local.attaches_certificate ? var.certificate_arn : null
    ssl_support_method             = local.attaches_certificate ? "sni-only" : null
    minimum_protocol_version       = local.attaches_certificate ? "TLSv1.2_2021" : null
  }

  tags = { Name = "${local.name}-api" }
}
