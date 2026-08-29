#!/usr/bin/env bash
# Run the REAL container image under AWS's own Lambda Runtime Interface Emulator.
#
# WHY THIS EXISTS ALONGSIDE THE LOCALSTACK RUN
#   They prove different things and neither subsumes the other.
#
#   `make dunmir-dev` proves the WIRING — IAM, S3, the function URL, the schedule, the schema,
#   the Cognito flow — but it runs a zip, because container-image Lambdas are a LocalStack Pro
#   feature.
#
#   This proves the ARTEFACT: the image that production actually deploys, executed by the same
#   Runtime Interface Client that Lambda uses, in a container built the same way. It is the only
#   check that catches the class of failure this repository has already been bitten by — a
#   package the application imports that was never COPY'd into the image, which produces an
#   image that builds cleanly, pushes cleanly, deploys cleanly and dies at startup with
#   `ModuleNotFoundError`. Six releases shipped in exactly that state.
#
# WHAT IT DOES NOT NEED: an AWS account, LocalStack, or a database. The checks are deliberately
# ones that exercise the import graph and the handler dispatch without touching Postgres, so
# this is a fast, standalone smoke of the packaging itself.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUNMIR="${DUNMIR:-$HERE/../../../../dunmir}"
IMAGE="${IMAGE:-dunmir-backend:lambda-test}"
NAME="dunmir-image-test"
PORT="${PORT:-9021}"

if [ ! -f "$DUNMIR/backend/Dockerfile.lambda" ]; then
  echo "no dunmir checkout at $DUNMIR — clone it beside infra, or pass DUNMIR=<path>" >&2
  exit 1
fi

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "building $IMAGE for linux/arm64 ..."
# arm64, matching `architectures = ["arm64"]` in the module. An amd64 image would run here on an
# emulating host and be rejected by Lambda at deploy time.
docker build --quiet --platform linux/arm64 \
  -f "$DUNMIR/backend/Dockerfile.lambda" \
  -t "$IMAGE" "$DUNMIR/backend" >/dev/null

echo "starting it under the Runtime Interface Emulator ..."
# No DATABASE_URL: every check below is chosen to avoid the database, so this stays a test of
# the PACKAGE rather than a second, worse copy of the LocalStack run.
docker run -d --name "$NAME" -p "$PORT:8080" \
  -e AUTH_MODE=cognito \
  -e COGNITO_REGION=eu-west-1 \
  -e COGNITO_USER_POOL_ID=eu-west-1_IMAGETEST \
  -e COGNITO_APP_CLIENT_ID=image-test-client \
  -e MULTI_TENANT=true \
  -e EMAIL_PROVIDER=none \
  "$IMAGE" >/dev/null

for _ in $(seq 1 30); do
  curl -sf -o /dev/null -XPOST "http://localhost:$PORT/2015-03-31/functions/function/invocations" \
    -d '{"version":"2.0","rawPath":"/v1/health","requestContext":{"http":{"method":"GET","path":"/v1/health","sourceIp":"127.0.0.1"}},"headers":{"host":"x"},"isBase64Encoded":false}' \
    && break
  sleep 1
done

fail=0
assert() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$label"
  else
    printf '  \033[31m✗\033[0m %s — expected %s, got %s\n' "$label" "$expected" "$actual"
    fail=1
  fi
}

invoke() {
  curl -s -XPOST "http://localhost:$PORT/2015-03-31/functions/function/invocations" -d "$1"
}

http_event() {
  printf '{"version":"2.0","rawPath":"%s","requestContext":{"http":{"method":"GET","path":"%s","sourceIp":"127.0.0.1"}},"headers":{"host":"api.example.com"},"isBase64Encoded":false}' "$1" "$1"
}

echo
echo "the image's import graph is complete and the handler dispatches:"

# The one that catches a missing COPY. If `dunmir_control_plane` (or any other package the app
# imports) is absent, the module-scope `from app.main import app` raises and EVERY invocation —
# including this one — returns an errorType instead of a response.
health="$(invoke "$(http_event /v1/health)")"
assert "the app imported and answers /v1/health" \
  '200' "$(printf '%s' "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("statusCode"))')"

assert "no import error escaped" \
  '' "$(printf '%s' "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("errorType",""))')"

# Proves the identity configuration is read and the public bootstrap document is servable
# without a database — which is what lets the console render a sign-in screen before, or during,
# a database outage.
config="$(invoke "$(http_event /api/session/config)")"
assert "the public config document is servable with no database" \
  '200' "$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("statusCode"))')"
assert "and names Cognito as the identity provider" \
  'cognito' "$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["body"])["auth_mode"])')"

# The task dispatch. An unknown task must RAISE rather than fall through to the HTTP path — a
# malformed scheduler payload silently 404ing as a request is invisible for months.
unknown="$(invoke '{"task":"not-a-real-task"}')"
assert "an unknown task is refused, not treated as HTTP" \
  'ValueError' "$(printf '%s' "$unknown" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("errorType",""))')"

# The regression that made every HTTP request fail after the first task on a warm container:
# `asyncio.run` closes its loop and clears the thread's current one. A task, then a request, on
# the SAME container is the exact reproduction.
invoke '{"task":"sweep"}' >/dev/null
after="$(invoke "$(http_event /v1/health)")"
assert "an HTTP request still works after a task ran on the same container" \
  '200' "$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("statusCode"))')"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m\033[1mthe image is deployable\033[0m\n\n'
else
  printf '\033[31m\033[1mthe image is NOT deployable — see above\033[0m\n\n'
  docker logs "$NAME" 2>&1 | tail -30
fi
exit "$fail"
