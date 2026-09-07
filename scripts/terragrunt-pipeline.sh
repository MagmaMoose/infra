#!/usr/bin/env bash
# Terragrunt plan/apply driver for .github/workflows/terragrunt.yml — the Atlantis
# replacement cleanup.md asks for.
#
# Kept as a script rather than inlined in the workflow so it can be run by hand
# identically to CI, which is most of what made Atlantis failures hard to debug.
#
# Subcommands:
#   discover all                     every leaf, one path per line
#   discover changed <changed-files> only leaves affected by those files
#   plan    <stack> <outdir>         writes <outdir>/{status,plan.txt}
#   apply   <stack> <outdir>         writes <outdir>/status
#   redact  <file>                   strips sensitive-looking lines to stdout
#
# status is one of: none | changes | failed
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

# A leaf is a directory with its own terragrunt.hcl that is NOT a shared include
# and NOT inside a .terragrunt-cache. The cache exclusion matters: terragrunt
# copies each unit's terragrunt.hcl into
# .terragrunt-cache/<hash>/<hash>/, so a naive find returns every leaf twice and
# CI plans phantom stacks that vanish when the cache is cleared.
#
# terraform/oci/cloudworkers/** is excluded until that tenancy is bootstrapped.
# Those leaves target a SECOND OCI tenancy (traceysargeant) and deliberately
# refuse to parse until it is real: each asserts OCI_CW_TENANCY_OCID and
# OCI_CW_COMPARTMENT_OCID with HCL regex(), and the edge/server leaves also
# assert OCI_CW_CHR_IMAGE_OCID and OCI_CW_K3S_TOKEN_SECRET_OCID, neither of
# which exists yet (the CHR image has to be imported into that tenancy, and the
# k3s node-token has to be copied into a vault there). Discovering them now
# would hard-fail the plan job on every PR and, because `apply` is gated on
# `needs.plan.result`, would block applies for every firefly stack too.
#
# TO RE-ENABLE: complete the bootstrap in
# .claude/decisions/2026-08-31-second-oci-tenancy-cloudworkers.md, add the
# OCI_CW_* secrets plus a ~/.oci/config for the parse-time vault lookups, then
# delete the -not -path line below.
discover_all() {
  find "$TF_DIR" -name terragrunt.hcl \
    -not -path '*/.terragrunt-cache/*' \
    -not -path "$TF_DIR/terragrunt.hcl" \
    -not -path "$TF_DIR/oci/cloudworkers/*" \
    -print0 \
  | xargs -0 -n1 dirname \
  | sed "s|^$REPO_ROOT/||" \
  | sort -u
}

# Shared files change the rendered config of leaves that do not contain them.
# This is the gap that made Atlantis unsafe here: its `when_modified` only sees
# each project's own subtree, so edits to root.hcl, region.hcl or modules/** were
# silently NOT planned and had to be triggered by hand, per COMMON_MISTAKES #6.
# Getting this right is most of the point of replacing it.
discover_changed() {
  local changed_file="$1"
  [[ -f "$changed_file" ]] || { echo "no such file: $changed_file" >&2; exit 2; }

  # Anything touching the root include, a shared module, or the pipeline itself
  # invalidates every leaf — cheaper to replan all than to reason about which.
  # Modules live at terraform/<provider>/modules/ (e.g. terraform/oci/modules/),
  # NOT terraform/modules/ — that path has never existed, so the original
  # pattern matched nothing and shared-module edits triggered zero replans.
  if grep -qE '^terraform/(root\.hcl|terragrunt\.hcl)$|^terraform/([a-z0-9-]+/)?modules/|^scripts/terragrunt-pipeline\.sh$|^\.github/workflows/terragrunt\.yml$' "$changed_file"; then
    discover_all
    return
  fi

  local -a leaves
  mapfile -t leaves < <(discover_all)

  {
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ "$f" == terraform/* ]] || continue
      for leaf in "${leaves[@]}"; do
        # direct hit: the changed file lives inside the leaf
        [[ "$f" == "$leaf"/* ]] && { printf '%s\n' "$leaf"; continue; }
      done
      # region.hcl / account.hcl invalidate every leaf beneath their directory
      if [[ "$(basename "$f")" =~ ^(region|account|env)\.hcl$ ]]; then
        local scope="${f%/*}"
        for leaf in "${leaves[@]}"; do
          [[ "$leaf" == "$scope"/* ]] && printf '%s\n' "$leaf"
        done
      fi
    done < "$changed_file"
  } | sort -u
}

run_stack() {
  local action="$1" stack="$2" outdir="$3"
  mkdir -p "$outdir"
  local log="$outdir/plan.txt"

  pushd "$REPO_ROOT/$stack" >/dev/null || { echo failed > "$outdir/status"; return 1; }

  local rc=0
  if [[ "$action" == plan ]]; then
    # -detailed-exitcode: 0 = no changes, 2 = changes, 1 = error. That
    # distinction is what lets scheduled runs report drift without failing.
    set +e
    terragrunt plan -no-color -detailed-exitcode -lock=false 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    case "$rc" in
      0) echo none    > "$outdir/status" ;;
      2) echo changes > "$outdir/status"; rc=0 ;;
      *) echo failed  > "$outdir/status" ;;
    esac
  else
    # Replan against the reviewed commit rather than reusing a saved plan file:
    # the gap between review and apply can be hours, and a stale saved plan
    # applies decisions made against infrastructure that has since moved.
    set +e
    terragrunt apply -auto-approve -no-color 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    [[ $rc -eq 0 ]] && echo changes > "$outdir/status" || echo failed > "$outdir/status"
  fi

  popd >/dev/null
  return $rc
}

# Terragrunt echoes variable values into plan output, and this repo is PUBLIC —
# plan comments land on pull requests anyone can read. Redaction is deliberately
# crude and over-broad: a false positive costs a reader one click into the run
# logs, a false negative publishes a credential permanently.
redact() {
  sed -E \
    -e 's/(password|secret|token|private_key|api_key|access_key|client_secret|admin_password)([^=:]*)([=:][[:space:]]*)"[^"]*"/\1\2\3"[REDACTED]"/Ig' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\[REDACTED PRIVATE KEY]' \
    -e 's/ocid1\.(customersecretkey|apikey)\.[A-Za-z0-9.-]+/[REDACTED OCID]/g' \
    "$1"
}

case "${1:-}" in
  discover)
    case "${2:-}" in
      all)     discover_all ;;
      changed) discover_changed "${3:?discover changed needs a changed-files path}" ;;
      *) echo "usage: $0 discover all|changed <file>" >&2; exit 2 ;;
    esac
    ;;
  plan)   run_stack plan  "${2:?stack}" "${3:?outdir}" ;;
  apply)  run_stack apply "${2:?stack}" "${3:?outdir}" ;;
  redact) redact "${2:?file}" ;;
  *)
    echo "usage: $0 {discover all|discover changed <file>|plan <stack> <out>|apply <stack> <out>|redact <file>}" >&2
    exit 2
    ;;
esac
