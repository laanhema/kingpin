#!/usr/bin/env bash
# Verification test for issue #96: a spawned worker's instruction context.
#
# Two halves of one bug: a worker must load the preamble the spawn gave it, and it
# must not load the orchestrator contract. `bin/kingpin-scope` names the instruction
# files a harness really loads; `kingpin spawn` refuses to launch when one of them
# carries the contract, and `kingpin guard install` puts the contract into
# instruction sources that exist only in the main checkout.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "worker-scope"
kp_test_project

# Keep the harness config directories inside the scratch tree, so a developer's own
# global instruction files cannot decide this suite's result.
export XDG_CONFIG_HOME=$T/xdg
mkdir -p "$XDG_CONFIG_HOME"
export KINGPIN_CLAUDE=$T/fake-worker
export KINGPIN_OPENCODE=$T/fake-worker

markers=(
  'kingpin orchestrator contract'
  'You are the underboss'
  'The user is the boss'
  'Never edit, write, or touch project code directly'
)
has_marker() { local m; for m in "${markers[@]}"; do grep -Fq -- "$m" "$1" && return 0; done; return 1; }
persona_text() {
  cat << 'EOF'
# Kingpin

You are the underboss (the consigliere).
The user is the boss (the kingpin).

1. **Never edit, write, or touch project code directly.**
EOF
}

# 1. The contract lives in a tracked template and in no file a worker loads
echo "=== Test 1: tracked instruction files ==="
[ -f "$KP_ROOT/orchestrator/contract.md" ] && pass "orchestrator/contract.md is the tracked contract" || fail "missing orchestrator/contract.md"
has_marker "$KP_ROOT/orchestrator/contract.md" && pass "the tracked contract still carries the persona" || fail "contract lost its persona"
for f in AGENTS.md CLAUDE.md worker/preamble.md; do
  if has_marker "$KP_ROOT/$f"; then
    fail "the orchestrator contract reaches workers through tracked $f"
  else
    pass "tracked $f carries no orchestrator contract"
  fi
done
grep -q '@AGENTS.md' "$KP_ROOT/CLAUDE.md" && pass "CLAUDE.md still imports AGENTS.md" || fail "CLAUDE.md no longer imports AGENTS.md"

# 2. kingpin-scope names the files each harness really loads
echo "=== Test 2: scope files ==="
w=$T/wt
mkdir -p "$w/.opencode" "$w/.claude/rules" "$w/.agents/rules"
printf '# Proj\nneutral instructions\n' > "$w/AGENTS.md"
printf '@AGENTS.md\n' > "$w/CLAUDE.md"
printf 'WORKER-PREAMBLE-TEXT\n' > "$w/pre.md"

sc() { "$KP_BIN/kingpin-scope" "$@"; }
# Captured rather than piped: `grep -q` closing the pipe early would trip pipefail.
sc files --harness opencode --worktree "$w" > "$T/files-oc"
grep -qxF "discovery	$w/AGENTS.md" "$T/files-oc" \
  && pass "opencode: AGENTS.md is a discovery source" || fail "opencode: AGENTS.md missing from the source list"
printf '{"instructions":["%s/pre.md"]}\n' "$w" > "$w/.opencode/opencode.json"
sc files --harness opencode --worktree "$w" > "$T/files-oc"
grep -qxF "configured	$w/pre.md" "$T/files-oc" \
  && pass "opencode: an instructions entry is a configured source" || fail "opencode: instructions entry not listed"
sc files --harness agy --worktree "$w" > "$T/files-agy"
grep -qxF "discovery	$w/AGENTS.md" "$T/files-agy" && pass "agy: AGENTS.md is a discovery source" || fail "agy: AGENTS.md missing"
printf 'WORKER-PREAMBLE-TEXT\n' > "$w/.agents/rules/kingpin.md"
sc files --harness agy --worktree "$w" > "$T/files-agy"
grep -qxF "ignored	$w/.agents/rules/kingpin.md" "$T/files-agy" \
  && pass "agy: a rules file without a trigger is reported as ignored" || fail "agy: ignored rules file not reported"
printf -- '---\ntrigger: always_on\ndescription: preamble\n---\n\nWORKER-PREAMBLE-TEXT\n' > "$w/.agents/rules/kingpin.md"
sc files --harness agy --worktree "$w" > "$T/files-agy"
grep -qxF "discovery	$w/.agents/rules/kingpin.md" "$T/files-agy" \
  && pass "agy: a rules file with trigger: always_on is a discovery source" || fail "agy: triggered rules file not listed"
printf '# contract\n' > "$w/.claude/rules/kingpin-orchestrator.md"
sc files --harness claude --worktree "$w" > "$T/files-claude"
grep -qxF "discovery	$w/.claude/rules/kingpin-orchestrator.md" "$T/files-claude" \
  && pass "claude: .claude/rules is a discovery source" || fail "claude: .claude/rules not listed"

# 3. check: green on a neutral worktree, red (naming the file) on a leak
echo "=== Test 3: scope check ==="
sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" \
  && pass "opencode: a neutral worktree with a loaded preamble passes" || fail "opencode: neutral worktree rejected"
persona_text > "$w/AGENTS.md"
err=$(sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" 2>&1 || true)
echo "$err" | grep -q "$w/AGENTS.md" && pass "opencode: the check names the leaking file" || fail "check did not name AGENTS.md: $err"
if sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "opencode: persona in AGENTS.md passed the check"
else
  pass "opencode: persona in AGENTS.md fails the check"
fi
printf '# Proj\nneutral instructions\n' > "$w/AGENTS.md"
if sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  pass "a neutral AGENTS.md with a loaded preamble passes again"
else
  fail "neutral worktree rejected after cleanup"
fi
rm -f "$w/.opencode/opencode.json"
err=$(sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" 2>&1 || true)
echo "$err" | grep -qi "not in OpenCode's instruction set" && pass "opencode: a missing preamble fails the check" || fail "missing preamble not reported: $err"
printf '{"instructions":["%s/pre.md"]}\n' "$w" > "$w/.opencode/opencode.json"
printf 'WORKER-PREAMBLE-TEXT\n' > "$w/.agents/rules/kingpin.md"
if sc check --harness agy --worktree "$w" --preamble "$w/.agents/rules/kingpin.md" >/dev/null 2>&1; then
  fail "agy: a rules file agy ignores passed the check"
else
  pass "agy: a rules file without a trigger fails the check"
fi
printf -- '---\ntrigger: always_on\ndescription: preamble\n---\n\nWORKER-PREAMBLE-TEXT\n' > "$w/.agents/rules/kingpin.md"
sc check --harness agy --worktree "$w" --preamble "$w/.agents/rules/kingpin.md" \
  && pass "agy: a triggered preamble passes the check" || fail "agy: triggered preamble rejected"
persona_text > "$w/.claude/rules/kingpin-orchestrator.md"
if sc check --harness claude --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "claude: the contract in .claude/rules passed the check"
else
  pass "claude: the contract in .claude/rules fails the check"
fi
rm -rf "$w"

# 4. Spawn writes the artifact each harness really reads, and refuses a leaky project
echo "=== Test 4: spawn artifacts and refusal ==="
"$KP_BIN/kingpin-spawn" demo-auto --issue 401 --id scope-oc --harness opencode >/dev/null
wt_oc=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/scope-oc/task.env")
[ -f "$wt_oc/.opencode/opencode.json" ] && pass "opencode worker gets .opencode/opencode.json" || fail "missing .opencode/opencode.json"
[ ! -e "$wt_oc/.opencode/config.json" ] && pass "opencode worker does not get the ignored .opencode/config.json" || fail "spawn wrote .opencode/config.json"
node -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const want = process.argv[2];
  process.exit(Array.isArray(cfg.instructions) && cfg.instructions.includes(want) ? 0 : 1);
' "$wt_oc/.opencode/opencode.json" "$KINGPIN_HOME/tasks/scope-oc/preamble.md" \
  && pass "opencode config loads the task preamble" || fail "opencode config does not load the preamble"
[ -z "$(git -C "$wt_oc" status --porcelain)" ] && pass "the opencode worktree stays clean" || fail "opencode worktree dirty"
"$KP_BIN/kingpin-spawn" demo-auto --issue 402 --id scope-agy --harness agy >/dev/null
wt_agy=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/scope-agy/task.env")
grep -qx "trigger: always_on" "$wt_agy/.agents/rules/kingpin.md" && pass "agy worker rules carry the trigger frontmatter" || fail "agy rules lack the trigger frontmatter"
[ -z "$(git -C "$wt_agy" status --porcelain)" ] && pass "the agy worktree stays clean" || fail "agy worktree dirty"

# A project whose tracked AGENTS.md still holds the contract: the spawn refuses, names
# the file, and leaves nothing behind.
git init -q "$T/badrepo"
persona_text > "$T/badrepo/AGENTS.md"
git -C "$T/badrepo" add AGENTS.md
git -C "$T/badrepo" -c user.email=t@t -c user.name=t commit -qm init
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/badrepo" "" > "$KINGPIN_HOME/projects/demo-bad.env"
rc=0
err=$("$KP_BIN/kingpin-spawn" demo-bad --issue 403 --id scope-bad --harness opencode 2>&1 >/dev/null) || rc=$?
[ "$rc" -ne 0 ] && pass "spawn refuses a worker whose AGENTS.md carries the contract" || fail "spawn launched a worker with the contract in AGENTS.md"
echo "$err" | grep -q "AGENTS.md" && pass "the refusal names the leaking file" || fail "refusal does not name the file: $err"
[ ! -d "$KINGPIN_HOME/tasks/scope-bad" ] && pass "the refused spawn left no task folder" || fail "refused spawn left a task folder"
! tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "scope-bad" && pass "the refused spawn opened no window" || fail "refused spawn opened a window"
"$KP_BIN/kingpin" "done" scope-oc --force >/dev/null 2>&1 || true
"$KP_BIN/kingpin" "done" scope-agy --force >/dev/null 2>&1 || true

# 5. guard install / check own the contract artifacts of the main checkout
echo "=== Test 5: guard contract install ==="
git init -q -b main "$T/grepo"
mkdir -p "$T/grepo/orchestrator"
cp "$KP_ROOT/orchestrator/contract.md" "$T/grepo/orchestrator/contract.md"
git -C "$T/grepo" add -A
git -C "$T/grepo" -c user.email=t@t -c user.name=t commit -qm init
"$KP_BIN/kingpin-guard" install --dir "$T/grepo" >/dev/null || fail "guard install failed"
for f in "$T/grepo/.claude/rules/kingpin-orchestrator.md" "$KINGPIN_HOME/orchestrator.md"; do
  cmp -s "$KP_ROOT/orchestrator/contract.md" "$f" && pass "installed contract copy: ${f#"$T"/}" || fail "missing or stale contract copy: $f"
done
grep -qx "trigger: always_on" "$T/grepo/.agents/rules/kingpin.md" && pass "the agy contract copy carries a trigger" || fail "agy contract copy lacks a trigger"
tail -n +6 "$T/grepo/.agents/rules/kingpin.md" | cmp -s - "$KP_ROOT/orchestrator/contract.md" \
  && pass "the agy contract copy carries the contract body" || fail "agy contract body differs"
node -e '
  const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit((cfg.instructions || []).includes(process.argv[2]) ? 0 : 1);
' "$T/grepo/.opencode/opencode.json" "$KINGPIN_HOME/orchestrator.md" \
  && pass "the main checkout's opencode config loads the installed contract" || fail "opencode config does not load the contract"
[ -z "$(git -C "$T/grepo" status --porcelain)" ] && pass "the contract artifacts leave the checkout clean" || fail "contract artifacts dirty the checkout"
"$KP_BIN/kingpin-guard" check --dir "$T/grepo" >/dev/null && pass "guard check passes after install" || fail "guard check failed after install"
"$KP_BIN/kingpin-guard" install --dir "$T/grepo" >/dev/null
node -e '
  const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(cfg.instructions.filter((e) => e === process.argv[2]).length === 1 ? 0 : 1);
' "$T/grepo/.opencode/opencode.json" "$KINGPIN_HOME/orchestrator.md" \
  && pass "a second install does not duplicate the instructions entry" || fail "install duplicated the instructions entry"
printf '# tampered\n' >> "$T/grepo/.claude/rules/kingpin-orchestrator.md"
err=$("$KP_BIN/kingpin-guard" check --dir "$T/grepo" 2>&1 >/dev/null || true)
echo "$err" | grep -q "kingpin-orchestrator.md" && pass "guard check names a stale contract copy" || fail "guard check ignored a stale copy: $err"
"$KP_BIN/kingpin-guard" install --dir "$T/grepo" >/dev/null
"$KP_BIN/kingpin-guard" check --dir "$T/grepo" >/dev/null && pass "install refreshes a stale contract copy" || fail "install did not refresh the copy"
# A rules file Kingpin did not write is never clobbered.
git init -q -b main "$T/ownrepo"
mkdir -p "$T/ownrepo/orchestrator" "$T/ownrepo/.agents/rules"
cp "$KP_ROOT/orchestrator/contract.md" "$T/ownrepo/orchestrator/contract.md"
printf '# my own rules\n' > "$T/ownrepo/.agents/rules/kingpin.md"
git -C "$T/ownrepo" add -A
git -C "$T/ownrepo" -c user.email=t@t -c user.name=t commit -qm init
err=$("$KP_BIN/kingpin-guard" install --dir "$T/ownrepo" 2>&1 >/dev/null || true)
echo "$err" | grep -q "was not written by Kingpin" && pass "install refuses to clobber a rules file it did not write" || fail "install clobbered a user rules file: $err"
grep -qx "# my own rules" "$T/ownrepo/.agents/rules/kingpin.md" && pass "the user's rules file is untouched" || fail "the user's rules file was rewritten"

git -C "$T/grepo" worktree add -q "$T/gwt" -b gwt
"$KP_BIN/kingpin-guard" install --dir "$T/gwt" >/dev/null 2>&1 && fail "guard installed the contract into a worker worktree" || pass "guard refuses to install the contract into a worker worktree"

# 6. The real harness, when it is installed: its own config view names the preamble
echo "=== Test 6: real OpenCode config discovery ==="
if command -v opencode >/dev/null 2>&1; then
  "$KP_BIN/kingpin-spawn" demo-auto --issue 404 --id scope-real --harness opencode >/dev/null
  wt_real=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/scope-real/task.env")
  oc_view=$(cd "$wt_real" && timeout 60 opencode debug config 2>/dev/null || true)
  if grep -q "preamble.md" <<< "$oc_view"; then
    pass "opencode loads the configured preamble according to its own config view"
  else
    fail "opencode's config view does not load the preamble"
  fi
  "$KP_BIN/kingpin" "done" scope-real --force >/dev/null 2>&1 || true
else
  pass "opencode is not installed here; skipped the harness config probe"
fi

kp_test_finish WORKER-SCOPE
