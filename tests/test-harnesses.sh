#!/usr/bin/env bash
# Verification test for Kingpin multi-harness support (claude, agy, opencode, pi).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "harnesses"

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

# A stub Pi records its argv and environment, then stays alive like a real TUI would.
# CI has no pi binary, so this stub is the only path that reaches the pi launch branch.
cat > "$T/fake-pi" << 'P'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$@" > "$d/pi-argv"
{
  printf 'KINGPIN_TASK_DIR=%s\n' "${KINGPIN_TASK_DIR:-}"
  printf 'KINGPIN_WORKTREE=%s\n' "${KINGPIN_WORKTREE:-}"
  printf 'KINGPIN_ROOT=%s\n' "${KINGPIN_ROOT:-}"
} > "$d/pi-env"
exec bash
P
chmod +x "$T/fake-pi"
export KINGPIN_PI=$T/fake-pi

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

# Test 3b: Pi spawn
echo "=== Test 3b: Pi Spawn ==="
"$KP_BIN/kingpin-spawn" demo --issue 130 --id task-pi --harness pi >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-pi/task.env" ] && pass "task-pi task.env created" || fail "missing task.env"
grep -q "^HARNESS=pi$" "$KINGPIN_HOME/tasks/task-pi/task.env" && pass "task-pi recorded HARNESS=pi" || fail "wrong harness in task.env"
grep -q -- "--append-system-prompt" "$KINGPIN_HOME/tasks/task-pi/launch.sh" && pass "task-pi launch script has --append-system-prompt" || fail "wrong launch script"
grep -q -- "-e .*worker/pi/kingpin-harness.ts" "$KINGPIN_HOME/tasks/task-pi/launch.sh" && pass "task-pi launch script loads the checkout extension" || fail "extension not loaded from the checkout"
grep -q "(cat .*prompt.txt)" "$KINGPIN_HOME/tasks/task-pi/launch.sh" && pass "task-pi launch script reads the prompt file" || fail "prompt is not read from its file"
# Pi expands a skill only when the job message starts with `/skill:` (issue #93
# review, M2), so the pi prompt is the bare command and nothing else.
grep -q '^/skill:issue-flow 130$' "$KINGPIN_HOME/tasks/task-pi/prompt.txt" && pass "task-pi prompt is the bare /skill:issue-flow 130 command" || fail "prompt: $(cat "$KINGPIN_HOME/tasks/task-pi/prompt.txt")"
! grep -q "no subagent tool" "$KINGPIN_HOME/tasks/task-pi/prompt.txt" && pass "task-pi prompt carries no prose before the skill command" || fail "the inline sentence is back in the pi prompt"
grep -q "no subagent tool" "$KINGPIN_HOME/tasks/task-pi/preamble.md" && pass "task-pi preamble tells the worker to run skills inline" || fail "no inline-delegation sentence in the pi preamble"
for h in claude agy opencode; do
  ! grep -q "no subagent tool" "$KINGPIN_HOME/tasks/task-$h/preamble.md" \
    && pass "$h preamble carries no pi-only inline-delegation sentence" || fail "the pi-only sentence leaked into the $h preamble"
done
grep -q "background code worker" "$KINGPIN_HOME/tasks/task-pi/preamble.md" && pass "pi preamble instructs background worker role" || fail "missing worker role in pi preamble"
! grep -q "You are the underboss" "$KINGPIN_HOME/tasks/task-pi/preamble.md" && pass "pi preamble carries no orchestrator persona" || fail "orchestrator persona in pi preamble"

wt_pi=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/task-pi/task.env")
[ -n "$wt_pi" ] && [ -d "$wt_pi" ] && pass "pi task leased a worktree" || fail "no pi worktree"
status_out=$(git -C "$wt_pi" status --porcelain)
[ -z "$status_out" ] && pass "the pi worktree stays clean" || fail "pi worktree dirty: $status_out"
pi_excl=$(git -C "$wt_pi" config --get --worktree core.excludesFile 2>/dev/null || true)
[ -z "$pi_excl" ] && pass "pi sets no worktree exclude file" || fail "pi worktree reads '${pi_excl}' as core.excludesFile"
[ ! -e "$KINGPIN_HOME/tasks/task-pi/injected" ] && pass "pi records no injected path" || fail "pi recorded an injected path: $(cat "$KINGPIN_HOME/tasks/task-pi/injected")"
[ ! -e "$KINGPIN_HOME/tasks/task-pi/exclude" ] && pass "pi creates no task exclude file" || fail "pi created a task exclude file"

# The tmux launch is asynchronous: poll for the stub's argv, then assert the preamble,
# the extension and the prompt arrived as arguments rather than on stdin.
for _ in $(seq 1 50); do
  [ -s "$T/pi-argv" ] && break
  sleep 0.1
done
[ -s "$T/pi-argv" ] && pass "pi stub recorded its argv" || fail "pi stub never ran"
grep -qxF -- "$KINGPIN_HOME/tasks/task-pi/preamble.md" "$T/pi-argv" && pass "the preamble path is an argv element" || fail "argv: $(cat "$T/pi-argv" 2>/dev/null)"
grep -qxF -- "$KP_ROOT/worker/pi/kingpin-harness.ts" "$T/pi-argv" && pass "the extension path is an argv element" || fail "extension missing from argv"
grep -qxF -- "/skill:issue-flow 130" "$T/pi-argv" && pass "the prompt is an argv element" || fail "prompt missing from argv"
grep -qxF "KINGPIN_TASK_DIR=$KINGPIN_HOME/tasks/task-pi" "$T/pi-env" && pass "the launcher exports KINGPIN_TASK_DIR" || fail "pi env: $(cat "$T/pi-env" 2>/dev/null)"
grep -qxF "KINGPIN_WORKTREE=$wt_pi" "$T/pi-env" && pass "the launcher exports KINGPIN_WORKTREE" || fail "KINDGIN_WORKTREE missing"
grep -qxF "KINGPIN_ROOT=$KP_ROOT" "$T/pi-env" && pass "the launcher exports KINGPIN_ROOT" || fail "KINGPIN_ROOT missing"

# The measured Pi 1.5.0 working rule must hold `quiet`, and a cleared pane must release it.
echo "100" > "$KINGPIN_HOME/tasks/task-pi/stopped"
echo "50" > "$KINGPIN_HOME/tasks/task-pi/seen_stopped"
tmux send-keys -t kingpin:task-pi 'printf "── ⠏ Working ─────────────────────────\n"' Enter
sleep 0.5
res=$("$KP_BIN/kingpin-wait" --once 2>&1 || true)
if echo "$res" | grep -q "task-pi quiet"; then
  fail "task-pi reported quiet while the Pi Working rule was present"
else
  pass "task-pi correctly held quiet while the Pi Working rule was present"
fi
tmux send-keys -t kingpin:task-pi 'clear' Enter
tmux clear-history -t kingpin:task-pi
sleep 0.5
res=$("$KP_BIN/kingpin-wait" --once 2>&1 || true)
echo "$res" | grep -q "task-pi quiet" && pass "task-pi reported quiet after pane cleared" || fail "task-pi did not report quiet"

# Test 3c: Codex spawn (issue #106). Codex is never installed in CI and the build host
# is logged out, so the stub below is the only path that reaches the codex launch branch.
echo "=== Test 3c: Codex Spawn ==="
cat > "$T/fake-codex" << 'C'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$@" > "$d/codex-argv"
{
  printf 'KINGPIN_TASK_DIR=%s\n' "${KINGPIN_TASK_DIR:-}"
  printf 'KINGPIN_WORKTREE=%s\n' "${KINGPIN_WORKTREE:-}"
  printf 'KINGPIN_ROOT=%s\n' "${KINGPIN_ROOT:-}"
  printf 'TMPDIR=%s\n' "${TMPDIR:-}"
} > "$d/codex-env"
exec bash
C
chmod +x "$T/fake-codex"
export KINGPIN_CODEX=$T/fake-codex
# The fleet's skills are linked into the worktree from this directory, so the leg needs
# no ~/.claude/skills and no developer's skill set decides its result.
mkdir -p "$T/skills/issue-flow" "$T/skills/do"
printf -- '---\nname: issue-flow\ndescription: fixture skill\n---\n\nFixture body.\n' > "$T/skills/issue-flow/SKILL.md"
printf -- '---\nname: do\ndescription: fixture skill\n---\n\nFixture body.\n' > "$T/skills/do/SKILL.md"
export KINGPIN_SKILLS_DIR=$T/skills

"$KP_BIN/kingpin-spawn" demo --issue 140 --id task-codex --harness codex >/dev/null
tc=$KINGPIN_HOME/tasks/task-codex
grep -q "^HARNESS=codex$" "$tc/task.env" && pass "task-codex recorded HARNESS=codex" || fail "wrong harness in task.env: $(cat "$tc/task.env" 2>/dev/null)"
grep -qx "\$issue-flow 140" "$tc/prompt.txt" && pass "task-codex prompt is the bare \$issue-flow 140 command" || fail "prompt: $(cat "$tc/prompt.txt" 2>/dev/null)"
! grep -q "Run " "$tc/prompt.txt" && pass "task-codex prompt carries no prose before the skill command" || fail "prose in the codex prompt: $(cat "$tc/prompt.txt" 2>/dev/null)"
grep -q "background code worker" "$tc/preamble.md" && pass "codex preamble instructs background worker role" || fail "missing worker role in codex preamble"
! grep -q "You are the underboss" "$tc/preamble.md" && pass "codex preamble carries no orchestrator persona" || fail "orchestrator persona in codex preamble"
grep -q "no subagent tool" "$tc/preamble.md" && pass "codex preamble tells the worker to run skills inline" || fail "no inline-delegation sentence in the codex preamble"

# The launch line is the containment contract: -C, -a never, the workspace-write sandbox,
# the preamble by config override, the sandbox flags and the notify turn end.
wt_codex=$(sed -n 's/^WORKTREE=//p' "$tc/task.env")
launch=$tc/launch.sh
# The launch script is written with `printf %q` per argv word, so a TOML value appears
# shell-escaped. Build the expected escaped word the same way the launcher does.
codex_word() { printf '%q' "$1"; }
grep -qF -- "-C $wt_codex" "$launch" && pass "codex launch runs in the worktree" || fail "codex launch line: $(cat "$launch")"
grep -qF -- "-a never" "$launch" && pass "codex launch disables per-command approval" || fail "-a never missing"
grep -qF -- "-s workspace-write" "$launch" && pass "codex launch selects the workspace-write sandbox" || fail "-s workspace-write missing"
grep -qF -- "$(codex_word "model_instructions_file=\"$tc/preamble.md\"")" "$launch" && pass "codex preamble arrives through model_instructions_file" || fail "preamble override missing: $(cat "$launch")"
grep -qF -- 'sandbox_workspace_write.exclude_slash_tmp=true' "$launch" && pass "codex sandbox denies /tmp" || fail "exclude_slash_tmp missing"
grep -qF -- 'sandbox_workspace_write.exclude_tmpdir_env_var=true' "$launch" && pass "codex sandbox keeps the TMPDIR-derived root out of view" || fail "exclude_tmpdir_env_var missing"
# A linked worktree keeps its index and refs outside the worktree root, and the sandbox
# mounts those directories read-only over a writable root that contains them, so a worker
# could edit files but never stage or commit (issue #106 review, H1). The launch line is
# the deterministic half of that proof; the live half ran against a model (see the review
# comment), because CI installs no codex binary.
codex_git_dir=$(kp_git_dir "$wt_codex") || fail "cannot read the codex worktree's git dir"
codex_common_dir=$(kp_git_common_dir "$wt_codex") || fail "cannot read the codex worktree's common git dir"
grep -qF -- "$(codex_word "sandbox_workspace_write.writable_roots=[\"$tc\",\"$codex_git_dir\",\"$codex_common_dir\"]")" "$launch" \
  && pass "codex sandbox makes the task folder and both git dirs writable so the worker can commit" \
  || fail "writable_roots does not carry both git dirs: $(grep -o 'writable_roots=.*' "$launch")"
grep -qF -- 'sandbox_workspace_write.network_access=true' "$launch" && pass "codex sandbox keeps network access for gh and git push" || fail "network_access missing"
grep -qF -- "$(codex_word "notify=[\"$tc/notify.sh\"]")" "$launch" && pass "codex turn end goes through the notify program" || fail "notify override missing"
grep -qxF "export TMPDIR=$tc/tmp" "$launch" && pass "codex launcher moves TMPDIR inside the task folder" || fail "TMPDIR export: $(cat "$launch")"
grep -qxF "mkdir -p -- $tc/tmp" "$launch" && pass "codex launcher creates the TMPDIR it exports" || fail "TMPDIR is not created before launch"
# The shipped harness pins no provider and no model: the launch inherits whatever the
# user's own `codex` is logged into.
for bad in model_provider '--model' base_url '-c model='; do
  ! grep -qF -- "$bad" "$launch" && pass "codex launch carries no '$bad'" || fail "codex launch carries '$bad': $(cat "$launch")"
done

# Hook trust: a host with a hook set raises Codex's second review dialog, which `-a never`
# does not answer, so the spawn passes the one measured bypass flag, and only then (issue
# #106 review, M3). Both detection paths are covered, and the absence case above is this
# host's default: no config.toml feature flag and no hooks.json yet.
! grep -qF -- '--dangerously-bypass-hook-trust' "$launch" \
  && pass "a host with no hook set gets no hook-trust bypass" || fail "the hook-trust bypass is in a launch with no hook set"
printf '{"hooks":{"stop":[{"command":"true"}]}}\n' > "$T/cfg-codex/hooks.json"
"$KP_BIN/kingpin-spawn" demo --issue 143 --id task-codex-hooks --harness codex >/dev/null
th=$KINGPIN_HOME/tasks/task-codex-hooks
grep -qF -- '--dangerously-bypass-hook-trust' "$th/launch.sh" \
  && pass "a hooks.json hook set adds the measured hook-trust bypass" || fail "hooks.json did not add the bypass: $(cat "$th/launch.sh")"
"$KP_BIN/kingpin" "done" task-codex-hooks --force >/dev/null 2>&1 || true
rm -f "$T/cfg-codex/hooks.json"
cp "$T/cfg-codex/config.toml" "$T/cfg-codex-feature.bak"
printf '\n[features]\nhooks = true\n' >> "$T/cfg-codex/config.toml"
"$KP_BIN/kingpin-spawn" demo --issue 144 --id task-codex-hooks-feature --harness codex >/dev/null
tf=$KINGPIN_HOME/tasks/task-codex-hooks-feature
grep -qF -- '--dangerously-bypass-hook-trust' "$tf/launch.sh" \
  && pass "features.hooks = true adds the measured hook-trust bypass" || fail "features.hooks did not add the bypass: $(cat "$tf/launch.sh")"
"$KP_BIN/kingpin" "done" task-codex-hooks-feature --force >/dev/null 2>&1 || true
cp "$T/cfg-codex-feature.bak" "$T/cfg-codex/config.toml"
"$KP_BIN/kingpin-spawn" demo --issue 147 --id task-codex-nohooks --harness codex >/dev/null
! grep -qF -- '--dangerously-bypass-hook-trust' "$KINGPIN_HOME/tasks/task-codex-nohooks/launch.sh" \
  && pass "the bypass goes away once the hook set does" || fail "the bypass survived the removed hook set"
"$KP_BIN/kingpin" "done" task-codex-nohooks --force >/dev/null 2>&1 || true

# The turn end, without a model: the notify program runs bin/kingpin-stop, which writes
# `stopped`. Codex fires it again for its title-generation turn, so a second run must
# rewrite the epoch and add no second outcome line.
[ -x "$tc/notify.sh" ] && pass "codex notify program is executable" || fail "notify.sh missing or not executable"
"$tc/notify.sh"
first_stop=$(cat "$tc/stopped" 2>/dev/null || true)
[ -n "$first_stop" ] && [ "$(printf '%s' "$first_stop" | tr -d '0-9')" = "" ] && pass "the notify program writes a turn-end epoch" || fail "stopped holds '${first_stop:-nothing}'"
"$tc/notify.sh"
[ "$(wc -l < "$tc/stopped")" -eq 1 ] && pass "a second notify keeps stopped a single epoch" || fail "stopped holds $(wc -l < "$tc/stopped") lines"
[ "$(grep -c '^failed: no status:' "$tc/status" || true)" -eq 1 ] && pass "the second notify adds no duplicate outcome line" || fail "status: $(cat "$tc/status" 2>/dev/null)"

# The fleet's skills are per-skill links into .codex/skills, hidden from git status by the
# task's own exclude file, and nothing else in the worktree is touched.
codex_link() { # <skill-name>
  [ -L "$wt_codex/.codex/skills/$1" ] && [ "$(readlink "$wt_codex/.codex/skills/$1")" = "$T/skills/$1" ] \
    && pass ".codex/skills/$1 links to the fleet's skill" || fail ".codex/skills/$1 is not Kingpin's link"
}
codex_link issue-flow
codex_link "do"
codex_excl=$(git -C "$wt_codex" config --get --worktree core.excludesFile 2>/dev/null || true)
[ "$codex_excl" = "$tc/exclude" ] && pass "codex worktree reads its task's exclude file" || fail "codex worktree reads '${codex_excl:-nothing}' as core.excludesFile"
grep -qx '\.codex/skills/issue-flow' "${codex_excl:-/nonexistent}" && pass "the issue-flow link is excluded through the task's exclude file" || fail "issue-flow link not excluded"
grep -qx '\.codex/skills/do' "${codex_excl:-/nonexistent}" && pass "the do link is excluded through the task's exclude file" || fail "do link not excluded"
status_out=$(git -C "$wt_codex" status --porcelain)
[ -z "$status_out" ] && pass "git status in the codex worktree is clean" || fail "git status dirty: $status_out"

# The folder-trust entry Codex needs before it starts unattended, in this suite's own
# CODEX_HOME (never the developer's).
codex_trusted() { # <worktree>
  awk -v hdr="[projects.\"$(realpath "$1")\"]" '
    $0 == hdr { inside = 1; next }
    /^\[/ { inside = 0 }
    inside && $0 == "trust_level = \"trusted\"" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$T/cfg-codex/config.toml"
}
codex_trusted "$wt_codex" && pass "the spawn seeds Codex's trusted-project entry" || fail "no trusted-project entry in $T/cfg-codex/config.toml"

# A project that already carries a skill at one of the fleet's names keeps it: Kingpin
# replaces only its own link and names what it leaves alone.
cat > "$T/setup-codex.sh" << 'SETUP'
mkdir -p .codex/skills/mine .codex/skills/do
printf -- '---\nname: mine\ndescription: project skill\n---\n\nProject body.\n' > .codex/skills/mine/SKILL.md
printf -- '---\nname: do\ndescription: project skill\n---\n\nProject body.\n' > .codex/skills/do/SKILL.md
ln -s "$KINGPIN_SKILLS_DIR/do" .codex/skills/issue-flow
SETUP
chmod +x "$T/setup-codex.sh"
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/proj" "$T/setup-codex.sh" > "$KINGPIN_HOME/projects/demo-codex.env"
codex_rc=0
codex_err=$("$KP_BIN/kingpin-spawn" demo-codex --issue 141 --id task-codex-keep --harness codex 2>&1 >/dev/null) || codex_rc=$?
[ "$codex_rc" -eq 0 ] && pass "a spawn over a project's own skill still launches" || fail "spawn over a project skill failed: $codex_err"
tk=$KINGPIN_HOME/tasks/task-codex-keep
wt_keep=$(sed -n 's/^WORKTREE=//p' "$tk/task.env")
[ "$(readlink "$wt_keep/.codex/skills/issue-flow" 2>/dev/null)" = "$T/skills/issue-flow" ] \
  && pass "an earlier task's link is replaced with the fleet's own skill" || fail "issue-flow link: $(readlink "$wt_keep/.codex/skills/issue-flow" 2>/dev/null)"
grep -q "Project body." "$wt_keep/.codex/skills/do/SKILL.md" && pass "the project's own do skill survives untouched" || fail "the project's do skill was replaced"
grep -q "Project body." "$wt_keep/.codex/skills/mine/SKILL.md" && pass "an unrelated project skill survives untouched" || fail "the project's mine skill was touched"
echo "$codex_err" | grep -q "leaving .codex/skills/do" && pass "the spawn names the project skill it leaves alone" || fail "the spawn did not name the skipped skill: $codex_err"
keep_excl=$(git -C "$wt_keep" config --get --worktree core.excludesFile 2>/dev/null || true)
grep -qx '\.codex/skills/issue-flow' "${keep_excl:-/nonexistent}" && pass "the replaced link is excluded" || fail "the replaced link is not excluded"
! grep -qx '\.codex/skills/do' "${keep_excl:-/nonexistent}" && pass "the project's own skill is not excluded" || fail "the project's own skill was excluded"
codex_trusted "$wt_keep" && pass "the second spawn seeds its own trusted-project entry" || fail "no trusted-project entry for the second worktree"

# A spawn that fails after it seeded the trust entry removes what it wrote (issue #106
# review, M1): a refusal the spawn itself produces must not leave config.toml changed for
# every failed attempt. The project here tracks one of the fleet's skill paths, so the
# refusal happens after the seed, at the link step. It tracks `issue-flow`, which sorts
# after `do`, so the loop has already created a link when it refuses (review, M4).
git init -q -b main "$T/codex-badrepo"
mkdir -p "$T/codex-badrepo/.codex/skills/issue-flow"
printf -- '---\nname: issue-flow\ndescription: project skill\n---\n\nProject body.\n' > "$T/codex-badrepo/.codex/skills/issue-flow/SKILL.md"
git -C "$T/codex-badrepo" add -A
git -C "$T/codex-badrepo" -c user.email=t@t -c user.name=t commit -qm init
printf 'PROJECT_PATH=%q\n' "$T/codex-badrepo" > "$KINGPIN_HOME/projects/demo-codexbad.env"
cp "$T/cfg-codex/config.toml" "$T/cfg-codex-before-fail.toml"
bad_rc=0
bad_err=$("$KP_BIN/kingpin-spawn" demo-codexbad --issue 146 --id task-codex-bad --harness codex 2>&1 >/dev/null) || bad_rc=$?
[ "$bad_rc" -ne 0 ] && pass "a tracked .codex skill refuses the codex spawn" || fail "the spawn over a tracked .codex skill launched"
echo "$bad_err" | grep -q "is tracked by the project" && pass "the refusal names the tracked skill path" || fail "refusal: $bad_err"
cmp -s "$T/cfg-codex-before-fail.toml" "$T/cfg-codex/config.toml" \
  && pass "the refused spawn removed the trust entry it had seeded" \
  || fail "the refused spawn left its trust entry: $(cat "$T/cfg-codex/config.toml")"
[ ! -d "$KINGPIN_HOME/tasks/task-codex-bad" ] && pass "the refused codex spawn left no task folder" || fail "the refused codex spawn left a task folder"
# The links already created before the refusal must go too (issue #106 review, M4): the
# failure trap removes what `<task-dir>/injected` names, so the loop has to record each
# link as it makes it. `git worktree list` still names the slot treehouse returned.
bad_wt=''
while IFS= read -r w; do
  [ "$w" = "$T/codex-badrepo" ] && continue
  bad_wt=$w
  break
done < <(git -C "$T/codex-badrepo" worktree list --porcelain | sed -n 's/^worktree //p')
[ -n "$bad_wt" ] && [ -d "$bad_wt" ] && pass "the refused codex spawn's slot is still registered" || fail "no worktree to inspect after the refusal"
# `do` sorts before the tracked `issue-flow`, so it was linked before the refusal. The
# project's own tracked skill must survive; the link Kingpin made must not.
if [ -n "$bad_wt" ] && { [ -e "$bad_wt/.codex/skills/do" ] || [ -L "$bad_wt/.codex/skills/do" ]; }; then
  fail "the refused spawn left .codex/skills/do in the slot"
else
  pass "a refusal inside the skill loop removes the link it already created"
fi
[ -n "$bad_wt" ] && [ -f "$bad_wt/.codex/skills/issue-flow/SKILL.md" ] \
  && pass "the project's own tracked skill survives the refused spawn" \
  || fail "the refused spawn removed the project's tracked skill"
[ -n "$bad_wt" ] && [ -z "$(git -C "$bad_wt" status --porcelain)" ] \
  && pass "the refused codex spawn leaves its slot clean" \
  || fail "the refused codex spawn left the slot dirty: $(git -C "$bad_wt" status --porcelain 2>/dev/null)"

# The measured working marker holds `quiet`, and a cleared pane releases it. The status
# file is emptied first: the notify runs above ended a turn, and `failed:` is terminal to
# kingpin-wait, which would skip the quiet check entirely.
: > "$tc/status"
echo 100 > "$tc/stopped"
echo 50 > "$tc/seen_stopped"
tmux send-keys -t kingpin:task-codex 'printf "• Working (2s • esc to interrupt)\n"' Enter
sleep 0.5
res=$("$KP_BIN/kingpin-wait" --once 2>&1 || true)
if echo "$res" | grep -q "task-codex quiet"; then
  fail "task-codex reported quiet while the Codex working marker was present"
else
  pass "task-codex correctly held quiet while the Codex working marker was present"
fi
tmux send-keys -t kingpin:task-codex 'clear' Enter
tmux clear-history -t kingpin:task-codex
sleep 0.5
res=$("$KP_BIN/kingpin-wait" --once 2>&1 || true)
echo "$res" | grep -q "task-codex quiet" && pass "task-codex reported quiet after pane cleared" || fail "task-codex did not report quiet: $res"

# A codex lock holder is the spawn default (the same precedence the other harnesses have).
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin-lock" acquire --harness codex >/dev/null
"$KP_BIN/kingpin-spawn" demo --issue 142 --id task-lock-codex >/dev/null
[ "$(sed -n 's/^HARNESS=//p' "$KINGPIN_HOME/tasks/task-lock-codex/task.env")" = "codex" ] \
  && pass "a codex lock holder is the spawn default" || fail "lock default: $(sed -n 's/^HARNESS=//p' "$KINGPIN_HOME/tasks/task-lock-codex/task.env")"
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin-lock" release >/dev/null

# Test 4: Project-default harness configuration
echo "=== Test 4: Project Default Harness ==="
printf 'PROJECT_PATH=%q\nHARNESS=opencode\n' "$T/proj" > "$KINGPIN_HOME/projects/demo-oc.env"
"$KP_BIN/kingpin-spawn" demo-oc --issue 104 --id task-default-oc >/dev/null
grep -q "^HARNESS=opencode$" "$KINGPIN_HOME/tasks/task-default-oc/task.env" && pass "task-default-oc picked up HARNESS=opencode from project env" || fail "failed project default harness"

# A project that pins pi gets a pi worker from the project env alone (issue #93
# review, L4): the pi legs above all pass --harness explicitly.
printf 'PROJECT_PATH=%q\nHARNESS=pi\n' "$T/proj" > "$KINGPIN_HOME/projects/demo-pi.env"
"$KP_BIN/kingpin-spawn" demo-pi --issue 105 --id task-default-pi >/dev/null
grep -q "^HARNESS=pi$" "$KINGPIN_HOME/tasks/task-default-pi/task.env" && pass "task-default-pi picked up HARNESS=pi from project env" || fail "project-env pi: $(cat "$KINGPIN_HOME/tasks/task-default-pi/task.env" 2>/dev/null)"
grep -q -- "-e .*worker/pi/kingpin-harness.ts" "$KINGPIN_HOME/tasks/task-default-pi/launch.sh" && pass "the project-env pi spawn loads the pi extension" || fail "project-env pi spawn did not launch pi"

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

# A pi lock holder is the default harness too
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin-lock" acquire --harness pi >/dev/null
"$KP_BIN/kingpin-spawn" demo --issue 117 --id task-lock-pi >/dev/null
[ "$(harness_of task-lock-pi)" = "pi" ] && pass "a pi lock holder is the spawn default" || fail "lock default: $(harness_of task-lock-pi)"
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin-lock" release >/dev/null

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
for h in claude agy opencode pi codex; do
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

kp_test_finish MULTI-HARNESS
