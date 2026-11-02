#!/usr/bin/env bash
# Verification test for Kingpin multi-harness support (claude, agy, opencode).
set -euo pipefail

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

KP_ROOT="/home/lauri/github/kingpin"
KP_BIN="$KP_ROOT/bin"

# Ensure kingpin tmux session exists and has only home window
tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home
for w in $(tmux list-windows -t kingpin -F '#{window_id}' 2>/dev/null | tail -n +2 || true); do
  tmux kill-window -t "$w" 2>/dev/null || true
done

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

# Fake agent starts interactive bash so tmux commands work
cat > "$T/fake-agent" << 'F'
#!/usr/bin/env bash
exec bash
F
chmod +x "$T/fake-agent"

export KINGPIN_CLAUDE=$T/fake-agent
export KINGPIN_AGY=$T/fake-agent
export KINGPIN_OPENCODE=$T/fake-agent

# Test 1: Claude spawn
echo "=== Test 1: Claude Spawn ==="
"$KP_BIN/kingpin-spawn" demo --issue 101 --id task-claude --harness claude >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-claude/task.env" ] && pass "task-claude task.env created" || fail "missing task.env"
grep -q "^HARNESS=claude$" "$KINGPIN_HOME/tasks/task-claude/task.env" && pass "task-claude recorded HARNESS=claude" || fail "wrong harness in task.env"
grep -q -- "--append-system-prompt-file" "$KINGPIN_HOME/tasks/task-claude/launch.sh" && pass "task-claude launch script has append-system-prompt-file" || fail "wrong launch script"

wt_claude=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-claude/task.env")
wt_claude_real=$(realpath "$wt_claude")
node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const wt = process.argv[2];
if (cfg.projects && cfg.projects[wt] && cfg.projects[wt].hasTrustDialogAccepted) process.exit(0);
process.exit(1);
' "$T/cfg/.claude.json" "$wt_claude_real" && pass "claude trust recorded for worktree" || fail "claude trust missing"

# Test 2: AGY spawn
echo "=== Test 2: AGY Spawn ==="
"$KP_BIN/kingpin-spawn" demo --issue 102 --id task-agy --harness agy >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-agy/task.env" ] && pass "task-agy task.env created" || fail "missing task.env"
grep -q "^HARNESS=agy$" "$KINGPIN_HOME/tasks/task-agy/task.env" && pass "task-agy recorded HARNESS=agy" || fail "wrong harness in task.env"
grep -q -- "--prompt-interactive" "$KINGPIN_HOME/tasks/task-agy/launch.sh" && pass "task-agy launch script has --prompt-interactive" || fail "wrong launch script"
grep -q -- "--dangerously-skip-permissions" "$KINGPIN_HOME/tasks/task-agy/launch.sh" && pass "task-agy launch script has --dangerously-skip-permissions" || fail "missing skip permissions"

wt_agy=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-agy/task.env")
wt_agy_real=$(realpath "$wt_agy")

# Verify AGY trust in settings.json
node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const wt = process.argv[2];
if (Array.isArray(cfg.trustedWorkspaces) && cfg.trustedWorkspaces.includes(wt)) process.exit(0);
process.exit(1);
' "$T/cfg-gemini/settings.json" "$wt_agy_real" && pass "agy trust recorded for worktree" || fail "agy trust missing"

# Verify AGY rules & hooks in worktree
[ -f "$wt_agy/.agents/rules/kingpin.md" ] && pass "agy rules/kingpin.md written in worktree" || fail "missing agy rules"
[ -f "$wt_agy/.agents/hooks.json" ] && pass "agy hooks.json written in worktree" || fail "missing agy hooks"
grep -q "KINGPIN_TASK_DIR/stopped" "$wt_agy/.agents/hooks.json" && pass "agy hook command writes to stopped file" || fail "wrong agy hook"
# Verify .agents excluded from git
git_excl=$(git -C "$wt_agy" rev-parse --git-path info/exclude)
case "$git_excl" in /*) ;; *) git_excl="$wt_agy/$git_excl" ;; esac
grep -q "^\.agents$" "$git_excl" && pass ".agents added to git info/exclude" || fail ".agents not excluded"
status_out=$(git -C "$wt_agy" status --porcelain)
[ -z "$status_out" ] && pass "git status in agy worktree is clean" || fail "git status dirty: $status_out"

# Test 3: OpenCode spawn
echo "=== Test 3: OpenCode Spawn ==="
"$KP_BIN/kingpin-spawn" demo --issue 103 --id task-opencode --harness opencode >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-opencode/task.env" ] && pass "task-opencode task.env created" || fail "missing task.env"
grep -q "^HARNESS=opencode$" "$KINGPIN_HOME/tasks/task-opencode/task.env" && pass "task-opencode recorded HARNESS=opencode" || fail "wrong harness in task.env"
grep -q -- "--standalone" "$KINGPIN_HOME/tasks/task-opencode/launch.sh" && pass "task-opencode launch script has --standalone" || fail "missing standalone"
grep -q -- "--auto" "$KINGPIN_HOME/tasks/task-opencode/launch.sh" && pass "task-opencode launch script has --auto" || fail "missing auto"

wt_oc=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-opencode/task.env")

# Verify OpenCode config & plugins in worktree
[ -f "$wt_oc/.opencode/config.json" ] && pass "opencode config.json written" || fail "missing config.json"
grep -q "preamble.md" "$wt_oc/.opencode/config.json" && pass "opencode config references preamble.md in instructions" || fail "missing instructions"
[ -f "$wt_oc/.opencode/plugins/kingpin-stop.js" ] && pass "opencode kingpin-stop.js plugin written" || fail "missing plugin"
[ -f "$wt_oc/.opencode/plugins/package.json" ] && pass "opencode plugin package.json written" || fail "missing plugin package.json"
# Verify .opencode excluded from git
git_excl=$(git -C "$wt_oc" rev-parse --git-path info/exclude)
case "$git_excl" in /*) ;; *) git_excl="$wt_oc/$git_excl" ;; esac
grep -q "^\.opencode$" "$git_excl" && pass ".opencode added to git info/exclude" || fail ".opencode not excluded"
status_out=$(git -C "$wt_oc" status --porcelain)
[ -z "$status_out" ] && pass "git status in opencode worktree is clean" || fail "git status dirty: $status_out"

# Test 4: Project-default harness configuration
echo "=== Test 4: Project Default Harness ==="
printf 'PROJECT_PATH=%q\nHARNESS=opencode\n' "$T/proj" > "$KINGPIN_HOME/projects/demo-oc.env"
"$KP_BIN/kingpin-spawn" demo-oc --issue 104 --id task-default-oc >/dev/null
grep -q "^HARNESS=opencode$" "$KINGPIN_HOME/tasks/task-default-oc/task.env" && pass "task-default-oc picked up HARNESS=opencode from project env" || fail "failed project default harness"

# Test 5: Qualified quiet state in kingpin-wait
echo "=== Test 5: Qualified Quiet State ==="
echo "100" > "$KINGPIN_HOME/tasks/task-agy/stopped"
echo "50" > "$KINGPIN_HOME/tasks/task-agy/seen_stopped"
# Mock pane capture for task-agy: simulate busy with "esc to cancel"
tmux send-keys -t kingpin:task-agy 'echo "esc to cancel"' Enter
sleep 0.5
res=$("$KP_BIN/kingpin-wait" --once 2>&1 || true)
if echo "$res" | grep -q "task-agy quiet"; then
  fail "task-agy reported quiet while esc to cancel was present"
else
  pass "task-agy correctly held quiet while esc to cancel was present"
fi

# Clear tmux pane and test quiet qualification
tmux send-keys -t kingpin:task-agy 'clear' Enter
tmux clear-history -t kingpin:task-agy
sleep 0.5
res=$("$KP_BIN/kingpin-wait" --once 2>&1 || true)
echo "$res" | grep -q "task-agy quiet" && pass "task-agy reported quiet after pane cleared" || fail "task-agy did not report quiet"

# Test 6: Board rendering with all 3 harnesses
echo "=== Test 6: Board Harness Badges ==="
"$KP_BIN/kingpin-board" --out "$T/board.html" >/dev/null
grep -q '<span class="badge badge-sm badge-outline">claude</span>' "$T/board.html" && pass "board renders claude badge" || fail "claude badge missing"
grep -q '<span class="badge badge-sm badge-outline">agy</span>' "$T/board.html" && pass "board renders agy badge" || fail "agy badge missing"
grep -q '<span class="badge badge-sm badge-outline">opencode</span>' "$T/board.html" && pass "board renders opencode badge" || fail "opencode badge missing"

for w in $(tmux list-windows -t kingpin -F '#{window_id}' 2>/dev/null | tail -n +2 || true); do
  tmux kill-window -t "$w" 2>/dev/null || true
done
tmux kill-session -t kingpin 2>/dev/null || true
rm -rf "$T"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL MULTI-HARNESS TESTS PASSED"
else
  echo "MULTI-HARNESS TESTS FAILED"
  exit 1
fi
