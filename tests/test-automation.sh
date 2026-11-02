#!/usr/bin/env bash
# Verification test for Kingpin automation (kingpin CLI, init, watch, and run).
set -euo pipefail

unset TMUX

T=$(mktemp -d)
export KINGPIN_HOME=$T/kp
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

# Override kingpin-send to simulate worker response
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
git -C "$KP_ROOT" checkout bin/kingpin-send >/dev/null 2>&1

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
[ -f "$KINGPIN_HOME/tasks/task-auto-1/done_cleaned" ] && pass "kingpin-watch completed auto-cleanup" || fail "auto-cleanup not triggered"

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
[ -f "$t10_dir1/done_cleaned" ] && pass "kingpin-watch retried the refused cleanup and wrote done_cleaned" || fail "refused cleanup was not retried by kingpin-watch"
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
cat > "$t10_dir4/task.env" << EOF2
TASK_ID=t10-force
PROJECT=demo-t10
PROJECT_PATH=$t10_wt1
WORKTREE=$t10_wt2
TMUX_TARGET=kingpin:t10-force
EOF2
echo "merged: pr=x" > "$t10_dir4/status"
echo "dirty" > "$t10_wt2/uncommitted.txt"
"$KP_BIN/kingpin-done" t10-force >/dev/null 2>&1 && fail "dirty cleanup was not refused" || pass "dirty cleanup refused without --force"
[ ! -f "$t10_dir4/done_cleaned" ] && pass "no done_cleaned after refusal without --force" || fail "done_cleaned written despite refusal"
"$KP_BIN/kingpin" done t10-force --force >/dev/null
[ -f "$t10_dir4/done_cleaned" ] && pass "kingpin-done --force created done_cleaned" || fail "done_cleaned missing after force cleanup"
rm -rf "$t10_dir4"

tmux kill-window -t kingpin:t10-dirty 2>/dev/null || true
tmux kill-window -t kingpin:t10-queued 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t10.landing" "$KINGPIN_HOME/projects/demo-t10.landing_queue"
rm -rf "$t10_dir1" "$t10_dir2" "$t10_wt1" "$t10_wt2" "$t10_remote"

for w in $(tmux list-windows -t kingpin -F '#{window_id}' 2>/dev/null | tail -n +2 || true); do
  tmux kill-window -t "$w" 2>/dev/null || true
done
tmux kill-session -t kingpin 2>/dev/null || true
rm -rf "$T"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL AUTOMATION TESTS PASSED"
else
  echo "AUTOMATION TESTS FAILED"
  exit 1
fi
