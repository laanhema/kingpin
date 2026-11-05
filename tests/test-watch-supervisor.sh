#!/usr/bin/env bash
# Verification test for Kingpin: the fleet supervisor (`kingpin watch`) is a daemon.
#
# Covers the pidfile lifecycle (start, second copy refused, stale file reclaimed),
# the `Supervisor:` line in `kingpin list` in both states, the `kingpin lock acquire`
# warning, the shipped `systemd/kingpin-watch.service` unit, and the point of the whole
# change: two events that arrive one after the other are both handled by the one watch
# process, with no re-arm and no human step.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "watch-supervisor"
# Test 13 arms and re-arms listeners for the t-arm task against the default Lavish stub
# on purpose; every recorded call must name it, so the rest of the suite stays armed.
kp_test_expect_lavish_calls '*t-arm*'

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
  kp_wait_until 16 pidfile_names "$WATCH_PID"
}

pidfile_names() {
  [ "$(sed -n 1p "$PID_FILE" 2>/dev/null | tr -d ' ')" = "$1" ]
}

seen_count() {
  local file="$KINGPIN_HOME/tasks/$1/seen"
  [ -f "$file" ] || { echo 0; return 0; }
  tr -d ' \n' < "$file"
}

# seen_is <task-id> <lines>: the cursor reached that line. The supervisor logs a
# handled line before it advances the cursor (a crash in between replays the line,
# never loses it), so a test that reads the cursor the instant a log line appears
# can catch the previous value; wait for the write instead of reading it once.
seen_is() {
  [ "$(seen_count "$1")" = "$2" ]
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

# Test 0: the shipped user unit mirrors kingpin-queue.service and starts the daemon
echo "=== Test 0: the shipped kingpin-watch user unit ==="
unit="$KP_ROOT/systemd/kingpin-watch.service"
[ -f "$unit" ] && pass "the unit file ships with the checkout" || fail "missing $unit"
if [ -f "$unit" ]; then
  [ "$(grep -c '^ExecStart=' "$unit")" = "1" ] \
    && pass "the unit has exactly one ExecStart" \
    || fail "the unit has $(grep -c '^ExecStart=' "$unit") ExecStart lines"
  grep -qE '^ExecStart=.*bin/kingpin watch$' "$unit" \
    && pass "ExecStart runs the supervisor daemon" \
    || fail "ExecStart does not run 'kingpin watch'"
  grep -qE '^ExecStart=.*--once' "$unit" \
    && fail "ExecStart passes --once, which is not a daemon" \
    || pass "ExecStart does not pass --once"
  grep -qx 'Type=simple' "$unit" \
    && pass "the unit is Type=simple" \
    || fail "the unit has no Type=simple"
  grep -qx 'Restart=always' "$unit" \
    && pass "the unit restarts on every exit" \
    || fail "the unit has no Restart=always"
  grep -qx 'RestartSec=30' "$unit" \
    && pass "the unit waits 30s between restarts" \
    || fail "the unit has no RestartSec=30"
  grep -qE '^Environment=PATH=' "$unit" \
    && pass "the unit carries a PATH for gh, tmux, treehouse and lavish-axi" \
    || fail "the unit has no Environment=PATH"
  grep -qx 'WantedBy=default.target' "$unit" \
    && pass "the unit installs for the user's default target" \
    || fail "the unit has no WantedBy=default.target"
fi

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

# Test 3b: a warning from a healthy wait pass reaches the fleet log (#78)
echo "=== Test 3b: a healthy pass's warning is logged ==="
mk_task t-warn
: > "$KINGPIN_HOME/tasks/t-warn/status"
printf 'CREATED=not-a-time\n' >> "$KINGPIN_HOME/tasks/t-warn/task.env"
kp_wait_until 15 log_has "[kingpin-watch] kingpin-wait warning: kingpin-launch-check: cannot parse CREATED='not-a-time'" \
  && pass "a warning from a healthy wait pass reaches the log" \
  || fail "the healthy-pass warning never reached the log: $(cat "$LOG")"
sleep 2
# The fixture records name the default socket and no default server runs here, so the
# pass also carries the dead-server warning (issue #165). Count the task warning only.
[ "$(grep -cF "cannot parse CREATED='not-a-time'" "$LOG")" = "1" ] \
  && pass "the healthy-pass warning is logged once, not on every pass" \
  || fail "the warning repeated: $(grep -cF "cannot parse CREATED='not-a-time'" "$LOG")"
rm -rf "$KINGPIN_HOME/tasks/t-warn"

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
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock release >/dev/null
stop_supervisor
acquire_err=$(KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire 2>&1 >/dev/null || true)
echo "$acquire_err" | grep -q "no fleet supervisor is running" \
  && pass "acquire warns when no supervisor is running" \
  || fail "acquire did not warn: $acquire_err"
echo "$acquire_err" | grep -q "kingpin-watch.service" \
  && pass "the warning names the kingpin-watch unit" \
  || fail "the warning did not name the unit: $acquire_err"
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock release >/dev/null

# Test 7: two events, one watch process, no re-arm anywhere
echo "=== Test 7: two events handled by one supervisor ==="
rm -f "$LOG"
start_supervisor || fail "supervisor did not start for the event test"
first_pid=$WATCH_PID

printf 'needs-input: probe question\n' >> "$KINGPIN_HOME/tasks/t-a/status"
kp_wait_until 15 log_has "[kingpin-watch] t-a needs input" \
  && pass "first event handled" \
  || fail "first event was not handled: $(cat "$LOG")"
kp_wait_until 4 seen_is t-a 2 && pass "first event acknowledged" || fail "t-a seen=$(seen_count t-a)"

printf 'failed: probe failure\n' >> "$KINGPIN_HOME/tasks/t-b/status"
kp_wait_until 15 log_has "[kingpin-watch] t-b reported failure: failed: probe failure" \
  && pass "second event handled after the first, with no re-arm" \
  || fail "second event was not handled: $(cat "$LOG")"
kp_wait_until 4 seen_is t-b 2 && pass "second event acknowledged" || fail "t-b seen=$(seen_count t-b)"

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
kp_wait_until 15 log_has "[kingpin-watch] t-order needs input" \
  && pass "first line of the batch dispatched" \
  || fail "first line of the batch was lost: $(cat "$LOG")"
kp_wait_until 15 log_has "[kingpin-watch] t-order reported failure: failed: batch-second" \
  && pass "second line of the batch dispatched in the same supervisor" \
  || fail "second line of the batch was lost: $(cat "$LOG")"
order_first=$(log_line_of "[kingpin-watch] t-order needs input")
order_second=$(log_line_of "[kingpin-watch] t-order reported failure: failed: batch-second")
[ -n "$order_first" ] && [ -n "$order_second" ] && [ "$order_first" -lt "$order_second" ] \
  && pass "the batch was dispatched in file order" \
  || fail "batch order wrong (first=$order_first second=$order_second)"
kp_wait_until 4 seen_is t-order 3 && pass "the whole batch was acknowledged once" || fail "t-order seen=$(seen_count t-order)"

# Test 7c: issue acceptance - merged: followed by an appended feedback: still cleans up
echo "=== Test 7c: merged: + feedback: runs the cleanup step ==="
mk_task t-merged demo-merged
printf 'merged: pr=https://example.test/pr/73\nfeedback: Request Changes: after merged\n' \
  >> "$KINGPIN_HOME/tasks/t-merged/status"
kp_wait_until 15 log_has "[kingpin-watch] t-merged merged; running cleanup..." \
  && pass "merged: ran the cleanup step despite the feedback: note" \
  || fail "merged: was acked away and never cleaned up: $(cat "$LOG")"
kp_wait_until 15 log_has "[kingpin-watch] t-merged received review feedback: feedback: Request Changes: after merged" \
  && pass "the listener feedback: note was still reported" \
  || fail "the feedback: note was not reported: $(cat "$LOG")"
kp_wait_until 4 seen_is t-merged 3 && pass "merged: + feedback: acknowledged" || fail "t-merged seen=$(seen_count t-merged)"

# Test 7d: issue acceptance - fixed: followed by feedback: during landing still lands
echo "=== Test 7d: fixed: + feedback: runs the land step ==="
mk_task t-fixed demo-fixed
touch "$KINGPIN_HOME/tasks/t-fixed/landing_in_progress"
printf 'fixed: high=0 report=.agents/reviews/r.md\nfeedback: Request Changes: after fixed\n' \
  >> "$KINGPIN_HOME/tasks/t-fixed/status"
kp_wait_until 15 log_has "[kingpin-watch] t-fixed reported fix pass; continuing landing..." \
  && pass "fixed: ran the land step despite the feedback: note" \
  || fail "fixed: was acked away and never landed: $(cat "$LOG")"
kp_wait_until 15 log_has "[kingpin-watch] t-fixed received review feedback: feedback: Request Changes: after fixed" \
  && pass "the feedback: after fixed: was still reported" \
  || fail "the feedback: after fixed: was not reported: $(cat "$LOG")"
kp_wait_until 4 seen_is t-fixed 3 && pass "fixed: + feedback: acknowledged" || fail "t-fixed seen=$(seen_count t-fixed)"

# Test 7e: blank and issue: lines advance the cursor without a dispatch
echo "=== Test 7e: blank and issue: lines are skipped, not dispatched ==="
mk_task t-skip
printf '\nissue: #73 informational\nwaiting: skipped-note\n' >> "$KINGPIN_HOME/tasks/t-skip/status"
kp_wait_until 15 log_has "[kingpin-watch] t-skip is waiting: skipped-note" \
  && pass "the real event after blank and issue: lines was dispatched" \
  || fail "the real event after blank and issue: lines was lost: $(cat "$LOG")"
log_has "[kingpin-watch] t-skip issue:" \
  && fail "an issue: line was dispatched" \
  || pass "issue: lines are not dispatched"
kp_wait_until 4 seen_is t-skip 4 \
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
kp_wait_until 15 log_has "[kingpin-watch] t-restart reported failure: failed: restart-first" \
  && pass "the first undispatched line was dispatched after the restart" \
  || fail "the first undispatched line was lost after the restart: $(cat "$LOG")"
kp_wait_until 15 log_has "[kingpin-watch] t-restart is waiting: restart-second" \
  && pass "the second undispatched line was dispatched after the restart" \
  || fail "the second undispatched line was lost after the restart: $(cat "$LOG")"
log_has "[kingpin-watch] t-restart needs input" \
  && fail "the restart re-dispatched a line the earlier supervisor had handled" \
  || pass "the restart did not repeat a handled line"
kp_wait_until 15 seen_is t-restart 4 \
  && pass "the restart left the cursor at the end" \
  || fail "t-restart seen=$(seen_count t-restart)"

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
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
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
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
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

# Test 7k: a line appended after the status file was rewritten shorter or the same
# length is still dispatched (issue #190). The cursor is a count, so a removed line
# plus an appended one leaves the count pointing past the new line.
echo "=== Test 7k: a merged: line after a rewrite is dispatched ==="
rewrite_wt="$T/wt-rewrite"
mkdir -p "$rewrite_wt"
git -C "$rewrite_wt" init -q
mk_task t-rewrite
printf 'PROJECT_PATH=%s\nWORKTREE=%s\n' "$T" "$rewrite_wt" >> "$KINGPIN_HOME/tasks/t-rewrite/task.env"
t_rewrite="$KINGPIN_HOME/tasks/t-rewrite"
# The incident's shape: the duplicate issue: line is the one the worker removes later.
printf 'issue: #190 https://example.test/190\nneeds-input: probe\nissue: #190 https://example.test/190\nready: branch=b review=APPROVE report=r.md\napproved: auto (afk)\n' > "$t_rewrite/status"
"$KP_BIN/kingpin-ack" --through 5 t-rewrite >/dev/null 2>&1 || true
[ "$(seen_count t-rewrite)" = "5" ] \
  && pass "the cursor was taken at five lines" \
  || fail "the fixture cursor is $(seen_count t-rewrite), expected 5"
# The rewrite: without the duplicate, with merged: appended. Same length as before.
printf 'issue: #190 https://example.test/190\nneeds-input: probe\nready: branch=b review=APPROVE report=r.md\napproved: auto (afk)\n' > "$t_rewrite/status"
printf 'merged: pr=https://example.test/pr/190\n' >> "$t_rewrite/status"
[ "$(wc -l < "$t_rewrite/status" | tr -d ' ')" = "5" ] \
  && pass "the rewritten file is as long as the cursor, so a count cannot see it" \
  || fail "the fixture rewrite is not the incident's shape: $(wc -l < "$t_rewrite/status")"
rewrite_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$rewrite_out" | grep -q "^t-rewrite status" \
  && pass "kingpin-wait reports a file rewritten under the cursor" \
  || fail "the rewrite raised no event (got: $rewrite_out)"
"$KP_BIN/kingpin-watch" --once >> "$LOG" 2>&1
log_has "[kingpin-watch] t-rewrite merged; running cleanup..." \
  && pass "the merged: line past the cursor was dispatched" \
  || fail "merged: was never dispatched: $(cat "$LOG")"
log_has "t-rewrite status file was rewritten under its cursor" \
  && pass "the rewrite is named in the log with the task" \
  || fail "the rewrite went unreported: $(cat "$LOG")"
grep -q '^cleanup-refused:' "$t_rewrite/status" \
  && pass "kingpin done ran for the rewritten task" \
  || fail "kingpin done never ran: $(cat "$t_rewrite/status")"
"$KP_BIN/kingpin-watch" --once >> "$LOG" 2>&1
[ "$(grep -cF 't-rewrite status file was rewritten' "$LOG")" = "1" ] \
  && pass "the rewrite is reported once, not on every pass" \
  || fail "the rewrite report repeated: $(grep -cF 't-rewrite status file was rewritten' "$LOG")"
rm -rf "$t_rewrite" "$rewrite_wt"

# Test 7l: a record written before seen_line existed keeps working. Its cursor has
# no anchor, so nothing looks rewritten and dispatch starts where the count says.
echo "=== Test 7l: a record without an anchor keeps its old behaviour ==="
mk_task t-legacy
printf 'needs-input: legacy-question\n' >> "$KINGPIN_HOME/tasks/t-legacy/status"
printf '1\n' > "$KINGPIN_HOME/tasks/t-legacy/seen"
"$KP_BIN/kingpin-watch" --once >> "$LOG" 2>&1
log_has "[kingpin-watch] t-legacy needs input" \
  && pass "an anchor-less record still dispatches its pending line" \
  || fail "an anchor-less record lost its line: $(cat "$LOG")"
log_has "t-legacy status file was rewritten" \
  && fail "an anchor-less record was reported as rewritten" \
  || pass "an anchor-less record is not reported as rewritten"
[ -s "$KINGPIN_HOME/tasks/t-legacy/seen_line" ] \
  && pass "the pass wrote the anchor for the next one" \
  || fail "the cursor gained no anchor"
[ "$(sed -n 1p "$KINGPIN_HOME/tasks/t-legacy/seen_line" 2>/dev/null || true)" = "needs-input: legacy-question" ] \
  && pass "the anchor is the handled line's own text" \
  || fail "the anchor is '$(sed -n 1p "$KINGPIN_HOME/tasks/t-legacy/seen_line" 2>/dev/null || true)'"
rm -rf "$KINGPIN_HOME/tasks/t-legacy"

# Test 8: stopping the supervisor clears the pidfile and the list line
echo "=== Test 8: supervisor stop ==="
stop_supervisor
kp_wait_until 4 test ! -f "$PID_FILE" && pass "pidfile removed on exit" || fail "pidfile survived the supervisor"
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
kp_wait_until 16 pidfile_names "$stop_test_pid" && pass "supervisor started with the default interval" || fail "supervisor did not start with the default interval"
start=$(date +%s)
kill "$stop_test_pid" 2>/dev/null || true
kp_wait_until 5 test ! -f "$PID_FILE"
elapsed=$(( $(date +%s) - start ))
[ ! -f "$PID_FILE" ] && [ "$elapsed" -le 4 ] \
  && pass "TERM removed the pidfile in ${elapsed}s without waiting for the interval" \
  || fail "TERM took ${elapsed}s or left the pidfile behind"
# Force-stop before the blocking `wait`: a regressed trap must fail this suite, not
# hang it until CI times out.
kill -9 "$stop_test_pid" 2>/dev/null || true
wait "$stop_test_pid" 2>/dev/null || true

# Test 11: --interval is validated before anything is claimed. Every run is bounded:
# a value the validation lets through starts the supervisor and blocks, and a
# regression must fail this suite rather than hang it until CI times out.
echo "=== Test 11: --interval is validated ==="
iv_rc=0; iv_err=$(timeout 5 "$KP_BIN/kingpin-watch" --interval abc 2>&1 >/dev/null) || iv_rc=$?
[ "$iv_rc" -eq 2 ] && echo "$iv_err" | grep -q "kingpin-watch: --interval" \
  && pass "--interval abc exits 2 with a message" || fail "--interval abc: rc $iv_rc, $iv_err"
iv_rc=0; iv_err=$(timeout 5 "$KP_BIN/kingpin-watch" --interval 0 2>&1 >/dev/null) || iv_rc=$?
[ "$iv_rc" -eq 2 ] && pass "--interval 0 exits 2" || fail "--interval 0: rc $iv_rc, $iv_err"
# Past bash's integer range `[ -lt ]` errors instead of comparing, so the digit
# count is what must reject it.
iv_rc=0; iv_err=$(timeout 5 "$KP_BIN/kingpin-watch" --interval 99999999999999999999 2>&1 >/dev/null) || iv_rc=$?
[ "$iv_rc" -eq 2 ] && echo "$iv_err" | grep -q "kingpin-watch: --interval is too large" \
  && pass "--interval past the shell's integer range exits 2" || fail "--interval huge: rc $iv_rc, $iv_err"
iv_rc=0; iv_err=$(timeout 5 "$KP_BIN/kingpin-watch" --interval 2>&1 >/dev/null) || iv_rc=$?
[ "$iv_rc" -eq 2 ] && echo "$iv_err" | grep -q "kingpin-watch: --interval needs a whole number of seconds" \
  && pass "--interval without a value exits 2 with the command's own message" \
  || fail "--interval with no value: rc $iv_rc, $iv_err"
[ ! -f "$PID_FILE" ] && pass "a bad --interval claims no pidfile" || fail "bad --interval wrote $PID_FILE"

# Test 12: a failing kingpin-wait warns once and backs off instead of spinning
echo "=== Test 12: a failing kingpin-wait backs off ==="
BACKOFF_LOG="$T/backoff.log"
WAIT_CALLS="$T/wait-calls"
export KP_TEST_WAIT_CALLS="$WAIT_CALLS"
cp -p "$KP_BIN/kingpin-wait" "$T/kingpin-wait.orig"
cat > "$KP_BIN/kingpin-wait" << 'WK'
#!/usr/bin/env bash
echo "call" >> "$KP_TEST_WAIT_CALLS"
echo "kingpin-wait: cannot use fleet directory /nonexistent/tasks" >&2
exit 1
WK
chmod +x "$KP_BIN/kingpin-wait"
rm -f "$WAIT_CALLS"
"$KP_BIN/kingpin-watch" --interval 1 >> "$BACKOFF_LOG" 2>&1 &
backoff_pid=$!
kp_wait_until 16 pidfile_names "$backoff_pid" || fail "supervisor did not start against a failing wait"
sleep 3
kill "$backoff_pid" 2>/dev/null || true
wait "$backoff_pid" 2>/dev/null || true
calls=0
[ -f "$WAIT_CALLS" ] && calls=$(wc -l < "$WAIT_CALLS" | tr -d ' ')
[ "$calls" -ge 1 ] && [ "$calls" -le 3 ] \
  && pass "a failing wait ran $calls times in 3 s (it backs off)" \
  || fail "a failing wait ran $calls times in 3 s (it spins)"
warns=$(grep -cF "kingpin-wait failed" "$BACKOFF_LOG" 2>/dev/null || true)
[ "$warns" = "1" ] && pass "the supervisor warned exactly once per failure streak" || fail "warnings for a failing wait: $warns"
grep -qF "cannot use fleet directory" "$BACKOFF_LOG" \
  && pass "the warning carries kingpin-wait's reason" \
  || fail "warning lost the reason: $(cat "$BACKOFF_LOG")"
# --once keeps its one-shot contract: the sweeps run and the command exits 0.
once_rc=0
"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1 || once_rc=$?
[ "$once_rc" -eq 0 ] && pass "--once keeps its exit 0 one-shot contract" || fail "--once exited $once_rc against a failing wait"
cp -p "$T/kingpin-wait.orig" "$KP_BIN/kingpin-wait"

# Test 12b: a warning streak that ends is logged again when the same warning returns
echo "=== Test 12b: a warning that clears and returns is logged again ==="
# Test 3b proves a warning is logged once while it persists. A pass with no warning at
# all ends the streak, so a fault that clears and returns hours later must reach the
# log again instead of staying silent for the supervisor's life (#165 review L2).
STREAK_LOG="$T/streak.log"
export KP_TEST_STREAK_COUNT="$T/streak-count"
cp -p "$KP_BIN/kingpin-wait" "$T/kingpin-wait.streak"
cat > "$KP_BIN/kingpin-wait" << 'WK'
#!/usr/bin/env bash
# Pace the loop the way a real wait does, and warn on the first and third pass only:
# a streak, a healthy pass with no warning, then the same warning again.
n=$(cat "$KP_TEST_STREAK_COUNT" 2>/dev/null || true)
n=$(( ${n:-0} + 1 ))
printf '%s\n' "$n" > "$KP_TEST_STREAK_COUNT"
case "$n" in
  1|3) echo "kingpin-wait: a warning that comes and goes" >&2 ;;
esac
sleep 0.3
exit 0
WK
chmod +x "$KP_BIN/kingpin-wait"
: > "$KP_TEST_STREAK_COUNT"
"$KP_BIN/kingpin-watch" --interval 1 >> "$STREAK_LOG" 2>&1 &
streak_pid=$!
kp_wait_until 16 pidfile_names "$streak_pid" || fail "supervisor did not start against the streak fixture"
sleep 3
kill "$streak_pid" 2>/dev/null || true
wait "$streak_pid" 2>/dev/null || true
streak_warns=$(grep -cF "a warning that comes and goes" "$STREAK_LOG" 2>/dev/null || true)
[ "$streak_warns" = "2" ] \
  && pass "a warning that clears and returns is logged again ($streak_warns lines)" \
  || fail "a returning warning stayed silent: $streak_warns line(s) in $(cat "$STREAK_LOG")"
cp -p "$T/kingpin-wait.streak" "$KP_BIN/kingpin-wait"

# Test 13: a dossier listener that dies is re-armed, and every blocker holds
echo "=== Test 13: a dead dossier listener is re-armed ==="
kp_test_stub_lavish
mk_task t-arm
echo '<html><body>review</body></html>' > "$KINGPIN_HOME/tasks/t-arm/report.html"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-arm/status"
"$KP_BIN/kingpin-ack" t-arm

listener_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
listener_dead() { [ -z "${1:-}" ] || ! kill -0 "$1" 2>/dev/null; }

# live_listener_pid <pid-file> <dead-pid>: the file names a live pid other than
# the dead one the test wrote. `kingpin-listen --background` returns as soon as
# any pid file exists, so the child that replaces the dead pid can still be
# writing it after the launcher has exited; poll for the child, do not read the
# stale value.
live_listener_pid() {
  local pid
  pid=$(cat "${1:?}" 2>/dev/null || true)
  [ -n "$pid" ] && [ "$pid" != "${2:?}" ] && listener_alive "$pid"
}

# A real listener, killed the way a crash kills one: the sweep must replace it.
"$KP_BIN/kingpin-listen" t-arm --background
started_pid=$(cat "$KINGPIN_HOME/tasks/t-arm/listener.pid" 2>/dev/null || true)
listener_alive "$started_pid" && pass "the listener started (pid $started_pid)" || fail "no live listener before the kill"
kill -- "-$started_pid" 2>/dev/null || kill "$started_pid" 2>/dev/null || true
kp_wait_until 8 listener_dead "$started_pid" && pass "the listener was killed" || fail "listener $started_pid survived the kill"
arm_out=$("$KP_BIN/kingpin-watch" --once 2>&1)
echo "$arm_out" | grep -q "t-arm: dossier listener is gone; re-arming" \
  && pass "watch reports the dead listener" || fail "no re-arming line: $arm_out"
arm_pid_file="$KINGPIN_HOME/tasks/t-arm/listener.pid"
kp_wait_until 8 live_listener_pid "$arm_pid_file" "$started_pid" \
  && pass "watch re-armed a live listener (pid $(cat "$arm_pid_file"))" \
  || fail "listener pid after --once: $(cat "$arm_pid_file" 2>/dev/null || true)"
arm_pid=$(cat "$arm_pid_file" 2>/dev/null || true)
kill -- "-$arm_pid" 2>/dev/null || kill "$arm_pid" 2>/dev/null || true
kp_wait_until 8 listener_dead "$arm_pid"

# A task.env without MODE is a review task, exactly as process_task_event reads it.
reset_arm_task() {
  printf 'PROJECT=demo\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:t-arm\nTMUX_WINDOW_ID=%s\n' \
    "$probe_wid" > "$KINGPIN_HOME/tasks/t-arm/task.env"
  printf 'issue: #74\nready: branch=b review=APPROVE report=none\n' > "$KINGPIN_HOME/tasks/t-arm/status"
  # The ready: line is already handled, so these cases exercise the re-arm sweep
  # and not the dispatch branch; the cursor and its anchor are left consistent with
  # the two-line file it now holds (issue #190).
  printf '2\n' > "$KINGPIN_HOME/tasks/t-arm/seen"
  rm -f "$KINGPIN_HOME/tasks/t-arm/seen_line"
  echo '<html><body>review</body></html>' > "$KINGPIN_HOME/tasks/t-arm/report.html"
  rm -f "$KINGPIN_HOME/tasks/t-arm/lavish_ended" "$KINGPIN_HOME/tasks/t-arm/landing_sent" \
    "$KINGPIN_HOME/tasks/t-arm/landing_in_progress" "$KINGPIN_HOME/tasks/t-arm/done_cleaned"
  printf '999999\n' > "$KINGPIN_HOME/tasks/t-arm/listener.pid"
}

assert_no_rearm() {
  local out
  out=$("$KP_BIN/kingpin-watch" --once 2>&1)
  if echo "$out" | grep -q "re-arming"; then
    fail "$1: watch re-armed a task it must leave alone: $out"
  elif [ "$(cat "$KINGPIN_HOME/tasks/t-arm/listener.pid" 2>/dev/null || true)" != "999999" ]; then
    fail "$1: listener.pid no longer names the dead pid"
  else
    pass "$1: re-arm refused"
  fi
}

reset_arm_task
printf 'PROJECT=demo\nHARNESS=claude\nTMUX_TARGET=kingpin:t-arm\nTMUX_WINDOW_ID=%s\n' "$probe_wid" \
  > "$KINGPIN_HOME/tasks/t-arm/task.env"
default_out=$("$KP_BIN/kingpin-watch" --once 2>&1)
echo "$default_out" | grep -q "t-arm: dossier listener is gone; re-arming" \
  && pass "a task.env without MODE defaults to review and is re-armed" \
  || fail "a missing MODE skipped the re-arm: $default_out"
default_pid_file="$KINGPIN_HOME/tasks/t-arm/listener.pid"
kp_wait_until 8 live_listener_pid "$default_pid_file" 999999 \
  && pass "the default-mode task got a live listener (pid $(cat "$default_pid_file"))" \
  || fail "listener pid after the default-mode sweep: $(cat "$default_pid_file" 2>/dev/null || true)"
default_pid=$(cat "$default_pid_file" 2>/dev/null || true)
kill -- "-$default_pid" 2>/dev/null || kill "$default_pid" 2>/dev/null || true
kp_wait_until 8 listener_dead "$default_pid"

# Test 13b: a listener that could not be launched is named, not reported as started (issue #182)
cp -p "$KP_BIN/kingpin-listen" "$T/kingpin-listen.orig"
cat > "$KP_BIN/kingpin-listen" << 'LISTEN'
#!/usr/bin/env bash
echo "kingpin-listen: refusing to launch from the suite" >&2
exit 1
LISTEN
chmod +x "$KP_BIN/kingpin-listen"
reset_arm_task
rm -f "$KINGPIN_HOME/tasks/t-arm/seen"
refused_out=$("$KP_BIN/kingpin-watch" --once 2>&1)
echo "$refused_out" | grep -q "could not start the dossier listener" \
  && pass "a refused listener launch in the ready branch is reported" \
  || fail "the ready-branch listener refusal is silent: $refused_out"
echo "$refused_out" | grep -q "could not re-arm the dossier listener" \
  && pass "a refused re-arm is reported" \
  || fail "the re-arm refusal is silent: $refused_out"
cp -p "$T/kingpin-listen.orig" "$KP_BIN/kingpin-listen"

# Test 13c: a launcher that exits 0 with nothing running is not called started
# (issue #182 review M1). `kingpin-listen --background` exits 0 without a listener
# when it cannot take the launch lock and when its child never writes listener.pid;
# the launch status alone does not mean a listener is up.
cat > "$KP_BIN/kingpin-listen" << 'LISTEN'
#!/usr/bin/env bash
echo "kingpin-listen: the suite's launcher starts nothing" >&2
exit 0
LISTEN
chmod +x "$KP_BIN/kingpin-listen"
reset_arm_task
rm -f "$KINGPIN_HOME/tasks/t-arm/seen"
quiet_out=$("$KP_BIN/kingpin-watch" --once 2>&1)
echo "$quiet_out" | grep -q "could not start the dossier listener" \
  && pass "a launch that exits 0 with no listener is not reported as started" \
  || fail "a listener-less launch was reported as started: $quiet_out"
echo "$quiet_out" | grep -q "dossier listener started" \
  && fail "the ready branch printed its success line for a listener-less launch: $quiet_out" \
  || pass "the ready branch prints no listener success line"
echo "$quiet_out" | grep -q "the suite's launcher starts nothing" \
  && pass "the launcher's own reason reaches the operator" \
  || fail "the launcher's reason stayed hidden: $quiet_out"
echo "$quiet_out" | grep -q "could not re-arm the dossier listener" \
  && pass "a re-arm that starts nothing is reported" \
  || fail "the re-arm of a listener-less launch is silent: $quiet_out"
cp -p "$T/kingpin-listen.orig" "$KP_BIN/kingpin-listen"

# Test 13d: a host without lavish-axi is the real shape of that case. The launcher
# prints its note and exits 0; the sweep must say a listener could not be started
# and repeat the note, not report a started listener.
reset_arm_task
rm -f "$KINGPIN_HOME/tasks/t-arm/seen"
missing_out=$(KINGPIN_LAVISH=/nonexistent/lavish-axi "$KP_BIN/kingpin-watch" --once 2>&1)
echo "$missing_out" | grep -q "could not start the dossier listener" \
  && pass "a host without lavish-axi is reported, not called started" \
  || fail "a missing lavish-axi was reported as a started listener: $missing_out"
echo "$missing_out" | grep -q "not installed; skipping" \
  && pass "the launcher's missing-binary note reaches the operator" \
  || fail "the missing-binary note stayed hidden: $missing_out"

# Every blocker keeps the dead pid in place.
reset_arm_task; touch "$KINGPIN_HOME/tasks/t-arm/lavish_ended"; assert_no_rearm "a reviewer-ended session"
reset_arm_task; touch "$KINGPIN_HOME/tasks/t-arm/landing_sent"; assert_no_rearm "a decided review"
reset_arm_task; touch "$KINGPIN_HOME/tasks/t-arm/landing_in_progress"; assert_no_rearm "a landing in progress"
reset_arm_task
printf 'PROJECT=demo\nHARNESS=claude\nMODE=auto\nTMUX_TARGET=kingpin:t-arm\nTMUX_WINDOW_ID=%s\n' "$probe_wid" \
  > "$KINGPIN_HOME/tasks/t-arm/task.env"
assert_no_rearm "auto mode"
reset_arm_task; printf 'needs-input: probe\n' >> "$KINGPIN_HOME/tasks/t-arm/status"; assert_no_rearm "a task that is not at ready:/fixed:"
reset_arm_task; touch "$KINGPIN_HOME/tasks/t-arm/done_cleaned"; assert_no_rearm "a finished task"
reset_arm_task; rm -f "$KINGPIN_HOME/tasks/t-arm/report.html"; assert_no_rearm "a task without report.html"
reset_arm_task; rm -f "$KINGPIN_HOME/tasks/t-arm/task.env"; assert_no_rearm "a task without task.env"

rm -rf "$KINGPIN_HOME/tasks/t-arm"
# Put the default stub back rather than unsetting KINGPIN_LAVISH: an unset value
# resolves the real lavish-axi from PATH again (issue #129).
kp_test_stub_lavish

tmux kill-window -t "$probe_wid" 2>/dev/null || true
kp_test_finish WATCH-SUPERVISOR
