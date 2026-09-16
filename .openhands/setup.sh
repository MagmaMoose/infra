#!/usr/bin/env bash
# Runs when OpenHands opens a conversation on this repository. Idempotent and quiet:
# it is on the critical path of every session start, so it skips anything already
# present rather than reinstalling.
#
# Architecture is detected because the agent pod schedules on the on-prem worker tier,
# which is ff-pi2 (arm64) or ff-vm1 (amd64) depending on where the scheduler puts it.
set -euo pipefail

BIN="${HOME}/.local/bin"
mkdir -p "$BIN"
case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=amd64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 0 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

if ! have kustomize; then
  echo "installing kustomize ($ARCH)"
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.5.0/kustomize_v5.5.0_linux_${ARCH}.tar.gz" \
    | tar -xz -C "$BIN" kustomize
fi

if ! have yq; then
  echo "installing yq ($ARCH)"
  curl -fsSL -o "$BIN/yq" "https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_linux_${ARCH}"
  chmod +x "$BIN/yq"
fi

# terraform and terragrunt are deliberately NOT installed here. They are large, this
# script gates every session start, and plan/apply runs through the terragrunt GitHub
# workflow rather than from the agent. Install them in-session if a task needs them.

grep -qxF "export PATH=\"\$HOME/.local/bin:\$PATH\"" "${HOME}/.bashrc" 2>/dev/null \
  || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "${HOME}/.bashrc"

echo "setup complete: $(kustomize version 2>/dev/null || echo 'kustomize missing'), $(yq --version 2>/dev/null || echo 'yq missing')"
