#!/usr/bin/env bash
# Verification test for the orchestrator-only tool guard: the deny rules for Edit,
# Write, NotebookEdit and Agent live in an untracked file of the main checkout and
# never reach a leased worker worktree.
set -euo pipefail

unset TMUX CLAUDECODE OPENCODE KINGPIN_HARNESS

T=$(mktemp -d)
export KINGPIN_HOME=$T/kp
export KINGPIN_SKIP_GUARD=1
export TREEHOUSE_ROOT=$T/pool
export CLAUDE_CONFIG_DIR=$T/cfg

mkdir -p "$T/cfg" "$KINGPIN_HOME/projects" "$KINGPIN_HOME/tasks"
echo '{"projects":{}}' > "$T/cfg/.claude.json"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"

# Isolated private tmux server on a temporary socket
export TMUX_TMPDIR="$T/tmux-tmp"
mkdir -p "$TMUX_TMPDIR" "$T/bin"
TEST_SOCKET="kingpin-test-worker-settings-$$"
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

TOOLS='["Edit","Write","NotebookEdit","Agent"]'

# Prints the tools from $TOOLS that the given settings files deny, one per line.
denied_in() {
  node -e '
    const fs = require("fs");
    const tools = JSON.parse(process.argv[1]);
    const denied = new Set();
    for (const f of process.argv.slice(2)) {
      if (!fs.existsSync(f)) continue;
      const cfg = JSON.parse(fs.readFileSync(f, "utf8"));
      for (const t of (cfg.permissions && cfg.permissions.deny) || []) denied.add(t);
    }
    for (const t of tools) if (denied.has(t)) console.log(t);
  ' "$TOOLS" "$@"
}

# 1. The tracked tree carries no deny rules
echo "=== Test 1: tracked tree ==="
tracked_settings=$(git -C "$KP_ROOT" ls-files '.claude/settings*.json')
[ -z "$tracked_settings" ] && pass "no tracked .claude/settings*.json" || fail "tracked settings: $tracked_settings"
git -C "$KP_ROOT" check-ignore -q .claude/settings.local.json && pass ".claude/settings.local.json is git-ignored" || fail "settings.local.json not ignored"

# 2. Guard install / check / idempotence / merge in an isolated "Kingpin checkout"
echo "=== Test 2: guard install ==="
git init -q -b main "$T/kp-checkout"
git -C "$T/kp-checkout" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
if "$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" >/dev/null 2>&1; then
  fail "check passed before install"
else
  pass "check fails before install"
fi
mkdir -p "$T/kp-checkout/.claude"
echo '{"permissions":{"deny":["Bash(rm -rf *)"],"allow":["Read"]},"model":"x"}' > "$T/kp-checkout/.claude/settings.local.json"
"$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" >/dev/null && pass "install exits 0" || fail "install failed"
"$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" >/dev/null && pass "install is idempotent" || fail "second install failed"
"$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" >/dev/null && pass "check passes after install" || fail "check failed after install"
got=$(denied_in "$T/kp-checkout/.claude/settings.local.json" | sort | tr '\n' ' ')
[ "$got" = "Agent Edit NotebookEdit Write " ] && pass "orchestrator checkout denies Edit, Write, NotebookEdit, Agent" || fail "denied: $got"
node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const d = c.permissions.deny;
  process.exit(d.length === 5 && d.includes("Bash(rm -rf *)") && c.model === "x" && c.permissions.allow[0] === "Read" ? 0 : 1);
' "$T/kp-checkout/.claude/settings.local.json" && pass "install merged into existing settings without duplicates" || fail "merge or dedupe wrong"
git -C "$T/kp-checkout" status --porcelain | grep -q . && fail "guard file dirties the checkout" || pass "guard file leaves the checkout clean"
echo '{bad' > "$T/kp-checkout/.claude/settings.local.json"
"$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" >/dev/null 2>&1 && fail "install overwrote malformed JSON" || pass "install refuses malformed JSON"
for bad in '[]' 'null' '{"permissions":"x"}' '"str"' '{"permissions":[]}'; do
  echo "$bad" > "$T/kp-checkout/.claude/settings.local.json"
  err=$("$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" 2>&1 >/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && echo "$err" | grep -q "^kingpin-guard:" && ! echo "$err" | grep -q "at \|node:"; then
    pass "install rejects wrong-shape JSON $bad"
  else
    fail "install on $bad: rc=$rc err=$err"
  fi
  [ "$(cat "$T/kp-checkout/.claude/settings.local.json")" = "$bad" ] && pass "wrong-shape file left untouched ($bad)" || fail "wrong-shape file rewritten ($bad)"
  "$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" >/dev/null 2>&1 && fail "check passed on $bad" || pass "check fails cleanly on $bad"
done
"$KP_BIN/kingpin-guard" install --dir "$T/nope" >/dev/null 2>&1 && fail "install accepted a missing dir" || pass "install refuses a missing dir"

# 3. A spawned worker's effective settings allow Edit, Write, NotebookEdit and Agent
echo "=== Test 3: spawned worker ==="
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/proj" 2>/dev/null
(
  cd "$T/proj"
  git checkout -q -b main
  # The project is a copy of this repo's tree (tracked and unignored files)
  (cd "$KP_ROOT" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf -) | tar -xf -
  git add -A
  git -c user.email=t@t -c user.name=t commit -qm "init"
  git push -q -u origin main
  git remote set-head origin main
)
"$KP_BIN/kingpin-guard" install --dir "$T/proj" >/dev/null && pass "guard installed in the main project checkout" || fail "guard install in project failed"
"$KP_BIN/kingpin-guard" check --dir "$T/proj" >/dev/null && pass "main checkout guard is active" || fail "main checkout guard inactive"

printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/proj" "" > "$KINGPIN_HOME/projects/demo.env"
cat > "$T/fake-agent" << 'F'
#!/usr/bin/env bash
exec bash
F
chmod +x "$T/fake-agent"
export KINGPIN_CLAUDE=$T/fake-agent

tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home
"$KP_BIN/kingpin-spawn" demo --issue 201 --id task-settings --harness claude >/dev/null
wt=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-settings/task.env")
[ -d "$wt" ] && pass "worker worktree leased" || fail "no worktree"

[ ! -e "$wt/.claude/settings.local.json" ] && pass "worker worktree has no settings.local.json" || fail "worker worktree has settings.local.json"
[ ! -e "$wt/.claude/settings.json" ] && pass "worker worktree has no settings.json" || fail "worker worktree has settings.json"
launch_settings=$(sed -n "s/.*--settings '\([^']*\)'.*/\1/p" "$KINGPIN_HOME/tasks/task-settings/launch.sh")
[ -f "$launch_settings" ] && pass "launch script passes a --settings file" || fail "no --settings file in launch.sh"
denied=$(denied_in "$wt/.claude/settings.json" "$wt/.claude/settings.local.json" "$launch_settings" "$wt/.claude/settings.json" | tr '\n' ' ')
[ -z "$denied" ] && pass "worker's effective settings deny none of Edit, Write, NotebookEdit, Agent" || fail "worker denies: $denied"
"$KP_BIN/kingpin-guard" install --dir "$wt" >/dev/null 2>&1 && fail "guard installed into a worker worktree" || pass "guard refuses a worker worktree"
[ -z "$(git -C "$wt" status --porcelain)" ] && pass "worker worktree is clean" || fail "worker worktree dirty"

# 4. kingpin init installs the guard; kingpin lock warns when it is missing
echo "=== Test 4: init and lock wiring ==="
unset KINGPIN_SKIP_GUARD
rm -f "$T/proj/.claude/settings.local.json"
(cd "$T/proj" && "$KP_BIN/kingpin" guard check >/dev/null 2>&1) && fail "proj wrapper check saw a guard it should not"
lock_err=$(KINGPIN_LOCK_PID=$$ "$T/proj/bin/kingpin-lock" acquire 2>&1 >/dev/null || true)
echo "$lock_err" | grep -q "guard is not active" && pass "lock acquire warns when the guard is missing" || fail "no lock warning: $lock_err"
list_err=$("$T/proj/bin/kingpin" list 2>&1 >/dev/null || true)
echo "$list_err" | grep -q "guard is not active" && pass "kingpin list repeats the guard warning" || fail "no list warning: $list_err"
wait_err=$("$T/proj/bin/kingpin-wait" --once 2>&1 >/dev/null || true)
echo "$wait_err" | grep -q "guard is not active" && pass "kingpin-wait startup repeats the guard warning" || fail "no wait warning: $wait_err"
skip_err=$(KINGPIN_SKIP_GUARD=1 "$T/proj/bin/kingpin" list 2>&1 >/dev/null || true)
echo "$skip_err" | grep -q "guard" && fail "KINGPIN_SKIP_GUARD=1 still warns: $skip_err" || pass "KINGPIN_SKIP_GUARD=1 silences the warning"
wt_err=$("$KP_BIN/kingpin-guard" warn --dir "$wt" 2>&1 || true)
[ -z "$wt_err" ] && pass "warn is silent in a worker worktree" || fail "warn in worktree: $wt_err"
"$T/proj/bin/kingpin" init demo-guard "$T/proj" >/dev/null 2>&1 || true
"$KP_BIN/kingpin-guard" check --dir "$T/proj" >/dev/null && pass "kingpin init installed the guard" || fail "kingpin init did not install the guard"
lock_err=$(KINGPIN_LOCK_PID=$$ "$T/proj/bin/kingpin-lock" acquire 2>&1 >/dev/null || true)
echo "$lock_err" | grep -q "guard is not active" && fail "lock warned despite an active guard" || pass "lock acquire is quiet with the guard active"
list_err=$("$T/proj/bin/kingpin" list 2>&1 >/dev/null || true)
[ -z "$list_err" ] && pass "kingpin list is quiet with the guard active" || fail "list warned with an active guard: $list_err"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL WORKER SETTINGS TESTS PASSED"
else
  echo "WORKER SETTINGS TESTS FAILED"
  exit 1
fi
