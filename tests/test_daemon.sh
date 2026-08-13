#!/bin/bash
#
# Daemon logic: the guard decision tables, the nudge state file parser, and the
# latch-off behavior.
#
# What this cannot cover: whether pmset actually flips SleepDisabled, and
# whether launchd keeps the daemon alive. Both need root and a real Mac, so
# install.sh verifies the first one at install time instead.

# These suites set variables that are read by the code they source (the daemon
# functions) or by lib.sh, so shellcheck cannot see the use. Scoped once here
# rather than sprinkling per-line directives through every fixture.
# shellcheck disable=SC2034

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="$(cd .. && pwd)"
D="$(make_state_dir)"
trap 'rm -rf "$D"' EXIT

export KEEPAWAKE_STATE_DIR="$D/state"
export KEEPAWAKE_LOG_FILE="$D/daemon.log"
export KEEPAWAKE_LIB_ONLY=1

# shellcheck source=/dev/null
. "$ROOT/libexec/keepawake-daemon"

NF="$KEEPAWAKE_STATE_DIR/nudge"
NOW=$(date +%s)

# ---------------------------------------------------------------------------
suite "nudge switch file parsing"

parse() { printf '%s' "$1" >"$NF"; read_nudge; }

parse 'off';             assert_eq "off" "$NUDGE_DESIRED" "'off' reads as off"
parse 'on 0';            assert_eq "on:0" "$NUDGE_DESIRED:$NUDGE_EXPIRES" "'on 0' is on with no expiry"
parse 'on 1786000000';   assert_eq "on:1786000000" "$NUDGE_DESIRED:$NUDGE_EXPIRES" "'on <epoch>' keeps the expiry"
parse 'on';              assert_eq "on:0" "$NUDGE_DESIRED:$NUDGE_EXPIRES" "bare 'on' is on with no expiry"
parse 'on garbage';      assert_eq "on:0" "$NUDGE_DESIRED:$NUDGE_EXPIRES" "unparseable expiry degrades to no expiry"
parse '';                assert_eq "off" "$NUDGE_DESIRED" "empty file reads as off"
parse $'on 123\n';       assert_eq "on:123" "$NUDGE_DESIRED:$NUDGE_EXPIRES" "trailing newline is tolerated"
parse 'ON';              assert_eq "off" "$NUDGE_DESIRED" "anything but exactly 'on' is off"

rm -f "$NF"; read_nudge
assert_eq "off" "$NUDGE_DESIRED" "missing file reads as off"
printf 'off' >"$NF"

# ---------------------------------------------------------------------------
suite "sleep block guards"

# The daemon caches the thermal reading per pass. Stub it so tests never depend
# on how warm the machine running them happens to be.
THERM_CACHE=1
BATT_FLOOR=30

decide() { DESIRED=$1; AC=$2; BATT=$3; THERM_CACHE=$4; decide_sleep_block; printf '%s/%s' "$REASON" "$WANT"; }

assert_eq "ok/1"          "$(decide on  1 80 1)" "on + AC + charged + cool  -> hold the flag"
assert_eq "off/0"         "$(decide off 1 80 1)" "switched off             -> release"
assert_eq "no-ac/0"       "$(decide on  0 80 1)" "on battery               -> release"
assert_eq "battery-low/0" "$(decide on  1 20 1)" "below the battery floor  -> release"
assert_eq "thermal/0"     "$(decide on  1 80 0)" "thermally throttled      -> release"
assert_eq "off/0"         "$(decide off 0 10 0)" "off wins over every guard"
assert_eq "no-ac/0"       "$(decide on  0 10 0)" "AC is checked before battery"
assert_eq "ok/1"          "$(decide on  1 30 1)" "battery exactly at the floor still holds"
assert_eq "battery-low/0" "$(decide on  1 29 1)" "one below the floor releases"

# ---------------------------------------------------------------------------
suite "nudge guards"

nd() { NUDGE_DESIRED=$1; NUDGE_EXPIRES=$2; AC=$3; BATT=$4; THERM_CACHE=$5; decide_nudge; printf '%s' "$NUDGE_VERDICT"; }

assert_eq "off"         "$(nd off 0 1 80 1)"            "switched off"
assert_eq "ok"          "$(nd on  0 1 80 1)"            "on + AC + charged + cool"
assert_eq "ok"          "$(nd on  $((NOW+3600)) 1 80 1)" "expiry in the future"
assert_eq "expired"     "$(nd on  $((NOW-1)) 1 80 1)"    "expiry in the past"
assert_eq "no-ac"       "$(nd on  0 0 80 1)"            "on battery"
assert_eq "battery-low" "$(nd on  0 1 20 1)"            "below the battery floor"
assert_eq "thermal"     "$(nd on  0 1 80 0)"            "thermally throttled"
assert_eq "expired"     "$(nd on  $((NOW-1)) 0 20 0)"   "expiry is checked before the power guards"
assert_eq "off"         "$(nd off $((NOW-1)) 0 20 0)"   "off short-circuits everything"

# ---------------------------------------------------------------------------
suite "nudge latches off and stays off"

# This is the property the whole design rests on: a guard must not merely hold
# nudging back, it must switch it off, so finding a power outlet later does not
# restart something the user only asked for once.
AC=1; BATT=80
printf 'on %s' "$((NOW + 3600))" >"$NF"
read_nudge
assert_eq "on" "$NUDGE_DESIRED" "starts on"

AC=0
nudge_latch_off no-ac
assert_eq "off" "$(cat "$NF")" "unplugging writes 'off' to the switch file"
assert_eq "off" "$NUDGE_DESIRED" "in-memory state follows"

AC=1
read_nudge
assert_eq "off" "$NUDGE_DESIRED" "replugging does NOT turn nudging back on"

read_nudge_last
assert_eq "no-ac" "$NUDGE_OFF_REASON" "the reason is recorded for status"
[ "$NUDGE_OFF_EPOCH" -ge "$NOW" ] \
  && ok "the time is recorded for status" \
  || no "the time is recorded for status" ">= $NOW" "$NUDGE_OFF_EPOCH"

assert_contains "$(cat "$KEEPAWAKE_LOG_FILE")" "nudge switched OFF automatically (reason=no-ac" \
  "the auto-off is logged"

# Every guard latches the same way.
for guard in expired battery-low thermal; do
  printf 'on 0' >"$NF"
  nudge_latch_off "$guard"
  assert_eq "off" "$(cat "$NF")" "$guard also latches the switch off"
  read_nudge_last
  assert_eq "$guard" "$NUDGE_OFF_REASON" "$guard is recorded as the reason"
done

# ---------------------------------------------------------------------------
suite "status.json is well formed"

DESIRED=on; AC=1; BATT=80
NUDGE_DESIRED=on; NUDGE_REASON=ok; NUDGE_EXPIRES=$((NOW + 60))
NUDGE_OFF_REASON=""; NUDGE_OFF_EPOCH=0
write_status "true" "ok" 1

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint -s - <"$KEEPAWAKE_STATE_DIR/status.json" >/dev/null 2>&1 \
     || python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$KEEPAWAKE_STATE_DIR/status.json" 2>/dev/null; then
    ok "status.json parses as JSON"
  else
    no "status.json parses as JSON" "valid JSON" "$(cat "$KEEPAWAKE_STATE_DIR/status.json")"
  fi
fi

S="$(cat "$KEEPAWAKE_STATE_DIR/status.json")"
assert_contains "$S" '"nudge_active": true'   "nudge_active is true when the reason is ok"
assert_contains "$S" '"nudge_desired": "on"'  "nudge_desired is published"

NUDGE_REASON=no-ac
write_status "true" "ok" 1
assert_contains "$(cat "$KEEPAWAKE_STATE_DIR/status.json")" '"nudge_active": false' \
  "nudge_active is false for any reason but ok"

summary
