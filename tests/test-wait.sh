#!/usr/bin/env bash
# Verification test for Kingpin: kingpin wait and kingpin ack: blocking, wake filtering, exit codes.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "wait"
kp_test_project

# Test 6: kingpin-wait blocking and kingpin ack single-event delivery
echo "=== Test 6: kingpin-wait blocking and kingpin ack single-event delivery ==="
task_w_dir="$KINGPIN_HOME/tasks/test-wait-1"
mkdir -p "$task_w_dir"
tmux new-window -d -t kingpin: -n test-wait-1
cat > "$task_w_dir/task.env" << ENV
PROJECT=demo-auto
HARNESS=claude
MODE=review
TMUX_TARGET=kingpin:test-wait-1
ENV
touch "$task_w_dir/status"
echo 0 > "$task_w_dir/seen"

set +e
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1
initial_exit=$?
set -e
[ "$initial_exit" -eq 1 ] && pass "kingpin-wait --once exits 1 when fleet is quiet" || fail "kingpin-wait --once did not exit 1 (got $initial_exit)"

wait_log="$T/wait-test.log"
"$KP_BIN/kingpin" wait --timeout 10 > "$wait_log" 2>&1 &
wait_pid=$!
sleep 0.5
kill -0 "$wait_pid" 2>/dev/null && pass "kingpin-wait blocks while idle" || fail "kingpin-wait exited prematurely"

t_start=$(date +%s)
echo "needs-input: test question" >> "$task_w_dir/status"
set +e
wait "$wait_pid"
wait_res=$?
set -e
t_end=$(date +%s)
elapsed=$((t_end - t_start))
[ "$wait_res" -eq 0 ] && pass "background kingpin-wait exited 0 on status update" || fail "background kingpin-wait failed with exit $wait_res"
[ "$elapsed" -lt 5 ] && pass "kingpin-wait woke within 5s (${elapsed}s)" || fail "kingpin-wait took ${elapsed}s (>= 5s)"
grep -q "^test-wait-1 status" "$wait_log" && pass "wait output matched test-wait-1 status" || fail "wait output did not match test-wait-1 status"

out_before_ack=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$out_before_ack" | grep -q "^test-wait-1 status" && pass "event persisted before ack" || fail "event did not persist before ack"

"$KP_BIN/kingpin" ack test-wait-1
seen_val=$(cat "$task_w_dir/seen" 2>/dev/null | tr -d ' ' || echo 0)
[ "$seen_val" -eq 1 ] && pass "kingpin ack updated seen to 1" || fail "seen not updated (got $seen_val)"

set +e
out_after_ack=$("$KP_BIN/kingpin" wait --once 2>/dev/null)
ack_exit=$?
set -e
[ "$ack_exit" -eq 1 ] && [ -z "$out_after_ack" ] && pass "kingpin-wait --once exits 1 with no events after ack" || fail "event printed again after ack"

# Test quiet event (the last status is an acknowledged needs-input, so the pane must show activity first)
sleep 1.2
tmux send-keys -t kingpin:test-wait-1 "echo activity" Enter
sleep 1.2
now_ts=$(date +%s)
echo "$now_ts" > "$task_w_dir/stopped"
quiet_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$quiet_out" | grep -q "^test-wait-1 quiet" && pass "kingpin-wait detected quiet event" || fail "quiet event not detected (got: $quiet_out)"
"$KP_BIN/kingpin" ack test-wait-1
set +e
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1
quiet_exit=$?
set -e
[ "$quiet_exit" -eq 1 ] && pass "quiet event suppressed after ack" || fail "quiet event repeated after ack"

# Test exited event
tmux kill-window -t kingpin:test-wait-1 2>/dev/null || true
sleep 0.2
exit_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$exit_out" | grep -q "^test-wait-1 exited" && pass "kingpin-wait detected exited event" || fail "exited event not detected (got: $exit_out)"
"$KP_BIN/kingpin" ack test-wait-1
[ -f "$task_w_dir/seen_exited" ] && pass "seen_exited touched by kingpin ack" || fail "seen_exited not created"
set +e
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1
exit_code_after=$?
set -e
[ "$exit_code_after" -eq 1 ] && pass "exited event suppressed after ack" || fail "exited event repeated after ack"

# Test ack --all
echo "merged: done" >> "$task_w_dir/status"
"$KP_BIN/kingpin" ack --all
seen_val_all=$(cat "$task_w_dir/seen" 2>/dev/null | tr -d ' ' || echo 0)
[ "$seen_val_all" -eq 2 ] && pass "kingpin ack --all updated seen to 2" || fail "seen not updated on ack --all"

rm -rf "$task_w_dir"

# Test 6c: kingpin-wait ignores informational lines, holds repeated quiet, spares a launching window
echo "=== Test 6c: kingpin-wait wake filtering (#45) ==="
t45_dir="$KINGPIN_HOME/tasks/t45-wait"
mkdir -p "$t45_dir"
t45_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n t45-wait)
cat > "$t45_dir/task.env" << ENV
PROJECT=demo-auto
HARNESS=claude
MODE=review
TMUX_TARGET=kingpin:t45-wait
TMUX_WINDOW_ID=$t45_wid
ENV
: > "$t45_dir/status"
echo 0 > "$t45_dir/seen"

# issue: lines alone do not wake the waiter; the next real line does
echo "issue: #45 https://example/45" >> "$t45_dir/status"
set +e; t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t45_rc=$?; set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: a lone issue: line does not wake kingpin-wait" || fail "t45: issue: line woke the waiter (rc=$t45_rc out=$t45_out)"
echo "ready: branch=b review=APPROVE report=r" >> "$t45_dir/status"
t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t45_out" | grep -q "^t45-wait status" && pass "t45: ready: after an issue: line still wakes" || fail "t45: ready: did not wake ($t45_out)"
for t45_line in "needs-input: q" "fixed: high=0 report=r" "merged: pr=u" "cleanup-refused: x" "approved: x" "feedback: x"; do
  : > "$t45_dir/status"; echo 0 > "$t45_dir/seen"
  echo "$t45_line" >> "$t45_dir/status"
  "$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait status" && pass "t45: '${t45_line%%:*}:' wakes" || fail "t45: '${t45_line%%:*}:' did not wake"
done

# An acknowledged needs-input is not reported quiet again until the pane changes
: > "$t45_dir/status"; echo 0 > "$t45_dir/seen"; rm -f "$t45_dir/stopped" "$t45_dir/seen_stopped"
echo "needs-input: q" >> "$t45_dir/status"
"$KP_BIN/kingpin" ack t45-wait
[ -s "$t45_dir/seen_activity" ] && pass "t45: ack records the pane activity" || fail "t45: ack wrote no seen_activity"
sleep 1.2
date +%s > "$t45_dir/stopped"
set +e; t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t45_rc=$?; set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: acked needs-input is not reported quiet" || fail "t45: quiet repeated after needs-input ($t45_out)"
tmux send-keys -t "$t45_wid" "echo t45-activity" Enter
sleep 1.2
echo $(( $(date +%s) + 1 )) > "$t45_dir/stopped"
t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t45_out" | grep -q "^t45-wait quiet" && pass "t45: quiet returns once the pane shows activity" || fail "t45: quiet not reported after pane activity ($t45_out)"
# A pane that still lists background subagents is not quiet
tmux send-keys -t "$t45_wid" "echo '/tasks to see subagents'" Enter
sleep 1.2
tmux clear-history -t "$t45_wid" 2>/dev/null || true
echo $(( $(date +%s) + 5 )) > "$t45_dir/stopped"
t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t45_out" | grep -q "^t45-wait quiet" && fail "t45: quiet reported while subagents run" || pass "t45: a pane with background subagents is not quiet"
"$KP_BIN/kingpin" ack t45-wait
echo "needs-input: again" >> "$t45_dir/status"
"$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait status" && pass "t45: a new status line wakes after a hold" || fail "t45: new status did not wake"

# A window that is still being created is not exited; a gone window still is
"$KP_BIN/kingpin" ack t45-wait
tmux kill-window -t "$t45_wid"
sleep 0.2
: > "$t45_dir/launching"
set +e; t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t45_rc=$?; set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: a launching task is not reported exited" || fail "t45: launching task reported ($t45_out)"
touch -d '10 minutes ago' "$t45_dir/launching"
"$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait exited" && pass "t45: a stale launching marker no longer hides a gone window" || fail "t45: stale marker hid exited"
rm -f "$t45_dir/launching"
"$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait exited" && pass "t45: a gone window is exited" || fail "t45: gone window not reported"
rm -rf "$t45_dir"

# Test 6b: kingpin-wait exit codes (timeout is not an error)
echo "=== Test 6b: kingpin-wait exit codes ==="
t6b_home="$T/kp-t6b"
mkdir -p "$t6b_home/tasks"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --timeout 1 2>"$T/t6b.err")
t6b_exit=$?
set -e
[ "$t6b_exit" -eq 0 ] && [ -z "$t6b_out" ] && [ ! -s "$T/t6b.err" ] && pass "kingpin-wait timeout exits 0 with empty stdout and stderr" || fail "timeout: exit $t6b_exit, out '$t6b_out', err '$(cat "$T/t6b.err")'"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --once 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -eq 1 ] && [ -z "$t6b_out" ] && pass "kingpin-wait --once with no events exits 1" || fail "--once no events: exit $t6b_exit, out '$t6b_out'"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --bogus 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -ne 0 ] && echo "$t6b_out" | grep -q "^kingpin-wait: " && pass "kingpin-wait bad argument exits non-zero with a message" || fail "bad arg: exit $t6b_exit, out '$t6b_out'"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --timeout abc 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -ne 0 ] && echo "$t6b_out" | grep -q "^kingpin-wait: " && pass "kingpin-wait bad --timeout exits non-zero with a message" || fail "bad timeout: exit $t6b_exit, out '$t6b_out'"
t6b_bad="$T/kp-t6b-bad"
mkdir -p "$t6b_bad"
echo "not a dir" > "$t6b_bad/tasks"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_bad" "$KP_BIN/kingpin-wait" --timeout 1 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -ne 0 ] && echo "$t6b_out" | grep -q "^kingpin-wait: " && pass "kingpin-wait unusable fleet dir exits non-zero with a message" || fail "bad fleet dir: exit $t6b_exit, out '$t6b_out'"

kp_test_finish WAIT
