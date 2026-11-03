#!/usr/bin/env bash
# Full acceptance test: 3 parallel workers, separate worktrees, serial landing, clean teardown.
set -euo pipefail

unset TMUX
export KINGPIN_SKIP_GUARD=1
# CI runners have no global git identity
export GIT_AUTHOR_NAME=kingpin-test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=kingpin-test GIT_COMMITTER_EMAIL=test@example.com

T=$(mktemp -d)
export KINGPIN_HOME=$T/kp
export TREEHOUSE_ROOT=$T/pool
export CLAUDE_CONFIG_DIR=$T/cfg

mkdir -p "$T/cfg" "$KINGPIN_HOME/projects" "$KINGPIN_HOME/tasks"
echo '{"projects":{}}' > "$T/cfg/.claude.json"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"

# Set up isolated private tmux server on a temporary socket
export TMUX_TMPDIR="$T/tmux-tmp"
mkdir -p "$TMUX_TMPDIR" "$T/bin"
TEST_SOCKET="kingpin-test-acceptance-$$"
REAL_TMUX=$(command -v tmux)
cat > "$T/bin/tmux" << EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH"

cleanup() {
  [ -f "$T/kingpin-send.orig" ] && cp -p "$T/kingpin-send.orig" "$KP_BIN/kingpin-send" || true
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

printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/proj" "" > "$KINGPIN_HOME/projects/demo.env"

# 2. Fake worker script that simulates /issue-flow and /issue-flow-done
cat > "$T/fake-claude" <<'F'
#!/usr/bin/env bash
set -eu
task_dir="$KINGPIN_TASK_DIR"
task_id=$(basename "$task_dir")

# Read initial prompt
prompt=$(cat "$task_dir/prompt.txt")

# Phase 1: Simulate planning & implementation
echo "feature work from $task_id" > "feature-$task_id.txt"
git add "feature-$task_id.txt"
git commit -qm "feat: $task_id changes"
echo "ready: branch=$(git branch --show-current) review=APPROVE report=none" >> "$task_dir/status"

# Wait for land command via kingpin-send
while [ ! -f "$task_dir/landed_signal" ]; do
  sleep 0.1
done
# Then wait for the test's go-ahead before merging, so the test's queue
# assertions cannot race this worker's merge (a finished holder frees the lane).
while [ ! -f "$task_dir/merge_go" ]; do
  sleep 0.1
done

# Phase 2: Simulate /issue-flow-done (rebase onto origin/main, push to origin, fast-forward origin main)
git fetch origin main >/dev/null 2>&1
git rebase origin/main >/dev/null 2>&1
git push origin HEAD:main >/dev/null 2>&1
git fetch origin main >/dev/null 2>&1
echo "merged: pr=https://github.com/laanhema/demo/pull/1" >> "$task_dir/status"
F
chmod +x "$T/fake-claude"
export KINGPIN_CLAUDE=$T/fake-claude

tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home
tmux display-message -p '#{socket_path}' | grep -q "$TEST_SOCKET" && pass "test operates on private tmux socket" || fail "test socket not isolated"

# 3. Spawn 3 parallel tasks
echo "Spawning 3 parallel tasks..."
"$KP_BIN/kingpin-spawn" demo --issue 10 --id demo-alpha >/dev/null
"$KP_BIN/kingpin-spawn" demo --issue 20 --id demo-beta >/dev/null
"$KP_BIN/kingpin-spawn" demo --issue 30 --id demo-gamma >/dev/null
pass "3 tasks spawned concurrently"

sleep 3

# Verify all 3 wrote ready status
for id in demo-alpha demo-beta demo-gamma; do
  grep -q "^ready:" "$KINGPIN_HOME/tasks/$id/status" && pass "$id reported ready" || fail "$id not ready"
done

# 4. Check kingpin list with 3 ready tasks
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "demo-alpha" && echo "$list_out" | grep -q "demo-beta" && echo "$list_out" | grep -q "demo-gamma" && pass "all 3 tasks present in kingpin list" || fail "tasks missing from kingpin list"

# 5. Land demo-alpha, demo-beta, demo-gamma
# Override kingpin-send to write landed_signal for fake-claude (backup keeps uncommitted edits of the real script)
cp -p "$KP_BIN/kingpin-send" "$T/kingpin-send.orig"
cat > "$KP_BIN/kingpin-send" <<'S'
#!/usr/bin/env bash
id=$1
cmd=$2
task_dir="${KINGPIN_HOME:-$HOME/.kingpin}/tasks/$id"
touch "$task_dir/landed_signal"
echo "OK: sent $cmd to $id"
S
chmod +x "$KP_BIN/kingpin-send"

"$KP_BIN/kingpin-land" demo-alpha >/dev/null
pass "demo-alpha landing initiated"

# Immediately attempt landing beta and gamma (should be queued)
"$KP_BIN/kingpin-land" demo-beta >/dev/null
"$KP_BIN/kingpin-land" demo-gamma >/dev/null
grep -qx "demo-beta" "$KINGPIN_HOME/projects/demo.landing_queue" && pass "demo-beta queued" || fail "beta not queued"
grep -qx "demo-gamma" "$KINGPIN_HOME/projects/demo.landing_queue" && pass "demo-gamma queued" || fail "gamma not queued"

# 6. Let demo-alpha finish its landing, then kingpin-done demo-alpha.
# Each worker merges only after the test says so, so the queue assertions above
# and the handoff below are deterministic rather than racing the worker.
merged_in() { # <task-id>: wait up to ~10 s for the worker's merged: line
  local id=$1 n=0
  while [ "$n" -lt 100 ]; do
    grep -q "^merged:" "$KINGPIN_HOME/tasks/$id/status" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

touch "$KINGPIN_HOME/tasks/demo-alpha/merge_go"
merged_in demo-alpha && pass "demo-alpha merged" || fail "alpha not merged"

"$KP_BIN/kingpin-done" demo-alpha >/dev/null
pass "demo-alpha cleaned up and queue advanced"

# Verify demo-beta received landing signal and merges
touch "$KINGPIN_HOME/tasks/demo-beta/merge_go"
merged_in demo-beta && pass "demo-beta merged" || fail "beta not merged"

"$KP_BIN/kingpin-done" demo-beta >/dev/null
pass "demo-beta cleaned up and queue advanced"

# Verify demo-gamma received landing signal and merges
touch "$KINGPIN_HOME/tasks/demo-gamma/merge_go"
merged_in demo-gamma && pass "demo-gamma merged" || fail "gamma not merged"

"$KP_BIN/kingpin-done" demo-gamma >/dev/null
pass "demo-gamma cleaned up"

# 7. Final assertions on repository and treehouse pool
git -C "$T/proj" fetch origin main >/dev/null 2>&1
git -C "$T/proj" checkout -q main
git -C "$T/proj" pull -q origin main

[ -f "$T/proj/feature-demo-alpha.txt" ] && pass "feature-demo-alpha merged to main" || fail "alpha feature missing on main"
[ -f "$T/proj/feature-demo-beta.txt" ] && pass "feature-demo-beta merged to main" || fail "beta feature missing on main"
[ -f "$T/proj/feature-demo-gamma.txt" ] && pass "feature-demo-gamma merged to main" || fail "gamma feature missing on main"

# Assert all treehouse slots were returned
leased_count=$( (cd "$T/proj" && treehouse status 2>/dev/null | grep -c leased || true) )
[ "$leased_count" -eq 0 ] && pass "all treehouse leases returned clean" || fail "lingering leases: $leased_count"

# Restore original kingpin-send
cp -p "$T/kingpin-send.orig" "$KP_BIN/kingpin-send"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL ACCEPTANCE TESTS PASSED"
else
  echo "ACCEPTANCE TESTS FAILED"
  exit 1
fi
