#!/bin/bash
#
# uninstall.sh: remove keepawake and restore stock sleep behavior.
#
set -u

LABEL="local.keepawake"

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh must run as root:  sudo ./uninstall.sh" >&2
  exit 1
fi

echo "==> Removing keepawake"

# Booting the daemon out makes it restore SleepDisabled=0 on its way down,
# but set it explicitly too in case the daemon already died.
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 1
/usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
echo "  sleep re-enabled (SleepDisabled=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/{print $2; exit}'))"

/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist"
/bin/rm -f /usr/local/libexec/keepawake-daemon
/bin/rm -f /usr/local/bin/keepawake
/bin/rm -rf /usr/local/var/keepawake
echo "  removed daemon, CLI, and state"

echo
echo "Logs left in place at /usr/local/var/log/keepawake.log (delete manually if you want)."
