#!/bin/bash
#
# Nudge agent: when it moves the cursor and, more importantly, when it does not.
#
# The agent is driven by a stub helper so the suite never needs a GUI session,
# a granted Accessibility permission, or a real cursor. The stub can also
# pretend to be an ungranted binary, which is the one failure mode worth
# regression-testing: macOS accepts a CGEventPost from an unauthorized process
# and silently discards it, so "the API said yes" proves nothing.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="$(cd .. && pwd)"
D="$(make_state_dir)"
trap 'rm -rf "$D"' EXIT

export KEEPAWAKE_STATE_DIR="$D/state"
export HOME="$D/home"

IDLE_FILE="$D/idle"; export IDLE_FILE
WORKS_FILE="$D/works"; export WORKS_FILE
LOG="$HOME/Library/Logs/keepawake-nudge.log"
REPORT="$HOME/Library/Application Support/keepawake/agent.json"

cat >"$D/stub-helper" <<'STUB'
#!/bin/bash
# Stands in for keepawake-nudge. WORKS_FILE decides whether the simulated event
# actually lands, mimicking a granted vs ungranted Accessibility permission.
idle=$(cat "$IDLE_FILE")
case "$1" in
  idle)  echo "$idle" ;;
  nudge) if [ "$(cat "$WORKS_FILE")" = "1" ]; then
           echo 0; echo 0 >"$IDLE_FILE"; echo nudge >>"$CALLS_FILE"
         else
           echo "$idle"; echo "nudge-noop" >>"$CALLS_FILE"
         fi ;;
  check) [ "$(cat "$WORKS_FILE")" = "1" ] && { echo granted; exit 0; }
         echo denied; exit 1 ;;
esac
STUB
chmod +x "$D/stub-helper"
export KEEPAWAKE_HELPER="$D/stub-helper"
CALLS_FILE="$D/calls"; export CALLS_FILE

cat >"$KEEPAWAKE_STATE_DIR/config" <<'EOF'
NUDGE_IDLE=300
NUDGE_POLL=1
EOF

set_active() {
  printf '{\n  "nudge_active": %s,\n  "updated_epoch": %s\n}\n' \
    "$1" "$(date +%s)" >"$KEEPAWAKE_STATE_DIR/status.json"
}

# Run the real agent for a few polls, then stop it.
#
# The liveness check is not ceremony. Half of these assertions are of the form
# "the agent did NOT nudge", and an agent that failed to start satisfies every
# one of them. Without this the suite reports green when it launched nothing.
start_agent() {
  rm -f "$LOG" "$CALLS_FILE"; : >"$CALLS_FILE"
  bash "$ROOT/libexec/keepawake-nudge-agent" &
  AGENT_PID=$!
  sleep 1
  if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    no "the agent process started" "a running agent" "it exited immediately"
    return 1
  fi
}

stop_agent() {
  kill "$AGENT_PID" 2>/dev/null
  wait "$AGENT_PID" 2>/dev/null
  AGENT_LOG="$(cat "$LOG" 2>/dev/null || true)"
  AGENT_CALLS="$(cat "$CALLS_FILE" 2>/dev/null || true)"
}

run_agent() {
  start_agent || { AGENT_LOG=""; AGENT_CALLS=""; return 1; }
  sleep "${1:-2}"
  stop_agent
}

# ---------------------------------------------------------------------------
suite "nudges when the Mac is genuinely idle"

echo 600 >"$IDLE_FILE"; echo 1 >"$WORKS_FILE"; set_active true
run_agent 3
assert_contains "$AGENT_LOG"   "nudged after 300s idle" "logs the nudge"
assert_contains "$AGENT_CALLS" "nudge"                  "actually called the helper"
assert_eq "0" "$(cat "$IDLE_FILE")" "the idle clock was reset"

# One nudge per idle period, not one per poll.
assert_eq "1" "$(grep -c '^nudge$' "$CALLS_FILE")" "nudges once, then waits for idle to build again"

# ---------------------------------------------------------------------------
suite "does not touch the cursor when it shouldn't"

echo 12 >"$IDLE_FILE"; echo 1 >"$WORKS_FILE"; set_active true
run_agent 3
assert_eq "" "$AGENT_CALLS" "someone is using the Mac (idle 12s) -> no nudge"
assert_eq "12" "$(cat "$IDLE_FILE")" "and the idle clock is untouched"

echo 900 >"$IDLE_FILE"; set_active false
run_agent 3
assert_eq "" "$AGENT_CALLS" "nudge switched off, idle 900s -> no nudge"
assert_eq "900" "$(cat "$IDLE_FILE")" "and the idle clock is untouched"

echo 299 >"$IDLE_FILE"; set_active true
run_agent 3
assert_eq "" "$AGENT_CALLS" "one second below the threshold -> no nudge"

# ---------------------------------------------------------------------------
suite "detects a silently discarded nudge"

echo 600 >"$IDLE_FILE"; echo 0 >"$WORKS_FILE"; set_active true
run_agent 3
assert_contains "$AGENT_CALLS" "nudge-noop"          "it tried"
assert_contains "$AGENT_LOG" "NUDGE HAD NO EFFECT"   "and noticed the event went nowhere"
assert_contains "$AGENT_LOG" "Privacy & Security > Accessibility" "and said how to fix it"
assert_contains "$AGENT_LOG" "requested Accessibility permission"  "and asked macOS for the grant"

# Repeating the same warning every poll for eight hours would bury the log.
COUNT="$(grep -c 'NUDGE HAD NO EFFECT' "$LOG" || true)"
assert_eq "1" "$COUNT" "the warning is logged once, not once per poll"

# ---------------------------------------------------------------------------
suite "reports its own state"

echo 600 >"$IDLE_FILE"; echo 1 >"$WORKS_FILE"; set_active true
start_agent
sleep 2
R="$(cat "$REPORT" 2>/dev/null || true)"
assert_contains "$R" '"trusted": true'  "publishes whether Accessibility is granted"
assert_contains "$R" '"nudges": 1'      "publishes the nudge count"
assert_contains "$R" '"running": true'  "publishes that it is alive"

# Hammer the file while the agent rewrites it every second. A truncate-in-place
# writer fails this within a few dozen reads; an atomic rename never does. This
# caught a real torn-read bug, so it reads the file many times rather than once.
if command -v python3 >/dev/null 2>&1; then
  TORN=0
  for _ in $(seq 1 120); do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$REPORT" 2>/dev/null \
      || TORN=$((TORN + 1))
  done
  assert_eq "0" "$TORN" "the report is never observed half-written (120 reads)"
fi

stop_agent
[ -f "$REPORT" ] \
  && no "a clean stop removes the report" "no file" "still present" \
  || ok "a clean stop removes the report"

# ---------------------------------------------------------------------------
suite "survives a missing helper"

export KEEPAWAKE_HELPER="$D/does-not-exist"
start_agent
stop_agent
assert_contains "$AGENT_LOG" "FATAL helper missing" \
  "says so plainly instead of spinning"

summary
