#!/bin/bash
#
# The compiled nudge helper.
#
# Scope is deliberately narrow. Whether a synthesized event actually reaches the
# window server depends on a GUI session and an Accessibility grant, neither of
# which exists on a CI runner. So this covers what is testable anywhere: that it
# builds clean, that its interface behaves, and that `idle` returns a plausible
# number. The end-to-end question is answered at runtime instead, by the agent
# checking whether the idle clock actually moved.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="$(cd .. && pwd)"
SRC="$ROOT/src/keepawake-nudge.c"
D=$(mktemp -d "${TMPDIR:-/tmp}/keepawake-helper.XXXXXX")
trap 'rm -rf "$D"' EXIT
BIN="$D/keepawake-nudge"

suite "build"

if [ "$(uname -s)" != "Darwin" ]; then
  printf '  %sSKIP%s not macOS, the helper cannot be built here\n' "$C_DIM" "$C_RESET"
  summary
  exit 0
fi

BUILD_ERR="$(cc -O2 -Wall -Werror -o "$BIN" "$SRC" -framework ApplicationServices 2>&1)"
if [ -x "$BIN" ]; then
  ok "compiles with -Wall -Werror"
else
  no "compiles with -Wall -Werror" "a binary" "$BUILD_ERR"
  summary
  exit 1
fi

assert_eq "" "$BUILD_ERR" "compiles without warnings"

suite "interface"

OUT="$("$BIN" idle 2>&1)"
case "$OUT" in
  ''|*[!0-9]*) no "'idle' prints a whole number of seconds" "digits" "$OUT" ;;
  *) ok "'idle' prints a whole number of seconds" ;;
esac

# A CI runner with no input for hours is plausible; a negative or absurd value
# is not, and would mean the API returned something unexpected.
if [ "$OUT" -ge 0 ] 2>/dev/null && [ "$OUT" -lt 2592000 ]; then
  ok "'idle' returns a plausible value (${OUT}s)"
else
  no "'idle' returns a plausible value" "0..30 days" "$OUT"
fi

OUT="$("$BIN" check 2>&1)"
case "$OUT" in
  granted|denied) ok "'check' reports granted or denied (got: $OUT)" ;;
  *) no "'check' reports granted or denied" "granted|denied" "$OUT" ;;
esac

# The exit code has to track the answer, because the agent branches on it.
if "$BIN" check >/dev/null 2>&1; then RC=0; else RC=1; fi
if [ "$OUT" = "granted" ]; then
  assert_eq "0" "$RC" "'check' exits 0 when granted"
else
  assert_eq "1" "$RC" "'check' exits non-zero when denied"
fi

assert_fails "no arguments is an error"      "$BIN"
assert_fails "an unknown subcommand is an error" "$BIN" frobnicate

OUT="$("$BIN" 2>&1 || true)"
assert_contains "$OUT" "usage:" "prints usage on misuse"

suite "nudge"

# Safe to call even without permission: unauthorized posts are discarded, and
# the cursor is put back where it started either way.
OUT="$("$BIN" nudge 2>&1)"
case "$OUT" in
  ''|*[!0-9]*) no "'nudge' prints the resulting idle time" "digits" "$OUT" ;;
  *) ok "'nudge' prints the resulting idle time" ;;
esac

if "$BIN" check >/dev/null 2>&1; then
  # Only meaningful where the grant exists, which is a real Mac, not CI.
  assert_eq "0" "$OUT" "with permission granted, a nudge resets the idle clock"
else
  printf '  %sSKIP%s no Accessibility grant here, cannot verify a nudge lands\n' \
    "$C_DIM" "$C_RESET"
fi

summary
