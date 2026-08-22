#!/usr/bin/env bash
#
# Bootstrap the franklinhouse k3s cluster.
# Folded in from calebsargeant/infra-v2 (scripts/bootstrap-k3s-cluster.sh);
# repointed at this repo's shared ansible/hosts.yaml inventory.
#
# Generates and caches a K3S_TOKEN on first run. That token is
# cluster-admin-equivalent and this repo is PUBLIC — it is written to
# ansible/.k3s_token, which is gitignored. Never commit it.
#
# Usage:
#   scripts/bootstrap-franklinhouse-k3s.sh --check     # dry run FIRST (repo convention)
#   scripts/bootstrap-franklinhouse-k3s.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY="${REPO_ROOT}/ansible/hosts.yaml"
PLAYBOOK="${REPO_ROOT}/ansible/franklinhouse-k3s-bootstrap.yaml"
TOKEN_FILE="${REPO_ROOT}/ansible/.k3s_token"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook is required but not installed."
  echo "Install it first, e.g.: python3 -m pip install --user ansible"
  exit 1
fi

if [[ -z "${K3S_TOKEN:-}" ]]; then
  if [[ -f "${TOKEN_FILE}" ]]; then
    K3S_TOKEN="$(<"${TOKEN_FILE}")"
    export K3S_TOKEN
    echo "K3S_TOKEN was loaded from ${TOKEN_FILE}."
  else
    K3S_TOKEN="$(openssl rand -hex 24)"
    export K3S_TOKEN
    umask 077
    printf '%s\n' "${K3S_TOKEN}" > "${TOKEN_FILE}"
    echo "K3S_TOKEN was generated and saved to ${TOKEN_FILE} (gitignored)."
  fi
fi

ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" "$@"
