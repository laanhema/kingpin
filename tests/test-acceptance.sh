#!/usr/bin/env bash
# Full acceptance test: 3 parallel workers, separate worktrees, serial landing, clean teardown.
set -euo pipefail

unset TMUX

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
  git -C "$KP_ROOT" checkout bin/kingpin-send >/dev/null 2>&1 || true
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
while true; do
  sleep 0.5
  # Check if prompt was updated or if a landing command was received
  if [ -f "$task_dir/landed_signal" ]; then
    break
  fi
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

# 4. Check board rendering with 3 ready tasks
"$KP_BIN/kingpin-board" --out "$T/board.html" >/dev/null
[ -f "$T/board.html" ] && pass "board rendered 3 tasks" || fail "board missing"
grep -q "demo-alpha" "$T/board.html" && grep -q "demo-beta" "$T/board.html" && grep -q "demo-gamma" "$T/board.html" && pass "all 3 tasks present on board" || fail "tasks missing from board"

# 5. Land demo-alpha, demo-beta, demo-gamma
# Override kingpin-send to write landed_signal for fake-claude
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

# 6. Simulate demo-alpha completing merge, then kingpin-done demo-alpha
sleep 2
grep -q "^merged:" "$KINGPIN_HOME/tasks/demo-alpha/status" && pass "demo-alpha merged" || fail "alpha not merged"

"$KP_BIN/kingpin-done" demo-alpha >/dev/null
pass "demo-alpha cleaned up and queue advanced"

# Verify demo-beta received landing signal and merges
sleep 2
grep -q "^merged:" "$KINGPIN_HOME/tasks/demo-beta/status" && pass "demo-beta merged" || fail "beta not merged"

"$KP_BIN/kingpin-done" demo-beta >/dev/null
pass "demo-beta cleaned up and queue advanced"

# Verify demo-gamma received landing signal and merges
sleep 2
grep -q "^merged:" "$KINGPIN_HOME/tasks/demo-gamma/status" && pass "demo-gamma merged" || fail "gamma not merged"

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
git -C "$KP_ROOT" checkout bin/kingpin-send >/dev/null 2>&1

if [ "$FAILED" -eq 0 ]; then
  echo "ALL ACCEPTANCE TESTS PASSED"
else
  echo "ACCEPTANCE TESTS FAILED"
  exit 1
fi
