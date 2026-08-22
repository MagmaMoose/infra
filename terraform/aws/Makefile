# Local development for the AWS front door. Nothing here touches a real AWS account.
#
#   make dev    everything below, in order
#   make up     start LocalStack
#   make apply-local  build the stack inside it (both modules, wired as the leaves wire them)
#   make smoke  drive it end to end and assert the invariants
#   make down   stop LocalStack
#
# The Lambda package is built by NIEVAH's own script from a sibling checkout, not by anything
# here. That is the point: CI publishes with the same script, so a local run and a released
# artifact cannot be built differently. Override with `make NIEVAH=/path/to/nievah dev`.

SHELL := /bin/bash
HERE  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LS    := $(HERE)localstack
NIEVAH ?= $(HERE)../../../nievah
EDGE_ZIP ?= $(NIEVAH)/dist/nievah-edge.zip

export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION    ?= eu-west-1
export AWS_ENDPOINT_URL      ?= http://localhost:4566

# OpenTofu by preference. The stack requires >= 1.9, which rules out the last BUSL-free
# Terraform release (1.5.7) — so on a machine with both, tofu is the one that works.
TFBIN ?= $(shell command -v tofu 2>/dev/null || command -v terraform 2>/dev/null)

.PHONY: dev up down edge-zip apply-local destroy-local smoke logs fmt validate

dev: up edge-zip apply-local smoke

up:
	docker compose -f $(LS)/docker-compose.yml up -d
	@echo "waiting for localstack..."
	@for i in $$(seq 1 60); do \
	  curl -sf http://localhost:4566/_localstack/health >/dev/null && exit 0; \
	  sleep 2; \
	done; echo "localstack did not become healthy" >&2; exit 1

down:
	docker compose -f $(LS)/docker-compose.yml down -v

# Fails loudly rather than silently building an empty package if the sibling checkout is
# missing — a zip with no handlers in it deploys fine and 500s on the first webhook.
edge-zip:
	@test -f "$(NIEVAH)/scripts/build_edge_zip.py" || { \
	  echo "no nievah checkout at $(NIEVAH) — clone it beside infra, or pass NIEVAH=<path>" >&2; \
	  exit 1; }
	cd $(NIEVAH) && python3 scripts/build_edge_zip.py --out dist/nievah-edge.zip

apply-local:
	cd $(LS) && $(TFBIN) init -input=false
	cd $(LS) && $(TFBIN) apply -auto-approve -input=false -var edge_zip_path=$(abspath $(EDGE_ZIP))
	$(LS)/seed.sh

destroy-local:
	cd $(LS) && $(TFBIN) destroy -auto-approve -input=false -var edge_zip_path=$(abspath $(EDGE_ZIP))

# `uv run --with` builds an ephemeral env, so infra needs no committed Python project or
# venv for the one script that wants boto3. Falls back to a plain interpreter if uv is
# absent, which works when boto3 happens to be installed.
smoke:
	cd $(LS) && $(TFBIN) output -json > $(LS)/.outputs.json
	@if command -v uv >/dev/null 2>&1; then \
	  uv run --quiet --with boto3 python $(LS)/smoke.py $(LS)/.outputs.json; \
	else \
	  python3 $(LS)/smoke.py $(LS)/.outputs.json; \
	fi

logs:
	aws --endpoint-url=$(AWS_ENDPOINT_URL) logs tail /aws/lambda/nievah-producer --follow

fmt:
	$(TFBIN) fmt -recursive $(HERE)

# Validates the MODULES, which is what Atlantis will run. The localstack root is validated
# implicitly by `apply-local`.
validate:
	@for m in artifacts nievah-frontdoor; do \
	  printf "%-18s " $$m; \
	  ( cd $(HERE)modules/$$m \
	    && printf 'provider "aws" { region = "eu-west-1" }\n' > _validate_provider.tf \
	    && $(TFBIN) init -backend=false -input=false >/dev/null 2>&1 \
	    && $(TFBIN) validate 2>&1 | tail -1; \
	    rm -f _validate_provider.tf ); \
	done
