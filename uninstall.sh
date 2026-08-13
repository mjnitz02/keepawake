#!/bin/bash
#
# uninstall.sh: remove keepawake and restore stock sleep behavior.
#
set -u

LABEL="local.keepawake"
NUDGE_LABEL="local.keepawake.nudge"

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh must run as root:  sudo ./uninstall.sh" >&2
  exit 1
fi

GUI_UID="$(/usr/bin/stat -f%u /dev/console 2>/dev/null || echo 0)"
[ "${GUI_UID:-0}" = "0" ] && GUI_UID="${SUDO_UID:-0}"

echo "==> Removing keepawake"

# Booting the daemon out makes it restore SleepDisabled=0 on its way down,
# but set it explicitly too in case the daemon already died.
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 1
/usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
echo "  sleep re-enabled (SleepDisabled=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/{print $2; exit}'))"

if [ "${GUI_UID:-0}" != "0" ]; then
  /bin/launchctl bootout "gui/$GUI_UID/$NUDGE_LABEL" 2>/dev/null || true
fi
/bin/rm -f "/Library/LaunchAgents/$NUDGE_LABEL.plist"

/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist"
/bin/rm -f /usr/local/libexec/keepawake-daemon
/bin/rm -f /usr/local/libexec/keepawake-nudge-agent
/bin/rm -f /usr/local/libexec/keepawake-nudge
/bin/rm -f /usr/local/libexec/.keepawake-nudge.srcsha
/bin/rm -f /usr/local/bin/keepawake
/bin/rm -rf /usr/local/var/keepawake
echo "  removed daemon, agent, helper, CLI, and state"

echo
echo "Logs left in place at /usr/local/var/log/keepawake.log (delete manually if you want)."
echo "The nudge agent's log and report live in the user's home:"
echo "  ~/Library/Logs/keepawake-nudge.log"
echo "  ~/Library/Application Support/keepawake/"
echo
echo "macOS keeps the Accessibility entry for the removed helper. Clear it in"
echo "System Settings > Privacy & Security > Accessibility if you want it gone."
