#!/usr/bin/env bash
# Verification test for Kingpin: every command in `kingpin --help` answers --help with usage
# and exits 0, and asking for help starts nothing (no tmux window, no task folder).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "cli-help"

# Test 22: the dispatcher's help is the list of subcommands
# ---------------------------------------------------------------------------
echo "--- Test 22: every listed command answers --help ---"
t22_rc=0
t22_help=$("$KP_BIN/kingpin" --help) || t22_rc=$?
[ "$t22_rc" -eq 0 ] && echo "$t22_help" | grep -q '^Commands:' && pass "t22: kingpin --help exits 0 and lists commands" || fail "t22: kingpin --help rc=$t22_rc"

cmds=()
while IFS= read -r c; do cmds+=("$c"); done < <(
  printf '%s\n' "$t22_help" | sed -n '/^Commands:/,/^$/p' | sed -n 's/^  \([a-z][a-z-]*\) .*/\1/p'
)
[ ${#cmds[@]} -ge 15 ] && pass "t22: parsed ${#cmds[@]} commands from kingpin --help" || fail "t22: parsed only ${#cmds[@]} commands: ${cmds[*]:-none}"

for c in "${cmds[@]}"; do
  t22_rc=0
  t22_out=$("$KP_BIN/kingpin" "$c" --help 2>&1) || t22_rc=$?
  if [ "$t22_rc" -eq 0 ] && printf '%s' "$t22_out" | grep -qi 'usage'; then
    pass "t22: kingpin $c --help exits 0 with usage"
  else
    fail "t22: kingpin $c --help rc=$t22_rc out=$(printf '%s' "$t22_out" | head -n 2 | tr '\n' ' ')"
  fi
  t22_rc=0
  t22_out=$("$KP_BIN/kingpin" "$c" -h 2>&1) || t22_rc=$?
  [ "$t22_rc" -eq 0 ] && printf '%s' "$t22_out" | grep -qi 'usage' && pass "t22: kingpin $c -h exits 0 with usage" || fail "t22: kingpin $c -h rc=$t22_rc"
done

# The dispatcher's own help states the contract the loop above enforces.
printf '%s\n' "$t22_help" | grep -q "kingpin <command> --help" && pass "t22: the help names 'kingpin <command> --help'" || fail "t22: kingpin --help lost its --help hint"

# Test 23: asking for help starts nothing
# ---------------------------------------------------------------------------
echo "--- Test 23: help has no side effects ---"
t23_windows_before=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null | LC_ALL=C sort)
t23_rc=0
t23_curate=$("$KP_BIN/kingpin" curate --help 2>&1) || t23_rc=$?
t23_windows_after=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null | LC_ALL=C sort)
[ "$t23_rc" -eq 0 ] && printf '%s' "$t23_curate" | grep -qi 'usage' && pass "t23: curate --help exits 0 with usage" || fail "t23: curate --help rc=$t23_rc out=$t23_curate"
[ "$t23_windows_before" = "$t23_windows_after" ] && pass "t23: curate --help creates no tmux window" || fail "t23: curate --help changed the tmux windows"
[ ! -e "$KINGPIN_HOME/curator" ] && pass "t23: curate --help writes no curator state" || fail "t23: curate --help created $KINGPIN_HOME/curator"

tasks_before=$(find "$KINGPIN_HOME/tasks" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
t23_rc=0
t23_run=$("$KP_BIN/kingpin" run --help 2>&1) || t23_rc=$?
tasks_after=$(find "$KINGPIN_HOME/tasks" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$t23_rc" -eq 0 ] && printf '%s' "$t23_run" | grep -q 'usage: kingpin-spawn'; then
  pass "t23: run --help prints spawn's usage"
else
  fail "t23: run --help rc=$t23_rc out=$(printf '%s' "$t23_run" | head -n 2 | tr '\n' ' ')"
fi
[ "$tasks_before" = "$tasks_after" ] && pass "t23: run --help creates no task" || fail "t23: run --help created a task ($tasks_before -> $tasks_after)"

t23_rc=0
"$KP_BIN/kingpin" spawn --help >/dev/null 2>&1 || t23_rc=$?
tasks_after=$(find "$KINGPIN_HOME/tasks" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$t23_rc" -eq 0 ] && [ "$tasks_before" = "$tasks_after" ] && pass "t23: spawn --help creates no task" || fail "t23: spawn --help rc=$t23_rc tasks=$tasks_after"

# Test 24: a bad argument is still an error
# ---------------------------------------------------------------------------
echo "--- Test 24: bad arguments still fail ---"
t24_rc=0
"$KP_BIN/kingpin" bogus-command >/dev/null 2>&1 || t24_rc=$?
[ "$t24_rc" -eq 2 ] && pass "t24: unknown command exits 2" || fail "t24: unknown command rc=$t24_rc"

t24_rc=0
"$KP_BIN/kingpin" spawn --bogus >/dev/null 2>&1 || t24_rc=$?
[ "$t24_rc" -ne 0 ] && pass "t24: spawn --bogus still fails (rc=$t24_rc)" || fail "t24: spawn --bogus exited 0"

t24_rc=0
"$KP_BIN/kingpin" lock bogus >/dev/null 2>&1 || t24_rc=$?
[ "$t24_rc" -eq 2 ] && pass "t24: lock bogus exits 2" || fail "t24: lock bogus rc=$t24_rc"

kp_test_finish CLI-HELP

exit 1
