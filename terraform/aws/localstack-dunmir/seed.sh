#!/usr/bin/env bash
# Create the local Cognito pool and hand its details to Terraform.
#
# WHY THIS RUNS BEFORE TERRAFORM, AND NOT AS PART OF IT
#   The function is configured with the pool's SIGNING KEYS, not with an address to fetch them
#   from. That is the design decision the whole free-tier topology rests on — a VPC Lambda with
#   no NAT gateway cannot reach `cognito-idp`, so verification has to be a pure local
#   computation. It also means the pool must exist before the function is created, in both
#   environments. On AWS, Terraform creates the pool and then reads the keys with an `http` data
#   source in the same apply. Here the pool lives in `moto` (Cognito is a LocalStack Pro
#   feature), which Terraform's AWS provider cannot be pointed at usefully, so it is created
#   here and its details are written into `local.auto.tfvars.json` for the apply that follows.
#
# WHAT MOTO GETS RIGHT, WHICH IS THE PART THAT MATTERS
#   Real RS256 tokens, signed with a real key, published at a real JWKS endpoint, and a real
#   password policy. So the backend's hand-rolled verifier, the issuer and audience checks, and
#   the browser's whole sign-in flow are exercised for real. What it does not model: the MFA
#   challenge sequence, and Cognito's own email delivery — which is why the address is confirmed
#   administratively in `smoke.py` rather than with the emailed code.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${COGNITO_ENDPOINT:=http://localhost:5001}" # DevSkim: ignore DS162092
: "${AWS_DEFAULT_REGION:=eu-west-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION

aws_cognito() {
  aws --endpoint-url="$COGNITO_ENDPOINT" cognito-idp "$@"
}

# Idempotent: `make dunmir-dev` is run repeatedly, and a fresh pool every time would orphan the
# users from the last run and invalidate any token still in a developer's browser.
POOL="$(aws_cognito list-user-pools --max-results 60 \
  --query "UserPools[?Name=='dunmir-local'].Id | [0]" --output text)"

if [ "$POOL" = "None" ] || [ -z "$POOL" ]; then
  # The password policy MIRRORS the real pool (identity.tf): length is the whole rule, no forced
  # character classes. Without it the stand-in falls back to its own default — uppercase, digit
  # AND symbol required — and the local run would reject passphrases the production pool
  # accepts, which is the local proving ground disagreeing with production about the one thing
  # a user types.
  POOL="$(aws_cognito create-user-pool \
    --pool-name dunmir-local \
    --auto-verified-attributes email \
    --username-attributes email \
    --policies 'PasswordPolicy={MinimumLength=12,RequireUppercase=false,RequireLowercase=false,RequireNumbers=false,RequireSymbols=false}' \
    --query 'UserPool.Id' --output text)"
  echo "created user pool $POOL"
else
  echo "reusing user pool $POOL"
fi

CLIENT="$(aws_cognito list-user-pool-clients --user-pool-id "$POOL" --max-results 60 \
  --query "UserPoolClients[?ClientName=='dunmir-local-console'].ClientId | [0]" --output text)"

if [ "$CLIENT" = "None" ] || [ -z "$CLIENT" ]; then
  # `--no-generate-secret` mirrors the real client and is load-bearing: a public SPA client with
  # a secret cannot authenticate from a browser at all, because every unauthenticated call would
  # need a SECRET_HASH the bundle has no way to compute.
  CLIENT="$(aws_cognito create-user-pool-client \
    --user-pool-id "$POOL" \
    --client-name dunmir-local-console \
    --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --query 'UserPoolClient.ClientId' --output text)"
  echo "created app client $CLIENT"
else
  echo "reusing app client $CLIENT"
fi

# The signing keys. Fetched from moto here exactly as Terraform fetches them from Cognito on
# AWS, and passed to the function the same way.
JWKS="$(curl -sf "$COGNITO_ENDPOINT/$POOL/.well-known/jwks.json")"
if ! printf '%s' "$JWKS" | jq -e '.keys[0].kid' >/dev/null 2>&1; then
  # Fail loudly. A function configured with an empty JWKS rejects every token, which presents as
  # "nobody can sign in" against a stack that otherwise looks perfectly healthy.
  echo "could not read a JWKS from $COGNITO_ENDPOINT/$POOL — is the cognito container up?" >&2
  exit 1
fi

# The issuer is the REAL AWS URL even locally: moto stamps tokens with it, so that is what the
# backend must match. The endpoint is where the browser (and the smoke test) actually send
# their calls. Two different strings for two different jobs — collapsing them is the mistake
# this comment exists to prevent.
jq -n \
  --arg pool "$POOL" \
  --arg client "$CLIENT" \
  --arg issuer "https://cognito-idp.${AWS_DEFAULT_REGION}.amazonaws.com/${POOL}" \
  --arg endpoint "$COGNITO_ENDPOINT" \
  --arg jwks "$JWKS" \
  '{cognito: {user_pool_id: $pool, client_id: $client, issuer: $issuer, endpoint: $endpoint, jwks: $jwks}}' \
  >"$HERE/local.auto.tfvars.json"

echo "wrote $HERE/local.auto.tfvars.json"
