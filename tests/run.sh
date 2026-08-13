#!/bin/bash
#
# Run every suite. Exits non-zero if any of them fail.
#
#   tests/run.sh              everything
#   tests/run.sh daemon cli   just those
#
# No root, no install, no changes to the machine's power settings: every suite
# works in a scratch directory against stub inputs.

set -u
cd "$(dirname "$0")" || exit 1

C_BOLD=''; C_GREEN=''; C_RED=''; C_DIM=''; C_RESET=''
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
fi

if [ $# -gt 0 ]; then
  SUITES=""
  for s in "$@"; do SUITES="$SUITES test_$s.sh"; done
else
  SUITES="test_helper.sh test_daemon.sh test_cli.sh test_agent.sh"
fi

FAILED=""
for s in $SUITES; do
  if [ ! -f "$s" ]; then
    printf '%sno such suite: %s%s\n' "$C_RED" "$s" "$C_RESET" >&2
    exit 2
  fi
  printf '\n%s=== %s %s%s\n' "$C_BOLD" "$s" \
    "$(printf '%*s' $((60 - ${#s})) '' | tr ' ' '=')" "$C_RESET"
  bash "$s" || FAILED="$FAILED $s"
done

printf '\n%s%s%s\n' "$C_BOLD" "$(printf '%68s' '' | tr ' ' '=')" "$C_RESET"
if [ -n "$FAILED" ]; then
  printf '%sFAILED:%s%s\n' "$C_RED" "$FAILED" "$C_RESET"
  exit 1
fi
printf '%sAll suites passed.%s\n' "$C_GREEN" "$C_RESET"

# Worth stating plainly so nobody reads a green run as more than it is.
printf '%s\nNot covered here (needs root and real hardware):\n' "$C_DIM"
printf '  - whether pmset actually flips SleepDisabled   (install.sh verifies this)\n'
printf '  - whether a synthesized event reaches the window server\n'
printf '    (needs an Accessibility grant; the agent verifies it at runtime by\n'
printf '     checking the idle clock actually moved)\n'
printf '  - launchd bootstrap, and behavior on a real unplug%s\n' "$C_RESET"
