#!/usr/bin/env bash
# Verification test for Kingpin automation (kingpin CLI, init, watch, and run).
set -euo pipefail

unset TMUX CLAUDECODE OPENCODE KINGPIN_HARNESS

T=$(mktemp -d)
export KINGPIN_HOME=$T/kp
export KINGPIN_SKIP_GUARD=1
export TREEHOUSE_ROOT=$T/pool
export CLAUDE_CONFIG_DIR=$T/cfg
export GEMINI_CONFIG_DIR=$T/cfg-gemini

mkdir -p "$T/cfg" "$T/cfg-gemini" "$KINGPIN_HOME/projects" "$KINGPIN_HOME/tasks"
echo '{"projects":{}}' > "$T/cfg/.claude.json"
echo '{"trustedWorkspaces":[]}' > "$T/cfg-gemini/settings.json"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

KP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KP_BIN="$KP_ROOT/bin"

# Set up isolated private tmux server on a temporary socket
export TMUX_TMPDIR="$T/tmux-tmp"
mkdir -p "$TMUX_TMPDIR" "$T/bin"
TEST_SOCKET="kingpin-test-auto-$$"
REAL_TMUX=$(command -v tmux)
cat > "$T/bin/tmux" << EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

# 1. Set up test repo with origin remote
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/proj" 2>/dev/null
(
  cd "$T/proj"
  git checkout -q -b main
  echo "initial code" > app.txt
  git add app.txt
  git commit -qm "init"
  git push -q -u origin main
  git remote set-head origin main
)

tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home
for w in $(tmux list-windows -t kingpin -F '#{window_id}' 2>/dev/null | tail -n +2 || true); do
  tmux kill-window -t "$w" 2>/dev/null || true
done
tmux display-message -p '#{socket_path}' | grep -q "$TEST_SOCKET" && pass "test operates on private tmux socket" || fail "test socket not isolated"

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

# Test 3: kingpin-watch auto-landing and auto-cleanup
echo "=== Test 3: kingpin-watch auto-lifecycle ==="
cat > "$T/fake-worker" << 'F'
#!/usr/bin/env bash
exec bash
F
chmod +x "$T/fake-worker"
export KINGPIN_AGY=$T/fake-worker

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
[ -f "$KINGPIN_HOME/archive/task-auto-1/done_cleaned" ] && [ ! -d "$KINGPIN_HOME/tasks/task-auto-1" ] && pass "kingpin-watch completed auto-cleanup and archived the task" || fail "auto-cleanup not triggered"

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
echo "$spawn_out_outside" | grep -q "tmux kingpin:task-target-outside" && pass "spawn logged kingpin target when TMUX is empty" || fail "spawn did not log kingpin target"
grep -q "^TMUX_TARGET=kingpin:task-target-outside$" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && pass "task.env recorded kingpin:task-target-outside" || fail "wrong TMUX_TARGET in task.env"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "task-target-outside" && pass "window spawned in kingpin session" || fail "window missing in kingpin session"
outside_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="task-target-outside"{print $1}')
grep -qx "TMUX_WINDOW_ID=$outside_wid" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && echo "$outside_wid" | grep -q '^@[0-9][0-9]*$' && pass "task.env recorded window ID $outside_wid" || fail "task.env TMUX_WINDOW_ID is not the spawned window's ID ($outside_wid)"
"$KP_BIN/kingpin" done task-target-outside --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' 2>/dev/null | grep -qx "task-target-outside" && pass "kingpin done cleaned up outside window" || fail "window lingering in kingpin session"

# Case B: Inside tmux (active session targeting)
tmux kill-session -t kp-test-active 2>/dev/null || true
tmux new-session -d -s kp-test-active -n home
active_sid=$(tmux display-message -p -t kp-test-active '#{session_id}' | tr -d '$')
tmux_sock=$(tmux display-message -p '#{socket_path}' 2>/dev/null || echo "/tmp/tmux-$(id -u)/default")
mock_tmux="$tmux_sock,$$,$active_sid"

spawn_out_inside=$(TMUX="$mock_tmux" "$KP_BIN/kingpin" spawn demo-auto --issue 204 --id task-target-inside --mode review)
echo "$spawn_out_inside" | grep -q "tmux kp-test-active:task-target-inside" && pass "spawn logged active session target when TMUX is set" || fail "spawn did not log active session target"
grep -q "^TMUX_TARGET=kp-test-active:task-target-inside$" "$KINGPIN_HOME/tasks/task-target-inside/task.env" && pass "task.env recorded kp-test-active:task-target-inside" || fail "wrong TMUX_TARGET in task.env"
tmux list-windows -t kp-test-active -F '#{window_name}' | grep -qx "task-target-inside" && pass "window spawned in active session" || fail "window missing in active session"
inside_wid=$(tmux list-windows -t kp-test-active -F '#{window_id} #{window_name}' | awk '$2=="task-target-inside"{print $1}')
grep -qx "TMUX_WINDOW_ID=$inside_wid" "$KINGPIN_HOME/tasks/task-target-inside/task.env" && pass "task.env recorded window ID $inside_wid in active session" || fail "task.env TMUX_WINDOW_ID is not the active-session window's ID ($inside_wid)"

# Test downstream kingpin-send targeting active session window
send_out=$("$KP_BIN/kingpin" send task-target-inside "echo inside-active-ok")
echo "$send_out" | grep -q "OK: sent to kp-test-active:task-target-inside" && pass "kingpin-send targeted active session window" || fail "kingpin-send failed targeting active session"

"$KP_BIN/kingpin" done task-target-inside --force >/dev/null
! tmux list-windows -t kp-test-active -F '#{window_name}' 2>/dev/null | grep -qx "task-target-inside" && pass "kingpin done cleaned up active session window" || fail "window lingering in active session"
tmux kill-session -t kp-test-active 2>/dev/null || true

# Case C: Lookup fallback when TMUX has invalid session id or lookup fails
spawn_out_fallback=$(TMUX="/tmp/nonexistent-sock,99999,99999" "$KP_BIN/kingpin" spawn demo-auto --issue 205 --id task-target-fallback --mode review)
grep -q "^TMUX_TARGET=kingpin:task-target-fallback$" "$KINGPIN_HOME/tasks/task-target-fallback/task.env" && pass "fallback resolved a valid TMUX_TARGET" || fail "wrong TMUX_TARGET on fallback"
"$KP_BIN/kingpin" done task-target-fallback --force >/dev/null

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

# Test quiet event
now_ts=$(date +%s)
echo "$now_ts" > "$task_w_dir/stopped"
quiet_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$quiet_out" | grep -q "^test-wait-1 quiet" && pass "kingpin-wait detected quiet event" || fail "quiet event not detected (got: $quiet_out)"
"$KP_BIN/kingpin" ack test-wait-1
set +e
quiet_after_ack=$("$KP_BIN/kingpin" wait --once 2>/dev/null)
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
exit_after_ack=$("$KP_BIN/kingpin" wait --once 2>/dev/null)
exit_code_after=$?
set -e
[ "$exit_code_after" -eq 1 ] && pass "exited event suppressed after ack" || fail "exited event repeated after ack"

# Test ack --all
echo "merged: done" >> "$task_w_dir/status"
"$KP_BIN/kingpin" ack --all
seen_val_all=$(cat "$task_w_dir/seen" 2>/dev/null | tr -d ' ' || echo 0)
[ "$seen_val_all" -eq 2 ] && pass "kingpin ack --all updated seen to 2" || fail "seen not updated on ack --all"

rm -rf "$task_w_dir"

# Test 7: kingpin lock lifecycle
echo "=== Test 7: kingpin lock lifecycle ==="
lock_status_init=$("$KP_BIN/kingpin" lock status)
[ "$lock_status_init" = "lock: free" ] && pass "initial lock status free" || fail "initial lock status not free: $lock_status_init"

# Start long-lived background process holding the lock
(
  "$KP_BIN/kingpin" lock acquire >/dev/null
  sleep 30
) &
holder_pid=$!

# Wait briefly for lock acquisition
for _ in 1 2 3 4 5; do
  [ -f "$KINGPIN_HOME/orchestrator.lock" ] && break
  sleep 0.1
done

lock_status_held=$("$KP_BIN/kingpin" lock status)
echo "$lock_status_held" | grep -q "lock: held by pid $holder_pid" && pass "lock reported held by parent pid" || fail "lock not held by parent: $lock_status_held"

# Collision rejection: second acquire from different process must exit 1 and name holder
acquire_rc=0
acquire_err=$( ("$KP_BIN/kingpin" lock acquire) 2>&1 ) || acquire_rc=$?
[ "$acquire_rc" -ne 0 ] && echo "$acquire_err" | grep -q "another live kingpin orchestrator session holds the lock (pid $holder_pid)" && pass "second acquire rejected with holder pid" || fail "second acquire did not reject: $acquire_err"

# Collision rejection: check from different process must exit 1 and name holder
check_rc=0
check_err=$( ("$KP_BIN/kingpin" lock check) 2>&1 ) || check_rc=$?
[ "$check_rc" -ne 0 ] && echo "$check_err" | grep -q "another live kingpin orchestrator session holds the lock (pid $holder_pid)" && pass "check rejected with holder pid" || fail "check did not reject: $check_err"

# Kill holder process and verify auto-freeing
kill -9 "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

lock_status_stale=$("$KP_BIN/kingpin" lock status)
[ "$lock_status_stale" = "lock: stale" ] && pass "lock reports stale after holder dies" || fail "lock not stale after holder dies: $lock_status_stale"

# Re-acquire lock over stale lock
reacquire_out=$("$KP_BIN/kingpin" lock acquire)
echo "$reacquire_out" | grep -q "lock: acquired" && pass "re-acquire over stale lock succeeded" || fail "re-acquire failed: $reacquire_out"

# Release lock
"$KP_BIN/kingpin" lock release >/dev/null
lock_status_released=$("$KP_BIN/kingpin" lock status)
[ "$lock_status_released" = "lock: free" ] && pass "lock release returned state to free" || fail "lock not free after release: $lock_status_released"

# Test 7b: lock records the harness of the session that holds it
echo "=== Test 7b: kingpin lock harness ==="
lock_file=$KINGPIN_HOME/orchestrator.lock

# Start a long-lived holder that runs `kingpin lock acquire <args>` under the env given in $1.
start_holder() {
  local envs=$1; shift
  (
    # shellcheck disable=SC2086
    env $envs "$KP_BIN/kingpin" lock acquire "$@" >/dev/null 2>&1
    sleep 30
  ) &
  holder_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(head -n 1 "$lock_file" 2>/dev/null)" = "$holder_pid" ] && break
    sleep 0.1
  done
}
stop_holder() {
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}

# A holder with no recognisable agent records no harness
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "A=1"
[ "$("$KP_BIN/kingpin" lock status)" = "lock: held by pid $holder_pid" ] && pass "unrecognised holder shows no harness in status" || fail "status: $("$KP_BIN/kingpin" lock status)"
[ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "lock harness is empty without a recorded harness" || fail "unexpected harness"
stop_holder

# --harness flag
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "A=1" --harness agy
[ "$("$KP_BIN/kingpin" lock status)" = "lock: held by pid $holder_pid (agy)" ] && pass "--harness agy recorded and shown in status" || fail "status: $("$KP_BIN/kingpin" lock status)"
[ "$("$KP_BIN/kingpin" lock harness)" = "agy" ] && pass "lock harness prints agy for a live holder" || fail "harness: $("$KP_BIN/kingpin" lock harness)"
[ "$(head -n 1 "$lock_file")" = "$holder_pid" ] && pass "pid stays on line 1 of the lock file" || fail "lock line 1: $(head -n 1 "$lock_file")"
stop_holder

# Stale lock: recorded harness is ignored
[ "$("$KP_BIN/kingpin" lock status)" = "lock: stale" ] && pass "status stale after the harness holder dies" || fail "status: $("$KP_BIN/kingpin" lock status)"
[ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "stale lock reports no harness" || fail "stale lock still reports a harness"

# Re-acquire over the stale lock without a harness drops the old record
start_holder "A=1"
[ -z "$("$KP_BIN/kingpin" lock harness)" ] && [ "$(wc -l < "$lock_file")" -eq 1 ] && pass "re-acquire over a stale lock rewrites the whole file" || fail "old harness survived re-acquire"
stop_holder

# KINGPIN_HARNESS env, and the flag beating the env
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "KINGPIN_HARNESS=opencode"
[ "$("$KP_BIN/kingpin" lock harness)" = "opencode" ] && pass "KINGPIN_HARNESS=opencode recorded" || fail "env override: $("$KP_BIN/kingpin" lock harness)"
stop_holder
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "KINGPIN_HARNESS=opencode" --harness agy
[ "$("$KP_BIN/kingpin" lock harness)" = "agy" ] && pass "--harness beats KINGPIN_HARNESS" || fail "flag vs env: $("$KP_BIN/kingpin" lock harness)"
stop_holder

# Environment marker of the calling agent
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "CLAUDECODE=1"
[ "$("$KP_BIN/kingpin" lock harness)" = "claude" ] && pass "CLAUDECODE=1 detected as claude" || fail "CLAUDECODE: $("$KP_BIN/kingpin" lock harness)"
stop_holder

# Invalid override is rejected and leaves the lock alone
"$KP_BIN/kingpin" lock release >/dev/null
bad_rc=0
bad_err=$(KINGPIN_HARNESS=bogus "$KP_BIN/kingpin" lock acquire 2>&1) || bad_rc=$?
[ "$bad_rc" -ne 0 ] && echo "$bad_err" | grep -q "unsupported harness: bogus" && [ ! -f "$lock_file" ] && pass "invalid KINGPIN_HARNESS rejected, no lock written" || fail "invalid override: rc=$bad_rc $bad_err"

# Process detection: the session process is named like the agent
mkdir -p "$T/agy-holder"
cat > "$T/agy-holder/agy" << F
#!/usr/bin/env bash
"$KP_BIN/kingpin" lock acquire >/dev/null 2>&1
sleep 30
F
chmod +x "$T/agy-holder/agy"
"$T/agy-holder/agy" &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(head -n 1 "$lock_file" 2>/dev/null)" = "$holder_pid" ] && break
  sleep 0.1
done
[ "$("$KP_BIN/kingpin" lock harness)" = "agy" ] && pass "session process named agy detected as agy" || fail "process detection: $("$KP_BIN/kingpin" lock harness)"

# release clears the record
"$KP_BIN/kingpin" lock release >/dev/null
[ ! -f "$lock_file" ] && [ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "release clears the recorded harness" || fail "harness survived release"
stop_holder

# init without --harness leaves HARNESS unset so the lock holder's harness can apply
"$KP_BIN/kingpin" init demo-noharness "$T/proj" >/dev/null
! grep -q "^HARNESS=" "$KINGPIN_HOME/projects/demo-noharness.env" && pass "init without --harness writes no HARNESS line" || fail "init wrote HARNESS without --harness"

# Test 8: kingpin curate lifecycle and quote robustness
echo "=== Test 8: kingpin curate lifecycle ==="
export KINGPIN_SKILLS_DIR=$T/skills
mkdir -p "$T/skills" "$KINGPIN_HOME/tasks/test-curate-1" "$KINGPIN_HOME/archive/test-curate-2"

tricky_critique="Special critique: 'single' and \"double\" and \$(echo subshell)"
echo "$tricky_critique" > "$KINGPIN_HOME/tasks/test-curate-1/critique"
echo "Simple archive critique" > "$KINGPIN_HOME/archive/test-curate-2/critique"

# 8.1 Dry-run inspection
dry_curate_out=$("$KP_BIN/kingpin" curate --dry-run)
echo "$dry_curate_out" | grep -q "dry-run, 2 task(s) have pending critiques:" && pass "curate --dry-run listed pending count" || fail "curate --dry-run wrong output: $dry_curate_out"
[ -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "dry-run preserved critique files" || fail "dry-run modified critique files"

# 8.2 Failing curator leaves critiques pending and delivers quotes verbatim
cat > "$T/fake-curator-fail" << EOF_FAIL
#!/usr/bin/env bash
printf "%s\n" "\$1" > "$T/curator-received.txt"
exit 1
EOF_FAIL
chmod +x "$T/fake-curator-fail"

export KINGPIN_CURATOR_CMD="$T/fake-curator-fail"
"$KP_BIN/kingpin" curate >/dev/null

for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done

[ -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "failing curator left critiques pending" || fail "failing curator archived critiques"
[ -f "$T/curator-received.txt" ] && grep -qF "$tricky_critique" "$T/curator-received.txt" && pass "critique reached curator verbatim with special quotes and subshell" || fail "critique text corrupted or not received"

# 8.3 Succeeding curator archives critiques upon writing curator-result
cat > "$T/fake-curator-success" << EOF_SUCC
#!/usr/bin/env bash
echo "applied: updated skill definition" > "$KINGPIN_HOME/curator-result"
exit 0
EOF_SUCC
chmod +x "$T/fake-curator-success"

export KINGPIN_CURATOR_CMD="$T/fake-curator-success"
"$KP_BIN/kingpin" curate >/dev/null

for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done

[ ! -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ ! -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "succeeding curator archived pending critiques" || fail "critiques still pending after success"
ls "$KINGPIN_HOME/tasks/test-curate-1"/critique.applied.* >/dev/null 2>&1 && ls "$KINGPIN_HOME/archive/test-curate-2"/critique.applied.* >/dev/null 2>&1 && pass "applied archive files created" || fail "missing critique.applied.* files"

# 8.4 Empty check
empty_curate_out=$("$KP_BIN/kingpin" curate)
echo "$empty_curate_out" | grep -q "no pending skill critiques" && pass "curate reports no pending skill critiques" || fail "curate did not report empty"

# Test 9: Landing review gate verdict parsing, fix-findings, and re-review
echo "=== Test 9: Landing review gate verdict parsing, fix-findings, and re-review ==="

# 1. Regex parsing unit tests
check_parse() {
  local last_status="$1"
  local exp_v="$2"
  local exp_r="$3"
  local verdict="" report=""
  if [[ $last_status =~ review=(.*)[[:space:]]+report=([^[:space:]]*) ]]; then
    verdict="${BASH_REMATCH[1]}"
    report="${BASH_REMATCH[2]}"
  elif [[ $last_status =~ review=([^ ]+( [^ ]+)*) ]]; then
    verdict="${BASH_REMATCH[1]}"
  fi
  if [ -z "$report" ] && [[ $last_status =~ report=([^[:space:]]+) ]]; then
    report="${BASH_REMATCH[1]}"
  fi
  verdict=$(echo "$verdict" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
  report=$(echo "$report" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
  [ "$verdict" = "$exp_v" ] && [ "$report" = "$exp_r" ]
}

check_parse "ready: branch=b review=APPROVE report=none" "APPROVE" "none" && pass "parsed APPROVE report=none" || fail "failed parse APPROVE"
check_parse "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r1.md" "APPROVE WITH NITS" ".agents/reviews/r1.md" && pass "parsed APPROVE WITH NITS" || fail "failed parse APPROVE WITH NITS"
check_parse "ready: branch=b review=NEEDS CHANGES report=r2.md" "NEEDS CHANGES" "r2.md" && pass "parsed NEEDS CHANGES" || fail "failed parse NEEDS CHANGES"

# 2. APPROVE WITH NITS and NEEDS CHANGES report path resolution & /fix-findings dispatch
t7_dir="$KINGPIN_HOME/tasks/t7-nits"
mkdir -p "$t7_dir"
tmux new-window -d -t kingpin: -n t7-nits cat
cat > "$t7_dir/task.env" << EOF
TASK_ID=t7-nits
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
ISSUE=301
TMUX_TARGET=kingpin:t7-nits
EOF
echo "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r1.md" > "$t7_dir/status"

"$KP_BIN/kingpin" land t7-nits >/dev/null
[ -f "$t7_dir/landing_in_progress" ] && pass "landing_in_progress set on APPROVE WITH NITS" || fail "landing_in_progress missing"
[ ! -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "landing lock not acquired during fix pass" || fail "landing lock prematurely acquired"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-nits -S -5)
echo "$pane_out" | grep -q "/fix-findings $T/proj/.agents/reviews/r1.md" && pass "resolved report path sent to /fix-findings" || fail "wrong fix-findings command: $pane_out"

# 3. fixed: high > 0 triggers /review dispatch
echo "fixed: high=1 report=.agents/reviews/r1.md" >> "$t7_dir/status"
"$KP_BIN/kingpin" land t7-nits >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-nits -S -5)
echo "$pane_out" | grep -q "/review --issue 301" && pass "/review --issue dispatched on high > 0" || fail "wrong review command: $pane_out"
[ ! -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "landing lock not acquired during re-review" || fail "landing lock prematurely acquired on re-review"

# Re-review without issue
t7_noissue="$KINGPIN_HOME/tasks/t7-noissue"
mkdir -p "$t7_noissue"
tmux new-window -d -t kingpin: -n t7-noissue cat
cat > "$t7_noissue/task.env" << EOF
TASK_ID=t7-noissue
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t7-noissue
EOF
echo "fixed: high=2 report=r.md" > "$t7_noissue/status"
"$KP_BIN/kingpin" land t7-noissue >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-noissue -S -5)
echo "$pane_out" | grep -qx "/review" && pass "/review dispatched when issue not set" || fail "wrong review command without issue: $pane_out"
tmux kill-window -t kingpin:t7-noissue 2>/dev/null || true
rm -rf "$t7_noissue"

# 4. fixed: high == 0 auto-advances to project landing lock & /issue-flow-done in review mode
echo "fixed: high=0 report=.agents/reviews/r1.md" >> "$t7_dir/status"
"$KP_BIN/kingpin" watch --once >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "project landing lock acquired on clean fix pass" || fail "landing lock not acquired"
[ -f "$t7_dir/landing_sent" ] && pass "landing_sent marker created on landing dispatch" || fail "landing_sent missing"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-nits -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 301" && pass "/issue-flow-done dispatched after clean fix" || fail "wrong done command: $pane_out"

tmux kill-window -t kingpin:t7-nits 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
rm -rf "$t7_dir"

# Auto mode continuation on fixed: high=0
t7_auto="$KINGPIN_HOME/tasks/t7-auto"
mkdir -p "$t7_auto"
tmux new-window -d -t kingpin: -n t7-auto cat
cat > "$t7_auto/task.env" << EOF
TASK_ID=t7-auto
PROJECT=demo-auto
MODE=auto
WORKTREE=$T/proj
ISSUE=303
TMUX_TARGET=kingpin:t7-auto
EOF
echo "fixed: high=0 report=r.md" > "$t7_auto/status"
"$KP_BIN/kingpin" watch --once >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "auto-mode acquired landing lock on clean fix pass" || fail "auto-mode landing lock not acquired"
[ -f "$t7_auto/landing_sent" ] && pass "auto-mode landing_sent created" || fail "auto-mode landing_sent missing"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-auto -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 303" && pass "auto-mode /issue-flow-done dispatched" || fail "wrong auto done command: $pane_out"

tmux kill-window -t kingpin:t7-auto 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
rm -rf "$t7_auto"

# 5. APPROVE with no findings goes straight to landing queue
t7_app="$KINGPIN_HOME/tasks/t7-app"
mkdir -p "$t7_app"
tmux new-window -d -t kingpin: -n t7-app cat
cat > "$t7_app/task.env" << EOF
TASK_ID=t7-app
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
ISSUE=302
TMUX_TARGET=kingpin:t7-app
EOF
echo "ready: branch=b review=APPROVE report=none" > "$t7_app/status"

"$KP_BIN/kingpin" land t7-app >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "landing lock acquired directly for APPROVE" || fail "landing lock not acquired for APPROVE"
[ -f "$t7_app/landing_sent" ] && pass "landing_sent created for APPROVE" || fail "landing_sent missing for APPROVE"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-app -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 302" && pass "/issue-flow-done dispatched for APPROVE" || fail "wrong done command for APPROVE: $pane_out"

tmux kill-window -t kingpin:t7-app 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
rm -rf "$t7_app"

# Test 10: Refused cleanup handling and landing queue preservation
echo "=== Test 10: Refused cleanup handling and landing queue preservation ==="
t10_dir1="$KINGPIN_HOME/tasks/t10-dirty"
t10_dir2="$KINGPIN_HOME/tasks/t10-queued"
mkdir -p "$t10_dir1" "$t10_dir2"

t10_wt1="$T/wt-t10-1"
t10_wt2="$T/wt-t10-2"
mkdir -p "$t10_wt1" "$t10_wt2"
git -C "$t10_wt1" init -q
git -C "$t10_wt2" init -q

(
  cd "$t10_wt1"
  git checkout -qb main
  git config user.name "Tester"
  git config user.email "test@example.com"
  echo "initial" > init.txt
  git add init.txt
  git commit -qm "initial commit"
)

t10_remote="$T/remote-t10.git"
git init --bare -q "$t10_remote"
(
  cd "$t10_wt1"
  git remote add origin "$t10_remote"
  git push -q origin main
  git branch -u origin/main main
)

cat > "$t10_dir1/task.env" << EOF
TASK_ID=t10-dirty
PROJECT=demo-t10
PROJECT_PATH=$t10_wt1
WORKTREE=$t10_wt1
BRANCH=feature-t10-1
TMUX_TARGET=kingpin:t10-dirty
EOF
echo "dirty uncommitted changes" > "$t10_wt1/uncommitted.txt"
echo "ready: branch=feature-t10-1 review=APPROVE report=none" > "$t10_dir1/status"

cat > "$t10_dir2/task.env" << EOF
TASK_ID=t10-queued
PROJECT=demo-t10
PROJECT_PATH=$t10_wt2
WORKTREE=$t10_wt2
BRANCH=feature-t10-2
TMUX_TARGET=kingpin:t10-queued
EOF
echo "ready: branch=feature-t10-2 review=APPROVE report=none" > "$t10_dir2/status"

tmux new-window -d -t kingpin: -n t10-dirty cat
tmux new-window -d -t kingpin: -n t10-queued cat

# 1. Task 1 lands and acquires landing lock
"$KP_BIN/kingpin" land t10-dirty >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-t10.landing" ] && pass "t10-dirty acquired landing lock" || fail "t10-dirty landing lock missing"

# 2. Task 2 attempts to land and gets queued
"$KP_BIN/kingpin" land t10-queued >/dev/null
grep -qx "t10-queued" "$KINGPIN_HOME/projects/demo-t10.landing_queue" 2>/dev/null && pass "t10-queued added to landing_queue" || fail "t10-queued not queued"

# 3. Simulate Task 1 reporting merged
echo "merged: pr=https://github.com/example/demo/pull/1" >> "$t10_dir1/status"

# 4. Run kingpin-watch --once (which will run kingpin-done t10-dirty)
"$KP_BIN/kingpin" watch --once >/dev/null 2>&1 || true

# Assert AC 1: done_cleaned is NOT written on refused cleanup
[ ! -f "$t10_dir1/done_cleaned" ] && pass "done_cleaned not written on refused cleanup" || fail "done_cleaned prematurely written on refused cleanup"

# Assert AC 2: A refused cleanup appears as a task event with refusal reason
grep -q "^cleanup-refused:" "$t10_dir1/status" && pass "cleanup-refused recorded in status" || fail "cleanup-refused not found in status"
refusal_reason=$(tail -n 1 "$t10_dir1/status")
echo "$refusal_reason" | grep -q "uncommitted changes" && pass "refusal reason captured in status event" || fail "refusal reason missing: $refusal_reason"

# Assert AC 3: Refused cleanup does not leave landing lock held forever; next queued task can land
holder=$(cat "$KINGPIN_HOME/projects/demo-t10.landing" 2>/dev/null || true)
[ "$holder" = "t10-queued" ] && pass "landing lock handed off to next queued task t10-queued" || fail "landing lock not handed off: holder=$holder"
[ -f "$t10_dir2/landing_sent" ] && pass "t10-queued received landing dispatch" || fail "t10-queued landing_sent missing"

# Assert dedupe: the watch cycle (event + retry) and repeated refusals add one status line only
refused_count=$(grep -c "^cleanup-refused:" "$t10_dir1/status" || true)
[ "$refused_count" = "1" ] && pass "watch cycle recorded exactly one cleanup-refused line" || fail "expected 1 cleanup-refused line after watch cycle, got $refused_count"
"$KP_BIN/kingpin-done" t10-dirty >/dev/null 2>&1 || true
"$KP_BIN/kingpin-done" t10-dirty >/dev/null 2>&1 || true
refused_count=$(grep -c "^cleanup-refused:" "$t10_dir1/status" || true)
[ "$refused_count" = "1" ] && pass "repeated refusals do not append duplicate cleanup-refused lines" || fail "duplicate cleanup-refused lines: $refused_count"

# Assert the refusal is a task event the orchestrator sees via kingpin-wait
wait_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$wait_out" | grep -q "^t10-dirty status" && pass "kingpin-wait reports the cleanup-refused event" || fail "kingpin-wait did not report t10-dirty: $wait_out"
"$KP_BIN/kingpin-ack" t10-dirty >/dev/null 2>&1 || true

# Assert a repeated refusal by a task that no longer holds the lock leaves the queue order alone
printf 't10-other\nt10-other2\n' > "$KINGPIN_HOME/projects/demo-t10.landing_queue"
"$KP_BIN/kingpin-done" t10-dirty >/dev/null 2>&1 || true
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing_queue")" = "$(printf 't10-other\nt10-other2')" ] && pass "repeated refusal does not pop the landing queue" || fail "landing queue changed by non-holder refusal: $(cat "$KINGPIN_HOME/projects/demo-t10.landing_queue")"
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-queued" ] && pass "repeated refusal leaves the lock holder alone" || fail "lock holder changed by non-holder refusal"
rm -f "$KINGPIN_HOME/projects/demo-t10.landing_queue"

# Assert automatic retry: once the cause clears, kingpin-watch completes the cleanup
rm -f "$t10_wt1/uncommitted.txt"
"$KP_BIN/kingpin" watch --once >/dev/null 2>&1 || true
[ -f "$KINGPIN_HOME/archive/t10-dirty/done_cleaned" ] && pass "kingpin-watch retried the refused cleanup and archived the task with done_cleaned" || fail "refused cleanup was not retried by kingpin-watch"
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-queued" ] && pass "retried cleanup left the new lock holder alone" || fail "retried cleanup disturbed the landing lock"

# Assert kingpin-land treats a lock holder in a terminal status as free
t10_dir3="$KINGPIN_HOME/tasks/t10-land"
t10_hold="$KINGPIN_HOME/tasks/t10-holder"
mkdir -p "$t10_dir3" "$t10_hold"
tmux new-window -d -t kingpin: -n t10-land cat
cat > "$t10_dir3/task.env" << EOF2
TASK_ID=t10-land
PROJECT=demo-t10
MODE=review
WORKTREE=$t10_wt2
TMUX_TARGET=kingpin:t10-land
EOF2
echo "ready: branch=b review=APPROVE report=none" > "$t10_dir3/status"
for terminal in "merged: pr=x" "failed: boom" "cleanup-refused: r"; do
  echo "$terminal" > "$t10_hold/status"
  echo "t10-holder" > "$KINGPIN_HOME/projects/demo-t10.landing"
  rm -f "$t10_dir3/landing_sent"
  "$KP_BIN/kingpin" land t10-land >/dev/null 2>&1 || true
  [ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-land" ] && [ -f "$t10_dir3/landing_sent" ] && pass "land takes the lock from a '${terminal%%:*}' holder" || fail "land blocked by a '${terminal%%:*}' holder"
done
echo "ready: branch=b review=APPROVE report=none" > "$t10_hold/status"
echo "t10-holder" > "$KINGPIN_HOME/projects/demo-t10.landing"
rm -f "$t10_dir3/landing_sent"
"$KP_BIN/kingpin" land t10-land >/dev/null 2>&1 || true
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-holder" ] && [ ! -f "$t10_dir3/landing_sent" ] && pass "land still queues behind a live holder" || fail "land overtook a live holder"
tmux kill-window -t kingpin:t10-land 2>/dev/null || true
rm -rf "$t10_dir3" "$t10_hold"

# 5. Force cleanup of a dirty worktree succeeds and touches done_cleaned
t10_dir4="$KINGPIN_HOME/tasks/t10-force"
mkdir -p "$t10_dir4"
# Its own worktree: t10-queued still holds wt2 and the slot guard protects it
t10_wt3="$T/wt-t10-3"
mkdir -p "$t10_wt3"
git -C "$t10_wt3" init -q
cat > "$t10_dir4/task.env" << EOF2
TASK_ID=t10-force
PROJECT=demo-t10
PROJECT_PATH=$t10_wt1
WORKTREE=$t10_wt3
TMUX_TARGET=kingpin:t10-force
EOF2
echo "merged: pr=x" > "$t10_dir4/status"
echo "dirty" > "$t10_wt3/uncommitted.txt"
"$KP_BIN/kingpin-done" t10-force >/dev/null 2>&1 && fail "dirty cleanup was not refused" || pass "dirty cleanup refused without --force"
[ ! -f "$t10_dir4/done_cleaned" ] && pass "no done_cleaned after refusal without --force" || fail "done_cleaned written despite refusal"
"$KP_BIN/kingpin" done t10-force --force >/dev/null
[ -f "$KINGPIN_HOME/archive/t10-force/done_cleaned" ] && pass "kingpin-done --force created done_cleaned and archived the task" || fail "done_cleaned missing in archive after force cleanup"
rm -rf "$t10_dir4" "$KINGPIN_HOME/archive/t10-force" "$KINGPIN_HOME/archive/t10-dirty" "$t10_wt3"

tmux kill-window -t kingpin:t10-dirty 2>/dev/null || true
tmux kill-window -t kingpin:t10-queued 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t10.landing" "$KINGPIN_HOME/projects/demo-t10.landing_queue"
rm -rf "$t10_dir1" "$t10_dir2" "$t10_wt1" "$t10_wt2" "$t10_remote"

# Test 11: Lavish review dossier auto-opening, live listener, and prompt routing
echo "=== Test 11: Lavish review dossier auto-opening, live listener, and prompt routing ==="
cat > "$T/mock-lavish" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/mock-lavish.log"
cmd="\${1:-}"
case "\$cmd" in
  poll)
    if [ -f "$T/mock-lavish-response.txt" ]; then
      cat "$T/mock-lavish-response.txt"
      rm -f "$T/mock-lavish-response.txt"
    else
      sleep 0.2
    fi
    ;;
  reply)
    echo "OK: reply accepted"
    ;;
  end)
    echo "OK: session ended"
    ;;
  *)
    echo "OK: opened"
    ;;
esac
EOF
chmod +x "$T/mock-lavish"
export KINGPIN_LAVISH="$T/mock-lavish"

# 1. Setup task in review mode with report.html
t11_task="$KINGPIN_HOME/tasks/task-lavish-1"
mkdir -p "$t11_task"
echo "<html><body>Review Dossier 1</body></html>" > "$t11_task/report.html"
cat > "$t11_task/task.env" << EOF
TASK_ID=task-lavish-1
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/wt-lavish-1
ISSUE=401
TMUX_TARGET=kingpin:task-lavish-1
EOF
tmux new-window -d -t kingpin: -n task-lavish-1 cat
echo "ready: branch=b review=APPROVE report=$t11_task/report.html" >> "$t11_task/status"

# 2. Run kingpin-watch --once to detect ready and auto-arm listener
"$KP_BIN/kingpin" watch --once >/dev/null

# Assert dossier was opened in lavish
sleep 0.3
grep -q "$t11_task/report.html" "$T/mock-lavish.log" 2>/dev/null && pass "mock-lavish opened review dossier" || fail "mock-lavish did not open review dossier"

# Assert listener.pid was created and process is running
[ -f "$t11_task/listener.pid" ] && pass "listener.pid created" || fail "listener.pid missing"
lpid=$(cat "$t11_task/listener.pid" 2>/dev/null || true)
[ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && pass "listener process is running (pid $lpid)" || fail "listener process not running"

# Assert kingpin list displays listener status
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "listening: pid $lpid" && pass "kingpin list displays listener pid" || fail "kingpin list missing listener pid: $list_out"

# kingpin list shows the orchestrator lock holder and its harness
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire --harness agy >/dev/null
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "Orchestrator lock: held by pid $$ (agy)" && pass "kingpin list shows lock holder harness" || fail "kingpin list missing lock harness: $list_out"
"$KP_BIN/kingpin" lock release >/dev/null
list_out=$("$KP_BIN/kingpin" list)
! echo "$list_out" | grep -q "Orchestrator lock" && pass "kingpin list hides the lock line when free" || fail "kingpin list shows lock line when free"

# 3. Simulate Approve & Land feedback via Lavish
cat > "$T/mock-lavish-response.txt" << 'RESP'
session:
  status: feedback
prompts[1]{prompt}:
  kingpin land task-lavish-1
RESP

for i in $(seq 1 30); do
  if [ -f "$t11_task/landing_sent" ] && grep -q "approved:" "$t11_task/status" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

grep -q "approved: by user via lavish dossier" "$t11_task/status" && pass "approved status logged" || fail "approved status missing"
[ -f "$t11_task/landing_sent" ] && pass "landing triggered by listener" || fail "landing not triggered"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:task-lavish-1 -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 401" && pass "/issue-flow-done dispatched on approval" || fail "wrong done command: $pane_out"
grep -q "reply $t11_task/report.html --agent-reply Approval received" "$T/mock-lavish.log" && pass "approval confirmation reply sent to lavish" || fail "approval reply missing"

# 4. Simulate user feedback / Request Changes
t11_task2="$KINGPIN_HOME/tasks/task-lavish-2"
mkdir -p "$t11_task2"
echo "<html><body>Review Dossier 2</body></html>" > "$t11_task2/report.html"
cat > "$t11_task2/task.env" << EOF
TASK_ID=task-lavish-2
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=402
TMUX_TARGET=kingpin:task-lavish-2
EOF
tmux new-window -d -t kingpin: -n task-lavish-2 cat
echo "ready: branch=b review=APPROVE report=$t11_task2/report.html" >> "$t11_task2/status"

cat > "$T/mock-lavish-response.txt" << 'RESP'
session:
  status: feedback
prompts[1]:
  - prompt: "Request Changes: please fix line 42 in foo.sh"
    tag: action
RESP

"$KP_BIN/kingpin" listen task-lavish-2 --once >/dev/null

[ -f "$t11_task2/feedback.md" ] && pass "feedback.md created" || fail "feedback.md missing"
grep -q "Request Changes: please fix line 42 in foo.sh" "$t11_task2/feedback.md" && pass "feedback text written correctly" || fail "feedback text incorrect"
grep -q "feedback: Request Changes: please fix line 42 in foo.sh" "$t11_task2/status" && pass "feedback status logged" || fail "feedback status missing"
grep -q "reply $t11_task2/report.html --agent-reply Feedback received" "$T/mock-lavish.log" && pass "feedback receipt reply sent to lavish" || fail "feedback reply missing"

# Negative feedback that mentions "approve" is feedback, not an approval
t11_task3="$KINGPIN_HOME/tasks/task-lavish-3"
mkdir -p "$t11_task3"
echo "<html><body>Review Dossier 3</body></html>" > "$t11_task3/report.html"
cat > "$t11_task3/task.env" << EOF3
TASK_ID=task-lavish-3
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=403
TMUX_TARGET=kingpin:task-lavish-3
EOF3
echo "ready: branch=b review=APPROVE report=none" >> "$t11_task3/status"
cat > "$T/mock-lavish-response.txt" << 'RESP'
session:
  status: feedback
prompts[2]{prompt,tag}:
  "cannot approve until tests pass",action
  "Request Changes: do not approve yet",action
RESP
"$KP_BIN/kingpin" listen task-lavish-3 --once >/dev/null
[ ! -f "$t11_task3/landing_sent" ] && pass "negative feedback mentioning approve did not land" || fail "negative feedback triggered landing"
! grep -q "^approved:" "$t11_task3/status" && pass "negative feedback not logged as approval" || fail "negative feedback logged as approval"
grep -q "cannot approve until tests pass" "$t11_task3/feedback.md" && grep -q "do not approve yet" "$t11_task3/feedback.md" && pass "both negative prompts kept as feedback" || fail "negative prompts missing from feedback.md"
rm -rf "$t11_task3"

# Listener notes after the worker's ready: line must not bypass the review gate
t11_gate="$KINGPIN_HOME/tasks/task-lavish-gate"
mkdir -p "$t11_gate"
cat > "$t11_gate/task.env" << EOF4
TASK_ID=task-lavish-gate
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=404
TMUX_TARGET=kingpin:task-lavish-gate
EOF4
tmux new-window -d -t kingpin: -n task-lavish-gate cat
printf '%s\n' "ready: branch=b review=NEEDS CHANGES report=.agents/reviews/r9.md" "feedback: Request Changes: please rename foo" "approved: by user via lavish dossier" > "$t11_gate/status"
"$KP_BIN/kingpin" land task-lavish-gate >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:task-lavish-gate -S -5)
echo "$pane_out" | grep -q "/fix-findings $T/proj/.agents/reviews/r9.md" && pass "feedback/approved notes do not bypass the fix-findings gate" || fail "gate bypassed after listener notes: $pane_out"
[ ! -f "$t11_gate/landing_sent" ] && pass "no landing dispatched for NEEDS CHANGES after listener notes" || fail "landing dispatched despite NEEDS CHANGES"
tmux kill-window -t kingpin:task-lavish-gate 2>/dev/null || true
rm -rf "$t11_gate"

# Repeat Approve while a fix pass is pending does not resend /fix-findings
t11_rep="$KINGPIN_HOME/tasks/task-lavish-repeat"
mkdir -p "$t11_rep"
echo "<html><body>Review Dossier R</body></html>" > "$t11_rep/report.html"
cat > "$t11_rep/task.env" << EOF5
TASK_ID=task-lavish-repeat
PROJECT=demo-repeat
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=405
TMUX_TARGET=kingpin:task-lavish-repeat
EOF5
tmux new-window -d -t kingpin: -n task-lavish-repeat cat
echo "ready: branch=b review=NEEDS CHANGES report=.agents/reviews/r5.md" > "$t11_rep/status"
approve_resp() {
  printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-repeat" > "$T/mock-lavish-response.txt"
}
count_fix() { tmux capture-pane -pt kingpin:task-lavish-repeat -S -50 | grep -c "^/fix-findings "; }
approve_resp; "$KP_BIN/kingpin" listen task-lavish-repeat --once >/dev/null
sleep 0.1
n1=$(count_fix)
approve_resp; "$KP_BIN/kingpin" listen task-lavish-repeat --once >/dev/null
sleep 0.1
n2=$(count_fix)
[ "$n1" -ge 1 ] && [ "$n1" = "$n2" ] && pass "repeat Approve did not resend /fix-findings" || fail "/fix-findings lines: first=$n1 after repeat=$n2"
grep -q "Approval already received" "$T/mock-lavish.log" && pass "repeat Approve answered with a waiting reply" || fail "waiting reply missing"
echo "fixed: high=0 report=.agents/reviews/r5.md" >> "$t11_rep/status"
approve_resp; "$KP_BIN/kingpin" listen task-lavish-repeat --once >/dev/null
[ -f "$t11_rep/landing_sent" ] && pass "Approve after the worker's new event lands" || fail "landing not started after fixed:"
tmux kill-window -t kingpin:task-lavish-repeat 2>/dev/null || true
rm -rf "$t11_rep"
rm -f "$KINGPIN_HOME/projects/demo-repeat.landing" "$KINGPIN_HOME/projects/demo-repeat.landing_queue"

# Concurrent background launches start exactly one listener
t11_race="$KINGPIN_HOME/tasks/task-lavish-race"
mkdir -p "$t11_race"
echo "<html><body>Review Dossier Q</body></html>" > "$t11_race/report.html"
cat > "$t11_race/task.env" << EOF6
TASK_ID=task-lavish-race
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF6
echo "ready: branch=b review=APPROVE report=none" > "$t11_race/status"
for _ in 1 2 3 4; do "$KP_BIN/kingpin" listen task-lavish-race --background & done
wait
sleep 0.3
n=$(pgrep -f "^bash .*/kingpin-listen task-lavish-race$" | wc -l)
[ "$n" = "1" ] && pass "concurrent launches started one listener" || fail "$n listeners running"
rpid=$(cat "$t11_race/listener.pid" 2>/dev/null || true)
[ -n "$rpid" ] && { kill -- "-$rpid" 2>/dev/null || kill "$rpid" 2>/dev/null || true; }
sleep 0.2
[ ! -d "$t11_race/listener.lock" ] && pass "launch lock released" || fail "launch lock left behind"
rm -rf "$t11_race"

# Prompts the parser cannot read are kept in listener.log, not dropped silently
t11_raw="$KINGPIN_HOME/tasks/task-lavish-raw"
mkdir -p "$t11_raw"
echo "<html><body>Review Dossier W</body></html>" > "$t11_raw/report.html"
cat > "$t11_raw/task.env" << EOF7
TASK_ID=task-lavish-raw
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF7
echo "ready: branch=b review=APPROVE report=none" > "$t11_raw/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - weird: shape" > "$T/mock-lavish-response.txt"
"$KP_BIN/kingpin" listen task-lavish-raw --once >/dev/null
grep -q "could not be parsed" "$t11_raw/listener.log" && grep -q "weird: shape" "$t11_raw/listener.log" && pass "unparsed prompts logged raw" || fail "unparsed prompts not logged"
grep -q "reply $t11_raw/report.html --agent-reply I could not read" "$T/mock-lavish.log" && pass "user told to resend unreadable feedback" || fail "no resend reply"
! grep -q "^feedback:" "$t11_raw/status" && pass "unreadable prompt did not produce a feedback note" || fail "bogus feedback note"
rm -rf "$t11_raw"

# Run kingpin-watch to verify feedback event handling
watch_fb=$("$KP_BIN/kingpin" watch --once 2>&1 || true)
echo "$watch_fb" | grep -q "received review feedback" && pass "kingpin-watch reported review feedback" || fail "kingpin-watch did not report feedback: $watch_fb"

# 5. Verify cleanup on kingpin-done
[ -f "$t11_task/listener.pid" ] && pass "task-lavish-1 listener.pid present before done" || fail "listener.pid missing before done"
"$KP_BIN/kingpin" done task-lavish-1 --force >/dev/null

[ ! -f "$t11_task/listener.pid" ] && [ ! -f "$KINGPIN_HOME/archive/task-lavish-1/listener.pid" ] && pass "listener.pid removed by kingpin-done" || fail "listener.pid still present after done"
kill -0 "$lpid" 2>/dev/null && fail "listener was not killed" || pass "listener process killed by kingpin-done"
grep -q "end $t11_task/report.html" "$T/mock-lavish.log" && pass "mock-lavish end invoked by kingpin-done" || fail "mock-lavish end missing"

# Teardown test 10 resources
tmux kill-window -t kingpin:task-lavish-1 2>/dev/null || true
tmux kill-window -t kingpin:task-lavish-2 2>/dev/null || true
rm -rf "$t11_task" "$t11_task2"
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
unset KINGPIN_LAVISH

# Test 12: archive finished tasks, hide them from list, and guard shared worktree slots
echo "=== Test 12: archive finished tasks and slot guard ==="
t12_repo="$T/t12-repo"
mkdir -p "$t12_repo"
git -C "$t12_repo" init -q
t12_slot_a="$T/t12-slot-a"
t12_slot_b="$T/t12-slot-b"
mkdir -p "$t12_slot_a" "$t12_slot_b"
git -C "$t12_slot_a" init -q
git -C "$t12_slot_b" init -q

t12_make_task() {
  local id=$1 worktree=$2 last_status=$3
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF12
TASK_ID=$id
PROJECT=demo-t12
PROJECT_PATH=$t12_repo
WORKTREE=$worktree
TMUX_TARGET=kingpin:$id
EOF12
  echo "$last_status" > "$KINGPIN_HOME/tasks/$id/status"
}

# 12.1 A successful cleanup moves the task dir from tasks/ to archive/
t12_make_task t12-merged "$t12_slot_a" "merged: pr=x"
echo "critique from archived task" > "$KINGPIN_HOME/tasks/t12-merged/critique"
"$KP_BIN/kingpin-done" t12-merged --force >/dev/null
[ ! -d "$KINGPIN_HOME/tasks/t12-merged" ] && [ -f "$KINGPIN_HOME/archive/t12-merged/task.env" ] && [ -f "$KINGPIN_HOME/archive/t12-merged/done_cleaned" ] && pass "kingpin-done moved the task dir into the archive" || fail "task dir not archived"

# 12.2 list hides finished tasks by default; --all shows them
t12_make_task t12-live "$t12_slot_b" "ready: branch=b review=APPROVE report=none"
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "t12-live" && ! echo "$list_out" | grep -q "t12-merged" && pass "list shows the live task and hides the merged one" || fail "list output wrong: $list_out"
list_all=$("$KP_BIN/kingpin" list --all)
echo "$list_all" | grep -q "t12-live" && echo "$list_all" | grep -q "t12-merged.*(archived)" && pass "list --all shows live and archived tasks" || fail "list --all output wrong: $list_all"
"$KP_BIN/kingpin" list --bogus >/dev/null 2>&1 && fail "list accepted an unknown flag" || pass "list rejects an unknown flag"

# 12.3 Archived critiques are still collected by curate
export KINGPIN_SKILLS_DIR=$T/skills
mkdir -p "$T/skills"
t12_curate=$("$KP_BIN/kingpin" curate --dry-run)
echo "$t12_curate" | grep -q "critique from archived task" && pass "curate collects the critique of an archived task" || fail "curate missed the archived critique: $t12_curate"

# 12.4 Cleanup is idempotent for an archived task
"$KP_BIN/kingpin-done" t12-merged >/dev/null 2>&1 && pass "kingpin-done on an archived task is a no-op" || fail "kingpin-done failed on an archived task"

# 12.5 Slot guard: refuse, even with --force, while another unfinished task holds the worktree
t12_make_task t12-old "$t12_slot_b" "merged: pr=y"
"$KP_BIN/kingpin-done" t12-old --force >/dev/null 2>&1 && fail "cleanup released a slot held by an unfinished task" || pass "kingpin-done --force refused a slot held by an unfinished task"
[ -d "$KINGPIN_HOME/tasks/t12-old" ] && [ ! -d "$KINGPIN_HOME/archive/t12-old" ] && pass "refused cleanup left the record in place" || fail "refused cleanup moved the record"
grep -q "^cleanup-refused: .*t12-live" "$KINGPIN_HOME/tasks/t12-old/status" && pass "refusal names the holding task" || fail "refusal reason missing"
[ -d "$t12_slot_b" ] && pass "held worktree still exists" || fail "held worktree was removed"
# Once the holder is finished the slot is no longer guarded
echo "merged: pr=z" >> "$KINGPIN_HOME/tasks/t12-live/status"
"$KP_BIN/kingpin-done" t12-old --force >/dev/null 2>&1 && [ -d "$KINGPIN_HOME/archive/t12-old" ] && pass "cleanup proceeds once the other task is finished" || fail "cleanup still refused after the holder finished"

# 12.6 A reused task id is archived beside the earlier record instead of overwriting it
mkdir -p "$KINGPIN_HOME/archive/t12-reuse"
echo "earlier" > "$KINGPIN_HOME/archive/t12-reuse/marker"
t12_make_task t12-reuse "$t12_slot_a" "merged: pr=r"
"$KP_BIN/kingpin-done" t12-reuse --force >/dev/null 2>&1
[ ! -d "$KINGPIN_HOME/tasks/t12-reuse" ] && [ -f "$KINGPIN_HOME/archive/t12-reuse/marker" ] && [ -f "$KINGPIN_HOME/archive/t12-reuse.2/done_cleaned" ] && pass "reused task id archived beside the earlier record" || fail "reused task id was not archived safely"

rm -rf "$KINGPIN_HOME/archive/t12-reuse" "$KINGPIN_HOME/archive/t12-reuse.2" "$KINGPIN_HOME/tasks/t12-live" "$KINGPIN_HOME/archive/t12-merged" "$KINGPIN_HOME/archive/t12-old" "$t12_repo" "$t12_slot_a" "$t12_slot_b"
unset KINGPIN_SKILLS_DIR

# Test 13: kingpin-send types text literally and submits it with a separate Enter
echo "=== Test 13: kingpin-send literal text ==="
t13_dir="$KINGPIN_HOME/tasks/t13-send"
mkdir -p "$t13_dir"
tmux new-window -d -t kingpin: -n t13-send cat
cat > "$t13_dir/task.env" << EOF
TASK_ID=t13-send
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t13-send
EOF

# Poll the pane (wrapped lines joined) until a line equal to $1 shows up
pane_has_line() {
  local want=$1 i
  for i in $(seq 1 50); do
    tmux capture-pane -pJt kingpin:t13-send -S -200 2>/dev/null | grep -qxF -- "$want" && return 0
    sleep 0.1
  done
  return 1
}

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "Escape" >/dev/null
pane_has_line "Escape" && pass "kingpin-send delivers 'Escape' as text, not the key" || fail "Escape did not arrive as text"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "C-c" >/dev/null
pane_has_line "C-c" && pass "kingpin-send delivers 'C-c' as text, not Ctrl-C" || fail "C-c did not arrive as text"
tmux list-panes -t kingpin:t13-send >/dev/null 2>&1 && pass "cat pane survived 'C-c' text" || fail "pane died after C-c"

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "-n literal dash" >/dev/null
pane_has_line "-n literal dash" && pass "kingpin-send delivers text starting with a dash" || fail "dash-leading text did not arrive"

long_msg=$(printf '%04d' $(seq 1 500))
[ "${#long_msg}" -eq 2000 ] || fail "test message is ${#long_msg} chars, not 2000"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "$long_msg" >/dev/null
pane_has_line "$long_msg" && pass "2,000-character message arrived intact" || fail "2,000-character message was truncated or altered"

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send $'multi-a\nmulti-b' >/dev/null
if pane_has_line "multi-a" && pane_has_line "multi-b"; then pass "multi-line message: both lines reached the pane"; else fail "multi-line message lost a line"; fi

tmux kill-window -t kingpin:t13-send 2>/dev/null || true
rm -rf "$t13_dir"

# Test 14: kingpin land states whether it lands or runs the fix pass first
echo "=== Test 14: kingpin land output (fix pass vs landing) and approve alias ==="
mk_t14() {
  local name=$1 status=$2
  local d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  tmux new-window -d -t kingpin: -n "$name" cat
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t14
MODE=review
WORKTREE=$T/proj
ISSUE=314
TMUX_TARGET=kingpin:$name
ENVEOF
  echo "$status" > "$d/status"
}
rm -f "$KINGPIN_HOME/projects/demo-t14.landing" "$KINGPIN_HOME/projects/demo-t14.landing_queue"

# Fix-findings path: says a fix pass runs first and that landing continues after fixed:
mk_t14 t14-nits "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r.md"
out=$("$KP_BIN/kingpin" land t14-nits)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "fix pass" && echo "$last" | grep -q "fixed:" && pass "fix path: last line says the fix pass runs first and landing continues after fixed:" || fail "fix path output unclear: $out"
echo "$last" | grep -q "not landing yet" && pass "fix path: output says it is not landing yet" || fail "fix path does not say it is not landing: $last"
[ ! -f "$KINGPIN_HOME/projects/demo-t14.landing" ] && pass "fix path: no landing lock taken" || fail "fix path took the landing lock"

# Fix pass left High findings: re-review, not landing
echo "fixed: high=1 report=r.md" >> "$KINGPIN_HOME/tasks/t14-nits/status"
out=$("$KP_BIN/kingpin" land t14-nits)
echo "$out" | tail -n 1 | grep -q "re-review" && pass "re-review path: output says a re-review comes first" || fail "re-review path output unclear: $out"

# Clean fix pass: says landing is starting, and the last line is the outcome (not kingpin-send's OK line)
echo "fixed: high=0 report=r.md" >> "$KINGPIN_HOME/tasks/t14-nits/status"
out=$("$KP_BIN/kingpin" land t14-nits)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "starting landing" && pass "clean fix pass: output says landing is starting" || fail "clean fix pass output unclear: $out"
echo "$last" | grep -q "^OK: sent" && fail "kingpin-send's OK line hides the outcome line" || pass "outcome line is the last line"
sleep 0.1
tmux capture-pane -pt kingpin:t14-nits -S -8 | grep -q "/issue-flow-done 314" && pass "clean fix pass dispatched /issue-flow-done" || fail "no /issue-flow-done after clean fix pass"
tmux kill-window -t kingpin:t14-nits 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"

# Clean review, via both names
mk_t14 t14-clean "ready: branch=b review=APPROVE report=none"
out=$("$KP_BIN/kingpin" land t14-clean)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "starting landing" && echo "$last" | grep -q "review is clean" && pass "clean path: output says the review is clean and landing is starting" || fail "clean path output unclear: $out"
tmux kill-window -t kingpin:t14-clean 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"
# No parsable verdict: lands as before, but does not claim the review is clean
mk_t14 t14-nover "ready: branch=b"
out=$("$KP_BIN/kingpin" land t14-nover)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "no review verdict recorded" && ! echo "$last" | grep -q "review is clean" && pass "no verdict: output does not claim the review is clean" || fail "no-verdict output unclear: $out"
tmux kill-window -t kingpin:t14-nover 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"
mk_t14 t14-alias "ready: branch=b review=APPROVE report=none"
out=$("$KP_BIN/kingpin" approve t14-alias)
echo "$out" | tail -n 1 | grep -q "starting landing" && [ -f "$KINGPIN_HOME/tasks/t14-alias/landing_sent" ] && pass "kingpin approve behaves like kingpin land" || fail "kingpin approve failed: $out"
tmux kill-window -t kingpin:t14-alias 2>/dev/null || true
"$KP_BIN/kingpin" --help | grep -q "approve" && pass "kingpin --help mentions the approve alias" || fail "--help does not mention approve"
rm -f "$KINGPIN_HOME/projects/demo-t14.landing" "$KINGPIN_HOME/projects/demo-t14.landing_queue"
rm -rf "$KINGPIN_HOME/tasks/t14-nits" "$KINGPIN_HOME/tasks/t14-clean" "$KINGPIN_HOME/tasks/t14-nover" "$KINGPIN_HOME/tasks/t14-alias"

# Test 15: workers are tracked by tmux window ID, so renames and moves keep working
echo "=== Test 15: window ID tracking (rename, move, gone, legacy) ==="
mk_t15() {
  local name=$1 cmd=${2:-cat} d wid
  d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "$name" "$cmd")
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t15
HARNESS=claude
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$T/t15-missing-worktree-$name
TMUX_TARGET=kingpin:$name
TMUX_WINDOW_ID=$wid
ENVEOF
  : > "$d/status"
  echo 0 > "$d/seen"
  printf '%s\n' "$wid"
}

# Rename + move to another session; the old name target must be dead
t15_wid=$(mk_t15 t15-move)
tmux new-session -d -s kp-t15-other -n home
tmux rename-window -t "$t15_wid" renamed-t15
tmux move-window -d -s "$t15_wid" -t kp-t15-other:
! tmux list-panes -t kingpin:t15-move >/dev/null 2>&1 && pass "t15: old name target no longer resolves after rename+move" || fail "t15: old name target still resolves"
tmux list-windows -t kp-t15-other -F '#{window_id}' | grep -qx "$t15_wid" && pass "t15: window now lives in the other session" || fail "t15: window did not move"

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t15-move "moved-ok" > "$T/t15-send.out" 2>&1 && pass "t15: kingpin-send reached the renamed+moved window" || fail "t15: kingpin-send failed: $(cat "$T/t15-send.out")"
t15_seen=0
for _ in $(seq 1 50); do
  tmux capture-pane -pJt "$t15_wid" -S -50 2>/dev/null | grep -qxF "moved-ok" && { t15_seen=1; break; }
  sleep 0.1
done
[ "$t15_seen" -eq 1 ] && pass "t15: text arrived in the moved window's pane" || fail "t15: text did not arrive in the moved window"

t15_wait=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t15_wait" | grep -q "^t15-move exited" && fail "t15: kingpin-wait reported a live renamed+moved window as exited" || pass "t15: kingpin-wait still sees the renamed+moved window as alive"
"$KP_BIN/kingpin" ack t15-move
[ ! -f "$KINGPIN_HOME/tasks/t15-move/seen_exited" ] && pass "t15: kingpin ack did not mark the live window exited" || fail "t15: kingpin ack marked the live window exited"

"$KP_BIN/kingpin-done" t15-move --force >/dev/null 2>&1 || true
! tmux list-windows -a -F '#{window_id}' | grep -qx "$t15_wid" && pass "t15: kingpin-done closed the renamed+moved window" || fail "t15: kingpin-done left the renamed+moved window alive"
tmux kill-session -t kp-t15-other 2>/dev/null || true

# Recorded window gone: reads as exited, even though a window with the old name exists again
t15g_wid=$(mk_t15 t15-gone)
tmux kill-window -t "$t15g_wid"
tmux new-window -d -t kingpin: -n t15-gone cat
t15g_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t15g_out" | grep -q "^t15-gone exited" && pass "t15: task whose window ID is gone reads as exited" || fail "t15: gone window not reported as exited (got: $t15g_out)"
"$KP_BIN/kingpin" ack t15-gone
[ -f "$KINGPIN_HOME/tasks/t15-gone/seen_exited" ] && pass "t15: kingpin ack marks the gone window exited" || fail "t15: seen_exited missing for gone window"
tmux kill-window -t kingpin:t15-gone 2>/dev/null || true

# Legacy task.env with only TMUX_TARGET still works through the name
t15l_wid=$(mk_t15 t15-legacy)
sed -i '/^TMUX_WINDOW_ID=/d' "$KINGPIN_HOME/tasks/t15-legacy/task.env"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t15-legacy "legacy-ok" >/dev/null 2>&1 && pass "t15: legacy task.env (TMUX_TARGET only) still reaches the window" || fail "t15: legacy task.env send failed"
"$KP_BIN/kingpin-done" t15-legacy --force >/dev/null 2>&1 || true
! tmux list-windows -a -F '#{window_id}' | grep -qx "$t15l_wid" && pass "t15: kingpin-done closed the legacy window" || fail "t15: kingpin-done left the legacy window alive"
rm -rf "$KINGPIN_HOME/tasks/t15-move" "$KINGPIN_HOME/tasks/t15-gone" "$KINGPIN_HOME/tasks/t15-legacy"

# Test 16: cleanup removes the branch the worker actually used, locally and on the remote
echo "=== Test 16: branch cleanup (switched branch, remote deletion) ==="
t16_remote="$T/t16-remote.git"
t16_repo="$T/t16-repo"
t16_stub="$T/t16-stub"
mkdir -p "$t16_stub"
git init --bare -q -b main "$t16_remote"
git init -q -b main "$t16_repo"
git -C "$t16_repo" config user.name Tester
git -C "$t16_repo" config user.email test@example.com
echo init > "$t16_repo/init.txt"
git -C "$t16_repo" add init.txt
git -C "$t16_repo" commit -qm init
git -C "$t16_repo" remote add origin "$t16_remote"
git -C "$t16_repo" push -q origin main
git -C "$t16_repo" remote set-head origin main >/dev/null 2>&1
# Stand-in for `treehouse return`: frees the slot by removing the worktree.
cat > "$t16_stub/treehouse" << 'EOF16'
#!/usr/bin/env bash
wt=${!#}
git worktree remove --force "$wt"
EOF16
chmod +x "$t16_stub/treehouse"

t16_make_task() {
  local id=$1 recorded=$2 actual=$3 merged=$4
  local wt="$T/t16-wt-$id"
  git -C "$t16_repo" fetch -q origin
  git -C "$t16_repo" merge -q --ff-only origin/main
  git -C "$t16_repo" branch "$recorded" main
  git -C "$t16_repo" worktree add -q "$wt" "$recorded"
  git -C "$wt" config user.name Tester
  git -C "$wt" config user.email test@example.com
  if [ "$actual" != "$recorded" ]; then git -C "$wt" checkout -qb "$actual"; fi
  echo "$id" > "$wt/$id.txt"
  git -C "$wt" add "$id.txt"
  git -C "$wt" commit -qm "work $id"
  git -C "$wt" push -q origin "$actual"
  if [ "$merged" = yes ]; then
    git -C "$t16_repo" fetch -q origin
    git -C "$t16_repo" push -q origin "refs/remotes/origin/$actual:refs/heads/main"
  fi
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF16T
TASK_ID=$id
PROJECT=demo-t16
PROJECT_PATH=$t16_repo
WORKTREE=$wt
BRANCH=$recorded
TMUX_TARGET=kingpin:$id
EOF16T
  echo "merged: pr=x" > "$KINGPIN_HOME/tasks/$id/status"
}
t16_local() { git -C "$t16_repo" show-ref --verify --quiet "refs/heads/$1"; }
t16_remote_has() { git -C "$t16_repo" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }

# The worker moved off kingpin/<id> to another branch, and its work is merged
t16_make_task t16-switch kingpin/t16-switch feature/t16-switch yes
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-switch >/dev/null 2>&1 && pass "t16: cleanup of a task on a switched branch succeeds" || fail "t16: cleanup of a switched branch failed"
! t16_local feature/t16-switch && pass "t16: local branch the worker used is deleted" || fail "t16: switched local branch survived cleanup"
! t16_local kingpin/t16-switch && pass "t16: recorded local branch is deleted" || fail "t16: recorded local branch survived cleanup"
! t16_remote_has feature/t16-switch && pass "t16: remote branch is deleted after the merge check passes" || fail "t16: remote branch survived cleanup"
t16_local main && t16_remote_has main && pass "t16: default branch is untouched" || fail "t16: default branch was removed"

# A branch that is already gone from the remote is not an error
t16_make_task t16-gone kingpin/t16-gone kingpin/t16-gone yes
git -C "$t16_repo" push -q origin --delete kingpin/t16-gone
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-gone >/dev/null 2>&1 && pass "t16: missing remote branch is not an error" || fail "t16: cleanup failed on a missing remote branch"
[ -f "$KINGPIN_HOME/archive/t16-gone/done_cleaned" ] && pass "t16: task archived despite the missing remote branch" || fail "t16: task not archived"

# Unmerged work: cleanup is refused and nothing is deleted
t16_make_task t16-unmerged kingpin/t16-unmerged feature/t16-unmerged no
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-unmerged >/dev/null 2>&1 && fail "t16: unmerged cleanup was not refused" || pass "t16: unmerged cleanup is refused"
t16_local feature/t16-unmerged && t16_remote_has feature/t16-unmerged && pass "t16: nothing deleted when the merge check fails" || fail "t16: branch deleted despite the refused cleanup"

# --force skips the merge check, so the remote branch stays
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-unmerged --force >/dev/null 2>&1 || true
t16_remote_has feature/t16-unmerged && pass "t16: --force leaves the unverified remote branch alone" || fail "t16: --force deleted the remote branch"

# Test 17: descriptive slugs for task ID, branch and window (kp-<n>-<slug> / kp-<slug>)
echo "=== Test 17: descriptive title slugs ==="
t17_title='Unify Task ID, git branch, and window name with descriptive title slugs'
[ "$(node "$KP_ROOT/lib/slug.mjs" "$t17_title")" = "unify-task-id" ] && pass "t17: slug of a long title is 3 words" || fail "t17: wrong slug for the long title"
[ -z "$(node "$KP_ROOT/lib/slug.mjs" '!!!')" ] && pass "t17: punctuation-only text gives an empty slug" || fail "t17: punctuation-only slug not empty"
[ "$(node "$KP_ROOT/lib/slug.mjs" 'Überprüfung der API')" = "uberprufung-der-api" ] && pass "t17: accents are folded" || fail "t17: accents not folded"
t17_long=$(node "$KP_ROOT/lib/slug.mjs" 'Internationalization infrastructure modernization')
[[ $t17_long =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#t17_long}" -le 24 ] && pass "t17: slug is lowercase dashes and at most 24 chars ($t17_long)" || fail "t17: bad slug shape: $t17_long"
[ "$(node "$KP_ROOT/lib/slug.mjs" 'the supercalifragilisticexpialidocious thing')" = "supercalifragilisticexpi" ] && pass "t17: an over-long first word falls back to a non-stop word" || fail "t17: over-long first word fell back to a stop word"

# gh stub: prints a fixed title, logs every call, fails when t17-gh-fail exists
cat > "$T/t17-gh" << 'EOF17'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/t17-gh-calls"
[ ! -e "$(dirname "$0")/t17-gh-fail" ] || exit 1
echo "Wait for worker wakeup events"
EOF17
chmod +x "$T/t17-gh"
export KINGPIN_GH=$T/t17-gh
export KINGPIN_AGY=$T/fake-worker

# Issue mode: ID, branch, window and TMUX_TARGET carry the same slug
t17_id=kp-301-wait-worker-wakeup
t17_out=$("$KP_BIN/kingpin" spawn demo-auto --issue 301 --mode review)
echo "$t17_out" | grep -q "spawned $t17_id " && pass "t17: issue spawn named $t17_id" || fail "t17: issue spawn ID wrong: $t17_out"
t17_env=$KINGPIN_HOME/tasks/$t17_id/task.env
grep -qx "BRANCH=kingpin/$t17_id" "$t17_env" && pass "t17: BRANCH is kingpin/$t17_id" || fail "t17: wrong BRANCH"
grep -qx "TMUX_TARGET=kingpin:$t17_id" "$t17_env" && pass "t17: TMUX_TARGET is kingpin:$t17_id" || fail "t17: wrong TMUX_TARGET"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "$t17_id" && pass "t17: tmux window is named $t17_id" || fail "t17: window name wrong"
t17_wt=$(sed -n 's/^WORKTREE=//p' "$t17_env")
[ "$(git -C "$t17_wt" branch --show-current)" = "kingpin/$t17_id" ] && pass "t17: worktree is on kingpin/$t17_id" || fail "t17: worktree branch wrong"
"$KP_BIN/kingpin" send "$t17_id" "echo t17-ok" | grep -q "OK: sent to kingpin:$t17_id" && pass "t17: kingpin send reaches the slugged window" || fail "t17: kingpin send failed"
"$KP_BIN/kingpin" done "$t17_id" --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "$t17_id" && [ ! -d "$KINGPIN_HOME/tasks/$t17_id" ] && pass "t17: kingpin done closed and archived the slugged task" || fail "t17: kingpin done left the task behind"

# gh failing: the spawn degrades to kp-<n>
touch "$T/t17-gh-fail"
"$KP_BIN/kingpin" spawn demo-auto --issue 302 --mode review | grep -q "spawned kp-302 " && pass "t17: gh failure falls back to kp-302" || fail "t17: gh failure did not fall back to kp-302"
"$KP_BIN/kingpin" done kp-302 --force >/dev/null
rm -f "$T/t17-gh-fail"

# Text mode: kp-<slug>, second identical request gets -2
"$KP_BIN/kingpin" spawn demo-auto --text "refactor authentication service" --mode review | grep -q "spawned kp-refactor-authentication " && pass "t17: text spawn named kp-refactor-authentication" || fail "t17: text spawn ID wrong"
"$KP_BIN/kingpin" spawn demo-auto --text "refactor authentication service" --mode review | grep -q "spawned kp-refactor-authentication-2 " && pass "t17: second identical text spawn gets -2" || fail "t17: text spawn collided"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "kp-refactor-authentication" && pass "t17: text window is named kp-refactor-authentication" || fail "t17: text window name wrong"

# Rename: once the worker reports its issue, the window and TMUX_TARGET follow
t17_text=kp-refactor-authentication
t17_tenv=$KINGPIN_HOME/tasks/$t17_text/task.env
t17_twid=$(sed -n 's/^TMUX_WINDOW_ID=//p' "$t17_tenv")
t17_tbranch=$(sed -n 's/^BRANCH=//p' "$t17_tenv")
echo "issue: #303 https://example/303" >> "$KINGPIN_HOME/tasks/$t17_text/status"
"$KP_BIN/kingpin-wait" --once >/dev/null || true
t17_new=kp-303-wait-worker-wakeup
[ "$(tmux display-message -p -t "$t17_twid" '#{window_name}')" = "$t17_new" ] && pass "t17: window renamed to $t17_new after the issue line" || fail "t17: window not renamed"
grep -qx "TMUX_TARGET=kingpin:$t17_new" "$t17_tenv" && pass "t17: TMUX_TARGET rewritten to kingpin:$t17_new" || fail "t17: TMUX_TARGET not rewritten"
grep -qx "TMUX_WINDOW_ID=$t17_twid" "$t17_tenv" && grep -qx "BRANCH=$t17_tbranch" "$t17_tenv" && [ -d "$KINGPIN_HOME/tasks/$t17_text" ] && pass "t17: window ID, branch and task folder unchanged" || fail "t17: rename touched the window ID, branch or task folder"
[ -f "$KINGPIN_HOME/tasks/$t17_text/renamed" ] && pass "t17: renamed marker written" || fail "t17: no renamed marker"
"$KP_BIN/kingpin" send "$t17_text" "echo t17-renamed" | grep -q "OK: sent to kingpin:$t17_new" && pass "t17: kingpin send reaches the renamed window" || fail "t17: kingpin send after rename failed"
t17_calls=$(wc -l < "$T/t17-gh-calls")
"$KP_BIN/kingpin-wait" --once >/dev/null || true
"$KP_BIN/kingpin-rename" "$t17_text" >/dev/null
[ "$(wc -l < "$T/t17-gh-calls")" = "$t17_calls" ] && [ "$(tmux display-message -p -t "$t17_twid" '#{window_name}')" = "$t17_new" ] && pass "t17: a second rename is a no-op" || fail "t17: second rename was not a no-op"
"$KP_BIN/kingpin" done "$t17_text" --force >/dev/null
"$KP_BIN/kingpin" done kp-refactor-authentication-2 --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' | grep -qE "^kp-(303|refactor)" && pass "t17: kingpin done closed the renamed windows" || fail "t17: windows left behind"

# An explicit --id wins and never calls gh
rm -f "$T/t17-gh-calls"
"$KP_BIN/kingpin" spawn demo-auto --issue 304 --id t17-explicit --mode review | grep -q "spawned t17-explicit " && pass "t17: --id overrides the generated ID" || fail "t17: --id ignored"
[ ! -e "$T/t17-gh-calls" ] && pass "t17: --id spawn made no gh call" || fail "t17: --id spawn called gh"
"$KP_BIN/kingpin" done t17-explicit --force >/dev/null
unset KINGPIN_GH

# Test 18: spawned windows keep the name Kingpin gave them
echo "=== Test 18: spawned windows are pinned against renames ==="
# Simulate a user config that renames windows; the private server dies in cleanup.
tmux set-option -g automatic-rename on
tmux set-option -g allow-rename on
cat > "$T/fake-renamer" << 'FRN'
#!/usr/bin/env bash
# Wait for the test's go marker, then emit a rename escape sequence like a child command would
until [ -f "$KINGPIN_TASK_DIR/go" ]; do sleep 0.1; done
printf '\033kevil\033\\'
: > "$KINGPIN_TASK_DIR/emitted"
exec bash
FRN
chmod +x "$T/fake-renamer"
export KINGPIN_AGY=$T/fake-renamer
"$KP_BIN/kingpin" spawn demo-auto --issue 306 --id t18-pinned --mode review >/dev/null
t18_wid=$(sed -n 's/^TMUX_WINDOW_ID=//p' "$KINGPIN_HOME/tasks/t18-pinned/task.env")
[ "$(tmux display-message -p -t "$t18_wid" '#{automatic-rename} #{allow-rename}')" = "0 0" ] && pass "t18: automatic-rename and allow-rename are off on the task window" || fail "t18: window options not pinned: $(tmux display-message -p -t "$t18_wid" '#{automatic-rename} #{allow-rename}')"
touch "$KINGPIN_HOME/tasks/t18-pinned/go"
for _ in $(seq 1 50); do
  [ -f "$KINGPIN_HOME/tasks/t18-pinned/emitted" ] && break
  sleep 0.1
done
sleep 0.3
[ -f "$KINGPIN_HOME/tasks/t18-pinned/emitted" ] && pass "t18: worker emitted the rename escape sequence" || fail "t18: worker never emitted the escape sequence"
[ "$(tmux display-message -p -t "$t18_wid" '#{window_name}')" = "t18-pinned" ] && pass "t18: escape-sequence rename did not change the window name" || fail "t18: window renamed to $(tmux display-message -p -t "$t18_wid" '#{window_name}')"
"$KP_BIN/kingpin" done t18-pinned --force >/dev/null
export KINGPIN_AGY=$T/fake-worker
tmux set-option -gu automatic-rename
tmux set-option -gu allow-rename

# Test 19: a refused kingpin done keeps a live worker's status; done stops the listener; ack on an archived task is a no-op
echo "=== Test 19: refused done vs live worker status, listener cleanup, ack on archived task ==="
cat > "$T/mock-lavish-t19" << 'MLEOF'
#!/usr/bin/env bash
case "${1:-}" in
  poll) sleep 0.2 ;;
  *) echo "OK" ;;
esac
MLEOF
chmod +x "$T/mock-lavish-t19"
export KINGPIN_LAVISH="$T/mock-lavish-t19"
mk_t19() {
  local name=$1 status=$2 wt d
  d="$KINGPIN_HOME/tasks/$name"
  wt="$T/wt-$name"
  mkdir -p "$d" "$wt"
  git -C "$wt" init -q
  echo dirty > "$wt/uncommitted.txt"
  echo "<html><body>$name</body></html>" > "$d/report.html"
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t19
HARNESS=claude
MODE=review
PROJECT_PATH=$wt
WORKTREE=$wt
TMUX_TARGET=kingpin:$name
ENVEOF
  printf '%s\n' "$status" > "$d/status"
  tmux new-window -d -t kingpin: -n "$name" cat
}

# (a) live worker waiting on needs-input: a refused done must not mask it
mk_t19 t19-live "needs-input: which flag should I use?"
if "$KP_BIN/kingpin-done" t19-live >"$T/t19-live.out" 2>&1; then
  fail "t19: done on a dirty live worker was not refused"
else
  pass "t19: done on a dirty live worker is refused"
fi
grep -q "uncommitted changes" "$T/t19-live.out" && pass "t19: the refusal reason is still printed" || fail "t19: refusal reason missing: $(cat "$T/t19-live.out")"
[ "$(tail -n 1 "$KINGPIN_HOME/tasks/t19-live/status")" = "needs-input: which flag should I use?" ] && pass "t19: live worker's last status is still needs-input" || fail "t19: live worker's status replaced: $(tail -n 1 "$KINGPIN_HOME/tasks/t19-live/status")"
! grep -q "^cleanup-refused:" "$KINGPIN_HOME/tasks/t19-live/status" && pass "t19: no cleanup-refused line recorded for a live worker" || fail "t19: cleanup-refused recorded for a live worker"
t19_list=$("$KP_BIN/kingpin" list)
echo "$t19_list" | grep "^t19-live " | grep -q "needs-input" && ! echo "$t19_list" | grep "^t19-live " | grep -q "cleanup-refused" && pass "t19: kingpin list still shows needs-input" || fail "t19: kingpin list masks needs-input: $t19_list"
tmux kill-window -t kingpin:t19-live 2>/dev/null || true

# A refusal must not stop the listener of a worker that is still live
mk_t19 t19-ready "ready: branch=b review=APPROVE report=none"
"$KP_BIN/kingpin-listen" t19-ready --background
t19r_pid=$(cat "$KINGPIN_HOME/tasks/t19-ready/listener.pid" 2>/dev/null || true)
[ -n "$t19r_pid" ] && kill -0 "$t19r_pid" 2>/dev/null && pass "t19: listener running for the ready task" || fail "t19: listener not running for the ready task"
"$KP_BIN/kingpin-done" t19-ready >/dev/null 2>&1 && fail "t19: done on a dirty ready task was not refused" || true
kill -0 "$t19r_pid" 2>/dev/null && pass "t19: refused done leaves a live worker's listener alone" || fail "t19: listener of a live worker was stopped"
[ "$(tail -n 1 "$KINGPIN_HOME/tasks/t19-ready/status")" = "ready: branch=b review=APPROVE report=none" ] && pass "t19: ready status kept" || fail "t19: ready status replaced"
rm -f "$T/wt-t19-ready/uncommitted.txt"
"$KP_BIN/kingpin-done" t19-ready --force >/dev/null 2>&1 || true
tmux kill-window -t kingpin:t19-ready 2>/dev/null || true

# (b) finished task: a refusal still reports cleanup-refused, and the listener is stopped
mk_t19 t19-merged "merged: pr=https://example.invalid/pull/1"
"$KP_BIN/kingpin-listen" t19-merged --background
t19m_pid=$(cat "$KINGPIN_HOME/tasks/t19-merged/listener.pid" 2>/dev/null || true)
[ -n "$t19m_pid" ] && kill -0 "$t19m_pid" 2>/dev/null && pass "t19: listener running for the merged task" || fail "t19: listener not running for the merged task"
t19_list=$("$KP_BIN/kingpin" list)
echo "$t19_list" | grep -q "listening: pid $t19m_pid" && pass "t19: list shows the merged task as listening before done" || fail "t19: list does not show the listener before done"
"$KP_BIN/kingpin-done" t19-merged >/dev/null 2>&1 && fail "t19: done on a dirty merged task was not refused" || true
tail -n 1 "$KINGPIN_HOME/tasks/t19-merged/status" | grep -q "^cleanup-refused: .*uncommitted changes" && pass "t19: refusal on a finished task still reports cleanup-refused" || fail "t19: cleanup-refused missing on a finished task: $(tail -n 1 "$KINGPIN_HOME/tasks/t19-merged/status")"
for _ in $(seq 1 40); do kill -0 "$t19m_pid" 2>/dev/null || break; sleep 0.05; done
kill -0 "$t19m_pid" 2>/dev/null && fail "t19: listener of the merged task still running after done" || pass "t19: done stopped the listener of the merged task"
[ ! -f "$KINGPIN_HOME/tasks/t19-merged/listener.pid" ] && pass "t19: listener.pid removed" || fail "t19: listener.pid left behind"
t19_list=$("$KP_BIN/kingpin" list)
! echo "$t19_list" | grep -q "listening" && pass "t19: kingpin list no longer shows listening" || fail "t19: kingpin list still shows listening"

# (b2) the listener's approved:/feedback: notes after merged: are not worker events: still a finished task
mk_t19 t19-approved "merged: pr=https://example.invalid/pull/2"
echo "approved: by user via lavish dossier" >> "$KINGPIN_HOME/tasks/t19-approved/status"
"$KP_BIN/kingpin-done" t19-approved >/dev/null 2>&1 && fail "t19: done on a dirty merged+approved task was not refused" || true
grep -q "^cleanup-refused: .*uncommitted changes" "$KINGPIN_HOME/tasks/t19-approved/status" && pass "t19: cleanup-refused recorded after a trailing approved: note" || fail "t19: cleanup-refused missing after approved: note: $(cat "$KINGPIN_HOME/tasks/t19-approved/status")"
tmux kill-window -t kingpin:t19-approved 2>/dev/null || true

# (c) ack on an archived task is a no-op with a note; an unknown task is still an error
"$KP_BIN/kingpin" done t19-merged --force >/dev/null 2>&1 || true
[ -d "$KINGPIN_HOME/archive/t19-merged" ] && [ ! -d "$KINGPIN_HOME/tasks/t19-merged" ] && pass "t19: done --force archived the task" || fail "t19: task not archived"
t19_ack_rc=0
t19_ack=$("$KP_BIN/kingpin" ack t19-merged 2>&1) || t19_ack_rc=$?
[ "$t19_ack_rc" -eq 0 ] && echo "$t19_ack" | grep -qi "archived" && pass "t19: ack on an archived task exits 0 with a note" || fail "t19: ack on an archived task (rc=$t19_ack_rc): $t19_ack"
t19_ack_rc=0
"$KP_BIN/kingpin" ack t19-no-such-task >/dev/null 2>&1 || t19_ack_rc=$?
[ "$t19_ack_rc" -eq 1 ] && pass "t19: ack on an unknown task still fails" || fail "t19: ack on an unknown task exited $t19_ack_rc"

tmux kill-window -t kingpin:t19-merged 2>/dev/null || true
rm -rf "$KINGPIN_HOME/archive/t19-"* "$KINGPIN_HOME/tasks/t19-"* "$T"/wt-t19-*
unset KINGPIN_LAVISH

# Test 20: kingpin peek prints the tail of a worker pane, read-only
echo "=== Test 20: kingpin peek ==="
t20_dir="$KINGPIN_HOME/tasks/t20-peek"
mkdir -p "$t20_dir"
tmux new-window -d -t kingpin: -n t20-peek bash -c 'for i in $(seq 1 40); do echo "line-$i"; echo; done; echo "   "; exec cat'
t20_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="t20-peek"{print $1}')
[ -n "$t20_wid" ] || fail "t20: fake pane window was not created"
cat > "$t20_dir/task.env" << EOF
TASK_ID=t20-peek
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t20-peek
TMUX_WINDOW_ID=$t20_wid
EOF
t20_ready=0
for _ in $(seq 1 50); do
  if tmux capture-pane -pJt "$t20_wid" -S -200 2>/dev/null | grep -qx "line-40"; then t20_ready=1; break; fi
  sleep 0.1
done
[ "$t20_ready" -eq 1 ] || fail "t20: fake pane never showed line-40"

# default: last 20 non-empty lines
t20_out=$("$KP_BIN/kingpin" peek t20-peek)
[ "$(echo "$t20_out" | wc -l)" -eq 20 ] && [ "$(echo "$t20_out" | head -n 1)" = "line-21" ] && [ "$(echo "$t20_out" | tail -n 1)" = "line-40" ] && pass "t20: peek prints the last 20 lines by default" || fail "t20: default peek output wrong: $t20_out"
if echo "$t20_out" | grep -qv '[^[:space:]]'; then fail "t20: peek output has a blank line"; else pass "t20: peek output has no blank lines"; fi

# --lines N
t20_out=$("$KP_BIN/kingpin" peek t20-peek --lines 5)
[ "$(echo "$t20_out" | wc -l)" -eq 5 ] && [ "$(echo "$t20_out" | tail -n 1)" = "line-40" ] && pass "t20: --lines 5 prints 5 lines" || fail "t20: --lines 5 output wrong: $t20_out"
t20_out=$("$KP_BIN/kingpin" peek --lines=3 t20-peek)
[ "$(echo "$t20_out" | wc -l)" -eq 3 ] && pass "t20: --lines=3 prints 3 lines" || fail "t20: --lines=3 output wrong: $t20_out"
for bad in 0 abc -2; do
  t20_rc=0
  "$KP_BIN/kingpin" peek t20-peek --lines "$bad" >/dev/null 2>&1 || t20_rc=$?
  [ "$t20_rc" -eq 2 ] && pass "t20: --lines $bad is rejected" || fail "t20: --lines $bad exited $t20_rc"
done

# no keys sent, no state changed: only list-panes and capture-pane reach tmux
mkdir -p "$T/t20-shim"
cat > "$T/t20-shim/tmux" << EOF
#!/usr/bin/env bash
echo "\$1" >> "$T/t20-tmux.log"
exec "$T/bin/tmux" "\$@"
EOF
chmod +x "$T/t20-shim/tmux"
: > "$T/t20-tmux.log"
t20_sum() { (cd "$t20_dir" && find . -type f | sort | xargs sha256sum; find . | sort); }
t20_before=$(t20_sum)
t20_pane_before=$(tmux capture-pane -pJt "$t20_wid" -S -200)
PATH="$T/t20-shim:$PATH" "$KP_BIN/kingpin" peek t20-peek >/dev/null
t20_after=$(t20_sum)
t20_pane_after=$(tmux capture-pane -pJt "$t20_wid" -S -200)
if [ -s "$T/t20-tmux.log" ] && ! grep -qv -e '^list-panes$' -e '^capture-pane$' "$T/t20-tmux.log"; then pass "t20: peek only runs list-panes and capture-pane"; else fail "t20: peek ran other tmux commands: $(sort -u "$T/t20-tmux.log" | tr '\n' ' ')"; fi
[ "$t20_before" = "$t20_after" ] && pass "t20: peek leaves the task folder unchanged" || fail "t20: task folder changed"
[ "$t20_pane_before" = "$t20_pane_after" ] && pass "t20: peek leaves the pane unchanged" || fail "t20: pane changed"

# window renamed: the stale TMUX_TARGET name no longer exists, the window ID still does
tmux rename-window -t "$t20_wid" t20-renamed
t20_out=$("$KP_BIN/kingpin" peek t20-peek --lines 1 2>&1) && [ "$t20_out" = "line-40" ] && pass "t20: peek reaches the pane after a window rename" || fail "t20: peek after rename failed: $t20_out"

# legacy task.env without TMUX_WINDOW_ID falls back to TMUX_TARGET
tmux rename-window -t "$t20_wid" t20-peek
sed -i '/^TMUX_WINDOW_ID=/d' "$t20_dir/task.env"
t20_out=$("$KP_BIN/kingpin" peek t20-peek --lines 1 2>&1) && [ "$t20_out" = "line-40" ] && pass "t20: legacy task.env falls back to TMUX_TARGET" || fail "t20: legacy peek failed: $t20_out"

# unknown task and missing window
t20_rc=0
t20_err=$("$KP_BIN/kingpin" peek t20-no-such-task 2>&1 >/dev/null) || t20_rc=$?
[ "$t20_rc" -eq 1 ] && echo "$t20_err" | grep -q "not found" && pass "t20: unknown task exits 1 with a clear message" || fail "t20: unknown task rc=$t20_rc: $t20_err"
[ -z "$t20_wid" ] || tmux kill-window -t "$t20_wid" 2>/dev/null || true
t20_rc=0
t20_err=$("$KP_BIN/kingpin" peek t20-peek 2>&1 >/dev/null) || t20_rc=$?
[ "$t20_rc" -eq 1 ] && echo "$t20_err" | grep -q "not alive" && pass "t20: missing window exits 1 with a clear message" || fail "t20: missing window rc=$t20_rc: $t20_err"

rm -rf "$t20_dir" "$T/t20-shim" "$T/t20-tmux.log"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL AUTOMATION TESTS PASSED"
else
  echo "AUTOMATION TESTS FAILED"
  exit 1
fi
