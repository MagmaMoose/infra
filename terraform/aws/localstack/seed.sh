#!/usr/bin/env bash
# Put the secrets the producer reads into LocalStack's SSM Parameter Store.
#
# Terraform deliberately does NOT create these. A secret in a Terraform resource is a secret
# in Terraform state, and this stack's state is the one thing in it that would be worth
# stealing. In production they are written once with `aws ssm put-parameter` (see
# aws/README.md); here they are fixed test values that smoke.py signs with.
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"  # DevSkim: ignore DS162092
: "${AWS_DEFAULT_REGION:=eu-west-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

PREFIX="${1:-/nievah/local}"

put() {
  aws --endpoint-url="$AWS_ENDPOINT_URL" ssm put-parameter \
    --name "$PREFIX/$1" --value "$2" --type SecureString --overwrite >/dev/null
  echo "  $PREFIX/$1"
}

echo "seeding secrets:"
put webhook-secret "localstack-github-webhook-secret"
put slack-signing-secret "localstack-slack-signing-secret"
# Comma-separated per-org secrets. Present so the multi-secret path in
# nievah.api.security.verify_signature_any is exercised rather than assumed.
put org-webhook-secrets "org-a-secret,org-b-secret"
