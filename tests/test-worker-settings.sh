#!/usr/bin/env bash
# Verification test for the tool guards: the orchestrator guard is a PreToolUse hook (not deny
# rules, which Claude Code would also load for leased worker worktrees) in an untracked file of
# the main checkout, and a worker hook confines edits to the worker's worktree and task folder.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "worker-settings"

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
# The contract is tracked, as it is in the operator's own checkout: a fixture without it
# skips the contract half of check, and the node-cost assertion (Test 2b) needs the shape
# where the check reads both JSON files.
mkdir -p "$T/kp-checkout/orchestrator"
cp "$KP_ROOT/orchestrator/contract.md" "$T/kp-checkout/orchestrator/contract.md"
git -C "$T/kp-checkout" add orchestrator/contract.md
git -C "$T/kp-checkout" -c user.email=t@t -c user.name=t commit -q -m init
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
got=$(denied_in "$T/kp-checkout/.claude/settings.local.json" | tr '\n' ' ')
[ -z "$got" ] && pass "orchestrator checkout carries no deny rule that workers would inherit" || fail "deny rules leak to workers: $got"
node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const d = c.permissions.deny;
  const e = c.hooks.PreToolUse;
  process.exit(d.length === 1 && d[0] === "Bash(rm -rf *)" && c.model === "x" && c.permissions.allow[0] === "Read" &&
    e.length === 1 && e[0].matcher === "Edit|Write|NotebookEdit|Agent" && e[0].hooks.length === 1 ? 0 : 1);
' "$T/kp-checkout/.claude/settings.local.json" && pass "install merged the hook into existing settings without duplicates" || fail "merge or dedupe wrong"
# Legacy deny rules (what older versions wrote) reach every worker worktree: check rejects them, install removes them.
echo '{"permissions":{"deny":["Edit","Write","NotebookEdit","Agent","Bash(rm -rf *)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}}' > "$T/kp-checkout/.claude/settings.local.json"
"$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" >/dev/null 2>&1 && fail "check passed with legacy deny rules" || pass "check rejects legacy deny rules"
"$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" >/dev/null && pass "install migrates legacy deny rules" || fail "migration failed"
"$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" >/dev/null && pass "check passes after migration" || fail "check failed after migration"
[ -z "$(denied_in "$T/kp-checkout/.claude/settings.local.json")" ] && pass "migration removed the four deny rules" || fail "legacy deny rules remain"
node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const e = c.hooks.PreToolUse;
  process.exit(c.permissions.deny.length === 1 && c.permissions.deny[0] === "Bash(rm -rf *)" &&
    e.length === 2 && e[0].matcher === "Bash" ? 0 : 1);
' "$T/kp-checkout/.claude/settings.local.json" && pass "migration kept unrelated deny rules and hooks" || fail "migration lost unrelated settings"
# The installed command fails closed: $T/kp-checkout has no bin/kingpin-guard, so the hook cannot run and must deny.
orch_cmd=$(node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(c.hooks.PreToolUse.find((e) => e.matcher === "Edit|Write|NotebookEdit|Agent").hooks[0].command)' "$T/kp-checkout/.claude/settings.local.json")
rc=0; printf '{}' | bash -c "$orch_cmd" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "installed orchestrator hook denies when the guard script cannot run" || fail "installed orchestrator hook failed open (rc=$rc)"
git -C "$T/kp-checkout" status --porcelain | grep -q . && fail "guard file dirties the checkout" || pass "guard file leaves the checkout clean"
echo '{bad' > "$T/kp-checkout/.claude/settings.local.json"
"$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" >/dev/null 2>&1 && fail "install overwrote malformed JSON" || pass "install refuses malformed JSON"
for bad in '[]' 'null' '{"permissions":"x"}' '"str"' '{"permissions":[]}' '{"hooks":[]}' '{"hooks":{"PreToolUse":{}}}'; do
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

# 2b. The check starts node once, on the fixture above (contract tracked, guard installed,
# .opencode/opencode.json carrying the contract entry): the shape the operator's checkout is in.
echo "=== Test 2b: guard check node cost ==="
# End of Test 2 leaves a wrong-shape guard file, so rewrite it and install again first:
# the installed state is what the operator's own checkout holds, and the count runs only
# around the check call.
printf '%s\n' '{"permissions":{"deny":["Bash(rm -rf *)"],"allow":["Read"]},"model":"x"}' > "$T/kp-checkout/.claude/settings.local.json"
"$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout" >/dev/null
mkdir -p "$T/bin"
real_node=$(command -v node)
cat > "$T/bin/node" << NODEEOF
#!/usr/bin/env bash
printf 'call\n' >> $T/node-count
exec $real_node "\$@"
NODEEOF
chmod +x "$T/bin/node"
: > "$T/node-count"
t2b_saved_path=$PATH
PATH="$T/bin:$PATH"
hash -r
t2b_out=$("$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" 2>&1)
t2b_calls=$(wc -l < "$T/node-count")
PATH=$t2b_saved_path
hash -r
[ "$t2b_calls" = 1 ] && pass "one guard check cost exactly one node" || fail "one guard check cost $t2b_calls node invocations, not 1"
printf '%s\n' "$t2b_out" | grep -q "^guard: active (" && pass "check still reports the guard active" || fail "check output wrong: $t2b_out"
printf '%s\n' "$t2b_out" | grep -q "^contract: active (" && pass "check still reports the contract active" || fail "check output wrong: $t2b_out"

# 3. A spawned worker's effective settings allow Edit, Write, NotebookEdit and Agent
echo "=== Test 3: spawned worker ==="
# The project is a copy of this repo's tree (tracked and unignored files), so the guard it
# installs and the wrapper scripts it runs are the real ones.
(
  cd "$T/proj" || exit 1
  (cd "$KP_ROOT" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf -) | tar -xf -
  git add -A
  git -c user.email=t@t -c user.name=t commit -qm "init"
  git push -q origin HEAD:main
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

"$KP_BIN/kingpin-spawn" demo --issue 201 --id task-settings --harness claude >/dev/null
wt=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-settings/task.env")
[ -d "$wt" ] && pass "worker worktree leased" || fail "no worktree"

[ ! -e "$wt/.claude/settings.local.json" ] && pass "worker worktree has no settings.local.json" || fail "worker worktree has settings.local.json"
[ ! -e "$wt/.claude/settings.json" ] && pass "worker worktree has no settings.json" || fail "worker worktree has settings.json"
launch_settings=$(sed -n "s/.*--settings '\([^']*\)'.*/\1/p" "$KINGPIN_HOME/tasks/task-settings/launch.sh")
[ -f "$launch_settings" ] && pass "launch script passes a --settings file" || fail "no --settings file in launch.sh"
# Claude Code also loads the main checkout's .claude/settings.local.json for its linked worktrees,
# so that file is part of the worker's effective settings. This is the leak behind issue #40.
denied=$(denied_in "$wt/.claude/settings.json" "$wt/.claude/settings.local.json" "$T/proj/.claude/settings.local.json" "$launch_settings" | tr '\n' ' ')
[ -z "$denied" ] && pass "worker's effective settings deny none of Edit, Write, NotebookEdit, Agent" || fail "worker denies: $denied"
grep -q "export KINGPIN_ROOT='$KP_ROOT'" "$KINGPIN_HOME/tasks/task-settings/launch.sh" && pass "launch script exports KINGPIN_ROOT for the worker hook" || fail "launch script lacks KINGPIN_ROOT"
grep -q "export KINGPIN_WORKTREE='$wt'" "$KINGPIN_HOME/tasks/task-settings/launch.sh" && pass "launch script pins the worker's worktree in KINGPIN_WORKTREE" || fail "launch script lacks KINGPIN_WORKTREE"
"$KP_BIN/kingpin-guard" install --dir "$wt" >/dev/null 2>&1 && fail "guard installed into a worker worktree" || pass "guard refuses a worker worktree"
[ -z "$(git -C "$wt" status --porcelain)" ] && pass "worker worktree is clean" || fail "worker worktree dirty"

# 3b. Hooks: the orchestrator is denied in the main checkout only, and a worker edits only
# inside its own worktree and task folder — wherever its session is.
echo "=== Test 3b: guard hooks ==="
task_folder=$KINGPIN_HOME/tasks/task-settings
# A subdirectory of a checkout must be classified like the checkout itself (issue #70 review):
# git prints the git dir and the common dir in different forms there.
mkdir -p "$T/proj/sub" "$wt/sub"
hook() {
  local mode=$1 tool=$2 cwd=$3 path=${4:-}
  printf '{"tool_name":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$cwd" "$path" \
    | KINGPIN_TASK_DIR="$task_folder" KINGPIN_WORKTREE=$wt "$KP_BIN/kingpin-guard" hook "$mode" 2>/dev/null
}
for tool in Edit Write NotebookEdit Agent; do
  hook orchestrator "$tool" "$T/proj" >/dev/null && fail "orchestrator hook let $tool through in the main checkout" || pass "orchestrator hook denies $tool in the main checkout"
  hook orchestrator "$tool" "$T/proj/sub" >/dev/null && fail "orchestrator hook let $tool through in a subdirectory of the main checkout" || pass "orchestrator hook denies $tool in a subdirectory of the main checkout"
  hook orchestrator "$tool" "$wt" >/dev/null && pass "orchestrator hook lets $tool through in a worker worktree" || fail "orchestrator hook denied $tool in a worker worktree"
  hook orchestrator "$tool" "$wt/sub" >/dev/null && pass "orchestrator hook lets $tool through in a subdirectory of a worker worktree" || fail "orchestrator hook denied $tool in a subdirectory of a worker worktree"
  hook orchestrator "$tool" "$T" >/dev/null && fail "orchestrator hook let $tool through outside a repository" || pass "orchestrator hook denies $tool outside a repository (fail closed)"
done
hook orchestrator Read "$T/proj" >/dev/null && pass "orchestrator hook has no opinion on Read" || fail "orchestrator hook denied Read"
# A guarded call with no file path: the orchestrator's verdict depends on the checkout,
# not the target (Agent never carries a path, and must stay usable in a worker worktree),
# so a worktree session is still let through; the worker half denies it (below).
printf '{"tool_name":"Agent","cwd":"%s","tool_input":{}}' "$wt" | KINGPIN_WORKTREE=$wt "$KP_BIN/kingpin-guard" hook orchestrator >/dev/null 2>&1 && pass "orchestrator hook lets Agent through in a worker worktree" || fail "orchestrator hook denied Agent in a worker worktree"
for mode in orchestrator worker; do
  rc=0; printf '{bad' | KINGPIN_TASK_DIR="$task_folder" KINGPIN_WORKTREE=$wt "$KP_BIN/kingpin-guard" hook "$mode" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && pass "$mode hook denies a malformed payload (fail closed)" || fail "$mode hook failed open on a malformed payload (rc=$rc)"
done
rc=0; printf '{"tool_name":"Write","cwd":"%s","tool_input":{}}' "$wt" | KINGPIN_TASK_DIR="$task_folder" KINGPIN_WORKTREE=$wt "$KP_BIN/kingpin-guard" hook worker >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "worker hook denies a payload with no file path (fail closed)" || fail "worker hook failed open without a file path (rc=$rc)"

allowed() { out=$(hook worker "$@") && printf '%s' "$out" | grep -q '"permissionDecision":"allow"'; }
allowed Edit "$wt" "$wt/lib/x.txt" && pass "worker hook allows an edit inside the worktree" || fail "worker edit inside the worktree not allowed"
allowed Write "$wt" "new/dir/file.txt" && pass "worker hook allows a relative path inside the worktree" || fail "relative path not allowed"
allowed Write "$wt" "$task_folder/report.html" && pass "worker hook allows a write into its task folder" || fail "task folder write not allowed"
# Issue #70: the worktree follows the worker, whatever directory the session is in.
allowed Write "$task_folder" "$task_folder/report.html" && pass "worker hook allows its task folder from the task folder" || fail "task folder write denied when cwd is the task folder"
allowed Write "$task_folder" "$wt/a.txt" && pass "worker hook allows the worktree from the task folder" || fail "worktree edit denied when cwd is the task folder"
allowed Write "$T/proj" "$wt/a.txt" && pass "worker hook allows the worktree from the main checkout" || fail "worktree edit denied when cwd is the main checkout"
allowed Edit "/" "$wt/a.txt" && pass "worker hook allows the worktree from outside any repository" || fail "worktree edit denied from outside a repository"
allowed Write "$wt/sub" "$wt/a.txt" && pass "worker hook allows the worktree from a subdirectory of the worktree" || fail "worktree edit denied when cwd is a worktree subdirectory"
ln -s "$T" "$wt/escape"
for case in "$T/proj/AGENTS.md" "/etc/hosts" "$wt/../outside.txt" "$wt/escape/outside.txt" "$KINGPIN_HOME/tasks/other-task/status"; do
  hook worker Edit "$wt" "$case" >/dev/null && fail "worker hook let an edit of $case through" || pass "worker hook denies an edit of $case"
done
rm -f "$wt/escape"
# Issue #70: a worker that cd's into the main checkout (or a subdirectory of it), its task
# folder, its own worktree subdirectory or nowhere must not gain a path it could not edit
# from its worktree root.
for cwd in "$T/proj" "$T/proj/sub" "$task_folder" "/" "$T" "$wt/sub"; do
  hook worker Edit "$cwd" "$T/proj/AGENTS.md" >/dev/null && fail "worker hook let an edit of the main checkout through from $cwd" || pass "worker hook denies the main checkout from $cwd"
done
printf '{"tool_name":"NotebookEdit","cwd":"%s","tool_input":{"notebook_path":"/etc/n.ipynb"}}' "$wt" | KINGPIN_TASK_DIR="$task_folder" KINGPIN_WORKTREE=$wt "$KP_BIN/kingpin-guard" hook worker >/dev/null 2>&1 && fail "worker hook let a NotebookEdit outside the worktree through" || pass "worker hook denies a NotebookEdit outside the worktree"
hook worker Bash "$wt" >/dev/null && pass "worker hook has no opinion on Bash" || fail "worker hook denied Bash"

# 3c. The sandbox comes from the environment, or from task.env when a worker was spawned
# before KINGPIN_WORKTREE existed — never from cwd. A worktree that is not a linked
# worktree (the main checkout) is refused instead of trusted.
echo "=== Test 3c: sandbox source ==="
worker_says() { # <cwd> <path> [VAR=value...] — KINGPIN_WORKTREE and KINGPIN_TASK_DIR stay
  # unset unless passed, so the caller's own Kingpin worker session cannot supply a root
  local cwd=$1 p=$2
  shift 2
  printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s"}}' "$cwd" "$p" \
    | env -u KINGPIN_WORKTREE -u KINGPIN_TASK_DIR "$@" "$KP_BIN/kingpin-guard" hook worker
}
env_allows() { out=$(worker_says "$@") && printf '%s' "$out" | grep -q '"permissionDecision":"allow"'; }
env_allows "$T/proj" "$wt/a.txt" KINGPIN_TASK_DIR="$task_folder" && pass "task.env pins the worktree when KINGPIN_WORKTREE is unset" || fail "task.env fallback did not allow the worktree"
worker_says "$T/proj" "$T/proj/AGENTS.md" KINGPIN_TASK_DIR="$task_folder" >/dev/null 2>&1 && fail "task.env fallback let the main checkout through" || pass "task.env fallback still denies the main checkout"
# The suite may run inside a Kingpin worker session, which exports KINGPIN_TASK_DIR; both
# that and KINGPIN_WORKTREE must be cleared for this case to reach the no-root deny (a
# task.env naming another worker's worktree would otherwise answer with an outside deny
# and keep the assertion green), so assert on the message as well as the status.
rc=0; err=$(worker_says "$wt" "$wt/a.txt" 2>&1 >/dev/null) || rc=$?
if [ "$rc" = 2 ] && echo "$err" | grep -q "cannot tell which worktree this worker owns"; then
  pass "worker hook denies when no worktree can be pinned (fail closed)"
else
  fail "worker hook failed open without KINGPIN_WORKTREE or task.env (rc=$rc): $err"
fi
cp "$task_folder/task.env" "$T/task.env.bak"
sed -i "s|^WORKTREE=.*|WORKTREE=$T/proj|" "$task_folder/task.env"
worker_says "$wt" "$T/proj/AGENTS.md" KINGPIN_TASK_DIR="$task_folder" >/dev/null 2>&1 && fail "a tampered task.env granted the main checkout" || pass "a tampered task.env cannot grant the main checkout (not a linked worktree)"
sed -i "s|^WORKTREE=.*|WORKTREE=$T/proj/sub|" "$task_folder/task.env"
worker_says "$wt" "$T/proj/sub/AGENTS.md" KINGPIN_TASK_DIR="$task_folder" >/dev/null 2>&1 && fail "a tampered task.env granted a subdirectory of the main checkout" || pass "a tampered task.env cannot grant a subdirectory of the main checkout (not a linked worktree)"
env_allows "$wt" "$wt/a.txt" KINGPIN_TASK_DIR="$task_folder" KINGPIN_WORKTREE="$wt" && pass "KINGPIN_WORKTREE wins over a tampered task.env" || fail "KINGPIN_WORKTREE did not override task.env"
cp "$T/task.env.bak" "$task_folder/task.env"

# The command that worker/hooks.json really runs, with the environment the launch script sets
worker_cmd=$(node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(c.hooks.PreToolUse.find((e) => e.matcher === "Edit|Write|NotebookEdit").hooks[0].command)' "$KP_ROOT/worker/hooks.json")
run_worker_hook() { printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | KINGPIN_ROOT=$KP_ROOT KINGPIN_TASK_DIR="$task_folder" KINGPIN_WORKTREE=$wt bash -c "$worker_cmd" 2>/dev/null; }
run_worker_hook "$wt" "$wt/a.txt" | grep -q '"permissionDecision":"allow"' && pass "hooks.json command allows an edit inside the worktree" || fail "hooks.json command did not allow an inside edit"
run_worker_hook "$T/proj" "$wt/a.txt" | grep -q '"permissionDecision":"allow"' && pass "hooks.json command allows the worktree from the main checkout" || fail "hooks.json command denied the worktree from the main checkout"
run_worker_hook "$T/proj" "$T/proj/a.txt" >/dev/null && fail "hooks.json command let an outside edit through" || pass "hooks.json command denies an edit outside the worktree"
rc=0; printf '{}' | KINGPIN_ROOT="$T/nope" bash -c "$worker_cmd" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "worker hook denies when kingpin-guard is missing" || fail "worker hook failed open on a missing script (rc=$rc)"
rc=0; printf '{}' | env -u KINGPIN_ROOT bash -c "$worker_cmd" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "worker hook denies when KINGPIN_ROOT is unset" || fail "worker hook failed open without KINGPIN_ROOT (rc=$rc)"

# 4. kingpin init installs the guard; kingpin lock warns when it is missing
echo "=== Test 4: init and lock wiring ==="
unset KINGPIN_SKIP_GUARD
rm -f "$T/proj/.claude/settings.local.json"
# --dir is required: kingpin-guard ignores the working directory and defaults to its own checkout,
# which carries a guard when the suite runs in the orchestrator's main checkout.
"$KP_BIN/kingpin" guard check --dir "$T/proj" >/dev/null 2>&1 && fail "proj wrapper check saw a guard it should not" || pass "proj wrapper check fails without a guard"
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

kp_test_finish WORKER-SETTINGS
