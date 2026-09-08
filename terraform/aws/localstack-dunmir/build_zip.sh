#!/usr/bin/env bash
# Build the Dün Mir Lambda zip for the LOCAL run, by calling the SAME script production uses.
#
# THIS FILE USED TO RESOLVE ITS OWN DEPENDENCY SET, AND THAT WAS THE BUG. It passed a single
# `--platform manylinux2014_aarch64`, which does not fail when a package publishes
# `manylinux_2_28` wheels only — pip walks BACK through the version list until it finds a tag it
# matches, and exits 0. asyncpg 0.31.0 is exactly that case, so the local stack silently ran
# asyncpg 0.30.0 while production ran 0.31.0. `--only-binary=:all:` does not help: it forbids
# source builds, it does not stop the resolver downgrading.
#
# The header of the old version claimed it kept "the SAME backend/requirements.txt ... so the
# local run is not testing a different program". It did not, and could not, because a second
# implementation of the same packaging is a second thing to keep in step. So there is now one:
# `backend/scripts/build_lambda_zip.py` in MagmaMoose/dunmir, which the release workflow, the
# package test and this harness all call. That is nievah's arrangement too, for the same reason.
#
# WHAT THE LOCAL RUN STILL DOES NOT PROVE: the artefact executing on the REAL Lambda runtime.
# LocalStack runs it under its own Python. `make -C aws dunmir-zip-test` covers that by
# unzipping it into /var/task inside `public.ecr.aws/lambda/python:3.12` and driving it through
# AWS's Runtime Interface Emulator. Neither check subsumes the other.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUNMIR="${DUNMIR:-$HERE/../../../../dunmir}"
BACKEND="$DUNMIR/backend"
OUT="${OUT:-$HERE/dunmir-lambda.zip}"

BUILDER="$BACKEND/scripts/build_lambda_zip.py"
if [ ! -f "$BUILDER" ]; then
  echo "no dunmir checkout at $DUNMIR — clone it beside infra, or pass DUNMIR=<path>" >&2
  exit 1
fi

# Python 3.12 SPECIFICALLY, because the builder emits bytecode and .pyc are tied to the
# interpreter version: a 3.13 would produce .pyc the runtime silently ignores. `uv` is the
# reliable way to get one without depending on what the host happens to have on PATH; a plain
# python3.12 with pip works too.
if command -v uv >/dev/null 2>&1; then
  runner=(uv run --no-project --python 3.12 --with pip python)
elif command -v python3.12 >/dev/null 2>&1; then
  runner=(python3.12)
else
  echo "need python 3.12 (or uv) to build the Lambda zip; see $BUILDER" >&2
  exit 1
fi

rm -f "$OUT"
"${runner[@]}" "$BUILDER" --out "$OUT" --work "$HERE/.build/lambda"
