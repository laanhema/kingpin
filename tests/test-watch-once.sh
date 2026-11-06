#!/usr/bin/env bash
# Verification suite for Kingpin issue #209: one status line is dispatched once,
# however many sweeps run.
#
# `kingpin run` calls `kingpin-watch --once` in a loop, and `--once` does not claim
# the supervisor pidfile (#99). Before the shared sweep lock, a `--once` sweep and
# the running supervisor's sweep could both read the same `seen` cursor and both
# dispatch the line. The dispatch under test is a stubbed `kingpin-done` that only
# records and sleeps, so its count is the dispatch count with no downstream guard
# (the real `kingpin-done` has a single-flight lock) hiding a second one.
#
# The suite also covers the lock's lifetime: a slow sweep refreshes its mutex with a
# heartbeat instead of being reclaimed, and the daemon skips a pass on a held lock
# and dispatches the un-acked line on a later wait.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "watch-once"

CALLS="$T/done-calls"
LOG="$T/supervisor.log"
MUTEX="$KINGPIN_HOME/locks/watch-sweep.mutex"
WATCH_PID=''
: > "$CALLS"
: > "$LOG"

# One live tmux window stands in for the workers' panes, so `kingpin wait` never
# reports a fixture task as exited while the suite drives its status file.
tmux new-window -t kingpin -n kp209-probe 'exec bash'
probe_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="kp209-probe"{print $1}')
[ -n "$probe_wid" ] && pass "probe window created ($probe_wid)" || fail "could not create the probe window"

# The dispatch under test: record the call, then sleep long enough that a second
# sweep started at once reads the cursor before this dispatch acks it. It writes
# no `done_cleaned` marker, because that marker would hide a second dispatch. The
# sleep is the dispatch window, and Test 5 widens it so the sweep outlives the
# mutex helper's one-minute staleness rule.
cp -p "$KP_BIN/kingpin-done" "$T/kingpin-done.orig"
cat > "$KP_BIN/kingpin-done" <<'DONE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KP_TEST_DONE_CALLS:?}"
sleep "${KP_TEST_DONE_SLEEP:-2}"
exit 0
DONE
chmod +x "$KP_BIN/kingpin-done"
export KP_TEST_DONE_CALLS="$CALLS"
# kp_test_cleanup restores every $T/kingpin-*.orig file, so a failure cannot leave
# the stub in place; this puts it back early for the assertions after Test 3.
restore_done() { cp -p "$T/kingpin-done.orig" "$KP_BIN/kingpin-done"; }

mk_task() {
  local id=$1
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  printf 'PROJECT=demo\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:%s\nTMUX_WINDOW_ID=%s\n' \
    "$id" "$probe_wid" > "$KINGPIN_HOME/tasks/$id/task.env"
  # An informational line only, so the task starts with no pending event.
  printf 'issue: #209\n' > "$KINGPIN_HOME/tasks/$id/status"
}

seen_count() {
  local file="$KINGPIN_HOME/tasks/$1/seen"
  [ -f "$file" ] || { echo 0; return 0; }
  tr -d ' \n' < "$file"
}

seen_is() { [ "$(seen_count "$1")" = "$2" ]; }

dispatch_count() {
  [ -f "$CALLS" ] || { echo 0; return 0; }
  wc -l < "$CALLS" | tr -d ' '
}

calls_started() { [ "$(dispatch_count)" -ge 1 ]; }

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
  [ "$(sed -n 1p "$KINGPIN_HOME/supervisor.pid" 2>/dev/null | tr -d ' ')" = "$1" ]
}

# Test 1: the reproduction. Two sweeps start together; the first dispatches a
# merged: line and sleeps in the stub, and the second must not dispatch it again.
echo "=== Test 1: two concurrent --once sweeps dispatch a line once ==="
mk_task t-double
printf 'merged: pr=https://example.test/pr/209\n' >> "$KINGPIN_HOME/tasks/t-double/status"
timeout 60 "$KP_BIN/kingpin-watch" --once >/dev/null 2>"$T/first.err" &
first_pid=$!
timeout 60 "$KP_BIN/kingpin-watch" --once >/dev/null 2>"$T/second.err" &
second_pid=$!
wait "$first_pid" || true
wait "$second_pid" || true
[ "$(dispatch_count)" = "1" ] \
  && pass "two concurrent sweeps dispatched the line once" \
  || fail "the line was dispatched $(dispatch_count) times: $(cat "$CALLS")"
kp_wait_until 4 seen_is t-double 2 \
  && pass "the cursor reached the line once" \
  || fail "t-double seen=$(seen_count t-double), expected 2"
rm -rf "$KINGPIN_HOME/tasks/t-double"

# Test 2: the issue's own shape, a `--once` sweep beside the running supervisor.
# The stub holds the dispatch open, so `--once` runs while the supervisor has the
# line in hand. It must wait for the sweep lock and find nothing pending.
echo "=== Test 2: --once beside the running supervisor dispatches once ==="
: > "$CALLS"
mk_task t-beside
start_supervisor || fail "supervisor did not start"
printf 'merged: pr=https://example.test/pr/209\n' >> "$KINGPIN_HOME/tasks/t-beside/status"
kp_wait_until 15 calls_started \
  && pass "the supervisor started the dispatch" \
  || fail "the supervisor never dispatched the line: $(cat "$LOG")"
once_out='' once_rc=0
kp_run once_out once_rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$once_rc" -eq 0 ] \
  && pass "--once exits 0 beside the running supervisor" \
  || fail "--once exited $once_rc: $once_out"
[ "$(dispatch_count)" = "1" ] \
  && pass "the line was dispatched once in total" \
  || fail "the line was dispatched $(dispatch_count) times: $(cat "$CALLS")"
kp_wait_until 4 seen_is t-beside 2 \
  && pass "the supervisor's ack stands after the --once pass" \
  || fail "t-beside seen=$(seen_count t-beside), expected 2"
[ "$(sed -n 1p "$KINGPIN_HOME/supervisor.pid" 2>/dev/null | tr -d ' ')" = "$WATCH_PID" ] \
  && kill -0 "$WATCH_PID" 2>/dev/null \
  && pass "--once left the supervisor and its pidfile alone" \
  || fail "--once disturbed the supervisor's pidfile"
stop_supervisor
rm -rf "$KINGPIN_HOME/tasks/t-beside"

# Test 3: a held sweep lock makes --once skip, never refuse. The suite's own pid
# is the live holder, so this is the same contention a long supervisor sweep gives.
echo "=== Test 3: a held sweep lock skips the pass, without refusing ==="
: > "$CALLS"
mk_task t-held
printf 'merged: pr=https://example.test/pr/209\n' >> "$KINGPIN_HOME/tasks/t-held/status"
mkdir -p "$KINGPIN_HOME/locks"
printf '%s\n' "$$" > "$MUTEX"
held_out='' held_rc=0
kp_run held_out held_rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$held_rc" -eq 0 ] \
  && pass "--once exits 0 when another sweep holds the lock" \
  || fail "--once exited $held_rc when the lock was held: $held_out"
echo "$held_out" | grep -qF "another sweep is running (pid $$)" \
  && pass "the skipped pass names the lock holder" \
  || fail "the skipped pass did not name pid $$: $held_out"
[ "$(dispatch_count)" = "0" ] \
  && pass "the skipped pass dispatched nothing" \
  || fail "the skipped pass dispatched: $(cat "$CALLS")"
[ "$(seen_count t-held)" = "0" ] \
  && pass "the skipped pass left the cursor untouched" \
  || fail "t-held seen=$(seen_count t-held), expected 0 (no pass had acked it)"

# Test 4: once the holder releases, the next pass dispatches exactly once.
echo "=== Test 4: the next pass dispatches after the lock is released ==="
rm -f "$MUTEX"
next_out='' next_rc=0
kp_run next_out next_rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$next_rc" -eq 0 ] \
  && pass "the next pass exits 0" \
  || fail "the next pass exited $next_rc: $next_out"
[ "$(dispatch_count)" = "1" ] \
  && pass "the released line was dispatched once" \
  || fail "the released line was dispatched $(dispatch_count) times: $(cat "$CALLS")"
kp_wait_until 4 seen_is t-held 2 \
  && pass "the released pass acknowledged the line" \
  || fail "t-held seen=$(seen_count t-held), expected 2"
rm -rf "$KINGPIN_HOME/tasks/t-held"

# Test 5 (review H1): a sweep that runs longer than the mutex helper's one-minute
# staleness rule keeps its lock. The stub holds the dispatch for 45 s, the mutex is
# aged past a minute while the sweep is alive, and a second --once starts only after
# the 15 s heartbeat has had a chance to refresh the file. Without the heartbeat the
# aged file is reclaimed and the same line is dispatched a second time. The 15 s
# interval is four refreshes inside that minute, so scheduler jitter cannot leave a
# live lock older than the rule; the 45 s dispatch window leaves the second sweep's
# own retry budget room to give up while the first still holds the lock.
echo "=== Test 5: a slow live sweep keeps its lock ==="
: > "$CALLS"
mk_task t-aged
printf 'merged: pr=https://example.test/pr/209\n' >> "$KINGPIN_HOME/tasks/t-aged/status"
mutex_fresh() { [ -n "$(find "$MUTEX" -maxdepth 0 -mmin -1 2>/dev/null)" ]; }
export KP_TEST_DONE_SLEEP=45
timeout 120 "$KP_BIN/kingpin-watch" --once >/dev/null 2>"$T/aged-first.err" &
first_pid=$!
kp_wait_until 10 calls_started \
  && pass "the slow sweep started the dispatch" \
  || fail "the slow sweep never dispatched: $(cat "$T/aged-first.err")"
kp_wait_until 4 mutex_fresh \
  && pass "the slow sweep holds the mutex" \
  || fail "the slow sweep never created the mutex"
kp_test_touch_ago "$MUTEX" 120
mutex_fresh \
  && fail "the mutex still reads fresh after it was aged" \
  || pass "the mutex was aged past the staleness rule"
kp_wait_until 20 mutex_fresh \
  && pass "the heartbeat refreshed the live sweep's mutex" \
  || fail "the live sweep did not refresh its mutex within 20 s"
aged_out='' aged_rc=0
kp_run aged_out aged_rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$aged_rc" -eq 0 ] \
  && pass "the second sweep exits 0 beside the live holder" \
  || fail "the second sweep exited $aged_rc: $aged_out"
[ "$(dispatch_count)" = "1" ] \
  && pass "the slow sweep's line was dispatched once" \
  || fail "the line was dispatched $(dispatch_count) times: $(cat "$CALLS")"
wait "$first_pid" || true
unset KP_TEST_DONE_SLEEP
rm -rf "$KINGPIN_HOME/tasks/t-aged"

# Test 6 (review L2): the daemon's own skip path. A live holder makes the
# supervisor's pass skip and name it; the line stays un-acked, so the next wait
# raises it again and the daemon dispatches it once after the lock is released.
echo "=== Test 6: the daemon skips a held lock and dispatches after release ==="
: > "$CALLS"
: > "$LOG"
mk_task t-daemon-skip
start_supervisor || fail "supervisor did not start"
mkdir -p "$KINGPIN_HOME/locks"
printf '%s\n' "$$" > "$MUTEX"
printf 'merged: pr=https://example.test/pr/209\n' >> "$KINGPIN_HOME/tasks/t-daemon-skip/status"
daemon_skipped() { grep -qF "another sweep is running (pid $$)" "$LOG"; }
kp_wait_until 25 daemon_skipped \
  && pass "the daemon logged the skipped pass" \
  || fail "the daemon never logged a skipped pass: $(cat "$LOG")"
[ "$(dispatch_count)" = "0" ] \
  && pass "the skipped pass dispatched nothing" \
  || fail "the skipped pass dispatched: $(cat "$CALLS")"
rm -f "$MUTEX"
kp_wait_until 15 calls_started \
  && pass "the daemon dispatched the line on a later wait" \
  || fail "the daemon never dispatched after the lock was released: $(cat "$LOG")"
[ "$(dispatch_count)" = "1" ] \
  && pass "the daemon dispatched the line once" \
  || fail "the line was dispatched $(dispatch_count) times: $(cat "$CALLS")"
kp_wait_until 4 seen_is t-daemon-skip 2 \
  && pass "the daemon acknowledged the line" \
  || fail "t-daemon-skip seen=$(seen_count t-daemon-skip), expected 2"
stop_supervisor
rm -rf "$KINGPIN_HOME/tasks/t-daemon-skip"

restore_done
tmux kill-window -t "$probe_wid" 2>/dev/null || true
kp_test_finish WATCH-ONCE
