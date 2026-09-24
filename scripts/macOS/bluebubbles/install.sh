#!/usr/bin/env bash
#
# Install BlueBubbles Server on the Mac mini and stage its per-user setup, so Hermes can
# send and receive iMessage. Run from an ADMIN login, from the repository root.
#
# BlueBubbles runs under a dedicated Standard macOS user (default `nievah`), never under a
# person's login: its API serves whatever the running user's Messages, Contacts and Find My
# hold. This script installs the app and hands the password to that user; the user's own
# setup is configure-user.sh. Full runbook: docs/guides/bluebubbles-imessage.md.
#
# Why not Homebrew: the cask was disabled on 2026-09-01 because 1.9.9 is not notarized. It
# IS Developer ID signed, so this pins the release DMG to the SHA-256 Homebrew recorded for
# it and to the signing team, and fails on any mismatch. curl sets no quarantine flag, so
# Gatekeeper does not re-assess the app at first launch.
#
# Steps, each skipped when already done:
#   1. install the pinned BlueBubbles.app into /Applications
#   2. read the server password: from stdin if piped, else the vault entry
#      `bluebubbles-password` (vault-prod) through scripts/oci-vault-secrets.py. It never
#      creates or rotates that entry: a failed read must not silently rotate a password
#      Hermes depends on. Creating it is a one-time step in the runbook.
#   3. stage configure-user.sh and a one-time password seed in /Users/Shared/bluebubbles.
#      The seed is readable (and removable) by the bot user only, through an ACL, and
#      configure-user.sh deletes it once applied.
#
# Usage:
#   scripts/macOS/bluebubbles/install.sh [--check] [--user <name>]
#   <password-cmd> | scripts/macOS/bluebubbles/install.sh [--user <name>]
#
# Requires: an admin login; op (authenticated) unless the password is piped in.

set -euo pipefail

BB_VERSION=1.9.9
BB_URL="https://github.com/BlueBubblesApp/bluebubbles-server/releases/download/v${BB_VERSION}/BlueBubbles-${BB_VERSION}-arm64.dmg"
BB_SHA256=fafd650c883f52e7494a6625e45249f2144d197378a4d57143ccf6198bb2e862
BB_TEAM=WPV275H8W7
APP=/Applications/BlueBubbles.app
STAGE=/Users/Shared/bluebubbles
VAULT_KEY=bluebubbles-password

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
CHECK=false
BB_USER=nievah

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=true ;;
    --user) BB_USER="${2:?--user needs a name}"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = Darwin ] || die "macOS only"
[ "$(uname -m)" = arm64 ] || die "this pins the arm64 build"
[ "$(id -u)" -ne 0 ] || die "run as your admin user, not root"
[[ " $(id -Gn) " == *" admin "* ]] || die "$(id -un) is not an admin; /Applications needs one"

TMP="$(mktemp -d)"
cleanup() { hdiutil detach "$TMP/mnt" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

install_app() {
  local have
  have="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
  if [ "$have" = "$BB_VERSION" ]; then
    note "BlueBubbles $BB_VERSION already installed"
    return
  fi
  [ -z "$have" ] || die "BlueBubbles $have is installed and this pins $BB_VERSION. To change it: quit BlueBubbles in the $BB_USER login, move $APP to the Trash, and rerun"
  if $CHECK; then note "would install BlueBubbles $BB_VERSION from $BB_URL"; return; fi

  note "downloading BlueBubbles $BB_VERSION"
  curl -fL --retry 3 --progress-bar -o "$TMP/bb.dmg" "$BB_URL"
  echo "$BB_SHA256  $TMP/bb.dmg" | shasum -a 256 -c - >/dev/null || die "SHA-256 mismatch for $BB_URL"
  mkdir "$TMP/mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/bb.dmg" >/dev/null
  codesign --verify --deep --strict "$TMP/mnt/BlueBubbles.app" || die "signature does not verify"
  local sig
  sig="$(codesign -dv "$TMP/mnt/BlueBubbles.app" 2>&1)"
  [[ $'\n'"$sig"$'\n' == *$'\n'"TeamIdentifier=$BB_TEAM"$'\n'* ]] || die "not signed by team $BB_TEAM"
  ditto "$TMP/mnt/BlueBubbles.app" "$APP"
  hdiutil detach "$TMP/mnt" >/dev/null
  note "installed $APP ($BB_VERSION)"
}

read_password() {
  if [ ! -t 0 ]; then
    PW="$(tr -d '\r\n')"
  else
    PW="$("$REPO_ROOT/scripts/oci-vault-secrets.py" -c firefly get "$VAULT_KEY")" \
      || die "could not read '$VAULT_KEY' from vault-prod (is op signed in?). If it does not exist yet, create it once:
  openssl rand -hex 32 | tr -d '\\n' | scripts/oci-vault-secrets.py -c firefly set $VAULT_KEY"
  fi
  # Hermes sends it as a query parameter and BlueBubbles compares it as a string, so keep it
  # URL-safe. The runbook generates 64 hex characters.
  [[ "$PW" =~ ^[A-Za-z0-9._~-]{16,}$ ]] || die "the password must be 16+ URL-safe characters"
}

stage() {
  if ! id "$BB_USER" >/dev/null 2>&1; then
    $CHECK && { note "no macOS user '$BB_USER' yet"; return; }
    die "no macOS user '$BB_USER'. Create it as a Standard user (System Settings > Users & Groups), log into it once, then rerun"
  fi
  if dseditgroup -o checkmember -m "$BB_USER" admin >/dev/null 2>&1; then
    die "'$BB_USER' is an admin. It must be a Standard user: BlueBubbles can read everything that user can"
  fi
  if $CHECK; then note "would stage $STAGE for $BB_USER"; return; fi

  mkdir -p "$STAGE"
  chmod 755 "$STAGE"
  install -m 755 "$HERE/configure-user.sh" "$STAGE/configure-user.sh"
  (umask 077 && printf '%s' "$PW" > "$STAGE/password")
  chmod -N "$STAGE/password"
  chmod +a "user:$BB_USER allow read,delete" "$STAGE/password"
  note "staged $STAGE for $BB_USER"
}

install_app
if $CHECK; then
  note "would read the password from stdin, else vault-prod/$VAULT_KEY"
else
  read_password
fi
stage
unset PW

$CHECK && exit 0
cat <<EOF

Next, in the '$BB_USER' login (with Messages already signed into its Apple Account),
open Terminal and run:

  $STAGE/configure-user.sh
EOF
