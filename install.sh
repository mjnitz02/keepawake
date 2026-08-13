#!/bin/bash
#
# install.sh: install the keepawake daemon and CLI.
#
#   sudo ./install.sh
#
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.keepawake"
NUDGE_LABEL="local.keepawake.nudge"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
AGENT_PLIST="/Library/LaunchAgents/$NUDGE_LABEL.plist"
STATE_DIR="/usr/local/var/keepawake"
LOG_DIR="/usr/local/var/log"
HELPER="/usr/local/libexec/keepawake-nudge"
HELPER_SRC="$SRC/src/keepawake-nudge.c"
HELPER_STAMP="/usr/local/libexec/.keepawake-nudge.srcsha"

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh must run as root:  sudo ./install.sh" >&2
  exit 1
fi

# The nudge agent runs in the GUI session, so the installer needs to know whose
# session that is. /dev/console is owned by the user actually logged in at the
# screen, which is more reliable than SUDO_USER when this is run over ssh.
GUI_UID="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || echo 0)"
[ "${GUI_UID:-0}" = "0" ] && GUI_UID="${SUDO_UID:-0}"

say() { printf '  %s\n' "$*"; }

echo "==> Installing keepawake"

# --- 1. directories ----------------------------------------------------------
/bin/mkdir -p /usr/local/bin /usr/local/libexec "$STATE_DIR" "$LOG_DIR"

# --- 2. daemon + CLI ---------------------------------------------------------
/usr/bin/install -o root -g wheel -m 755 "$SRC/libexec/keepawake-daemon" /usr/local/libexec/keepawake-daemon
/usr/bin/install -o root -g wheel -m 755 "$SRC/libexec/keepawake-nudge-agent" /usr/local/libexec/keepawake-nudge-agent
/usr/bin/install -o root -g wheel -m 755 "$SRC/bin/keepawake" /usr/local/bin/keepawake
say "installed /usr/local/libexec/keepawake-daemon"
say "installed /usr/local/libexec/keepawake-nudge-agent"
say "installed /usr/local/bin/keepawake"

# --- 2b. nudge helper --------------------------------------------------------
# Compiled here rather than shipped as a binary so there is nothing unreadable
# in the repo. Skipped when the source has not changed, and that matters more
# than build time: macOS ties the Accessibility grant to the binary's hash, so
# a needless rebuild would silently revoke the permission nudge mode depends on.
NEW_SHA="$(/usr/bin/shasum -a 256 "$HELPER_SRC" | /usr/bin/awk '{print $1}')"
OLD_SHA="$( [ -r "$HELPER_STAMP" ] && /bin/cat "$HELPER_STAMP" || echo none)"

if [ -x "$HELPER" ] && [ "$NEW_SHA" = "$OLD_SHA" ]; then
  say "nudge helper unchanged, kept existing build (Accessibility grant survives)"
elif ! command -v cc >/dev/null 2>&1; then
  say "WARNING: no compiler found; nudge mode unavailable"
  say "         install the Xcode command line tools: xcode-select --install"
else
  TMP_BIN="$(/usr/bin/mktemp -t keepawake-nudge)"
  if /usr/bin/cc -O2 -Wall -o "$TMP_BIN" "$HELPER_SRC" -framework ApplicationServices 2>/dev/null; then
    # Ad-hoc signature so the binary has a stable identity for TCC to record.
    /usr/bin/codesign -f -s - "$TMP_BIN" >/dev/null 2>&1 || true
    /usr/bin/install -o root -g wheel -m 755 "$TMP_BIN" "$HELPER"
    printf '%s' "$NEW_SHA" >"$HELPER_STAMP"
    /bin/chmod 644 "$HELPER_STAMP"
    say "built $HELPER"
    [ "$OLD_SHA" = "none" ] || say "NOTE: helper rebuilt, so Accessibility must be granted again"
  else
    say "WARNING: nudge helper failed to compile; nudge mode unavailable"
  fi
  /bin/rm -f "$TMP_BIN"
fi

# --- 3. state + config -------------------------------------------------------
# The state file is group-writable by 'admin' so `keepawake on|off` works without
# sudo. The daemon only ever reads on/off from it, so the blast radius is "an
# admin user can toggle sleep", which an admin can already do with pmset.
[ -f "$STATE_DIR/state" ] || printf 'off' >"$STATE_DIR/state"
/usr/sbin/chown root:admin "$STATE_DIR/state"
/bin/chmod 664 "$STATE_DIR/state"

# Nudge always starts off. Reinstalling is not a reason to start moving
# someone's cursor, and this mode has no automatic enablement by design.
printf 'off' >"$STATE_DIR/nudge"
/usr/sbin/chown root:admin "$STATE_DIR/nudge"
/bin/chmod 664 "$STATE_DIR/nudge"

if [ ! -f "$STATE_DIR/config" ]; then
  /bin/cat >"$STATE_DIR/config" <<'EOF'
# keepawake daemon config. Restart the daemon after editing:
#   sudo launchctl kickstart -k system/local.keepawake

INTERVAL=2        # seconds between checks (how fast we undo an external reset)
BATT_FLOOR=30     # release the block if battery drops below this, even on AC
THERM_FLOOR=50    # release the block if CPU speed limit falls below this %

# Nudge mode. Read by the user-session agent; restart it after editing:
#   launchctl kickstart -k gui/$(id -u)/local.keepawake.nudge
#
# NUDGE_IDLE must stay comfortably under the screen saver's idle time, which on
# a managed Mac you do not control. Check yours with:
#   defaults read /Library/Managed\ Preferences/com.apple.screensaver idleTime
NUDGE_IDLE=300              # nudge once the Mac has been idle this many seconds
NUDGE_POLL=5                # seconds between agent checks
NUDGE_DEFAULT_DURATION=8h   # how long `keepawake nudge on` runs with no argument
EOF
  /usr/sbin/chown root:wheel "$STATE_DIR/config"
  /bin/chmod 644 "$STATE_DIR/config"
else
  # An existing config overrides the daemon defaults, so a stale generated value
  # would silently defeat a changed default. Only migrate a line still matching
  # what a previous installer wrote, never a value that was edited by hand.
  if /usr/bin/grep -q '^INTERVAL=5 *#' "$STATE_DIR/config"; then
    /usr/bin/sed -i '' 's/^INTERVAL=5 *#/INTERVAL=2        #/' "$STATE_DIR/config"
    say "migrated config: INTERVAL 5 -> 2 (tighter window when unplugging)"
  fi
  # Append the nudge keys to a config written before nudge mode existed. The
  # code defaults to these values anyway; writing them makes the knobs findable.
  if ! /usr/bin/grep -q '^NUDGE_IDLE=' "$STATE_DIR/config"; then
    /bin/cat >>"$STATE_DIR/config" <<'EOF'

# Nudge mode. Read by the user-session agent; restart it after editing:
#   launchctl kickstart -k gui/$(id -u)/local.keepawake.nudge
#
# NUDGE_IDLE must stay comfortably under the screen saver's idle time.
NUDGE_IDLE=300              # nudge once the Mac has been idle this many seconds
NUDGE_POLL=5                # seconds between agent checks
NUDGE_DEFAULT_DURATION=8h   # how long `keepawake nudge on` runs with no argument
EOF
    say "migrated config: added nudge settings"
  fi
fi
say "state dir $STATE_DIR"

# A NUDGE_IDLE at or above the enforced screen saver timeout would never win the
# race, and the symptom (screen saver still starts, occasionally) is miserable
# to debug. Check it here where it is cheap to notice.
SS_IDLE="$(/usr/bin/defaults read "/Library/Managed Preferences/com.apple.screensaver" idleTime 2>/dev/null || true)"
NUDGE_IDLE_CFG="$(/usr/bin/sed -n 's/^NUDGE_IDLE=\([0-9]*\).*/\1/p' "$STATE_DIR/config" | /usr/bin/head -1)"

is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

if is_number "$SS_IDLE" && is_number "$NUDGE_IDLE_CFG"; then
  if [ "$NUDGE_IDLE_CFG" -ge "$SS_IDLE" ]; then
    say "WARNING: NUDGE_IDLE=$NUDGE_IDLE_CFG is not below the enforced screen saver"
    say "         idleTime=$SS_IDLE. Lower NUDGE_IDLE or the screen saver still starts."
  else
    say "screen saver idleTime=${SS_IDLE}s, nudging at ${NUDGE_IDLE_CFG}s idle"
  fi
fi

# --- 4. launchd daemon -------------------------------------------------------
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
  sleep 1
fi
/usr/bin/install -o root -g wheel -m 644 "$SRC/launchd/$LABEL.plist" "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
say "loaded launchd daemon $LABEL"

# --- 4b. nudge LaunchAgent ---------------------------------------------------
/bin/mkdir -p /Library/LaunchAgents
/usr/bin/install -o root -g wheel -m 644 "$SRC/launchd/$NUDGE_LABEL.plist" "$AGENT_PLIST"

if [ "${GUI_UID:-0}" != "0" ]; then
  /bin/launchctl bootout "gui/$GUI_UID/$NUDGE_LABEL" 2>/dev/null || true
  if /bin/launchctl bootstrap "gui/$GUI_UID" "$AGENT_PLIST" 2>/dev/null; then
    say "loaded launch agent $NUDGE_LABEL in gui/$GUI_UID"
  else
    say "installed $NUDGE_LABEL; it will load at next login"
  fi
else
  say "installed $NUDGE_LABEL; no GUI session found, it will load at next login"
fi

# --- 5. verify ---------------------------------------------------------------
echo
echo "==> Verifying that the kernel accepts the sleep block"
printf 'on' >"$STATE_DIR/state"
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  flag="$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/{print $2; exit}')"
  if [ "${flag:-0}" = "1" ]; then ok=1; break; fi
done

if [ "$ok" -eq 1 ]; then
  echo "  OK. SleepDisabled=1. Clamshell sleep is blocked while on AC power."
else
  echo "  FAILED. SleepDisabled never flipped to 1."
  echo "  Something refused the change (an MDM restriction, or you're not on AC)."
  echo "  Check:  keepawake status   and   tail /usr/local/var/log/keepawake.log"
fi

if [ -x "$HELPER" ]; then
  echo
  echo "==> Nudge mode needs one manual permission"
  echo "  Posting a mouse event requires Accessibility, granted per binary."
  echo "  Without it macOS accepts the event and discards it, with no error,"
  echo "  so this is worth doing before you rely on it:"
  echo
  echo "    keepawake nudge grant"
  echo
  echo "  then press '+', hit Cmd+Shift+G, and paste:"
  echo "    $HELPER"
  echo
  echo "  Verify with 'keepawake nudge status'. The agent reports whether a"
  echo "  nudge actually moved the idle clock, not just whether the API agreed."
fi

echo
echo "Done. Try:"
echo "  keepawake status         # one-shot state and which guard is active"
echo "  keepawake watch          # live view, Ctrl-C to stop"
echo "  keepawake why            # what the Mac last slept for"
echo "  keepawake off            # hand sleep back to macOS"
echo "  keepawake nudge on 7h    # also keep the screen saver away for 7 hours"
echo "  keepawake nudge status   # nudge switch, idle time, Accessibility"
