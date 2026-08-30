#!/usr/bin/env bash
# Run the REAL deployment zip on the REAL Lambda runtime, under AWS's own Runtime Interface
# Emulator.
#
# WHY THIS EXISTS ALONGSIDE THE LOCALSTACK RUN
#   They prove different things and neither subsumes the other.
#
#   `make dunmir-dev` proves the WIRING — IAM, S3, the API, the schedule, the schema, the
#   Cognito flow — but it executes the code under LocalStack's own Python, on this machine's
#   architecture.
#
#   This proves the ARTEFACT: the exact bytes production deploys, unpacked into /var/task inside
#   the same base image Lambda runs, driven by the same Runtime Interface Client, as an
#   unprivileged uid, with no network. It is the only check that catches the class of failure
#   this repository has already been bitten by — a package the application imports that was
#   never added to the build script's source list, which produces an artefact that builds,
#   uploads, deploys, and dies at startup with `ModuleNotFoundError`. Six releases shipped in
#   exactly that state.
#
#   For a zip there is a second failure only this can catch. Lambda validates a container
#   image's architecture from its manifest and rejects a mismatch at deploy time; it cannot do
#   that for a zip. A package of x86_64 wheels installs onto an arm64 function without complaint
#   and fails at the first invocation — and CPython's error names the MODULE, not the
#   architecture, so it reads exactly like the missing-source bug above.
#
# WHAT IT DOES NOT NEED: an AWS account, LocalStack, or a database. Every check is chosen to
# exercise the import graph and the handler dispatch without touching Postgres.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUNMIR="${DUNMIR:-$HERE/../../../../dunmir}"
ZIP="${ZIP:-$HERE/dunmir-lambda.zip}"
NAME="dunmir-zip-test"
PORT="${PORT:-9021}"

# Must match `architectures` on aws_lambda_function.api and ARCHITECTURE in the build script.
PLATFORM="${PLATFORM:-linux/amd64}"
BASE="${BASE:-public.ecr.aws/lambda/python:3.12}"

if [ ! -f "$DUNMIR/backend/scripts/build_lambda_zip.py" ]; then
  echo "no dunmir checkout at $DUNMIR — clone it beside infra, or pass DUNMIR=<path>" >&2
  exit 1
fi

cleanup() {
  docker rm -f "$NAME" "$NAME-nokeys" >/dev/null 2>&1 || true
  rm -rf "$HERE/.zip-test"
}
trap cleanup EXIT
cleanup

if [ ! -f "$ZIP" ]; then
  echo "building the deployment zip ..."
  "$HERE/build_zip.sh"
fi

# Unpacked rather than mounted from the build tree: what is asserted is the ARCHIVE's contents,
# including its recorded permissions. A build directory read directly would carry the build
# host's modes and hide a member the runtime cannot read.
ROOT="$HERE/.zip-test/var-task"
mkdir -p "$ROOT"
unzip -qo "$ZIP" -d "$ROOT"
echo "unpacked $(find "$ROOT" -type f | wc -l | tr -d ' ') files from $(basename "$ZIP")"

# A throwaway RSA public key in JWKS form. The app refuses to START under AUTH_MODE=cognito with
# no signing keys (`cognito.check_configuration`) — correct behaviour, asserted separately below
# — so the happy path has to supply some.
JWKS='{"keys":[{"kty":"RSA","alg":"RS256","use":"sig","kid":"zip-test","e":"AQAB","n":"sXchDaQebHnPiGvyDOAT4saGEUetSyo9MKLOoWFsueri23bOdgWp4Dy1WlUzewbgBHod5pcM9H95GQRV3JDXboIRROSBigeC5yjU1hGzHHyXss8UDprecbAYxknTcQkhslANGRUZmdTOQ5qTRsLAt6BTYuyvVRdhS8exSZEy_c4gs_7svlJJQ4H9_NxsiIh4XLnCz5FvJp3ZaGZjJnvo1KTMHNMzHNhFKZzBzHhL0GLZLDdz9DpzM4rNzLMxWZLQ2VjBHTLcYw1qhwFqBLpUqvNMlOgKKJEsVCzQlOOqE0uHwGKlH8mYyIfxJnkzVJKAJqzTnCiGKmSSHiRDkDvzhqQ"}]}'

# `-u 993:990`: an arbitrary unprivileged uid, because Lambda does not run the function as root.
# A zip member without world-read is imported perfectly by a root RIE and raises PermissionError
# in production — a difference that only ever appears after deploy.
#
# `--network none`: the AUTH_MODE=cognito topology is built on the function making no outbound
# calls at all. If that ever stops being true, this is where it shows up.
docker run -d --name "$NAME" -p "$PORT:8080" \
  --platform "$PLATFORM" --network none -u 993:990 \
  -v "$ROOT:/var/task:ro" \
  -e AUTH_MODE=cognito \
  -e COGNITO_REGION=eu-west-1 \
  -e COGNITO_USER_POOL_ID=eu-west-1_ZIPTEST \
  -e COGNITO_APP_CLIENT_ID=zip-test-client \
  -e COGNITO_JWKS="$JWKS" \
  -e MULTI_TENANT=true \
  -e EMAIL_PROVIDER=none \
  "$BASE" lambda_handler.handler >/dev/null

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
echo "the artefact's import graph is complete and the handler dispatches:"

# The one that catches a missing source tree. If `dunmir_control_plane` (or anything else the
# app imports) is absent, the module-scope `from app.main import app` raises and EVERY
# invocation returns an errorType instead of a response.
health="$(invoke "$(http_event /v1/health)")"
assert "the app imported and answers /v1/health" \
  '200' "$(printf '%s' "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("statusCode"))')"
assert "no import error escaped" \
  '' "$(printf '%s' "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("errorType",""))')"

# A 200 above already proves pydantic_core's extension LOADED, since the app cannot import
# without it — which is most of the architecture check. asyncpg is imported lazily, so it is not
# covered here; the build script's ELF assertion covers it before the archive is written, and
# the sweep below is what exercises the database import path.

# Proves the identity configuration is read and the public bootstrap document is servable
# without a database — which is what lets the console render a sign-in screen during an outage.
config="$(invoke "$(http_event /api/session/config)")"
assert "the public config document is servable with no database" \
  '200' "$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("statusCode"))')"
assert "and names Cognito as the identity provider" \
  'cognito' "$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["body"])["auth_mode"])')"

# The RDS bundle moved from /opt (where a container image put it) to the package root, because
# a zip function's /opt is where LAYERS extract and is empty. `db_ssl_root_cert_path` in the
# module must name the same path, and the two fail together if they drift.
assert "the RDS CA bundle ships in the package" \
  'ok' "$([ -f "$ROOT/rds-global-bundle.pem" ] && echo ok || echo missing)"

# The task dispatch. An unknown task must RAISE rather than fall through to the HTTP path — a
# malformed scheduler payload silently 404ing as a request is invisible for months.
unknown="$(invoke '{"task":"not-a-real-task"}')"
assert "an unknown task is refused, not treated as HTTP" \
  'ValueError' "$(printf '%s' "$unknown" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("errorType",""))')"

# The sweep with no database configured. This is the assertion that reaches the DATABASE import
# path, so a broken asyncpg surfaces here rather than at the first real sweep in production.
sweep="$(invoke '{"task":"sweep"}')"
assert "the sweep reaches the database layer and reports no database, not a broken import" \
  'RuntimeError' "$(printf '%s' "$sweep" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("errorType",""))')"

# The regression that made every HTTP request fail after the first task on a warm container:
# `asyncio.run` closes its loop and clears the thread's current one. A task, then a request, on
# the SAME container is the exact reproduction.
after="$(invoke "$(http_event /v1/health)")"
assert "an HTTP request still works after a task ran on the same container" \
  '200' "$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("statusCode"))')"

# The boot check itself. A Cognito deployment with no signing keys can never authenticate
# anybody, and every symptom of that is identical at runtime — "nobody can sign in", with a
# health check answering 200 the whole time. So it must refuse to START.
echo
echo "a Cognito deployment with no signing keys refuses to start:"
docker run -d --name "$NAME-nokeys" -p "$((PORT + 1)):8080" \
  --platform "$PLATFORM" --network none -u 993:990 \
  -v "$ROOT:/var/task:ro" \
  -e AUTH_MODE=cognito \
  -e COGNITO_REGION=eu-west-1 \
  -e COGNITO_USER_POOL_ID=eu-west-1_ZIPTEST \
  -e COGNITO_APP_CLIENT_ID=zip-test-client \
  -e MULTI_TENANT=true \
  "$BASE" lambda_handler.handler >/dev/null

# `grep -c`, NOT `grep -q`, and that is not a style choice. This script runs under
# `set -o pipefail`, and `grep -q` exits the instant it matches, closing the pipe and killing
# `docker logs` with SIGPIPE (141). pipefail then reports the PIPELINE as failed even though
# grep succeeded — so the check reported "no match" every time it actually matched.
found=0
for _ in $(seq 1 20); do
  curl -s -o /dev/null --max-time 3 -XPOST \
    "http://localhost:$((PORT + 1))/2015-03-31/functions/function/invocations" \
    -d "$(http_event /v1/health)" 2>/dev/null || true
  found=$(docker logs "$NAME-nokeys" 2>&1 | grep -c "COGNITO_JWKS" || true)
  if [ "$found" -gt 0 ]; then break; fi
  sleep 1
done

if [ "$found" -gt 0 ]; then
  printf '  \033[32m✓\033[0m it fails at boot, naming the missing setting\n'
else
  printf '  \033[31m✗\033[0m it started anyway, or failed for another reason\n'
  docker logs "$NAME-nokeys" 2>&1 | grep -iE "error|cognito" | head -3 || true
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m\033[1mthe artefact is deployable\033[0m\n\n'
else
  printf '\033[31m\033[1mthe artefact is NOT deployable — see above\033[0m\n\n'
  docker logs "$NAME" 2>&1 | tail -30
fi
exit "$fail"
