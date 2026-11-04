#!/usr/bin/env bash
# Full acceptance test: 3 parallel workers, separate worktrees, serial landing, clean teardown.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "acceptance"

# The project is the scratch repo kp_test_setup made; no setup command for these spawns.
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/proj" "" > "$KINGPIN_HOME/projects/demo.env"

# 1. Fake worker script that simulates /issue-flow and /issue-flow-done
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

tmux display-message -p '#{socket_path}' | grep -qF "$TMUX_TMPDIR/" && pass "test operates on the private fleet socket" || fail "test socket not isolated"

# 2. Spawn 3 parallel tasks
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

# 3. Check kingpin list with 3 ready tasks
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "demo-alpha" && echo "$list_out" | grep -q "demo-beta" && echo "$list_out" | grep -q "demo-gamma" && pass "all 3 tasks present in kingpin list" || fail "tasks missing from kingpin list"

# 4. Land demo-alpha, demo-beta, demo-gamma
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

# 5. Let demo-alpha finish its landing, then kingpin-done demo-alpha.
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

# 6. Final assertions on repository and treehouse pool
git -C "$T/proj" fetch origin main >/dev/null 2>&1
git -C "$T/proj" checkout -q main
git -C "$T/proj" pull -q origin main

[ -f "$T/proj/feature-demo-alpha.txt" ] && pass "feature-demo-alpha merged to main" || fail "alpha feature missing on main"
[ -f "$T/proj/feature-demo-beta.txt" ] && pass "feature-demo-beta merged to main" || fail "beta feature missing on main"
[ -f "$T/proj/feature-demo-gamma.txt" ] && pass "feature-demo-gamma merged to main" || fail "gamma feature missing on main"

# Assert all treehouse slots were returned. A `treehouse status` that fails must not read
# as a clean pool: `grep -c leased` prints 0 and exits 0 on empty input, which is how this
# assertion stayed green while slots were still leased (issue #81).
leased_count() { # <repo>: print the leased slot count; non-zero when status cannot be read
  local out
  out=$(cd "$1" && treehouse status 2>&1) || return 1
  grep -c leased <<< "$out" || true
}

if leased=$(leased_count "$T/proj"); then
  [ "$leased" -eq 0 ] && pass "all treehouse leases returned clean" || fail "lingering leases: $leased"
else
  fail "treehouse status failed, so the pool state is unknown"
fi

# The check above is only worth its line if a broken treehouse fails it: prove the
# negative with a stub that exits 1.
mkdir -p "$T/broken-treehouse"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/broken-treehouse/treehouse"
chmod +x "$T/broken-treehouse/treehouse"
if PATH="$T/broken-treehouse:$PATH" leased_count "$T/proj" >/dev/null; then
  fail "a failing 'treehouse status' was read as a clean pool"
else
  pass "a failing 'treehouse status' fails the lease check"
fi

# The expression this replaced was `treehouse status 2>/dev/null | grep -c leased || true`,
# which read that same stub as zero leases. Show it, so the strict form cannot quietly turn
# back into the old one without a red suite.
old_leased=$(cd "$T/proj" && PATH="$T/broken-treehouse:$PATH" bash -c 'treehouse status 2>/dev/null | grep -c leased || true')
[ "$old_leased" = "0" ] && pass "the old lease expression read the broken stub as a clean pool" || fail "the old lease expression no longer reproduces the gap (got '$old_leased')"

kp_test_finish ACCEPTANCE
