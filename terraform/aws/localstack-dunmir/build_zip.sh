#!/usr/bin/env bash
# Package the Dün Mir backend as a Lambda zip, for the LOCAL run only.
#
# WHY A ZIP EXISTS AT ALL, when production deploys a container image: container-image Lambdas
# are a LocalStack Pro feature, and the community image answers
# `NotImplementedError: Container images are a Pro feature` at the first invocation. So the
# local stack runs the same application code, through the same `lambda_handler.handler`, from a
# zip.
#
# WHAT IS KEPT IDENTICAL TO THE IMAGE, deliberately, so the local run is not testing a different
# program:
#
#   * the SAME `backend/requirements.txt`, plus the same `mangum` the Dockerfile installs;
#   * the SAME source trees — and every one of them, which is the failure this list exists to
#     prevent: `dunmir_control_plane` stopped being a pip dependency and became ordinary source,
#     the container's COPY for it was missed, and six releases shipped images that could not
#     start with `ModuleNotFoundError`. A zip that omits a package fails the same way.
#   * linux/aarch64 wheels, matching the arm64 function.
#
# WHAT IS NOT PROVED HERE: the image itself — its base, its layers, and whether ITS copies are
# complete. That is covered by `make -C aws dunmir-image-test`, which runs the real image under
# AWS's own Runtime Interface Emulator. Neither check subsumes the other.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUNMIR="${DUNMIR:-$HERE/../../../../dunmir}"
BACKEND="$DUNMIR/backend"
BUILD="$HERE/.build"
OUT="${OUT:-$HERE/dunmir-lambda.zip}"

if [ ! -f "$BACKEND/lambda_handler.py" ]; then
  echo "no dunmir checkout at $DUNMIR — clone it beside infra, or pass DUNMIR=<path>" >&2
  exit 1
fi

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"

echo "installing dependencies for linux/aarch64 ..."
# `--platform` + `--only-binary=:all:` because asyncpg and pydantic-core are compiled: pip would
# otherwise build them for THIS machine (macOS/arm64), producing a zip whose extensions the
# Lambda runtime cannot load — and the error appears at the first invocation, not at build time.
# `mangum` matches the version pinned in backend/Dockerfile.lambda.
python3 -m pip install --quiet --upgrade \
  --target "$BUILD" \
  --platform manylinux2014_aarch64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  -r "$BACKEND/requirements.txt" "mangum~=0.19"

echo "copying application source ..."
# Every package the app imports. Keep this list in step with backend/Dockerfile.lambda's COPY
# lines — a package present in one and absent from the other means the local run and the
# deployed image are different programs.
for tree in app dunmir_control_plane schema scripts; do
  cp -R "$BACKEND/$tree" "$BUILD/$tree"
done
cp "$BACKEND/lambda_handler.py" "$BUILD/"

# Bytecode caches and test trees make the zip larger and can shadow a source change with a stale
# .pyc if the timestamps land oddly.
find "$BUILD" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$BUILD" -name '*.pyc' -delete 2>/dev/null || true
find "$BUILD" -maxdepth 2 -name 'tests' -type d -prune -exec rm -rf {} + 2>/dev/null || true

( cd "$BUILD" && zip -qr "$OUT" . -x '*.dist-info/RECORD' )
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
