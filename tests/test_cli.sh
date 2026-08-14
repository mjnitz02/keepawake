#!/bin/bash
#
# CLI: duration parsing, JSON reading, and the status rendering for every state
# the nudge switch can be in.
#
# Status rendering is worth testing precisely because it is the part that lies
# most expensively. A dead agent shown as healthy, or "on" shown while every
# nudge is silently discarded, would send someone home trusting a machine that
# is about to lock them out.

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
export KEEPAWAKE_LOG_FILE="$D/keepawake.log"
export HOME="$D/home"
export NO_COLOR=1

NOW=$(date +%s)

# Load the CLI as a library for the pure functions.
(
  export KEEPAWAKE_LIB_ONLY=1
  # shellcheck source=/dev/null
  . "$ROOT/bin/keepawake"

  suite "duration parsing"
  assert_eq "30"    "$(parse_duration 30s)"      "30s"
  assert_eq "2700"  "$(parse_duration 45m)"      "45m"
  assert_eq "21600" "$(parse_duration 6h)"       "6h"
  assert_eq "25200" "$(parse_duration 7h)"       "7h, the firefighting evening"
  assert_eq "5400"  "$(parse_duration 90)"       "a bare number means minutes"
  assert_eq "0"     "$(parse_duration forever)"  "forever means no expiry"
  assert_eq "0"     "$(parse_duration none)"     "none is a synonym"
  assert_fails "'0' is rejected as ambiguous"  parse_duration 0
  assert_fails "'bogus' is rejected"           parse_duration bogus
  assert_fails "'5weeks' is rejected"          parse_duration 5weeks
  assert_fails "'-5m' is rejected"             parse_duration -5m
  assert_fails "an empty duration is rejected" parse_duration ""

  suite "duration formatting"
  assert_eq "45s"   "$(human_dur 45)"    "seconds"
  assert_eq "12m"   "$(human_dur 720)"   "minutes"
  assert_eq "5h58m" "$(human_dur 21480)" "hours and minutes"
  assert_eq "0s"    "$(human_dur 0)"     "zero"
  assert_eq "0s"    "$(human_dur -30)"   "a negative value clamps to zero"
  assert_eq "1h0m"  "$(human_dur 3600)"  "exactly an hour"

  suite "JSON reading"
  write_status_json "$D" on true ok on true ok $((NOW + 60)) "" 0 "$NOW"
  assert_eq "on"   "$(json_get desired)"      "reads a string value"
  assert_eq "true" "$(json_get nudge_active)" "reads a boolean"
  assert_eq "80"   "$(json_get battery)"      "reads a number"
  assert_eq "$NOW" "$(json_get updated_epoch)" "reads the last field before the closing brace"
  assert_eq "ok"   "$(json_get reason)"       "'reason' does not match 'nudge_reason'"
  assert_eq "on"   "$(json_get desired)"      "'desired' does not match 'nudge_desired'"
  assert_eq "2026-08-13 11:39:11" "$(json_get updated)" "a value containing a space survives"

  summary
) || exit 1

# ---------------------------------------------------------------------------
# Full status rendering, driven through the real entry point.
run_status() { "$ROOT/bin/keepawake" status 2>/dev/null | grep -E '^  (nudge|agent) ' || true; }

# Reset the counters for the out-of-subshell half of this suite.
PASS=0; FAIL=0

suite "status rendering: nudge states"

# 5h58m30s, deliberately off the minute boundary: an expiry of exactly 5h58m
# would render as 5h57m the moment a second elapsed between writing the fixture
# and reading it, and that would be the test being flaky, not the code.
write_status_json "$D" on true ok on true ok $((NOW + 21510)) "" 0 "$NOW"
write_agent_json  "$D" true 312 $((NOW - 180)) 7 "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "idle 5m"          "shows how long the Mac has been idle"
assert_contains "$OUT" "nudged 3m ago (7)" "shows the last nudge and the count"
assert_contains "$OUT" "5h58m left"        "shows the time until auto-off"
assert_contains "$OUT" "Accessibility granted" "confirms the permission is in place"

write_status_json "$D" on true ok on true ok 0 "" 0 "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "no expiry" "an expiry of 0 renders as no expiry"

# The failure this whole design is built to make visible.
write_agent_json "$D" false 640 0 0 "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "Accessibility not granted"      "an ungranted agent is called out"
assert_contains "$OUT" "nudges will silently do nothing" "and the consequence is spelled out"

write_agent_json "$D" true 300 $((NOW - 60)) 3 $((NOW - 900))
OUT="$(run_status)"
assert_contains "$OUT" "not running"      "a stale agent report reads as not running"
assert_not_contains "$OUT" "idle 5m"      "and its stale idle time is not shown as live"
assert_not_contains "$OUT" "nudged 15m ago" "nor its stale nudge time"

write_status_json "$D" on true ok off false off 0 no-ac $((NOW - 720)) "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "auto-off: no-ac, 12m ago" "an auto-off explains itself"
assert_not_contains "$OUT" "agent " "the agent line is hidden when nudge is off"

write_status_json "$D" on true ok off false off 0 "" 0 "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "nudge      off" "a never-used nudge just reads off"

write_status_json "$D" on true ok on false stopped $((NOW + 600)) "" 0 "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "the daemon is not running it (stopped)" \
  "switched on but not running says so"

suite "status rendering: no agent report at all"
rm -f "$HOME/Library/Application Support/keepawake/agent.json"
write_status_json "$D" on true ok on true ok 0 "" 0 "$NOW"
OUT="$(run_status)"
assert_contains "$OUT" "not running" "a missing agent report reads as not running"

# ---------------------------------------------------------------------------
suite "the nudge switch file"

# The CLI waits for the daemon to acknowledge, and no daemon runs here, so cap
# each call. The switch file is written before the wait either way.
setn() { timeout 12 "$ROOT/bin/keepawake" nudge "$@" >/dev/null 2>&1 || true; }

setn on 7h
V="$(cat "$KEEPAWAKE_STATE_DIR/nudge")"
assert_eq "on" "${V%% *}" "'nudge on 7h' switches on"
EXP="${V#on }"
DELTA=$((EXP - NOW))
if [ "$DELTA" -ge 25190 ] && [ "$DELTA" -le 25260 ]; then
  ok "'nudge on 7h' sets an expiry 7 hours out"
else
  no "'nudge on 7h' sets an expiry 7 hours out" "~25200s" "${DELTA}s"
fi

setn on forever
assert_eq "on 0" "$(cat "$KEEPAWAKE_STATE_DIR/nudge")" "'nudge on forever' sets no expiry"

setn off
assert_eq "off" "$(cat "$KEEPAWAKE_STATE_DIR/nudge")" "'nudge off' switches off"

OUT="$("$ROOT/bin/keepawake" nudge on 5weeks 2>&1 || true)"
assert_contains "$OUT" "could not read duration" "a bad duration is rejected with a hint"
assert_eq "off" "$(cat "$KEEPAWAKE_STATE_DIR/nudge")" "and a rejected duration does not switch anything on"

OUT="$("$ROOT/bin/keepawake" nudge frobnicate 2>&1 || true)"
assert_contains "$OUT" "unknown nudge command" "an unknown subcommand is rejected"

suite "help"
OUT="$("$ROOT/bin/keepawake" --help 2>&1)"
assert_contains "$OUT" "nudge on [DURATION]" "help documents nudge on"
assert_contains "$OUT" "nudge grant"         "help documents nudge grant"
assert_contains "$OUT" "never turns itself on" "help states the no-auto-enable rule"

summary
