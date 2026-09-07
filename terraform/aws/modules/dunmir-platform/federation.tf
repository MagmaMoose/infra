# Federated sign-in: the pool's OAuth domain, the social providers, and the IAM
# that lets the console create a customer's own identity provider.
#
# WHY ANY OF THIS EXISTS WHEN identity.tf SAYS "NO HOSTED UI, NO DOMAIN"
#   That comment is still true of the PASSWORD flow and it should stay: sign-up,
#   sign-in, TOTP enrolment and reset are driven from our own screens against the
#   unauthenticated `cognito-idp` API, which needs no domain and no client secret.
#
#   Federation cannot work that way, and no configuration makes it. A SAML
#   assertion is POSTed by the customer's identity provider to Cognito's
#   `/saml2/idpresponse`; an OIDC authorization code is exchanged at Cognito's
#   `/oauth2/token`. Both endpoints exist only on a user pool domain, so
#   federated sign-in is an authorization-code redirect through one. There is no
#   version of this that keeps the browser on our origin.
#
#   What we do keep is the SCREEN. The console passes `identity_provider=` on the
#   authorize request, which makes Cognito 302 straight through to the provider
#   rather than rendering its own sign-in page — so an operator goes from our
#   screen to Google, or to their employer's IdP, and back. The Amazon hostname
#   is visible for the length of one redirect and never paints a page.
#
# THE PREFIX DOMAIN, NOT A CUSTOM ONE
#   A Cognito custom domain needs an ACM certificate in **us-east-1** (not the
#   pool's region), an A record at the parent domain, and — for a name two labels
#   deep under magmamoose.com — its own Cloudflare certificate pack. Four moving
#   parts, each with its own propagation delay, for a hostname nobody reads.
#   `dunmir-prod.auth.eu-west-1.amazoncognito.com` is free, instant, and needs no
#   DNS at all. Moving to a custom domain later changes this resource,
#   `COGNITO_DOMAIN` on the backend, and the console's CSP — and nothing else.
#
# APPLYING THIS IS TWO PHASES, like the certificate already is
#   The provider credentials are SSM parameters created here with a placeholder
#   and `ignore_changes = [value]`, exactly as `sweep_http.tf` does for the admin
#   token: Terraform makes the box, a human puts the secret in, and the value
#   never reaches a plan file or a pull request. So:
#
#     1. apply with every `enable_*` false. The domain and the parameters exist.
#     2. `aws ssm put-parameter --overwrite` the real client ids and secrets.
#     3. flip the `enable_*` flags and apply again.
#
#   Creating a provider from a placeholder secret would succeed at AWS and fail
#   at Google, which is the failure this ordering exists to avoid.

locals {
  federates = local.creates_pool && var.cognito_domain_prefix != ""

  # Where Cognito sends the browser back. MUST MATCH the console's route and the
  # backend's COGNITO_REDIRECT_URI byte for byte — Cognito compares the string,
  # and a trailing slash or an http/https difference answers `redirect_mismatch`
  # on its OWN error page, which never reaches the SPA and therefore never
  # reaches a log anybody reads.
  console_callback = "${trimsuffix(var.frontend_origin, "/")}/auth/callback"
  console_logout   = "${trimsuffix(var.frontend_origin, "/")}/login"

  # The providers actually created below, by the name that travels in the
  # browser's `identity_provider=` parameter. Fed to the app client and echoed in
  # an output, so `COGNITO_SOCIAL_PROVIDERS` on the backend can be copied from a
  # command rather than remembered.
  social_providers = compact([
    var.enable_google_signin ? "Google" : "",
    var.enable_microsoft_signin ? "Microsoft" : "",
    var.enable_amazon_signin ? "LoginWithAmazon" : "",
    var.enable_apple_signin ? "SignInWithApple" : "",
  ])
}

# --------------------------------------------------------------------------- #
# The domain
# --------------------------------------------------------------------------- #
resource "aws_cognito_user_pool_domain" "this" {
  count = local.federates ? 1 : 0

  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.this[0].id
}

# --------------------------------------------------------------------------- #
# Provider credentials, as parameters a human fills in
# --------------------------------------------------------------------------- #
locals {
  # One parameter per value, rather than one JSON blob, so a rotation touches the
  # thing that rotated. `aws ssm put-parameter --name <name> --value … --overwrite`
  # is the whole procedure and it appears in the outputs.
  provider_secrets = local.federates ? {
    google_client_id        = "Google OAuth client ID"
    google_client_secret    = "Google OAuth client secret"
    microsoft_client_id     = "Microsoft (Entra) application (client) ID"
    microsoft_client_secret = "Microsoft (Entra) client secret"
    amazon_client_id        = "Login with Amazon client ID"
    amazon_client_secret    = "Login with Amazon client secret"
    apple_client_id         = "Apple Services ID"
    apple_team_id           = "Apple Developer team ID"
    apple_key_id            = "Apple Sign in with Apple key ID"
    apple_private_key       = "Apple .p8 private key, PEM"
  } : {}
}

resource "aws_ssm_parameter" "federation" {
  # checkov:skip=CKV_AWS_337:No KMS CMK on these parameters. SecureString already encrypts with the AWS-managed key; a CMK bills per key per month and defends against a threat (someone with ssm:GetParameter but not kms:Decrypt) that does not exist here — the only principal that reads them is this Terraform run.
  for_each = local.provider_secrets

  name        = "/${local.name}/federation/${replace(each.key, "_", "-")}"
  description = each.value
  type        = "SecureString"
  # A PLACEHOLDER, and the `enable_*` flags default to false so nothing is ever
  # built from it. Same discipline as `sweep_http.tf`'s admin token: the box is
  # Terraform's, the secret is not.
  value = "PLACEHOLDER-set-me-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_ssm_parameter" "federation" {
  for_each = local.provider_secrets

  name = aws_ssm_parameter.federation[each.key].name
}

# --------------------------------------------------------------------------- #
# The built-in providers
# --------------------------------------------------------------------------- #
#
# ATTRIBUTE MAPPING IS THE PART THAT SILENTLY DOES NOT WORK. Cognito maps a claim
# onto a user pool attribute only when the mapping names it AND the incoming token
# carries it. `email` is present for all three below. `email_verified` is NOT: it
# is in Google's ID token, absent from Microsoft's entirely, and absent from
# Amazon's. So it is mapped where it exists and simply not mentioned where it does
# not — and the BACKEND does not require it for a federated subject, because a
# rule that demanded it would refuse every Microsoft user while working perfectly
# for Google, with nothing on screen to say why. See `backend/app/sso.py`.

resource "aws_cognito_identity_provider" "google" {
  count = local.federates && var.enable_google_signin ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this[0].id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = data.aws_ssm_parameter.federation["google_client_id"].value
    client_secret    = data.aws_ssm_parameter.federation["google_client_secret"].value
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    username       = "sub"
  }
}

# MICROSOFT IS NOT ONE OF COGNITO'S BUILT-INS. Cognito ships Google, Facebook,
# Amazon and Apple; Microsoft accounts are reached as a generic OIDC provider.
# Pointed at the `consumers` authority, which is personal Microsoft accounts —
# a customer's *workforce* Entra tenant is their own SAML or OIDC connection,
# created from the console, and must not be conflated with this.
#
# The provider is named "Microsoft" because that string travels in the browser's
# `identity_provider=` parameter and is what the backend's known-provider list
# contains. Renaming it here breaks the button and nothing says so.
resource "aws_cognito_identity_provider" "microsoft" {
  count = local.federates && var.enable_microsoft_signin ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this[0].id
  provider_name = "Microsoft"
  provider_type = "OIDC"

  provider_details = {
    client_id     = data.aws_ssm_parameter.federation["microsoft_client_id"].value
    client_secret = data.aws_ssm_parameter.federation["microsoft_client_secret"].value
    oidc_issuer   = "https://login.microsoftonline.com/consumers/v2.0"
    # Cognito reads /.well-known/openid-configuration from the issuer and fills
    # in the four endpoints itself. Naming them explicitly is four more values to
    # get wrong and four more that go stale when Microsoft moves one.
    authorize_scopes = "openid email profile"
    # GET, because that is what Microsoft's userinfo endpoint serves. POST is
    # refused, and the refusal surfaces as a federated user with no email claim —
    # which the backend then declines to provision, correctly and confusingly.
    attributes_request_method = "GET"
  }

  # NO `email_verified`. Microsoft's tokens do not carry one, so a mapping here
  # would name a claim that never arrives and Cognito would leave the attribute
  # false forever.
  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}

resource "aws_cognito_identity_provider" "amazon" {
  count = local.federates && var.enable_amazon_signin ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this[0].id
  provider_name = "LoginWithAmazon"
  provider_type = "LoginWithAmazon"

  provider_details = {
    client_id        = data.aws_ssm_parameter.federation["amazon_client_id"].value
    client_secret    = data.aws_ssm_parameter.federation["amazon_client_secret"].value
    authorize_scopes = "profile"
  }

  attribute_mapping = {
    email    = "email"
    username = "user_id"
  }
}

# SIGN IN WITH APPLE NEEDS A PAID APPLE DEVELOPER ACCOUNT — a Services ID, a team
# ID and a .p8 signing key, none of which exist without the $99/year membership.
# The resource is written so enabling it later is a flag and three parameters
# rather than a design exercise, and it is off.
#
# One thing to know before turning it on: Apple's private relay gives a user an
# `@privaterelay.appleid.com` address. That address can never match a workspace's
# verified domain, so an Apple sign-in will always found a personal workspace and
# never join a company one. That is a product decision, not a bug, and it should
# be made deliberately rather than discovered.
resource "aws_cognito_identity_provider" "apple" {
  count = local.federates && var.enable_apple_signin ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this[0].id
  provider_name = "SignInWithApple"
  provider_type = "SignInWithApple"

  provider_details = {
    client_id        = data.aws_ssm_parameter.federation["apple_client_id"].value
    team_id          = data.aws_ssm_parameter.federation["apple_team_id"].value
    key_id           = data.aws_ssm_parameter.federation["apple_key_id"].value
    private_key      = data.aws_ssm_parameter.federation["apple_private_key"].value
    authorize_scopes = "email name"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}

# --------------------------------------------------------------------------- #
# IAM for the console's own provider management
# --------------------------------------------------------------------------- #
#
# WHY AN IAM USER AND NOT A ROLE. The application that makes these calls runs on
# the OCI Amsterdam cluster, which has no AWS identity to assume. A role would
# need an OIDC identity provider trusting that cluster's service-account issuer,
# which means exposing the cluster's JWKS publicly and maintaining a trust policy
# for a cluster that is not AWS's. An access key for a user whose entire
# permission set is the four calls below is the smaller thing.
#
# **NO ACCESS KEY IS CREATED HERE, DELIBERATELY.** `aws_iam_access_key` would put
# the secret in the state file, which is the one place it must not be. Create it
# by hand and put it straight into OCI Vault:
#
#     aws iam create-access-key --user-name <the sso_manager_user_name output>
#
# The Lambda topology does not need any of this: `SSO_MANAGEMENT_ENABLED` is off
# there because a function in a VPC with no NAT gateway cannot reach cognito-idp
# at all. That is a property of that topology, not of the feature.
resource "aws_iam_user" "sso_manager" {
  count = local.federates && var.create_sso_manager_user ? 1 : 0

  name = "${local.name}-sso-manager"
  tags = { Name = "${local.name}-sso-manager" }
}

resource "aws_iam_user_policy" "sso_manager" {
  count = local.federates && var.create_sso_manager_user ? 1 : 0

  name = "${local.name}-sso-manager"
  user = aws_iam_user.sso_manager[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SCOPED TO THIS POOL BY ARN. The identity-provider calls take a pool id
        # in the request and AWS authorises them against the pool's ARN, so a
        # policy naming `*` here would let this credential add an identity
        # provider to every pool in the account — including one that fronts
        # something else.
        Sid    = "ManageThisPoolsIdentityProviders"
        Effect = "Allow"
        Action = [
          "cognito-idp:CreateIdentityProvider",
          "cognito-idp:UpdateIdentityProvider",
          "cognito-idp:DeleteIdentityProvider",
          "cognito-idp:DescribeIdentityProvider",
          "cognito-idp:ListIdentityProviders",
          # The app client has to LIST the provider before it may be used in an
          # authorize request, and Cognito's update is a full replace — so the
          # describe is not optional, it is what stops the update blanking the
          # callback URLs and the token lifetimes.
          "cognito-idp:DescribeUserPoolClient",
          "cognito-idp:UpdateUserPoolClient",
        ]
        Resource = aws_cognito_user_pool.this[0].arn
      },
    ]
  })
}
