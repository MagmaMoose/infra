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

# ─────────────────────────────────────────────────────────────────────────────────────────────
# Dün Mir — the free-tier backend (Lambda + RDS + Cognito + S3 behind CloudFront).
#
#   make dunmir-dev         everything below, in order
#   make dunmir-up          start LocalStack + Postgres + the Cognito stand-in
#   make dunmir-seed        create the local user pool and write its ids for Terraform
#   make dunmir-zip         build the function package from a sibling dunmir checkout
#   make dunmir-apply       build the stack inside LocalStack (the same module the leaf uses)
#   make dunmir-migrate     apply schema/postgres.sql, the way production does
#   make dunmir-smoke       drive it end to end and assert the invariants
#   make dunmir-image-test  run the REAL container image under AWS's Runtime Interface Emulator
#   make dunmir-down        stop everything
#
# TWO PROOFS, AND BOTH ARE NEEDED. `dunmir-smoke` exercises the WIRING but runs a zip, because
# container-image Lambdas are a LocalStack Pro feature. `dunmir-image-test` exercises the
# ARTEFACT production actually deploys. Neither one catches what the other does.

DUNMIR ?= $(HERE)../../../dunmir
DM     := $(HERE)localstack-dunmir
DM_ZIP ?= $(DM)/dunmir-lambda.zip

.PHONY: dunmir-dev dunmir-up dunmir-down dunmir-seed dunmir-zip dunmir-apply dunmir-migrate \
        dunmir-smoke dunmir-image-test dunmir-destroy dunmir-logs dunmir-validate

dunmir-dev: dunmir-up dunmir-seed dunmir-zip dunmir-apply dunmir-migrate dunmir-smoke

dunmir-up:
	docker compose -f $(DM)/docker-compose.yml up -d
	@echo "waiting for localstack..."
	@for i in $$(seq 1 60); do \
	  curl -sf http://localhost:4566/_localstack/health >/dev/null && exit 0; \
	  sleep 2; \
	done; echo "localstack did not become healthy" >&2; exit 1

dunmir-down:
	docker compose -f $(DM)/docker-compose.yml down -v

# BEFORE the apply, not part of it: the function is configured with the pool's SIGNING KEYS
# rather than a URL to fetch them from, so the pool has to exist first. That is the same
# ordering the real apply has (Terraform creates the pool, then reads its JWKS with an `http`
# data source) — it is just visible here because the stand-in lives outside Terraform.
dunmir-seed:
	$(DM)/seed.sh

dunmir-zip:
	DUNMIR=$(DUNMIR) $(DM)/build_zip.sh

dunmir-apply:
	cd $(DM) && $(TFBIN) init -input=false
	cd $(DM) && $(TFBIN) apply -auto-approve -input=false -var lambda_zip_path=$(abspath $(DM_ZIP))

dunmir-destroy:
	cd $(DM) && $(TFBIN) destroy -auto-approve -input=false -var lambda_zip_path=$(abspath $(DM_ZIP))

# The same invocation the runbook uses on AWS. It has to be an invocation rather than a psql
# session because in production the database has no public address, and this function is the
# only thing inside the VPC that can reach it.
dunmir-migrate:
	aws --endpoint-url=$(AWS_ENDPOINT_URL) lambda invoke \
	  --function-name $$(cd $(DM) && $(TFBIN) output -raw function_name) \
	  --cli-binary-format raw-in-base64-out --payload '{"task":"migrate"}' /dev/null >/dev/null
	@echo "schema applied"

smoke_dunmir_deps = $(DM)/.outputs.json
dunmir-smoke:
	cd $(DM) && $(TFBIN) output -json > $(DM)/.outputs.json
	python3 $(DM)/smoke.py $(DM)/.outputs.json

dunmir-image-test:
	DUNMIR=$(DUNMIR) $(DM)/image_test.sh

dunmir-logs:
	aws --endpoint-url=$(AWS_ENDPOINT_URL) logs tail /aws/lambda/dunmir-local-api --follow

# Validates the MODULE, which is what Atlantis will run. The localstack root is validated
# implicitly by `dunmir-apply`.
# A tripwire for the class of bug that made `make dev` dangerous.
#
# Both obvious names for a LocalStack provider file are matched by .gitignore —
# `*_override.tf` (the stock HashiCorp rule) and `provider.tf` (Terragrunt generates one into
# every leaf). A provider file under either name is silently untracked, and a fresh clone then
# gets a local root with NO provider at all: Terraform falls back to the ambient credentials and
# builds the stack in whatever REAL account the operator is logged into. That is what happened to
# terraform/aws/localstack/, and nobody noticed because the failure only appears on a clone.
#
# So: every .tf in a localstack root must be tracked by git. Cheap, and it fails loudly.
.PHONY: localstack-tracked
localstack-tracked:
	@fail=0; \
	for root in $(HERE)localstack $(HERE)localstack-dunmir; do \
	  [ -d "$$root" ] || continue; \
	  for f in "$$root"/*.tf; do \
	    [ -e "$$f" ] || continue; \
	    if git -C $(HERE).. check-ignore -q "$$f" 2>/dev/null; then \
	      echo "IGNORED (would vanish on a fresh clone): $$f"; fail=1; \
	    elif ! git -C $(HERE).. ls-files --error-unmatch "$$f" >/dev/null 2>&1; then \
	      echo "UNTRACKED: $$f"; fail=1; \
	    fi; \
	  done; \
	done; \
	if [ $$fail -ne 0 ]; then \
	  echo; \
	  echo "A LocalStack root with no committed provider falls back to REAL AWS credentials."; \
	  echo "Rename the file to something no .gitignore rule matches (see"; \
	  echo "localstack-dunmir/localstack_provider.tf) and commit it."; \
	  exit 1; \
	fi; \
	echo "every .tf in a localstack root is tracked"

dunmir-validate:
	@printf "%-18s " dunmir-platform; \
	( cd $(HERE)modules/dunmir-platform \
	  && printf 'provider "aws" {\n  region = "eu-west-1"\n}\nprovider "aws" {\n  alias  = "us_east_1"\n  region = "us-east-1"\n}\n' > _validate_provider.tf \
	  && $(TFBIN) init -backend=false -input=false >/dev/null 2>&1 \
	  && $(TFBIN) validate 2>&1 | tail -1; \
	  rm -f _validate_provider.tf )
