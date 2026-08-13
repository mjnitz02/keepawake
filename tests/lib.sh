#!/bin/bash
#
# Minimal assertion helpers. Deliberately dependency-free: this repo is four
# shell scripts and a 100-line C file, and adding bats or shunit2 to test that
# would be more machinery than the thing being tested.

PASS=0
FAIL=0

C_GREEN=''; C_RED=''; C_DIM=''; C_BOLD=''; C_RESET=''
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
fi

suite() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

ok() {
  PASS=$((PASS + 1))
  printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"
  [ $# -gt 1 ] && printf '       %sexpected:%s %s\n' "$C_DIM" "$C_RESET" "$2"
  [ $# -gt 2 ] && printf '       %sgot:     %s %s\n' "$C_DIM" "$C_RESET" "$3"
  return 0
}

assert_eq() { # want got label
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "$1" "$2"; fi
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) no "$3" "output containing '$2'" "$1" ;;
  esac
}

assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*) no "$3" "output without '$2'" "$1" ;;
    *) ok "$3" ;;
  esac
}

assert_fails() { # label, then command
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    no "$label" "non-zero exit" "exit 0"
  else
    ok "$label"
  fi
}

summary() {
  printf '\n%s%d passed, %d failed%s\n' \
    "$( [ "$FAIL" -eq 0 ] && printf '%s' "$C_GREEN" || printf '%s' "$C_RED" )" \
    "$PASS" "$FAIL" "$C_RESET"
  [ "$FAIL" -eq 0 ]
}

# Every suite gets its own scratch state dir, wired the way the installer wires
# the real one.
make_state_dir() {
  d=$(mktemp -d "${TMPDIR:-/tmp}/keepawake-test.XXXXXX")
  mkdir -p "$d/state" "$d/home/Library/Logs" "$d/home/Library/Application Support/keepawake"
  printf 'off' >"$d/state/state"
  printf 'off' >"$d/state/nudge"
  printf '%s' "$d"
}

# Writes a status.json in the daemon's exact format, so the CLI parser is
# tested against the real shape rather than a convenient one.
write_status_json() { # dir desired active reason nudge_desired nudge_active nudge_reason expires off_reason off_epoch epoch
  cat >"$1/state/status.json" <<EOF
{
  "desired": "$2",
  "active": $3,
  "reason": "$4",
  "ac": true,
  "battery": 80,
  "sleep_disabled": 1,
  "nudge_desired": "$5",
  "nudge_active": $6,
  "nudge_reason": "$7",
  "nudge_expires_epoch": $8,
  "nudge_off_reason": "$9",
  "nudge_off_epoch": ${10},
  "updated": "2026-08-13 11:39:11",
  "updated_epoch": ${11}
}
EOF
}

write_agent_json() { # dir trusted idle last_nudge count epoch
  cat >"$1/home/Library/Application Support/keepawake/agent.json" <<EOF
{
  "running": true,
  "trusted": $2,
  "idle": $3,
  "last_nudge_epoch": $4,
  "nudges": $5,
  "helper": "/usr/local/libexec/keepawake-nudge",
  "uid": 501,
  "updated_epoch": $6
}
EOF
}
