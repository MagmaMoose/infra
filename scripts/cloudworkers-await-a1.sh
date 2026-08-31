#!/usr/bin/env bash
#
# Keep retrying the cloudworkers `server` leaf until ff-oci3 and ff-oci4 are both
# RUNNING, then exit 0.
#
# WHY THIS EXISTS. OCI will not hand a new tenancy A1.Flex capacity in
# eu-amsterdam-1 on demand. `terragrunt apply` returns
# `500-InternalError, Out of host capacity` and there is nothing to fix: the
# quota is free (41 cores available, 0 used), Oracle simply has no ARM host to
# place the instance on right now. The only known remedy is to keep asking.
# Everything else in the stack (VCN, CHRs, IPSec) is already applied; this leaf
# is idempotent and only the two instances are missing, so re-running is safe.
#
# Run it on a machine that stays on and leave it. It is quiet by default: one
# line per attempt, and it only gets loud when something happens.
#
#   scripts/cloudworkers-await-a1.sh                 # forever, 5 min apart
#   scripts/cloudworkers-await-a1.sh -i 120          # every 2 minutes
#   scripts/cloudworkers-await-a1.sh -n 50           # give up after 50 tries
#
# DO NOT run two of these at once, and do not run one while applying that leaf
# by hand. They share one GCS state file; concurrent applies fight over the lock
# and the loser dies mid-apply.
#
# Requires `op` (authenticated), `oci`, `terragrunt`, `tofu`, and working GCP
# application-default credentials for the state backend. Credentials are pulled
# from 1Password at run time into a 0700 temp dir that is deleted on exit --
# same approach as scripts/oci-vault-secrets.py. Nothing is written to the repo.

set -Eeuo pipefail

INTERVAL=300
MAX_ATTEMPTS=0 # 0 = forever

while getopts ":i:n:h" opt; do
    case "$opt" in
        i) INTERVAL=$OPTARG ;;
        n) MAX_ATTEMPTS=$OPTARG ;;
        h)
            sed -n '3,28p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        \?) echo "unknown option -$OPTARG (try -h)" >&2 && exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEAF="$REPO_ROOT/terraform/oci/cloudworkers/prod/eu-amsterdam-1/server"
OP_ITEM="op://Magma Moose/6kbpuhvcmj6bmmujjifwtmlg4q"

# Identifiers, not secrets. The tenancy and user OCIDs and the key fingerprint are
# already committed elsewhere in this repo; only the private key is sensitive, and
# that is the one thing fetched at run time.
TENANCY=ocid1.tenancy.oc1..aaaaaaaaataglyil3djobabznvcsqpqszsafgkeujqb55rf3aiugh5dj2lva
USER_OCID=ocid1.user.oc1..aaaaaaaaihbmjqxijzogpbsvdblgsa4727ozrmkcyfxobom2ktp3pbtrmpoa
FINGERPRINT=71:5f:58:10:bf:fb:3c:2a:58:04:fb:24:e7:5b:ff:38
AD=TTzG:eu-amsterdam-1-AD-1

for bin in op oci terragrunt tofu python; do
    command -v "$bin" > /dev/null || { echo "error: $bin is required but not installed" >&2; exit 1; }
done

WORK="$(mktemp -d)"
chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The 1Password copy of this key is FLATTENED -- its PEM newlines are spaces. Pasted
# as-is the OCI SDK fails with "PEM data was not found in buffer", which reads like an
# auth error and is not. Rebuild it canonically: strip the markers, drop all
# whitespace, re-wrap the base64 at 64 columns.
echo "fetching the API signing key from 1Password..." >&2
op read "$OP_ITEM/private key" > "$WORK/raw.key"
python - "$WORK/raw.key" "$WORK/key.pem" <<'PY'
import re, sys, textwrap
raw = open(sys.argv[1]).read()
m = re.search(r"-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----", raw, re.S)
if not m:
    sys.exit("no PEM markers found in the 1Password field")
label, body = m.group(1), re.sub(r"\s+", "", m.group(2))
with open(sys.argv[2], "w", newline="\n") as fh:
    fh.write(f"-----BEGIN {label}-----\n" + "\n".join(textwrap.wrap(body, 64)) + f"\n-----END {label}-----\n")
PY
rm -f "$WORK/raw.key"
chmod 600 "$WORK/key.pem"

printf '[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=eu-amsterdam-1\nkey_file=%s\n' \
    "$USER_OCID" "$FINGERPRINT" "$TENANCY" "$WORK/key.pem" > "$WORK/oci_config"
chmod 600 "$WORK/oci_config"

export OCI_CW_TENANCY_OCID="$TENANCY"
export OCI_CW_COMPARTMENT_OCID="$TENANCY" # this tenancy has no child compartments
export OCI_CW_USER_OCID="$USER_OCID"
export OCI_CW_FINGERPRINT="$FINGERPRINT"
export OCI_CW_PRIVATE_KEY_PATH="$WORK/key.pem"
export TG_TF_PATH=tofu
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True SUPPRESS_LABEL_WARNING=True

# Are both nodes actually up? Asked of OCI rather than inferred from terraform's exit
# code, because "apply succeeded" and "the VMs are running" are not the same claim.
both_running() {
    local raw n
    # `|| true` and the digit-scrub are both load-bearing. Under `set -o pipefail` a
    # failed `oci` call makes the whole pipeline non-zero, so an `|| echo 0` tacked on
    # the end would append a second value to python's -- yielding "0\n0", which `[ -eq ]`
    # rejects as "integer expected" and which would make this function permanently
    # false. That would mean the loop never recognises success and retries forever
    # against two healthy VMs.
    raw=$(OCI_CLI_CONFIG_FILE="$WORK/oci_config" oci compute instance list \
        --compartment-id "$TENANCY" --all 2>/dev/null \
        | python -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
want={'ff-oci3','ff-oci4'}
print(sum(1 for i in d.get('data',[]) if i.get('display-name') in want and i.get('lifecycle-state')=='RUNNING'))
" 2>/dev/null) || true
    n=$(printf '%s' "${raw:-}" | tr -cd '0-9' | tail -c 1)
    [ "${n:-0}" = "2" ]
}

if both_running; then
    echo "ff-oci3 and ff-oci4 are already RUNNING. Nothing to do."
    exit 0
fi

echo "waiting for A1 capacity in ${AD}. Interval ${INTERVAL}s. Ctrl-C to stop."
attempt=0
while :; do
    attempt=$((attempt + 1))
    log="$WORK/apply.log"

    set +e
    (cd "$LEAF" && timeout 1800 terragrunt apply -input=false -auto-approve) > "$log" 2>&1
    rc=$?
    set -e

    if [ $rc -eq 0 ] && both_running; then
        echo "attempt ${attempt}: SUCCESS. ff-oci3 and ff-oci4 are RUNNING."
        echo
        echo "Next, on the cluster (the kubelet may not self-set kubernetes.io labels,"
        echo "so the worker role label has to be applied by hand):"
        echo "  kubectl label node ff-oci3 node-role.kubernetes.io/worker=\"\" --overwrite"
        echo "  kubectl label node ff-oci4 node-role.kubernetes.io/worker=\"\" --overwrite"
        echo
        echo "They will not join until the FortiGate tunnels are up, so expect NotReady"
        echo "until then. k3s-agent retries on its own; nothing to restart."
        exit 0
    fi

    if grep -q "Out of host capacity" "$log"; then
        echo "$(date '+%H:%M:%S') attempt ${attempt}: no capacity, retrying in ${INTERVAL}s"
    elif grep -qE "Plugin did not respond|plugin process exited" "$log"; then
        # Seen intermittently on Windows under memory pressure: the 250 MB oracle/oci
        # provider fails to load its schema. Transient and unrelated to capacity, so it
        # is retried rather than treated as fatal.
        echo "$(date '+%H:%M:%S') attempt ${attempt}: provider plugin crashed (transient), retrying in ${INTERVAL}s"
    elif [ $rc -eq 0 ]; then
        echo "$(date '+%H:%M:%S') attempt ${attempt}: apply succeeded but both nodes are not RUNNING yet; rechecking in ${INTERVAL}s"
    else
        # Anything else is a real problem and repeating it will not help.
        echo "attempt ${attempt}: FAILED for a reason that is not capacity. Stopping." >&2
        echo >&2
        grep -E "^\s*│?\s*Error:" "$log" | sed 's/^[[:space:]]*│\?[[:space:]]*//' | sort -u | head -10 >&2
        echo >&2
        echo "Full log copied to: ${TMPDIR:-/tmp}/cloudworkers-a1-failure.log" >&2
        cp "$log" "${TMPDIR:-/tmp}/cloudworkers-a1-failure.log" 2>/dev/null || true
        exit 1
    fi

    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "gave up after ${attempt} attempts; still no A1 capacity." >&2
        exit 2
    fi
    sleep "$INTERVAL"
done
