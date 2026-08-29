# The Cognito user pool that owns operator credentials.
#
# WHAT COGNITO OWNS, AND WHAT IT DOES NOT
#   It owns the password, the TOTP factor, account confirmation and the emails that carry a
#   confirmation or reset code. It does NOT own the product's identity model: tenants,
#   memberships, roles and the audit trail all hang off a local `users` row keyed on the token's
#   immutable `sub` (dunmir migration 0017). Cognito is the credential store; the database is
#   still the system of record.
#
# NO HOSTED UI, NO APP-CLIENT SECRET, NO DOMAIN
#   The console drives the pool directly from the browser through the unauthenticated
#   `cognito-idp` operations — `SignUp`, `InitiateAuth`, `AssociateSoftwareToken`,
#   `ForgotPassword` — so the sign-in screens stay MagmaMoose's rather than Amazon's. That flow
#   needs no OAuth domain and no client secret. `generate_secret = false` is load-bearing: a
#   public SPA client with a secret cannot authenticate at all, because the secret would have to
#   be in the bundle, and Cognito requires a SECRET_HASH on every call once one exists.
#
# COST: 10,000 monthly active users, free, permanently. Not one of the twelve-month allowances.

locals {
  creates_pool = !var.localstack

  # ONE shape for the pool, whether this module created it or `seed.sh` did. Everything
  # downstream (the function's environment, the outputs) reads this and never branches again —
  # so the local stack and the real one differ in exactly one place instead of in five.
  # Computed WITHOUT reference to `local.cognito`, because the JWKS data source below reads it
  # and `local.cognito` reads the data source — routing the URL through the merged object would
  # be a dependency cycle Terraform refuses to plan.
  created_pool_issuer = local.creates_pool ? format(
    "https://cognito-idp.%s.amazonaws.com/%s", var.region, aws_cognito_user_pool.this[0].id
  ) : ""

  cognito = local.creates_pool ? {
    user_pool_id = aws_cognito_user_pool.this[0].id
    client_id    = aws_cognito_user_pool_client.console[0].id
    issuer       = local.created_pool_issuer
    endpoint     = "https://cognito-idp.${var.region}.amazonaws.com"
    jwks         = data.http.cognito_jwks[0].response_body
    } : coalesce(var.cognito_override, {
      user_pool_id = ""
      client_id    = ""
      issuer       = ""
      endpoint     = ""
      jwks         = ""
  })

  cognito_issuer = local.cognito.issuer
}

resource "aws_cognito_user_pool" "this" {
  count = local.creates_pool ? 1 : 0

  name = local.name

  # The address IS the username. The product has always identified operators by email, invites
  # are raised against a mailbox, and the audit trail records an address — a separate username
  # would be a second identifier with no meaning to anyone.
  username_attributes = ["email"]
  # Case-insensitive, matching `app.auth.normalise_email`, which lower-cases every address on
  # the way in. Without this, `Alice@` and `alice@` are two Cognito accounts resolving to one
  # local row, and the second one to arrive is refused with a confusing collision.
  username_configuration {
    case_sensitive = false
  }

  # Cognito verifies the address itself, by emailing a code. This is what removes SES — and
  # therefore the need for any egress from the function — from the sign-up path entirely.
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length = var.cognito_password_minimum_length
    # Length is the whole policy. Forced classes buy little entropy and reliably produce
    # `Password1!`; this matches the first-party stack's rule and the copy on the sign-up
    # screen, so the two modes cannot tell an operator different things.
    require_lowercase                = false
    require_uppercase                = false
    require_numbers                  = false
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  mfa_configuration = var.cognito_mfa
  # TOTP only. SMS costs money per message, needs an IAM role for SNS, and is the weakest second
  # factor on offer — the product has never used it.
  dynamic "software_token_mfa_configuration" {
    for_each = var.cognito_mfa == "OFF" ? [] : [1]
    content {
      enabled = true
    }
  }

  # AN ADDRESS CANNOT BE CHANGED WITHOUT RE-PROVING IT. Cognito's default lets a
  # signed-in user rewrite their own `email` attribute, and the new value appears
  # in the very next ID token with `email_verified: false`.
  #
  # That matters here more than it usually would, because the invitation flow
  # treats "the token's address equals the invited mailbox" as proof of mailbox
  # control (app/routers/session.py `_accept_invite_cognito`). Without this, an
  # attacker who obtained an invite link — a forwarded mail, a pasted URL — could
  # sign up as anyone, rewrite their address to the invited one, and redeem it.
  #
  # The backend refuses an unverified address as well (app/cognito.py). Belt and
  # braces on purpose: this one is a policy somebody can relax in a console, that
  # one is code.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: 50 emails a day, free, no SES verification and no domain to
  # authenticate. That is enough for onboarding and comfortably enough for password resets on a
  # console with tens of operators. Moving to SES is a `email_sending_account = "DEVELOPER"`
  # block here plus a verified identity — and would NOT need function egress, since Cognito
  # sends the mail, not us.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    # CODE, not LINK. A link would have to land on a Cognito-hosted page; a code is typed into
    # our own screen, which is what keeps the flow inside the console.
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your Dun Mir confirmation code"
    email_message        = "Your Dun Mir confirmation code is {####}. It expires in 24 hours."
  }

  # Protects against a `terraform destroy` taking every operator's credential with it. Unlike
  # the database there is no snapshot to restore from: deleting a pool is final, and everyone
  # would have to sign up again — losing, along the way, the `sub` that their local user row and
  # therefore their workspace membership is keyed on.
  deletion_protection = "ACTIVE"

  tags = { Name = local.name }
}

resource "aws_cognito_user_pool_client" "console" {
  count = local.creates_pool ? 1 : 0

  name         = "${local.name}-console"
  user_pool_id = aws_cognito_user_pool.this[0].id

  # A PUBLIC client. See the module header: a secret here cannot be kept in a browser bundle,
  # and its mere existence makes every unauthenticated call require a SECRET_HASH the SPA has no
  # way to compute.
  generate_secret = false

  explicit_auth_flows = [
    # The browser sends the password to Cognito over TLS. SRP would prove knowledge without
    # sending it, and is not worth ~300 lines of hand-written bignum arithmetic in a path where
    # a subtle error fails OPEN. The password reaches the same party either way.
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Tokens: an hour of access, thirty days of refresh. The console holds the refresh token and
  # exchanges it, so the operator signs in about monthly rather than hourly.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Turn OFF Cognito's default of answering "no such user" distinctly. Left enabled, the sign-in
  # form becomes an account-existence oracle — precisely the leak the first-party endpoints go
  # to some trouble to avoid, re-introduced by a default.
  prevent_user_existence_errors = "ENABLED"

  # The console needs to read and update the operator's own email; it has no business writing
  # anything else, and an attribute it cannot write is an attribute a compromised bundle cannot
  # forge.
  read_attributes  = ["email", "email_verified"]
  write_attributes = ["email"]

  # Revoking a refresh token is what makes "sign out everywhere" true rather than decorative —
  # the console calls GlobalSignOut, and without this the token stays valid until it expires.
  enable_token_revocation = true
}

# The pool's public signing keys, read ONCE at apply time and passed to the function as
# configuration.
#
# THIS IS THE LOAD-BEARING TRICK OF THE WHOLE TOPOLOGY. Verifying a Cognito JWT needs the pool's
# JWKS. Fetching it at runtime would mean the function needs a route to the internet, which
# means a NAT gateway (~$32/month) or an interface endpoint (~$7.30/month) — and there is no VPC
# endpoint for `cognito-idp` at all, so the interface option does not even exist. Reading the
# keys here instead makes token verification a pure local computation and the VPC genuinely
# closed.
#
# The keys are RSA public keys: public by definition, safe in state, safe in an environment
# variable. Cognito publishes two per pool and does not rotate them — a pool that is recreated
# gets new ones, and recreating the pool already changes the issuer, so this is re-read on the
# same apply that would have broken verification anyway.
data "http" "cognito_jwks" {
  count = local.creates_pool ? 1 : 0

  url = "${local.created_pool_issuer}/.well-known/jwks.json"

  # Fail the apply rather than shipping an empty JWKS. A function configured with no keys
  # rejects every token, which presents as "nobody can sign in" with a perfectly healthy stack.
  lifecycle {
    postcondition {
      condition     = can(jsondecode(self.response_body).keys[0].kid)
      error_message = "Cognito JWKS did not parse; the function would reject every token."
    }
  }
}
