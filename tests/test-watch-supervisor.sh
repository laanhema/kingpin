#!/usr/bin/env bash
# Verification test for Kingpin: the fleet supervisor (`kingpin watch`) is a daemon.
#
# Covers the pidfile lifecycle (start, second copy refused, stale file reclaimed),
# the `Supervisor:` line in `kingpin list` in both states, the `kingpin lock acquire`
# warning, and the point of the whole change: two events that arrive one after the
# other are both handled by the one watch process, with no re-arm and no human step.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "watch-supervisor"

PID_FILE="$KINGPIN_HOME/supervisor.pid"
LOG="$T/supervisor.log"
WATCH_PID=''

stop_supervisor() {
  [ -n "$WATCH_PID" ] || return 0
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=''
}

start_supervisor() {
  "$KP_BIN/kingpin-watch" --interval 1 >> "$LOG" 2>&1 &
  WATCH_PID=$!
  wait_until 80 pidfile_names "$WATCH_PID"
}

pidfile_names() {
  [ "$(sed -n 1p "$PID_FILE" 2>/dev/null | tr -d ' ')" = "$1" ]
}

# wait_until <tries> <cmd...>: poll every 0.2 s until the command succeeds.
wait_until() {
  local tries=$1
  shift
  for _ in $(seq 1 "$tries"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  return 1
}

seen_count() {
  local file="$KINGPIN_HOME/tasks/$1/seen"
  [ -f "$file" ] || { echo 0; return 0; }
  tr -d ' \n' < "$file"
}

log_has() {
  grep -qF "$1" "$LOG"
}

# The log line number of the first line holding the text, empty when absent.
log_line_of() {
  { grep -nF "$1" "$LOG" || true; } | head -n 1 | cut -d: -f1
}

# One live tmux window stands in for the workers' panes, so `kingpin wait` never
# reports a task as exited while the suite drives its status file.
tmux new-window -t kingpin -n kp99-probe 'exec bash'
probe_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="kp99-probe"{print $1}')
[ -n "$probe_wid" ] && pass "probe window created ($probe_wid)" || fail "could not create the probe window"

mk_task() {
  local id=$1 project=${2:-demo}
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  printf 'PROJECT=%s\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:%s\nTMUX_WINDOW_ID=%s\n' \
    "$project" "$id" "$probe_wid" > "$KINGPIN_HOME/tasks/$id/task.env"
  # An informational line only, so the task starts with no pending event.
  printf 'issue: #99\n' > "$KINGPIN_HOME/tasks/$id/status"
}
mk_task t-a
mk_task t-b

# Test 1: no supervisor, in list and in --once
echo "=== Test 1: no supervisor yet ==="
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "Supervisor: none - run kingpin watch" \
  && pass "list reports no supervisor and how to start one" \
  || fail "list did not report the missing supervisor: $list_out"

"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1 && pass "--once runs without a supervisor" || fail "--once failed"
[ ! -f "$PID_FILE" ] && pass "--once does not claim the pidfile" || fail "--once wrote $PID_FILE"

# Test 2: a pidfile that names a dead pid is stale
echo "=== Test 2: stale pidfile ==="
printf '999999\n%s\n' "$(date +%s)" > "$PID_FILE"
grep -q "Supervisor: none" <<< "$("$KP_BIN/kingpin" list)" \
  && pass "dead pid in the pidfile still reports no supervisor" \
  || fail "dead pid was treated as a running supervisor"

# Test 3: the supervisor starts and becomes visible
echo "=== Test 3: supervisor start and list line ==="
start_supervisor || fail "supervisor did not write its pidfile"
[ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null && pass "supervisor is running (pid $WATCH_PID)" || fail "supervisor process is not alive"
grep -qE '^[0-9]+$' <(sed -n 2p "$PID_FILE") && pass "pidfile records the start time on line 2" || fail "pidfile has no start time"
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "Supervisor: running (pid $WATCH_PID, since " \
  && pass "list shows the running supervisor with pid and start time" \
  || fail "list did not show the running supervisor: $list_out"

# Test 4: a second copy is refused quickly and never disturbs the first copy's claim
echo "=== Test 4: second supervisor refused ==="
before=$(cat "$PID_FILE")
second_err_file="$T/second-supervisor.err"
"$KP_BIN/kingpin-watch" --interval 1 >/dev/null 2>"$second_err_file" &
second_pid=$!
# It must be gone within 0.5 s. The old mkdir mutex was held for the supervisor's
# whole lifetime, so a duplicate spent 3 s spinning before it refused; polling the
# process (bash reaps a finished child, so kill -0 fails) needs no sub-second clock.
second_fast=0
for _ in $(seq 1 10); do
  if ! kill -0 "$second_pid" 2>/dev/null; then second_fast=1; break; fi
  sleep 0.05
done
[ "$second_fast" -eq 1 ] \
  && pass "second supervisor refused within 0.5s (nothing is held while the supervisor runs)" \
  || fail "second supervisor was still running after 0.5s; the claim is held while the supervisor runs"
kill -9 "$second_pid" 2>/dev/null || true
second_rc=0
wait "$second_pid" 2>/dev/null || second_rc=$?
second_err=$(cat "$second_err_file" 2>/dev/null || true)
[ "$second_rc" -eq 1 ] && pass "second supervisor exits 1" || fail "second supervisor exited $second_rc"
echo "$second_err" | grep -q "already running (pid $WATCH_PID)" \
  && pass "refusal names the running pid" \
  || fail "refusal did not name the pid: $second_err"
[ "$(cat "$PID_FILE")" = "$before" ] \
  && pass "refusal left the running supervisor's claim in place" \
  || fail "refusal revoked or rewrote the running supervisor's claim"
leftovers=$(ls -1 "$KINGPIN_HOME"/supervisor.pid.claim.* "$KINGPIN_HOME"/supervisor.pid.stale.* 2>/dev/null || true)
[ -z "$leftovers" ] \
  && pass "refusal left no claim or stale file behind" \
  || fail "refusal left files behind: $leftovers"

# Test 5: --once keeps working while a supervisor runs, without touching the pidfile
echo "=== Test 5: --once beside a running supervisor ==="
"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1 && pass "--once exits 0 while a supervisor runs" || fail "--once failed beside a supervisor"
[ "$(cat "$PID_FILE")" = "$before" ] && pass "--once left the pidfile alone" || fail "--once rewrote the pidfile"

# Test 6: lock acquire warns only when no supervisor is running
echo "=== Test 6: lock acquire warning ==="
acquire_err=$(KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire 2>&1 >/dev/null || true)
echo "$acquire_err" | grep -q "no fleet supervisor is running" \
  && fail "acquire warned while a supervisor was running: $acquire_err" \
  || pass "acquire stays quiet while a supervisor runs"
"$KP_BIN/kingpin" lock release >/dev/null
stop_supervisor
acquire_err=$(KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire 2>&1 >/dev/null || true)
echo "$acquire_err" | grep -q "no fleet supervisor is running; run 'kingpin watch'" \
  && pass "acquire warns when no supervisor is running" \
  || fail "acquire did not warn: $acquire_err"
"$KP_BIN/kingpin" lock release >/dev/null

# Test 7: two events, one watch process, no re-arm anywhere
echo "=== Test 7: two events handled by one supervisor ==="
rm -f "$LOG"
start_supervisor || fail "supervisor did not start for the event test"
first_pid=$WATCH_PID

printf 'needs-input: probe question\n' >> "$KINGPIN_HOME/tasks/t-a/status"
wait_until 75 log_has "[kingpin-watch] t-a needs input" \
  && pass "first event handled" \
  || fail "first event was not handled: $(cat "$LOG")"
[ "$(seen_count t-a)" = "2" ] && pass "first event acknowledged" || fail "t-a seen=$(seen_count t-a)"

printf 'failed: probe failure\n' >> "$KINGPIN_HOME/tasks/t-b/status"
wait_until 75 log_has "[kingpin-watch] t-b reported failure: failed: probe failure" \
  && pass "second event handled after the first, with no re-arm" \
  || fail "second event was not handled: $(cat "$LOG")"
[ "$(seen_count t-b)" = "2" ] && pass "second event acknowledged" || fail "t-b seen=$(seen_count t-b)"

[ "$WATCH_PID" = "$first_pid" ] && [ "$(sed -n 1p "$PID_FILE" | tr -d ' ')" = "$first_pid" ] \
  && kill -0 "$first_pid" 2>/dev/null \
  && pass "one supervisor handled both events" \
  || fail "supervisor was replaced between events"
[ "$(grep -cF 'Watching fleet events' "$LOG")" = "1" ] \
  && pass "exactly one supervisor instance ran" \
  || fail "more than one supervisor instance ran: $(grep -cF 'Watching fleet events' "$LOG")"

# Test 7b: every line of a batch is dispatched once, in file order (#73)
echo "=== Test 7b: a batch dispatches every line once, in order ==="
mk_task t-order
printf 'needs-input: batch-first\nfailed: batch-second\n' >> "$KINGPIN_HOME/tasks/t-order/status"
wait_until 75 log_has "[kingpin-watch] t-order needs input" \
  && pass "first line of the batch dispatched" \
  || fail "first line of the batch was lost: $(cat "$LOG")"
wait_until 75 log_has "[kingpin-watch] t-order reported failure: failed: batch-second" \
  && pass "second line of the batch dispatched in the same supervisor" \
  || fail "second line of the batch was lost: $(cat "$LOG")"
order_first=$(log_line_of "[kingpin-watch] t-order needs input")
order_second=$(log_line_of "[kingpin-watch] t-order reported failure: failed: batch-second")
[ -n "$order_first" ] && [ -n "$order_second" ] && [ "$order_first" -lt "$order_second" ] \
  && pass "the batch was dispatched in file order" \
  || fail "batch order wrong (first=$order_first second=$order_second)"
[ "$(seen_count t-order)" = "3" ] && pass "the whole batch was acknowledged once" || fail "t-order seen=$(seen_count t-order)"

# Test 7c: issue acceptance - merged: followed by an appended feedback: still cleans up
echo "=== Test 7c: merged: + feedback: runs the cleanup step ==="
mk_task t-merged demo-merged
printf 'merged: pr=https://example.test/pr/73\nfeedback: Request Changes: after merged\n' \
  >> "$KINGPIN_HOME/tasks/t-merged/status"
wait_until 75 log_has "[kingpin-watch] t-merged merged; running cleanup..." \
  && pass "merged: ran the cleanup step despite the feedback: note" \
  || fail "merged: was acked away and never cleaned up: $(cat "$LOG")"
wait_until 75 log_has "[kingpin-watch] t-merged received review feedback: feedback: Request Changes: after merged" \
  && pass "the listener feedback: note was still reported" \
  || fail "the feedback: note was not reported: $(cat "$LOG")"
[ "$(seen_count t-merged)" = "3" ] && pass "merged: + feedback: acknowledged" || fail "t-merged seen=$(seen_count t-merged)"

# Test 7d: issue acceptance - fixed: followed by feedback: during landing still lands
echo "=== Test 7d: fixed: + feedback: runs the land step ==="
mk_task t-fixed demo-fixed
touch "$KINGPIN_HOME/tasks/t-fixed/landing_in_progress"
printf 'fixed: high=0 report=.agents/reviews/r.md\nfeedback: Request Changes: after fixed\n' \
  >> "$KINGPIN_HOME/tasks/t-fixed/status"
wait_until 75 log_has "[kingpin-watch] t-fixed reported fix pass; continuing landing..." \
  && pass "fixed: ran the land step despite the feedback: note" \
  || fail "fixed: was acked away and never landed: $(cat "$LOG")"
wait_until 75 log_has "[kingpin-watch] t-fixed received review feedback: feedback: Request Changes: after fixed" \
  && pass "the feedback: after fixed: was still reported" \
  || fail "the feedback: after fixed: was not reported: $(cat "$LOG")"
[ "$(seen_count t-fixed)" = "3" ] && pass "fixed: + feedback: acknowledged" || fail "t-fixed seen=$(seen_count t-fixed)"

# Test 7e: blank and issue: lines advance the cursor without a dispatch
echo "=== Test 7e: blank and issue: lines are skipped, not dispatched ==="
mk_task t-skip
printf '\nissue: #73 informational\nwaiting: skipped-note\n' >> "$KINGPIN_HOME/tasks/t-skip/status"
wait_until 75 log_has "[kingpin-watch] t-skip is waiting: skipped-note" \
  && pass "the real event after blank and issue: lines was dispatched" \
  || fail "the real event after blank and issue: lines was lost: $(cat "$LOG")"
log_has "[kingpin-watch] t-skip issue:" \
  && fail "an issue: line was dispatched" \
  || pass "issue: lines are not dispatched"
wait_until 20 test "$(seen_count t-skip)" = "4" \
  && pass "the cursor advanced past the skipped lines" \
  || fail "t-skip seen=$(seen_count t-skip), expected 4"

# Test 7f: a restart resumes at the first undispatched line
echo "=== Test 7f: a fresh supervisor resumes at the first undispatched line ==="
stop_supervisor
mk_task t-restart
printf 'needs-input: handled-before-restart\nfailed: restart-first\nwaiting: restart-second\n' \
  >> "$KINGPIN_HOME/tasks/t-restart/status"
printf '2\n' > "$KINGPIN_HOME/tasks/t-restart/seen"
start_supervisor || fail "supervisor did not start for the restart case"
wait_until 75 log_has "[kingpin-watch] t-restart reported failure: failed: restart-first" \
  && pass "the first undispatched line was dispatched after the restart" \
  || fail "the first undispatched line was lost after the restart: $(cat "$LOG")"
wait_until 75 log_has "[kingpin-watch] t-restart is waiting: restart-second" \
  && pass "the second undispatched line was dispatched after the restart" \
  || fail "the second undispatched line was lost after the restart: $(cat "$LOG")"
log_has "[kingpin-watch] t-restart needs input" \
  && fail "the restart re-dispatched a line the earlier supervisor had handled" \
  || pass "the restart did not repeat a handled line"
[ "$(seen_count t-restart)" = "4" ] && pass "the restart left the cursor at the end" || fail "t-restart seen=$(seen_count t-restart)"

# Test 7g: a cursor moved through one line leaves later appends pending (the race)
echo "=== Test 7g: --through leaves later lines pending ==="
stop_supervisor
mk_task t-race
printf 'failed: race-first\nneeds-input: race-second\n' >> "$KINGPIN_HOME/tasks/t-race/status"
"$KP_BIN/kingpin-ack" --through 2 t-race >/dev/null 2>&1 || true
[ "$(seen_count t-race)" = "2" ] \
  && pass "kingpin-ack --through moved the cursor to the handled line" \
  || fail "--through did not move seen (got $(seen_count t-race))"
race_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$race_out" | grep -q "^t-race status" \
  && pass "a line appended after the handled prefix stays pending" \
  || fail "the later line was swallowed by the cursor (got: $race_out)"
"$KP_BIN/kingpin-ack" t-race >/dev/null
[ "$(seen_count t-race)" = "3" ] \
  && pass "a plain kingpin-ack still acknowledges the whole file" \
  || fail "plain ack broke (got $(seen_count t-race))"
set +e
race_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null)
race_rc=$?
set -e
[ "$race_rc" -eq 1 ] && [ -z "$race_out" ] \
  && pass "kingpin-wait --once is quiet after the full ack (single announce)" \
  || fail "kingpin-wait repeated an acked line (rc=$race_rc out=$race_out)"

# Test 7h: a status-less event (exited) is acknowledged, so it is not repeated
echo "=== Test 7h: a gone window is reported once, not every pass ==="
mk_task t-exited
cat > "$KINGPIN_HOME/tasks/t-exited/task.env" << ENV
PROJECT=demo
HARNESS=claude
MODE=review
TMUX_TARGET=kingpin:no-such-window
TMUX_WINDOW_ID=@999999
ENV
echo 1 > "$KINGPIN_HOME/tasks/t-exited/seen"
exit_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$exit_out" | grep -q "^t-exited exited" \
  && pass "a gone window is reported before the ack" \
  || fail "the gone window was not reported (got: $exit_out)"
"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1
[ -f "$KINGPIN_HOME/tasks/t-exited/seen_exited" ] \
  && pass "watch --once acknowledged the status-less exited event" \
  || fail "watch --once left seen_exited unwritten (the event repeats forever)"
set +e
exit_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null)
exit_rc=$?
set -e
[ "$exit_rc" -eq 1 ] && [ -z "$exit_out" ] \
  && pass "the exited event is not reported again" \
  || fail "the exited event repeated (rc=$exit_rc out=$exit_out)"

# Test 7i: a task directory with task.env and no status file is acknowledged too
echo "=== Test 7i: a task with no status file still gets its event acknowledged ==="
mkdir -p "$KINGPIN_HOME/tasks/t-nostatus"
cat > "$KINGPIN_HOME/tasks/t-nostatus/task.env" << ENV
PROJECT=demo
HARNESS=claude
MODE=review
TMUX_TARGET=kingpin:no-such-window
TMUX_WINDOW_ID=@999999
ENV
nostatus_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$nostatus_out" | grep -q "^t-nostatus exited" \
  && pass "a status-less task directory is reported before any ack" \
  || fail "the status-less task was not reported (got: $nostatus_out)"
"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1
[ -f "$KINGPIN_HOME/tasks/t-nostatus/seen_exited" ] \
  && pass "watch --once acknowledged a task directory with no status file" \
  || fail "watch --once skipped the ack for a task with no status file (the event repeats forever)"
set +e
nostatus_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null)
nostatus_rc=$?
set -e
[ "$nostatus_rc" -eq 1 ] && [ -z "$nostatus_out" ] \
  && pass "the status-less event is not reported again" \
  || fail "the status-less event repeated (rc=$nostatus_rc out=$nostatus_out)"
rm -rf "$KINGPIN_HOME/tasks/t-nostatus"

# Test 7j: a line a dispatch appends is past the pass's own snapshot, so it waits
echo "=== Test 7j: a line the dispatch appends stays pending for the next pass ==="
snap_wt="$T/wt-snap"
mkdir -p "$snap_wt"
git -C "$snap_wt" init -q
echo dirty > "$snap_wt/uncommitted.txt"
mk_task t-snapshot
printf 'PROJECT_PATH=%s\nWORKTREE=%s\n' "$T" "$snap_wt" >> "$KINGPIN_HOME/tasks/t-snapshot/task.env"
printf 'merged: pr=https://example.test/pr/73\n' >> "$KINGPIN_HOME/tasks/t-snapshot/status"
"$KP_BIN/kingpin-watch" --once >> "$LOG" 2>&1
log_has "[kingpin-watch] t-snapshot merged; running cleanup..." \
  && pass "the merged: line was dispatched" \
  || fail "merged: was not dispatched: $(cat "$LOG")"
grep -q '^cleanup-refused:' "$KINGPIN_HOME/tasks/t-snapshot/status" \
  && pass "the refusing cleanup appended cleanup-refused: during the pass" \
  || fail "the cleanup did not refuse: $(cat "$KINGPIN_HOME/tasks/t-snapshot/status")"
[ "$(wc -l < "$KINGPIN_HOME/tasks/t-snapshot/status" | tr -d ' ')" = "3" ] \
  && pass "the status file holds the appended refusal past the snapshot" \
  || fail "expected 3 status lines, got: $(cat "$KINGPIN_HOME/tasks/t-snapshot/status")"
[ "$(seen_count t-snapshot)" = "2" ] \
  && pass "the cursor stopped one line short of the line the dispatch appended" \
  || fail "t-snapshot seen=$(seen_count t-snapshot), expected 2 (the pass acked past its own snapshot)"
"$KP_BIN/kingpin-watch" --once >> "$LOG" 2>&1
log_has "[kingpin-watch] t-snapshot cleanup refused: worktree" \
  && pass "the next pass dispatched the appended refusal" \
  || fail "the appended refusal was swallowed: $(cat "$LOG")"
[ "$(seen_count t-snapshot)" = "3" ] \
  && pass "the next pass acknowledged the refusal" \
  || fail "t-snapshot seen=$(seen_count t-snapshot), expected 3"
rm -rf "$KINGPIN_HOME/tasks/t-snapshot" "$snap_wt"

# Test 8: stopping the supervisor clears the pidfile and the list line
echo "=== Test 8: supervisor stop ==="
stop_supervisor
wait_until 20 test ! -f "$PID_FILE" && pass "pidfile removed on exit" || fail "pidfile survived the supervisor"
grep -q "Supervisor: none" <<< "$("$KP_BIN/kingpin" list)" \
  && pass "list reports no supervisor after it stops" \
  || fail "list still reports a supervisor"

# Test 9: stale pidfiles are reclaimed, both dead and foreign
echo "=== Test 9: stale pidfile reclaim ==="
printf '999999\n%s\n' "$(date +%s)" > "$PID_FILE"
start_supervisor || fail "supervisor did not reclaim a dead pid"
[ "$WATCH_PID" != "999999" ] && [ "$(sed -n 1p "$PID_FILE" | tr -d ' ')" = "$WATCH_PID" ] \
  && pass "a dead pid is reclaimed" \
  || fail "dead pid was not reclaimed"
stop_supervisor

# A live pid that is not a supervisor (a recycled pid) must not block supervision.
printf '%s\n%s\n' "$$" "$(date +%s)" > "$PID_FILE"
start_supervisor || fail "supervisor did not reclaim a foreign live pid"
[ "$(sed -n 1p "$PID_FILE" | tr -d ' ')" = "$WATCH_PID" ] && [ "$WATCH_PID" != "$$" ] \
  && pass "a live non-supervisor pid is reclaimed" \
  || fail "a foreign live pid blocked the supervisor"
stop_supervisor

# Test 10: the default long interval must not delay a stop
echo "=== Test 10: TERM stops the supervisor promptly ==="
"$KP_BIN/kingpin-watch" >> "$LOG" 2>&1 &
stop_test_pid=$!
wait_until 80 pidfile_names "$stop_test_pid" && pass "supervisor started with the default interval" || fail "supervisor did not start with the default interval"
start=$(date +%s)
kill "$stop_test_pid" 2>/dev/null || true
wait_until 25 test ! -f "$PID_FILE"
elapsed=$(( $(date +%s) - start ))
[ ! -f "$PID_FILE" ] && [ "$elapsed" -le 4 ] \
  && pass "TERM removed the pidfile in ${elapsed}s without waiting for the interval" \
  || fail "TERM took ${elapsed}s or left the pidfile behind"
# Force-stop before the blocking `wait`: a regressed trap must fail this suite, not
# hang it until CI times out.
kill -9 "$stop_test_pid" 2>/dev/null || true
wait "$stop_test_pid" 2>/dev/null || true

tmux kill-window -t "$probe_wid" 2>/dev/null || true
kp_test_finish WATCH-SUPERVISOR
