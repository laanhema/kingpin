#!/usr/bin/env bash
# Verification test for Kingpin: kingpin init, list, watch, run and tmux session targeting.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "lifecycle"

# Test 1: kingpin init
echo "=== Test 1: kingpin init ==="
"$KP_BIN/kingpin" init demo-auto "$T/proj" --harness agy --setup "echo setup" >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.env" ] && pass "demo-auto.env created" || fail "missing demo-auto.env"
grep -q "HARNESS=agy" "$KINGPIN_HOME/projects/demo-auto.env" && pass "harness recorded in env" || fail "harness missing in env"
grep -q "SETUP_CMD=" "$KINGPIN_HOME/projects/demo-auto.env" && pass "setup cmd recorded in env" || fail "setup cmd missing in env"

# init without --setup
"$KP_BIN/kingpin" init demo-nosetup "$T/proj" --harness agy >/dev/null && pass "init without --setup exited 0" || fail "init without --setup non-zero exit"
[ -f "$KINGPIN_HOME/projects/demo-nosetup.env" ] && pass "demo-nosetup.env created" || fail "missing demo-nosetup.env"

# Test 2: kingpin list on empty fleet
echo "=== Test 2: kingpin list ==="
out=$("$KP_BIN/kingpin" list)
echo "$out" | grep -q "No tasks in fleet" && pass "empty fleet reported" || fail "list did not report empty"

# The socket guard itself is silent in lib.sh; this is the suite's one assertion about it.
tmux display-message -p '#{socket_path}' | grep -qF "$TMUX_TMPDIR/" && [ "$(tmux display-message -p '#S')" = kingpin ] && pass "test operates on the private fleet socket" || fail "test socket not isolated"

# Test 3: kingpin-watch auto-landing and auto-cleanup
echo "=== Test 3: kingpin-watch auto-lifecycle ==="

# Spawn task in auto mode
"$KP_BIN/kingpin" spawn demo-auto --issue 201 --id task-auto-1 --mode auto >/dev/null
pass "task-auto-1 spawned in auto mode"

# Mock ready status
echo "ready: branch=kingpin/task-auto-1 review=APPROVE report=none" >> "$KINGPIN_HOME/tasks/task-auto-1/status"

# Override kingpin-send to simulate worker response (backup keeps uncommitted edits of the real script)
cp -p "$KP_BIN/kingpin-send" "$T/kingpin-send.orig"
cat > "$KP_BIN/kingpin-send" << 'S'
#!/usr/bin/env bash
id=$1
cmd=$2
# When /issue-flow-done is sent, simulate immediate merge
echo "merged: pr=https://github.com/laanhema/demo/pull/201" >> "${KINGPIN_HOME}/tasks/$id/status"
S
chmod +x "$KP_BIN/kingpin-send"

# Run one step of kingpin-watch (should detect ready in auto mode, trigger kingpin-land)
"$KP_BIN/kingpin" watch --once >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-auto-1/landing_sent" ] && pass "kingpin-watch triggered landing" || fail "landing not triggered"

# Restore original kingpin-send
cp -p "$T/kingpin-send.orig" "$KP_BIN/kingpin-send"

# In the leased worktree, commit and push to origin main so merge assertion passes
wt_path=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-auto-1/task.env")
(
  cd "$wt_path"
  echo "auto feature" > auto.txt
  git add auto.txt
  git commit -qm "feat: auto feature"
  git push -q origin HEAD:main
)

# Run one step of kingpin-watch (should detect merged status, trigger kingpin-done)
echo "merged: pr=https://github.com/laanhema/demo/pull/201" >> "$KINGPIN_HOME/tasks/task-auto-1/status"
"$KP_BIN/kingpin" watch --once >/dev/null
[ -f "$KINGPIN_HOME/archive/task-auto-1/done_cleaned" ] && [ -L "$KINGPIN_HOME/tasks/task-auto-1" ] && pass "kingpin-watch completed auto-cleanup and archived the task" || fail "auto-cleanup not triggered"

# Test 4: kingpin run one-command lifecycle
echo "=== Test 4: kingpin run one-command lifecycle ==="
cat > "$T/fake-runner" << 'FR'
#!/usr/bin/env bash
# Simulate immediate work in leased worktree
echo "run feature" > run.txt
git add run.txt
git commit -qm "feat: run feature"
git push -q origin HEAD:main
echo "ready: branch=$(git branch --show-current) review=APPROVE report=none" >> "$KINGPIN_TASK_DIR/status"
# When landing is triggered, simulate merged
while true; do
  if [ -f "$KINGPIN_TASK_DIR/landing_sent" ]; then
    echo "merged: pr=https://github.com/laanhema/demo/pull/202" >> "$KINGPIN_TASK_DIR/status"
    break
  fi
  sleep 0.2
done
exec bash
FR
chmod +x "$T/fake-runner"
export KINGPIN_AGY=$T/fake-runner

# Run kingpin run in auto mode (should spawn, auto-land via watch, clean up, and exit 0)
"$KP_BIN/kingpin" run demo-auto --issue 202 --id task-run-1 --mode auto > "$T/run.log" 2>&1
grep -q "merged and cleaned up successfully" "$T/run.log" && pass "kingpin run completed full lifecycle" || fail "kingpin run failed"

# Test 5: Worker tmux session targeting (inside and outside tmux)
echo "=== Test 5: Worker tmux session targeting ==="
export KINGPIN_AGY=$T/fake-worker

# Case A: Outside tmux (TMUX unset or empty)
spawn_out_outside=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 203 --id task-target-outside --mode review)
echo "$spawn_out_outside" | grep -q "tmux -L $KINGPIN_TMUX_SOCKET kingpin:task-target-outside" && pass "spawn logged the fleet server and kingpin session" || fail "spawn did not log the fleet target"
grep -q "^TMUX_TARGET=kingpin:task-target-outside$" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && pass "task.env recorded kingpin:task-target-outside" || fail "wrong TMUX_TARGET in task.env"
grep -q "^TMUX_SOCKET=$KINGPIN_TMUX_SOCKET$" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && pass "task.env recorded the fleet socket" || fail "task.env did not record TMUX_SOCKET"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "task-target-outside" && pass "window spawned in kingpin session" || fail "window missing in kingpin session"
outside_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="task-target-outside"{print $1}')
grep -qx "TMUX_WINDOW_ID=$outside_wid" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && echo "$outside_wid" | grep -q '^@[0-9][0-9]*$' && pass "task.env recorded window ID $outside_wid" || fail "task.env TMUX_WINDOW_ID is not the spawned window's ID ($outside_wid)"
"$KP_BIN/kingpin" "done" task-target-outside --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' 2>/dev/null | grep -qx "task-target-outside" && pass "kingpin done cleaned up outside window" || fail "window lingering in kingpin session"

# Case B: Inside an operator tmux session, on the operator's own server (issue #142).
# The worker must not land there: the operator's session is not part of the fleet.
ops_socket="$TEST_SOCKET-ops"
tmux -L "$ops_socket" new-session -d -s kp-test-active -n home
active_sid=$(tmux -L "$ops_socket" display-message -p -t kp-test-active '#{session_id}' | tr -d '$')
ops_path=$(tmux -L "$ops_socket" display-message -p '#{socket_path}')
mock_tmux="$ops_path,$$,$active_sid"

spawn_out_inside=$(TMUX="$mock_tmux" "$KP_BIN/kingpin" spawn demo-auto --issue 204 --id task-target-inside --mode review)
echo "$spawn_out_inside" | grep -q "tmux -L $KINGPIN_TMUX_SOCKET kingpin:task-target-inside" && pass "spawn named the fleet server while inside the operator's session" || fail "spawn output: $spawn_out_inside"
grep -q "^TMUX_TARGET=kingpin:task-target-inside$" "$KINGPIN_HOME/tasks/task-target-inside/task.env" && pass "task.env targets the kingpin session, not the operator's" || fail "wrong TMUX_TARGET in task.env"
! tmux -L "$ops_socket" list-windows -t kp-test-active -F '#{window_name}' 2>/dev/null | grep -qx "task-target-inside" && pass "window did not land in the operator's session" || fail "window landed in the operator's session"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "task-target-inside" && pass "window spawned in the fleet's kingpin session" || fail "window missing in the fleet session"
inside_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="task-target-inside"{print $1}')
grep -qx "TMUX_WINDOW_ID=$inside_wid" "$KINGPIN_HOME/tasks/task-target-inside/task.env" && pass "task.env recorded window ID $inside_wid" || fail "task.env TMUX_WINDOW_ID is not the spawned window's ID ($inside_wid)"

# Test downstream kingpin-send targeting the fleet window
send_out=$("$KP_BIN/kingpin" send task-target-inside "echo inside-active-ok")
echo "$send_out" | grep -q "OK: sent to kingpin:task-target-inside" && pass "kingpin-send reached the fleet window" || fail "kingpin-send failed targeting the fleet window"

"$KP_BIN/kingpin" "done" task-target-inside --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' 2>/dev/null | grep -qx "task-target-inside" && pass "kingpin done cleaned up the fleet window" || fail "window lingering in kingpin session"
tmux -L "$ops_socket" kill-server 2>/dev/null || true

# Case C: TMUX points nowhere. The worker still lands on the fleet server.
TMUX="/tmp/nonexistent-sock,99999,99999" "$KP_BIN/kingpin" spawn demo-auto --issue 205 --id task-target-fallback --mode review >/dev/null
grep -q "^TMUX_TARGET=kingpin:task-target-fallback$" "$KINGPIN_HOME/tasks/task-target-fallback/task.env" && grep -q "^TMUX_SOCKET=$KINGPIN_TMUX_SOCKET$" "$KINGPIN_HOME/tasks/task-target-fallback/task.env" && pass "an unusable TMUX still resolves the fleet target" || fail "wrong TMUX_TARGET on fallback"
"$KP_BIN/kingpin" "done" task-target-fallback --force >/dev/null

# Test 6: kingpin run ends instead of polling forever
echo "=== Test 6: kingpin run ends on needs-input:/waiting: and on a stopped worker ==="
cat > "$T/fake-runner-needs" << 'FR'
#!/usr/bin/env bash
echo "needs-input: which API shape?" >> "$KINGPIN_TASK_DIR/status"
exec bash
FR
chmod +x "$T/fake-runner-needs"
t6_rc=0
t6_out=$(KINGPIN_AGY=$T/fake-runner-needs timeout 60 "$KP_BIN/kingpin" run demo-auto --issue 208 --id task-run-needs --mode review 2>&1) || t6_rc=$?
if [ "$t6_rc" -eq 0 ] && echo "$t6_out" | grep -qF "Question: $KINGPIN_HOME/tasks/task-run-needs/question.md"; then
  pass "run exits 0 on needs-input: and names the question path"
else
  fail "run did not end on needs-input: (rc $t6_rc): $t6_out"
fi
"$KP_BIN/kingpin" "done" task-run-needs --force >/dev/null 2>&1 || true

# The Stop hook's line for a worker blocked on a human must end run the same way,
# naming the question file its kind points at.
cat > "$T/fake-runner-waiting" << 'FR'
#!/usr/bin/env bash
echo "waiting: needs-input $KINGPIN_TASK_DIR/question.md" >> "$KINGPIN_TASK_DIR/status"
exec bash
FR
chmod +x "$T/fake-runner-waiting"
t6w_rc=0
t6w_out=$(KINGPIN_AGY=$T/fake-runner-waiting timeout 60 "$KP_BIN/kingpin" run demo-auto --issue 211 --id task-run-waiting --mode review 2>&1) || t6w_rc=$?
if [ "$t6w_rc" -eq 0 ] && echo "$t6w_out" | grep -qF "OK: task-run-waiting is waiting: needs-input $KINGPIN_HOME/tasks/task-run-waiting/question.md"; then
  pass "run exits 0 on waiting: and names the task id and question path"
else
  fail "run did not end on waiting: (rc $t6w_rc): $t6w_out"
fi
"$KP_BIN/kingpin" "done" task-run-waiting --force >/dev/null 2>&1 || true

cat > "$T/fake-runner-dead" << 'FR'
#!/usr/bin/env bash
echo "issue: #209" >> "$KINGPIN_TASK_DIR/status"
FR
chmod +x "$T/fake-runner-dead"
t6b_rc=0
t6b_out=$(KINGPIN_AGY=$T/fake-runner-dead timeout 60 "$KP_BIN/kingpin" run demo-auto --issue 209 --id task-run-dead --mode review 2>&1) || t6b_rc=$?
if [ "$t6b_rc" -eq 1 ] && echo "$t6b_out" | grep -q "FAILED: task-run-dead exited"; then
  pass "run exits 1 with the exited reason when the worker stops after issue:"
else
  fail "run did not end with exited (rc $t6b_rc): $t6b_out"
fi
"$KP_BIN/kingpin" "done" task-run-dead --force >/dev/null 2>&1 || true

# The negative of that exited check: a live window whose only line is issue: keeps
# run waiting. Kill run after a bounded wait instead of letting a regression hang
# the suite.
cat > "$T/fake-runner-live" << 'FR'
#!/usr/bin/env bash
echo "issue: #212" >> "$KINGPIN_TASK_DIR/status"
exec bash
FR
chmod +x "$T/fake-runner-live"
KINGPIN_AGY=$T/fake-runner-live "$KP_BIN/kingpin" run demo-auto --issue 212 --id task-run-live --mode review > "$T/run-live.log" 2>&1 &
live_pid=$!
live_alive=0
for _ in 1 2 3 4 5 6; do
  sleep 0.5
  kill -0 "$live_pid" 2>/dev/null || break
done
kill -0 "$live_pid" 2>/dev/null && live_alive=1
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
if [ "$live_alive" -eq 1 ] && ! grep -q "FAILED:" "$T/run-live.log"; then
  pass "run keeps waiting on a live worker whose last line is issue:"
else
  fail "run left a live issue:-only worker (log: $(cat "$T/run-live.log"))"
fi
"$KP_BIN/kingpin" "done" task-run-live --force >/dev/null 2>&1 || true

# The resolved open question: in auto mode the worker is the only process that can
# finish the landing, so a window that dies after ready: must end run, not wait.
cat > "$T/fake-runner-auto-dead" << 'FR'
#!/usr/bin/env bash
echo "ready: branch=kingpin/task-run-auto-dead review=APPROVE report=none" >> "$KINGPIN_TASK_DIR/status"
FR
chmod +x "$T/fake-runner-auto-dead"
t6c_rc=0
t6c_out=$(KINGPIN_AGY=$T/fake-runner-auto-dead timeout 60 "$KP_BIN/kingpin" run demo-auto --issue 210 --id task-run-auto-dead --mode auto 2>&1) || t6c_rc=$?
if [ "$t6c_rc" -eq 1 ] && echo "$t6c_out" | grep -q "FAILED: task-run-auto-dead exited" \
  && echo "$t6c_out" | grep -q "last status: ready:"; then
  pass "run reports exited for an auto-mode worker that died after ready:"
else
  fail "auto-mode dead worker (rc $t6c_rc): $t6c_out"
fi
"$KP_BIN/kingpin" "done" task-run-auto-dead --force >/dev/null 2>&1 || true

kp_test_finish LIFECYCLE
