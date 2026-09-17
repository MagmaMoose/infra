# Google sign-in for somebody who already has a password account: link, don't duplicate.
#
# WHAT GOES WRONG WITHOUT THIS
#   Cognito's default for a first Google sign-in is to create a NEW federated user
#   (`google_<sub>`), even when a confirmed password account already holds the same address.
#   That user has a different `sub`, the backend keys its `users` row on `sub`, and the address
#   is UNIQUE there, so the backend refuses it: the operator who clicks "Continue with Google"
#   with an existing account cannot sign in at all.
#
# WHAT THIS DOES
#   A pre sign-up trigger. For a Google sign-in whose address belongs to exactly one confirmed,
#   enabled password account with a verified address, it calls AdminLinkProviderForUser, so
#   Google signs in AS that account: same `sub`, same local row, same workspace. The password
#   and its TOTP factor keep working.
#
# ONLY WHERE GOOGLE OWNS THE ADDRESS
#   Linking hands an existing account to a Google login, so it happens only when Google is the
#   authority for the mailbox, which is Google's own rule for account linking: a Gmail address,
#   or a Google Workspace account whose `hd` claim is the address's domain. A personal Google
#   account registered on a company address proves somebody could read that mailbox once; it
#   does not get the account, and falls through to Cognito's default, which the application
#   still refuses to adopt.
#
#   `hd` reaches the trigger only through the attribute mapping on the Google provider
#   (federation.tf) into `custom:google_hd`, declared on the pool in identity.tf.

locals {
  links_google_accounts = local.federates && var.enable_google_signin
}

data "archive_file" "google_account_linking" {
  count = local.links_google_accounts ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/.build/google-account-linking.zip"

  source {
    filename = "handler.py"
    content  = <<-PY
      """Cognito pre sign-up: link a Google sign-in to the account that holds its address.

      NOTHING IS SHIPPED WITH THIS. boto3 is provided by the managed runtime, so the
      zip is one file, like the sweep poker's.

      EVERY PATH BUT ONE RETURNS THE EVENT UNTOUCHED. This runs on every sign-up,
      password ones included, so an exception anywhere else would turn a Cognito or
      IAM hiccup into nobody being able to create an account. A failure to link
      falls back to Cognito's default, which is today's behaviour.

      THE ONE DELIBERATE EXCEPTION comes after a successful link. Cognito is still
      part-way through creating the federated user it started with and does not
      reliably finish that sign-in as the linked account (the first attempt can end
      "Already found an entry for username"). So it is ended on purpose, with a
      marker the console finds in the callback's `error_description`. The console
      starts the Google sign-in once more, and that pass finds the link.
      """

      import json
      import logging

      import boto3
      from botocore.config import Config

      log = logging.getLogger()
      log.setLevel(logging.INFO)

      # Cognito waits five seconds for a trigger. Short timeouts and one retry keep
      # a slow call inside that, and running out only means "not linked".
      _idp = boto3.client(
          "cognito-idp",
          config=Config(connect_timeout=2, read_timeout=2, retries={"max_attempts": 2, "mode": "standard"}),
      )

      GMAIL_DOMAINS = frozenset({"gmail.com", "googlemail.com"})

      # The console's sign-in callback matches this exact string. Change the two
      # together.
      LINKED_MARKER = "DUNMIR_ACCOUNT_LINKED"


      def handler(event, context):
          if event.get("triggerSource") != "PreSignUp_ExternalProvider":
              return event
          # "google_<sub>". The pool is case-insensitive, so Cognito lower-cases the
          # provider prefix; Google's subject is digits and arrives unchanged.
          prefix, _, subject = str(event.get("userName") or "").partition("_")
          if prefix.lower() != "google" or not subject:
              return event

          attributes = (event.get("request") or {}).get("userAttributes") or {}
          email = str(attributes.get("email") or "").strip().lower()
          refusal = _refusal(attributes, email)
          if refusal:
              _record(False, refusal, email)
              return event

          try:
              username = _password_account(event["userPoolId"], email)
              if username is None:
                  _record(False, "no single confirmed password account holds this address", email)
                  return event
              _idp.admin_link_provider_for_user(
                  UserPoolId=event["userPoolId"],
                  DestinationUser={"ProviderName": "Cognito", "ProviderAttributeValue": username},
                  SourceUser={
                      "ProviderName": "Google",
                      "ProviderAttributeName": "Cognito_Subject",
                      "ProviderAttributeValue": subject,
                  },
              )
          except Exception:
              log.exception("linking failed; Cognito creates a separate federated user instead")
              return event

          _record(True, "linked", email)
          raise RuntimeError(LINKED_MARKER)


      def _refusal(attributes, email):
          """Why Google is not the authority for this address, or None when it is."""
          if email.count("@") != 1 or any(ch in email for ch in '"\\ '):
              return "no usable address"
          local, _, domain = email.partition("@")
          if not local or "." not in domain:
              return "no usable address"
          # Absent is not a refusal: Google always verifies a Gmail address and a
          # Workspace account's primary address, and those are the only two cases
          # that pass below. Present and false is.
          if str(attributes.get("email_verified", "true")).lower() != "true":
              return "Google has not verified the address"
          if domain in GMAIL_DOMAINS:
              return None
          if str(attributes.get("custom:google_hd") or "").strip().lower() == domain:
              return None
          return "Google is not the authority for this domain"


      def _password_account(pool_id, email):
          """The one confirmed, enabled password account with this verified address."""
          # `email` passed _refusal, so it carries no quote or backslash to break
          # out of the filter string.
          users = _idp.list_users(UserPoolId=pool_id, Filter=f'email = "{email}"', Limit=10).get("Users") or []
          matches = []
          for user in users:
              # EXTERNAL_PROVIDER is another federated user. Anything short of
              # CONFIRMED never proved the mailbox, and linking a Google login to an
              # account somebody else registered is the pre-hijack to avoid.
              if user.get("UserStatus") != "CONFIRMED" or not user.get("Enabled", False):
                  continue
              attrs = {item["Name"]: item["Value"] for item in user.get("Attributes") or []}
              if str(attrs.get("email_verified", "")).lower() != "true":
                  continue
              if str(attrs.get("email", "")).lower() != email:
                  continue
              matches.append(user["Username"])
          return matches[0] if len(matches) == 1 else None


      def _record(linked, reason, email):
          # The domain and not the address: enough to explain a refusal without
          # writing people's mailboxes into CloudWatch.
          print(json.dumps({"linked": linked, "reason": reason, "domain": email.rpartition("@")[2]}))
    PY
  }
}

# trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "google_account_linking" {
  # checkov:skip=CKV_AWS_158:No KMS CMK for CW log groups: AES256 default is sufficient here
  # checkov:skip=CKV_AWS_338:Retention is set explicitly below; the 1-year rule does not apply
  count = local.links_google_accounts ? 1 : 0

  name              = "/aws/lambda/${local.name}-google-account-linking"
  retention_in_days = var.log_retention_days
}

# trivy:ignore:AVD-AWS-0066
resource "aws_lambda_function" "google_account_linking" { # nosemgrep: terraform.aws.security.aws-lambda-x-ray-tracing-not-active.aws-lambda-x-ray-tracing-not-active
  # checkov:skip=CKV_AWS_173:No environment variables to encrypt
  # checkov:skip=CKV_AWS_116:No DLQ: Cognito invokes this synchronously and handles the failure itself
  # checkov:skip=CKV_AWS_272:No code-signing CA configured in this account
  # checkov:skip=CKV_AWS_115:No reserved concurrency: one invocation per sign-up
  # checkov:skip=CKV_AWS_117:NOT VPC-bound, deliberately: it has to reach the cognito-idp API, which has no VPC endpoint
  # checkov:skip=CKV_AWS_50:X-Ray not enabled: cost not justified for two API calls
  count = local.links_google_accounts ? 1 : 0

  function_name = "${local.name}-google-account-linking"
  description   = "Cognito pre sign-up: links a Google sign-in to the password account that holds its address"
  role          = aws_iam_role.google_account_linking[0].arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  # Cognito abandons a trigger after five seconds, so a longer timeout buys nothing.
  timeout = 5
  # Not for the work, which is two API calls: for the cold start. boto3's import is most of
  # it, and at 128 MB it eats a visible share of the five seconds.
  memory_size = 256

  filename         = data.archive_file.google_account_linking[0].output_path
  source_code_hash = data.archive_file.google_account_linking[0].output_base64sha256

  depends_on = [aws_cloudwatch_log_group.google_account_linking]
}

resource "aws_iam_role" "google_account_linking" {
  count = local.links_google_accounts ? 1 : 0

  name = "${local.name}-google-account-linking"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "google_account_linking" {
  count = local.links_google_accounts ? 1 : 0

  name = "google-account-linking"
  role = aws_iam_role.google_account_linking[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.google_account_linking[0].arn}:*"
      },
      {
        # This pool only. AdminLinkProviderForUser lets one identity sign in as another user,
        # so it is exactly the permission that must not reach any other pool in the account.
        Effect   = "Allow"
        Action   = ["cognito-idp:ListUsers", "cognito-idp:AdminLinkProviderForUser"]
        Resource = aws_cognito_user_pool.this[0].arn
      },
    ]
  })
}

# SCOPED BY ACCOUNT, NOT BY THE POOL'S ARN, and that is about apply order rather than taste.
# `source_arn` would make this permission depend on the pool, so Terraform would create it AFTER
# the pool update that switches the trigger on, and every sign-up in between would fail with
# Cognito unable to invoke its own trigger. `source_account` still stops a pool in some other
# account from invoking it.
resource "aws_lambda_permission" "google_account_linking" {
  count = local.links_google_accounts ? 1 : 0

  statement_id   = "AllowCognitoPreSignUp"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.google_account_linking[0].function_name
  principal      = "cognito-idp.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}
