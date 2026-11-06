#!/usr/bin/env bash
# Verification test for Kingpin: kingpin-launch-check: workers that die at launch.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "launch-check"
kp_test_bsd_shims
kp_test_project

kp_test_stub_lavish

# Test 22: a worker that stops without ever writing a status line is reported failed
echo "=== Test 22: workers that die at launch ==="
# A hand-made task: $1 name, $2 harness, $3 seconds since CREATED, $4 window command.
mk_t22() {
  local name=$1 harness=$2 age=$3 cmd=$4 d wid
  d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "$name" "$cmd")
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t22
HARNESS=$harness
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$T/t22-missing-worktree-$name
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
TMUX_WINDOW_ID=$wid
CREATED=$(kp_test_iso_ago "$age")
ENVEOF
  : > "$d/status"
  echo 0 > "$d/seen"
}
t22_status_lines() { grep -c '' "$KINGPIN_HOME/tasks/$1/status" 2>/dev/null || true; }
# pane_silent_for <window-id> <seconds>: the private server stamps `window_activity` when
# the pane last printed, and the launch check gates that silence as well as the stop age,
# so a fixture is silent past a grace window when the stamp is older than it (issue #233).
pane_silent_for() {
  local activity now
  activity=$(tmux display-message -p -t "$1" '#{window_activity}' 2>/dev/null) || return 1
  [[ $activity =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [ $((now - activity)) -ge "$2" ]
}

# AC1+AC2+AC3: the process is gone and the grace period is over -> failed line naming task and harness
mk_t22 t22-dead agy 120 'exit 1'
sleep 0.5
t22_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t22_out" | grep -q "^t22-dead status" && pass "t22: kingpin-wait reports the dead worker as a status event" || fail "t22: no status event for t22-dead (got: $t22_out)"
t22_last=$(tail -n 1 "$KINGPIN_HOME/tasks/t22-dead/status")
case "$t22_last" in "failed: no status: t22-dead (agy) "*) pass "t22: the failed line names the task and its harness" ;; *) fail "t22: unexpected status line: $t22_last" ;; esac
echo "$t22_last" | grep -q "tmux window gone" && pass "t22: the failed line gives the cause (window gone)" || fail "t22: cause missing: $t22_last"
t22_list=$("$KP_BIN/kingpin" list 2>/dev/null | grep '^t22-dead ')
echo "$t22_list" | grep -q "failed: no status" && ! echo "$t22_list" | grep -q "(pending)" && pass "t22: kingpin list shows the task as failed, not pending" || fail "t22: list row: $t22_list"
"$KP_BIN/kingpin" ack t22-dead
t22_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t22_out" | grep -q "^t22-dead" && fail "t22: dead worker reported again after ack: $t22_out" || pass "t22: no repeat event after ack"
[ "$(t22_status_lines t22-dead)" = 1 ] && pass "t22: the failed line is written once" || fail "t22: status has $(t22_status_lines t22-dead) lines"

# AC4: inside the grace period nothing is failed; a live worker that is only slow is left alone
mk_t22 t22-young agy 5 'exit 1'
mk_t22 t22-slow claude 120 'cat'
sleep 0.5
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1 || true
[ ! -s "$KINGPIN_HOME/tasks/t22-young/status" ] && pass "t22: a worker inside the grace period is not failed" || fail "t22: young worker failed: $(cat "$KINGPIN_HOME/tasks/t22-young/status")"
[ ! -s "$KINGPIN_HOME/tasks/t22-slow/status" ] && pass "t22: a live worker with an empty status and no stop is not failed" || fail "t22: slow worker failed: $(cat "$KINGPIN_HOME/tasks/t22-slow/status")"
KINGPIN_STATUS_GRACE=1 "$KP_BIN/kingpin" wait --once >/dev/null 2>&1 || true
tail -n 1 "$KINGPIN_HOME/tasks/t22-young/status" | grep -q "^failed: no status: t22-young" && pass "t22: KINGPIN_STATUS_GRACE shortens the grace period" || fail "t22: young worker not failed under a 1s grace"
[ ! -s "$KINGPIN_HOME/tasks/t22-slow/status" ] && pass "t22: a short grace still leaves a live worker alone" || fail "t22: slow worker failed under a 1s grace"

# A worker that reported anything is never rewritten
mk_t22 t22-reported agy 120 'exit 1'
echo "issue: #1 https://example.invalid/1" >> "$KINGPIN_HOME/tasks/t22-reported/status"
sleep 0.5
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1 || true
[ "$(t22_status_lines t22-reported)" = 1 ] && pass "t22: a worker with a status line gets no failed line" || fail "t22: reported worker status: $(cat "$KINGPIN_HOME/tasks/t22-reported/status")"

# A CREATED that does not parse is reported, not read as "now" (which would hide the death)
mk_t22 t22-badtime agy 120 'exit 1'
kp_test_sub "$KINGPIN_HOME/tasks/t22-badtime/task.env" 's|^CREATED=.*|CREATED=not-a-time|'
set +e
t22_badrc_out=$("$KP_BIN/kingpin-launch-check" "$KINGPIN_HOME/tasks/t22-badtime" 2>"$T/t22-badtime.err")
t22_badrc=$?
set -e
[ "$t22_badrc" -eq 1 ] && [ ! -s "$KINGPIN_HOME/tasks/t22-badtime/status" ] && pass "t22: an unparseable CREATED records nothing" || fail "t22: unparseable CREATED rc=$t22_badrc out='$t22_badrc_out'"
grep -q "cannot parse CREATED" "$T/t22-badtime.err" && pass "t22: the unparseable CREATED is named on stderr" || fail "t22: no stderr warning for an unparseable CREATED"

# An empty CREATED is what the old GNU-only date wrote on macOS: name it too
mk_t22 t22-notime agy 120 'exit 1'
kp_test_sub "$KINGPIN_HOME/tasks/t22-notime/task.env" 's|^CREATED=.*|CREATED=|'
set +e
t22_notime_out=$("$KP_BIN/kingpin-launch-check" "$KINGPIN_HOME/tasks/t22-notime" 2>"$T/t22-notime.err")
t22_notime_rc=$?
set -e
[ "$t22_notime_rc" -eq 1 ] && [ ! -s "$KINGPIN_HOME/tasks/t22-notime/status" ] && [ -z "$t22_notime_out" ] && pass "t22: an empty CREATED records nothing" || fail "t22: empty CREATED rc=$t22_notime_rc out='$t22_notime_out'"
grep -q "CREATED is empty" "$T/t22-notime.err" && pass "t22: the empty CREATED is named on stderr" || fail "t22: no stderr warning for an empty CREATED"

# BSD `date -j -f` keeps a field it cannot parse (a month of 13 reads as "now")
# instead of failing. A stub that degrades the same way must not be read as a time.
mkdir -p "$T/t22-lenient-bin"
cat > "$T/t22-lenient-bin/date" << 'LENEOF'
#!/usr/bin/env bash
# macOS-shaped date for one test: GNU -d is refused, -j -f accepts anything, and
# -r formats the "now" it degrades to.
case ${1:-} in
  -d) exit 1 ;;
  -j) printf '%s\n' 1735689600 ;;
  -r) printf '%s\n' 2025-01-01T00:00:00+0000 ;;
esac
exit 1
LENEOF
chmod +x "$T/t22-lenient-bin/date"
set +e
t22_lenient_out=$(PATH="$T/t22-lenient-bin:$PATH" bash -c '. "$1/lib/portable.sh"; kp_epoch_from_iso 2025-13-01T00:00:00+0100' _ "$KP_ROOT")
t22_lenient_rc=$?
set -e
[ "$t22_lenient_rc" -eq 1 ] && [ -z "$t22_lenient_out" ] && pass "t22: a BSD date that keeps an unparsed field is rejected" || fail "t22: an invalid ISO timestamp read as '$t22_lenient_out' (rc=$t22_lenient_rc)"
rm -rf "$T/t22-lenient-bin"

# A valid instant written in another offset is still valid: the reader's local
# offset must not make the round-trip look like a lenient parse.
mkdir -p "$T/t22-offset-bin"
cat > "$T/t22-offset-bin/date" << 'OFFEOF'
#!/usr/bin/env bash
# BSD-shaped date for one test: GNU -d is refused, -j -f parses the value, and
# -r formats the epoch in this reader's +0200.
case ${1:-} in
  -d) exit 1 ;;
  -j) printf '%s\n' 1735689600 ;;
  -r) printf '%s\n' 2025-01-01T02:00:00+0200 ;;
esac
exit 1
OFFEOF
chmod +x "$T/t22-offset-bin/date"
set +e
t22_offset_out=$(PATH="$T/t22-offset-bin:$PATH" bash -c '. "$1/lib/portable.sh"; kp_epoch_from_iso 2025-01-01T00:00:00+0000' _ "$KP_ROOT")
t22_offset_rc=$?
set -e
[ "$t22_offset_rc" -eq 0 ] && [ "$t22_offset_out" = 1735689600 ] && pass "t22: a valid instant in another offset is accepted" || fail "t22: foreign offset rejected (out='$t22_offset_out' rc=$t22_offset_rc)"
rm -rf "$T/t22-offset-bin"

# A stopped worker whose window stays open: failed only after the window has been silent for the grace period
mk_t22 t22-idle opencode 600 'cat'
echo $(( $(date +%s) - 120 )) > "$KINGPIN_HOME/tasks/t22-idle/stopped"
mk_t22 t22-busy claude 600 'while :; do echo tick; sleep 0.3; done'
echo $(( $(date +%s) - 120 )) > "$KINGPIN_HOME/tasks/t22-busy/stopped"
# Stopped and silent, but the pane shows the working marker that `quiet` skips for its harness
mk_t22 t22-wclaude claude 600 'printf "Waiting for 1 background agent\n"; exec cat'
echo $(( $(date +%s) - 120 )) > "$KINGPIN_HOME/tasks/t22-wclaude/stopped"
# The claude subagent footer is a working marker on its own (#80): launch-check's old
# copy of the marker list missed it, so a worker waiting on background agents was failed.
mk_t22 t22-wtasks claude 600 'printf "/tasks to see subagents\n"; exec cat'
echo $(( $(date +%s) - 120 )) > "$KINGPIN_HOME/tasks/t22-wtasks/stopped"
mk_t22 t22-wagy agy 600 'printf "working\nesc to cancel\n"; exec cat'
echo $(( $(date +%s) - 120 )) > "$KINGPIN_HOME/tasks/t22-wagy/stopped"
mk_t22 t22-wopencode opencode 600 'printf "working\nInterrupt\n"; exec cat'
echo $(( $(date +%s) - 120 )) > "$KINGPIN_HOME/tasks/t22-wopencode/stopped"
# The just-stopped fixture needs a grace window an order of magnitude wider than the
# `wait --once` below, because that invocation's own latency counts against the window: a
# loaded runner took more than two seconds for it, so a 2-second grace failed a worker that
# had only just stopped (issue #233). The launch check also gates the pane's own silence,
# so the stale fixtures above must be silent for the whole 30 seconds as well: wait on the
# pane's clock instead of a fixed pause, and create the just-stopped fixture after that
# wait so it stays inside the window. The boundary itself stays covered by the `t22-young`
# block under KINGPIN_STATUS_GRACE=1 above.
t22_last_win=$(sed -n 's/^TMUX_WINDOW_ID=//p' "$KINGPIN_HOME/tasks/t22-wopencode/task.env")
kp_wait_until 45 pane_silent_for "$t22_last_win" 30 || fail "t22: the stale fixtures never went silent for the grace"
mk_t22 t22-justnow claude 600 'cat'
date +%s > "$KINGPIN_HOME/tasks/t22-justnow/stopped"
KINGPIN_STATUS_GRACE=30 "$KP_BIN/kingpin" wait --once >/dev/null 2>&1 || true
tail -n 1 "$KINGPIN_HOME/tasks/t22-idle/status" | grep -q "^failed: no status: t22-idle (opencode) stopped and went silent.*kingpin peek t22-idle" && pass "t22: a stopped worker with a silent window is failed, with a peek hint" || fail "t22: idle worker status: $(cat "$KINGPIN_HOME/tasks/t22-idle/status")"
[ ! -s "$KINGPIN_HOME/tasks/t22-busy/status" ] && pass "t22: a stopped worker whose window still prints is not failed" || fail "t22: busy worker failed: $(cat "$KINGPIN_HOME/tasks/t22-busy/status")"
[ ! -s "$KINGPIN_HOME/tasks/t22-justnow/status" ] && pass "t22: a worker that stopped inside the grace period is not failed" || fail "t22: just-stopped worker failed"
for t in t22-wclaude t22-wtasks t22-wagy t22-wopencode; do
  [ ! -s "$KINGPIN_HOME/tasks/$t/status" ] && pass "t22: a stopped, silent worker showing a working marker is not failed ($t)" || fail "t22: working worker $t failed: $(cat "$KINGPIN_HOME/tasks/$t/status")"
done

# remain-on-exit keeps the window of a dead process: the pane is dead
mk_t22 t22-paneDead agy 120 'sleep 1; exit 3'
tmux set-window-option -t "$(sed -n 's/^TMUX_WINDOW_ID=//p' "$KINGPIN_HOME/tasks/t22-paneDead/task.env")" remain-on-exit on
sleep 2
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1 || true
tail -n 1 "$KINGPIN_HOME/tasks/t22-paneDead/status" | grep -q "tmux pane dead" && pass "t22: a dead pane in a kept window is failed" || fail "t22: pane-dead status: $(cat "$KINGPIN_HOME/tasks/t22-paneDead/status")"

# An unreachable tmux server says nothing about the worker
mk_t22 t22-notmux agy 120 'exit 1'
mkdir -p "$T/t22-notmux-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/t22-notmux-bin/tmux"
chmod +x "$T/t22-notmux-bin/tmux"
sleep 0.5
PATH="$T/t22-notmux-bin:$PATH" "$KP_BIN/kingpin" wait --once >/dev/null 2>&1 || true
[ ! -s "$KINGPIN_HOME/tasks/t22-notmux/status" ] && pass "t22: nothing is recorded when tmux cannot be asked" || fail "t22: failed written without tmux: $(cat "$KINGPIN_HOME/tasks/t22-notmux/status")"

for t in t22-dead t22-young t22-slow t22-reported t22-badtime t22-notime t22-idle t22-busy t22-justnow t22-wclaude t22-wtasks t22-wagy t22-wopencode t22-paneDead t22-notmux; do
  tmux kill-window -t "$(sed -n 's/^TMUX_WINDOW_ID=//p' "$KINGPIN_HOME/tasks/$t/task.env")" 2>/dev/null || true
  rm -rf "$KINGPIN_HOME/tasks/$t"
done
rm -rf "$T/t22-notmux-bin"

# End to end: a real spawn whose harness exits at once, then kingpin done releases the slot
cat > "$T/t22-dead-harness" << 'DH'
#!/usr/bin/env bash
exit 1
DH
chmod +x "$T/t22-dead-harness"
KINGPIN_AGY=$T/t22-dead-harness "$KP_BIN/kingpin" spawn demo-auto --issue 246 --id t22-spawn --mode review >/dev/null
sleep 2
t22_out=$(KINGPIN_STATUS_GRACE=1 "$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t22_out" | grep -q "^t22-spawn status" && pass "t22: a spawned worker that exits at once is reported" || fail "t22: spawned dead worker not reported (got: $t22_out)"
"$KP_BIN/kingpin" list 2>/dev/null | grep '^t22-spawn ' | grep -q "failed: no status: t22-spawn (agy)" && pass "t22: list shows the spawned worker as failed" || fail "t22: list row for t22-spawn: $("$KP_BIN/kingpin" list 2>/dev/null | grep '^t22-spawn ')"
"$KP_BIN/kingpin" "done" t22-spawn >/dev/null 2>&1 && [ -d "$KINGPIN_HOME/archive/t22-spawn" ] && pass "t22: kingpin done releases the failed task without --force" || fail "t22: kingpin done refused the dead task"

# kingpin run stops on a worker that died at launch instead of polling forever
t22_run_rc=0
t22_run_out=$(KINGPIN_AGY=$T/t22-dead-harness KINGPIN_STATUS_GRACE=1 timeout 60 "$KP_BIN/kingpin" run demo-auto --issue 247 --id t22-run --mode review 2>&1) || t22_run_rc=$?
[ "$t22_run_rc" -eq 1 ] && echo "$t22_run_out" | grep -q "FAILED: t22-run failed: failed: no status:" && pass "t22: kingpin run exits 1 with the failed line for a worker that died at launch" || fail "t22: kingpin run rc=$t22_run_rc: $t22_run_out"
"$KP_BIN/kingpin" "done" t22-run >/dev/null 2>&1 || true

kp_test_finish LAUNCH-CHECK
