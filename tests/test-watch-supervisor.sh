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

# One live tmux window stands in for the workers' panes, so `kingpin wait` never
# reports a task as exited while the suite drives its status file.
tmux new-window -t kingpin -n kp99-probe 'exec bash'
probe_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="kp99-probe"{print $1}')
[ -n "$probe_wid" ] && pass "probe window created ($probe_wid)" || fail "could not create the probe window"

mk_task() {
  local id=$1
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  printf 'PROJECT=demo\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:%s\nTMUX_WINDOW_ID=%s\n' \
    "$id" "$probe_wid" > "$KINGPIN_HOME/tasks/$id/task.env"
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
