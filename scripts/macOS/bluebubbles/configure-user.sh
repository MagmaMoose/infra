#!/usr/bin/env bash
#
# Configure BlueBubbles Server for the macOS user that runs it. Run it from Terminal INSIDE
# that user's login (the bot user, `nievah`), after install.sh has staged it:
#
#   /Users/Shared/bluebubbles/configure-user.sh
#
# BlueBubbles serves whatever the running user's Messages, Contacts and Find My hold, so this
# refuses to run for an admin: a person's login must never be the one it runs in.
#
# Safe to rerun, e.g. after rotating the password or to repair the LaunchAgents. It sets up:
#   ~/bluebubbles.yml
#       Settings BlueBubbles applies and persists at every start, so they win over its UI:
#       LAN only (no Cloudflare/ngrok tunnel), port 1234, keep the Mac awake, no auto-update,
#       no Find My, Private API off.
#   the `password` row in its config.db
#       Written with sqlite3 while BlueBubbles is stopped. Not through the YAML or argv:
#       BlueBubbles logs every value it applies from those, in plaintext.
#   LaunchAgent com.bluebubbles.server
#       Start at login, restart on crash. The same plist BlueBubbles writes itself for its
#       "launch agent" start method, which the YAML selects, so the two never disagree.
#   LaunchAgent com.sargeant.messages-keepalive
#       Every 5 minutes: close Messages' windows and ask it for its chat count. On Apple
#       Silicon an idle Messages stops writing chat.db, and an open Messages window holds
#       webhooks back until someone clicks a chat (BlueBubbles issue #750).
#
# The password comes from the one-time seed install.sh staged, removed once applied. Without
# a seed, the password already in config.db is kept.

set -euo pipefail

PORT=1234
APP=/Applications/BlueBubbles.app
EXE="$APP/Contents/MacOS/BlueBubbles"
SEED=/Users/Shared/bluebubbles/password
DB="$HOME/Library/Application Support/bluebubbles-server/config.db"
AGENTS="$HOME/Library/LaunchAgents"
BB_LABEL=com.bluebubbles.server
KA_LABEL=com.sargeant.messages-keepalive
DOMAIN="gui/$(id -u)"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run this as the bot user, not root"
if [[ " $(id -Gn) " == *" admin "* ]]; then
  die "$(id -un) is an admin. BlueBubbles serves the Messages, Contacts and Find My of the user it runs as, so run this in the dedicated Standard user's login (nievah)"
fi
[ -x "$EXE" ] || die "$APP is missing; run install.sh from an admin login first"
launchctl print "$DOMAIN" >/dev/null 2>&1 \
  || die "no login session for $(id -un); run this from Terminal inside its login, not over ssh"

db_password() { sqlite3 "$DB" "SELECT value FROM config WHERE name = 'password';" 2>/dev/null || true; }
bb_running() { pgrep -U "$(id -u)" -f "^$EXE" >/dev/null 2>&1; }
job_loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }

start_job() {  # start_job <label>: (re)load a LaunchAgent so it picks up its plist
  if job_loaded "$1"; then launchctl bootout "$DOMAIN/$1" 2>/dev/null || true; fi
  launchctl enable "$DOMAIN/$1"
  launchctl bootstrap "$DOMAIN" "$AGENTS/$1.plist"
}

stop_bb() {  # launchd's SIGTERM first; pkill covers a copy someone started by hand
  if job_loaded "$BB_LABEL"; then launchctl bootout "$DOMAIN/$BB_LABEL" 2>/dev/null || true; fi
  for _ in $(seq 1 15); do bb_running || return 0; sleep 1; done
  pkill -TERM -U "$(id -u)" -f "^$EXE" 2>/dev/null || true
  for _ in $(seq 1 15); do bb_running || return 0; sleep 1; done
  die "BlueBubbles did not quit; quit it from its menu bar icon and rerun"
}

api() {  # api <path>: GET /api/v1/<path>. The password goes through curl's stdin, not argv.
  printf 'url = "http://127.0.0.1:%s/api/v1/%s?password=%s"\n' "$PORT" "$1" "$PW" \
    | curl -fsS --max-time 5 --config -
}

json() { plutil -extract "$1" raw -o - - 2>/dev/null || echo "?"; }  # json <keypath> < body

# --- password -----------------------------------------------------------------------------
PW=""
if [ -r "$SEED" ]; then
  PW="$(tr -d '\r\n' < "$SEED")"
  [[ "$PW" =~ ^[A-Za-z0-9._~-]{16,}$ ]] || die "$SEED must hold 16+ URL-safe characters"
elif [ -z "$(db_password)" ]; then
  die "no password: $SEED is missing and BlueBubbles has none. Rerun install.sh from an admin login"
fi

# --- settings -----------------------------------------------------------------------------
umask 077
cat > "$HOME/bluebubbles.yml" <<'YAML'
# Written by infra scripts/macOS/bluebubbles/configure-user.sh. BlueBubbles applies these at
# every start and persists them, so changing one in its UI lasts only until the next start.
tutorial_is_done: true
socket_port: 1234
proxy_service: lan-url
auto_caffeinate: true
auto_start_method: launch-agent
start_minimized: true
check_for_updates: false
auto_install_updates: false
open_findmy_on_startup: false
enable_private_api: false
YAML
note "wrote ~/bluebubbles.yml"

mkdir -p "$AGENTS" "$HOME/Library/Logs"
cat > "$AGENTS/$BB_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.BlueBubbles.BlueBubbles-Server</string>
    </array>
    <key>Label</key>
    <string>$BB_LABEL</string>
    <key>Program</key>
    <string>$EXE</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

cat > "$AGENTS/$KA_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$KA_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/osascript</string>
        <string>-e</string>
        <string>tell application "Messages"</string>
        <string>-e</string>
        <string>close every window</string>
        <string>-e</string>
        <string>count of chats</string>
        <string>-e</string>
        <string>end tell</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/messages-keepalive.log</string>
</dict>
</plist>
PLIST
plutil -lint -s "$AGENTS/$BB_LABEL.plist" "$AGENTS/$KA_LABEL.plist"
note "wrote LaunchAgents $BB_LABEL and $KA_LABEL"

# --- apply the password -------------------------------------------------------------------
if [ ! -f "$DB" ]; then
  # BlueBubbles creates config.db with its defaults on first start, before it applies the
  # YAML or opens its API. The API refuses every call while the password is empty.
  note "first start, so BlueBubbles creates its config database"
  start_job "$BB_LABEL"
  for _ in $(seq 1 90); do
    [ "$(sqlite3 "$DB" "SELECT count(*) FROM config WHERE name = 'password';" 2>/dev/null)" = 1 ] && break
    sleep 1
  done
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM config WHERE name = 'password';" 2>/dev/null)" = 1 ] \
    || die "BlueBubbles did not create $DB within 90s; see ~/Library/Logs/bluebubbles-server/main.log"
fi

stop_bb
if [ -n "$PW" ]; then
  # printf is a builtin and the SQL goes through a pipe, so the value is in no argv or file.
  printf "INSERT INTO config (name, value) VALUES ('password', '%s')
          ON CONFLICT (name) DO UPDATE SET value = excluded.value;\n" "$PW" | sqlite3 "$DB"
  [ "$(db_password)" = "$PW" ] || die "the password did not persist in $DB"
  rm -f "$SEED" 2>/dev/null || note "could not remove $SEED; remove it from an admin login"
  note "password set"
else
  PW="$(db_password)"
  note "no seed; kept the existing password"
fi

start_job "$BB_LABEL"
start_job "$KA_LABEL"

# --- verify -------------------------------------------------------------------------------
note "waiting for the API on :$PORT"
for _ in $(seq 1 60); do api ping >/dev/null 2>&1 && break; sleep 1; done
api ping >/dev/null || die "no answer on :$PORT; see ~/Library/Logs/bluebubbles-server/main.log"

check_db_access() { api chat/count >/dev/null 2>&1; }
if ! check_db_access; then
  cat <<'EOF'

BlueBubbles cannot read the Messages database yet. In the System Settings windows opening now,
turn BlueBubbles on under BOTH Full Disk Access and Accessibility (click + and pick
/Applications/BlueBubbles.app if it is not listed). An admin name and password is needed.
EOF
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  if [ -t 0 ]; then
    read -r -p "Press Enter once both are on... " _
    stop_bb
    start_job "$BB_LABEL"
    for _ in $(seq 1 60); do check_db_access && break; sleep 1; done
  fi
  check_db_access || die "still no access to the Messages database; grant it and rerun this script"
fi

INFO="$(api server/info)"
LAN_IP="$(ipconfig getifaddr en0 || true)"
[ -n "$LAN_IP" ] || LAN_IP="<LAN IP>"
cat <<EOF

BlueBubbles is up for $(id -un):
  version        $(printf '%s' "$INFO" | json data.server_version)
  macOS          $(printf '%s' "$INFO" | json data.os_version)
  iMessage as    $(printf '%s' "$INFO" | json data.detected_imessage)
  private API    $(printf '%s' "$INFO" | json data.private_api)
  proxy          $(printf '%s' "$INFO" | json data.proxy_service)
  URL for Hermes http://$LAN_IP:$PORT

Check "iMessage as" is the bot's Apple Account, not a person's. Click Allow/OK on any
prompt this login shows: the firewall, and "osascript" or "BlueBubbles" wanting to control
Messages. Then switch back to your own login and leave this one logged in.
EOF
