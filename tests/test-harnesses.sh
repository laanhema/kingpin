#!/usr/bin/env bash
# Verification test for Kingpin multi-harness support (claude, agy, opencode).
set -euo pipefail

unset TMUX CLAUDECODE OPENCODE KINGPIN_HARNESS
export KINGPIN_SKIP_GUARD=1
# CI runners have no global git identity
export GIT_AUTHOR_NAME=kingpin-test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=kingpin-test GIT_COMMITTER_EMAIL=test@example.com

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

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"

# Set up isolated private tmux server on a temporary socket
export TMUX_TMPDIR="$T/tmux-tmp"
mkdir -p "$TMUX_TMPDIR" "$T/bin"
TEST_SOCKET="kingpin-test-harnesses-$$"
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

# Ensure kingpin tmux session exists and has only home window
tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home
for w in $(tmux list-windows -t kingpin -F '#{window_id}' 2>/dev/null | tail -n +2 || true); do
  tmux kill-window -t "$w" 2>/dev/null || true
done
tmux display-message -p '#{socket_path}' | grep -q "$TEST_SOCKET" && pass "test operates on private tmux socket" || fail "test socket not isolated"

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
grep -q "background code worker" "$KINGPIN_HOME/tasks/task-claude/preamble.md" && pass "claude preamble instructs background worker role" || fail "missing worker role in claude preamble"
! grep -q "You are the underboss" "$KINGPIN_HOME/tasks/task-claude/preamble.md" && pass "claude preamble carries no orchestrator persona" || fail "orchestrator persona in claude preamble"
! grep -q "{{WORKTREE}}" "$KINGPIN_HOME/tasks/task-claude/preamble.md" && pass "claude preamble substituted WORKTREE" || fail "unsubstituted WORKTREE in claude preamble"

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
grep -q "background code worker" "$wt_agy/.agents/rules/kingpin.md" && pass "agy rules instruct background worker role" || fail "missing worker role in agy rules"
grep -qx "trigger: always_on" "$wt_agy/.agents/rules/kingpin.md" && pass "agy rules carry the trigger frontmatter agy needs to load them" || fail "agy rules lack trigger: always_on"
! grep -q "You are the underboss" "$wt_agy/.agents/rules/kingpin.md" && pass "agy rules carry no orchestrator persona" || fail "orchestrator persona in agy rules"
! grep -q "{{WORKTREE}}" "$wt_agy/.agents/rules/kingpin.md" && pass "agy rules substituted WORKTREE" || fail "unsubstituted WORKTREE in agy rules"
[ -f "$wt_agy/.agents/hooks.json" ] && pass "agy hooks.json written in worktree" || fail "missing agy hooks"
grep -q "kingpin-stop" "$wt_agy/.agents/hooks.json" && pass "agy hook command runs the shared stop hook" || fail "wrong agy hook"
# Verify the specific agy files are excluded through the task's own exclude file, not
# the shared .git/info/exclude (issue #77)
git_excl=$(git -C "$wt_agy" config --get --worktree core.excludesFile 2>/dev/null || true)
[ "$git_excl" = "$KINGPIN_HOME/tasks/task-agy/exclude" ] && pass "agy worktree reads its task's exclude file" || fail "agy worktree reads '${git_excl:-nothing}' as core.excludesFile"
grep -qx '\.agents/rules/kingpin\.md' "${git_excl:-/nonexistent}" && pass "rules/kingpin.md excluded through the task's exclude file" || fail "rules/kingpin.md not excluded"
grep -qx '\.agents/hooks\.json' "${git_excl:-/nonexistent}" && pass "hooks.json excluded through the task's exclude file" || fail "hooks.json not excluded"
status_out=$(git -C "$wt_agy" status --porcelain)
[ -z "$status_out" ] && pass "git status in agy worktree is clean" || fail "git status dirty: $status_out"

# Verify new files in .agents/ show up in git status
touch "$wt_agy/.agents/PRD.md"
status_out=$(git -C "$wt_agy" status --porcelain -u)
echo "$status_out" | grep -q "\.agents/PRD\.md" && pass "new .agents/PRD.md shows in git status" || fail "new .agents file hidden from git status"
rm -f "$wt_agy/.agents/PRD.md"

# Test 3: OpenCode spawn
echo "=== Test 3: OpenCode Spawn ==="
"$KP_BIN/kingpin-spawn" demo --issue 103 --id task-opencode --harness opencode >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-opencode/task.env" ] && pass "task-opencode task.env created" || fail "missing task.env"
grep -q "^HARNESS=opencode$" "$KINGPIN_HOME/tasks/task-opencode/task.env" && pass "task-opencode recorded HARNESS=opencode" || fail "wrong harness in task.env"
grep -q -- "--standalone" "$KINGPIN_HOME/tasks/task-opencode/launch.sh" && pass "task-opencode launch script has --standalone" || fail "missing standalone"
grep -q -- "--auto" "$KINGPIN_HOME/tasks/task-opencode/launch.sh" && pass "task-opencode launch script has --auto" || fail "missing auto"

wt_oc=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-opencode/task.env")

# Verify OpenCode config & plugins in worktree
[ -f "$wt_oc/.opencode/opencode.json" ] && pass "opencode opencode.json written" || fail "missing opencode.json"
grep -q "preamble.md" "$wt_oc/.opencode/opencode.json" && pass "opencode config references preamble.md in instructions" || fail "missing instructions"
[ ! -e "$wt_oc/.opencode/config.json" ] && pass "opencode does not get the config.json it ignores" || fail "spawn wrote .opencode/config.json, which OpenCode never reads"
grep -q "background code worker" "$KINGPIN_HOME/tasks/task-opencode/preamble.md" && pass "opencode preamble instructs background worker role" || fail "missing worker role in opencode preamble"
! grep -q "You are the underboss" "$KINGPIN_HOME/tasks/task-opencode/preamble.md" && pass "opencode preamble carries no orchestrator persona" || fail "orchestrator persona in opencode preamble"
! grep -q "{{WORKTREE}}" "$KINGPIN_HOME/tasks/task-opencode/preamble.md" && pass "opencode preamble substituted WORKTREE" || fail "unsubstituted WORKTREE in opencode preamble"
[ -f "$wt_oc/.opencode/plugins/kingpin-stop.js" ] && pass "opencode kingpin-stop.js plugin written" || fail "missing plugin"
[ -f "$wt_oc/.opencode/plugins/package.json" ] && pass "opencode plugin package.json written" || fail "missing plugin package.json"
# Verify the opencode files are excluded through the task's own exclude file, not the
# shared .git/info/exclude (issue #77)
git_excl=$(git -C "$wt_oc" config --get --worktree core.excludesFile 2>/dev/null || true)
[ "$git_excl" = "$KINGPIN_HOME/tasks/task-opencode/exclude" ] && pass "opencode worktree reads its task's exclude file" || fail "opencode worktree reads '${git_excl:-nothing}' as core.excludesFile"
grep -qx '\.opencode/opencode\.json' "${git_excl:-/nonexistent}" && pass "opencode.json excluded through the task's exclude file" || fail "opencode.json not excluded"
grep -qx '\.opencode/plugins/package\.json' "${git_excl:-/nonexistent}" && pass "plugin package.json excluded through the task's exclude file" || fail "plugin package.json not excluded"
grep -qx '\.opencode/plugins/kingpin-stop\.js' "${git_excl:-/nonexistent}" && pass "kingpin-stop.js excluded through the task's exclude file" || fail "plugin kingpin-stop.js not excluded"
status_out=$(git -C "$wt_oc" status --porcelain)
[ -z "$status_out" ] && pass "git status in opencode worktree is clean" || fail "git status dirty: $status_out"

# Verify new files in .opencode/ show up in git status
touch "$wt_oc/.opencode/notes.txt"
status_out=$(git -C "$wt_oc" status --porcelain -u)
echo "$status_out" | grep -q "\.opencode/notes\.txt" && pass "new .opencode/notes.txt shows in git status" || fail "new .opencode file hidden from git status"
rm -f "$wt_oc/.opencode/notes.txt"

# Test 4: Project-default harness configuration
echo "=== Test 4: Project Default Harness ==="
printf 'PROJECT_PATH=%q\nHARNESS=opencode\n' "$T/proj" > "$KINGPIN_HOME/projects/demo-oc.env"
"$KP_BIN/kingpin-spawn" demo-oc --issue 104 --id task-default-oc >/dev/null
grep -q "^HARNESS=opencode$" "$KINGPIN_HOME/tasks/task-default-oc/task.env" && pass "task-default-oc picked up HARNESS=opencode from project env" || fail "failed project default harness"

# Test 4b: Default harness follows the orchestrator lock holder
echo "=== Test 4b: Lock Holder Harness Precedence ==="
# The test script itself is the live lock holder.
harness_of() { sed -n 's/^HARNESS=//p' "$KINGPIN_HOME/tasks/$1/task.env"; }
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin-lock" acquire --harness agy >/dev/null

"$KP_BIN/kingpin-spawn" demo --issue 111 --id task-lock-default >/dev/null
[ "$(harness_of task-lock-default)" = "agy" ] && pass "lock holder harness is the default" || fail "lock default: $(harness_of task-lock-default)"

"$KP_BIN/kingpin-spawn" demo --issue 112 --id task-lock-flag --harness opencode >/dev/null
[ "$(harness_of task-lock-flag)" = "opencode" ] && pass "--harness beats the lock holder" || fail "flag vs lock: $(harness_of task-lock-flag)"

printf 'PROJECT_PATH=%q\nHARNESS=claude\n' "$T/proj" > "$KINGPIN_HOME/projects/demo-claude.env"
"$KP_BIN/kingpin-spawn" demo-claude --issue 113 --id task-lock-project >/dev/null
[ "$(harness_of task-lock-project)" = "claude" ] && pass "explicit project HARNESS beats the lock holder" || fail "project vs lock: $(harness_of task-lock-project)"

printf 'DEFAULT_HARNESS=opencode\n' > "$KINGPIN_HOME/config.env"
"$KP_BIN/kingpin-spawn" demo --issue 114 --id task-lock-global >/dev/null
[ "$(harness_of task-lock-global)" = "agy" ] && pass "lock holder beats DEFAULT_HARNESS" || fail "lock vs global: $(harness_of task-lock-global)"

KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin-lock" release >/dev/null
"$KP_BIN/kingpin-spawn" demo --issue 115 --id task-global-default >/dev/null
[ "$(harness_of task-global-default)" = "opencode" ] && pass "DEFAULT_HARNESS applies once the lock is released" || fail "global default: $(harness_of task-global-default)"

rm -f "$KINGPIN_HOME/config.env"
"$KP_BIN/kingpin-spawn" demo --issue 116 --id task-fallback-claude >/dev/null
[ "$(harness_of task-fallback-claude)" = "claude" ] && pass "falls back to claude with no lock and no config" || fail "fallback: $(harness_of task-fallback-claude)"

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

# Test 6: kingpin list shows all 3 harnesses
echo "=== Test 6: List Harness Column ==="
list_out=$("$KP_BIN/kingpin" list)
for h in claude agy opencode; do
  echo "$list_out" | grep -Eq "[[:space:]]${h}[[:space:]]" && pass "list shows $h harness" || fail "$h harness missing from list"
done

# Test 7: the orchestrator contract is not in a file a worker loads (issue #96)
echo "=== Test 7: Orchestrator Contract & Role Separation ==="
! grep -q "underboss" "$KP_ROOT/AGENTS.md" && pass "AGENTS.md carries no orchestrator persona" || fail "orchestrator persona is back in AGENTS.md"
! grep -q "The user is the boss" "$KP_ROOT/AGENTS.md" && pass "AGENTS.md carries no boss address" || fail "boss address is back in AGENTS.md"
[ -f "$KP_ROOT/orchestrator/contract.md" ] && pass "orchestrator/contract.md holds the contract" || fail "missing orchestrator/contract.md"
grep -q "You are the underboss" "$KP_ROOT/orchestrator/contract.md" && pass "the contract still has its persona" || fail "contract lost the persona"
grep -qi "background code worker" "$KP_ROOT/worker/preamble.md" && pass "worker preamble declares background code worker role" || fail "missing background code worker in preamble"
grep -q "kingpin spawn" "$KP_ROOT/worker/preamble.md" && pass "worker preamble forbids orchestration commands" || fail "preamble does not forbid orchestration commands"
grep -q "you DO edit code" "$KP_ROOT/worker/preamble.md" && pass "worker preamble says the worker may edit code" || fail "preamble does not say a worker may edit code"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL MULTI-HARNESS TESTS PASSED"
else
  echo "MULTI-HARNESS TESTS FAILED"
  exit 1
fi
