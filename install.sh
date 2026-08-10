#!/bin/bash
#
# install.sh: install the keepawake daemon and CLI.
#
#   sudo ./install.sh
#
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.keepawake"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATE_DIR="/usr/local/var/keepawake"
LOG_DIR="/usr/local/var/log"

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh must run as root:  sudo ./install.sh" >&2
  exit 1
fi

say() { printf '  %s\n' "$*"; }

echo "==> Installing keepawake"

# --- 1. directories ----------------------------------------------------------
/bin/mkdir -p /usr/local/bin /usr/local/libexec "$STATE_DIR" "$LOG_DIR"

# --- 2. daemon + CLI ---------------------------------------------------------
/usr/bin/install -o root -g wheel -m 755 "$SRC/libexec/keepawake-daemon" /usr/local/libexec/keepawake-daemon
/usr/bin/install -o root -g wheel -m 755 "$SRC/bin/keepawake" /usr/local/bin/keepawake
say "installed /usr/local/libexec/keepawake-daemon"
say "installed /usr/local/bin/keepawake"

# --- 3. state + config -------------------------------------------------------
# The state file is group-writable by 'admin' so `keepawake on|off` works without
# sudo. The daemon only ever reads on/off from it, so the blast radius is "an
# admin user can toggle sleep", which an admin can already do with pmset.
[ -f "$STATE_DIR/state" ] || printf 'off' >"$STATE_DIR/state"
/usr/sbin/chown root:admin "$STATE_DIR/state"
/bin/chmod 664 "$STATE_DIR/state"

if [ ! -f "$STATE_DIR/config" ]; then
  /bin/cat >"$STATE_DIR/config" <<'EOF'
# keepawake daemon config. Restart the daemon after editing:
#   sudo launchctl kickstart -k system/local.keepawake

INTERVAL=2        # seconds between checks (how fast we undo an external reset)
BATT_FLOOR=30     # release the block if battery drops below this, even on AC
THERM_FLOOR=50    # release the block if CPU speed limit falls below this %
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
fi
say "state dir $STATE_DIR"

# --- 4. launchd daemon -------------------------------------------------------
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
  sleep 1
fi
/usr/bin/install -o root -g wheel -m 644 "$SRC/launchd/$LABEL.plist" "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
say "loaded launchd daemon $LABEL"

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

echo
echo "Done. Try:"
echo "  keepawake status     # one-shot state and which guard is active"
echo "  keepawake watch      # live view, Ctrl-C to stop"
echo "  keepawake why        # what the Mac last slept for"
echo "  keepawake off        # hand sleep back to macOS"
