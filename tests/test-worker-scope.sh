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
# Claude Code also loads .claude/CLAUDE.md and every nested CLAUDE.md, and the
# CLAUDE.md of each ancestor directory up to $HOME (issue #96 review, L2).
printf '# project\n' > "$w/.claude/CLAUDE.md"
mkdir -p "$w/nested"
printf '# nested\n' > "$w/nested/CLAUDE.md"
sc files --harness claude --worktree "$w" > "$T/files-claude"
grep -qxF "discovery	$w/.claude/CLAUDE.md" "$T/files-claude" \
  && pass "claude: .claude/CLAUDE.md is a discovery source" || fail "claude: .claude/CLAUDE.md not listed"
grep -qxF "discovery	$w/nested/CLAUDE.md" "$T/files-claude" \
  && pass "claude: a nested CLAUDE.md is a discovery source" || fail "claude: nested CLAUDE.md not listed"
mkdir -p "$T/fakehome/proj/wt"
printf '# ancestor\n' > "$T/fakehome/proj/CLAUDE.md"
HOME=$T/fakehome "$KP_BIN/kingpin-scope" files --harness claude --worktree "$T/fakehome/proj/wt" > "$T/files-anc"
grep -qxF "discovery	$T/fakehome/proj/CLAUDE.md" "$T/files-anc" \
  && pass "claude: an ancestor CLAUDE.md is a discovery source" || fail "claude: ancestor CLAUDE.md not listed"

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
printf '# project\n' > "$w/.claude/rules/kingpin-orchestrator.md"
# The other Claude Code sources the gate has to cover (issue #96 review, L2).
persona_text > "$w/nested/CLAUDE.md"
if sc check --harness claude --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "claude: the contract in a nested CLAUDE.md passed the check"
else
  pass "claude: the contract in a nested CLAUDE.md fails the check"
fi
rm -rf "$w/nested"
printf '# project\n' > "$w/.claude/CLAUDE.md"
persona_text > "$w/.claude/CLAUDE.md"
if sc check --harness claude --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "claude: the contract in .claude/CLAUDE.md passed the check"
else
  pass "claude: the contract in .claude/CLAUDE.md fails the check"
fi
printf '# project\n' > "$w/.claude/CLAUDE.md"
persona_text > "$T/fakehome/proj/CLAUDE.md"
if HOME=$T/fakehome "$KP_BIN/kingpin-scope" check --harness claude --worktree "$T/fakehome/proj/wt" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "claude: the contract in an ancestor CLAUDE.md passed the check"
else
  pass "claude: the contract in an ancestor CLAUDE.md fails the check"
fi
printf '# ancestor\n' > "$T/fakehome/proj/CLAUDE.md"

# OpenCode accepts JSONC (comments, trailing commas): a commented project config is read,
# so a contract in its instructions cannot hide behind the comments (issue #96 review, L2).
mv "$w/.opencode/opencode.json" "$T/oc.json.bak"
printf '// the project config\n{\n  "instructions": ["pre.md",], /* the preamble */\n}\n' > "$w/.opencode/opencode.jsonc"
sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" \
  && pass "opencode: a JSONC config is read and its instructions pass the check" || fail "opencode: a JSONC config's instructions were not read"
persona_text > "$w/leak.md"
printf '// the project leaks the contract\n{\n  "instructions": ["pre.md", "leak.md",],\n}\n' > "$w/.opencode/opencode.jsonc"
if sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "opencode: the contract behind a JSONC instructions entry passed the check"
else
  pass "opencode: the contract behind a JSONC instructions entry fails the check"
fi
rm -f "$w/leak.md" "$w/.opencode/opencode.jsonc"
mv "$T/oc.json.bak" "$w/.opencode/opencode.json"

# A contract in a *global* instruction file refuses too: Kingpin cannot edit the user's
# own config, so it names the file instead of launching a worker that may wake up as the
# orchestrator (issue #96 review, M1).
mkdir -p "$XDG_CONFIG_HOME/opencode"
persona_text > "$XDG_CONFIG_HOME/opencode/AGENTS.md"
err=$(sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" 2>&1 || true)
if sc check --harness opencode --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1; then
  fail "opencode: the contract in the global AGENTS.md passed the check"
else
  pass "opencode: the contract in the global AGENTS.md fails the check"
fi
echo "$err" | grep -q "$XDG_CONFIG_HOME/opencode/AGENTS.md" \
  && pass "the refusal names the global instruction file" || fail "the global refusal does not name the file: $err"
KINGPIN_ALLOW_GLOBAL_CONTRACT=1 "$KP_BIN/kingpin-scope" check --harness opencode --worktree "$w" --preamble "$w/pre.md" >/dev/null 2>&1 \
  && pass "KINGPIN_ALLOW_GLOBAL_CONTRACT=1 downgrades a global hit to a warning" || fail "the global opt-in still refused the launch"
rm -f "$XDG_CONFIG_HOME/opencode/AGENTS.md"
rm -rf "$w"

# 3b. The pi harness: its context files, its check, and the doctor probe
echo "=== Test 3b: pi scope, check and doctor ==="
mkdir -p "$T/pihome/proj/wt/.pi" "$T/pi-agent"
printf '# ancestor\n' > "$T/pihome/proj/AGENTS.md"
printf '# proj\nneutral instructions\n' > "$T/pihome/proj/wt/AGENTS.md"
printf '@AGENTS.md\n' > "$T/pihome/proj/wt/CLAUDE.md"
printf 'APPEND\n' > "$T/pihome/proj/wt/.pi/APPEND_SYSTEM.md"
printf 'WORKER-PREAMBLE-TEXT\n' > "$T/pihome/proj/wt/pre.md"
printf '# global\n' > "$T/pi-agent/AGENTS.md"

HOME=$T/pihome "$KP_BIN/kingpin-scope" files --harness pi --worktree "$T/pihome/proj/wt" > "$T/files-pi"
grep -qxF "discovery	$T/pihome/proj/wt/AGENTS.md" "$T/files-pi" \
  && pass "pi: AGENTS.md is a discovery source" || fail "pi: worktree AGENTS.md missing"
grep -qxF "discovery	$T/pihome/proj/wt/CLAUDE.md" "$T/files-pi" \
  && pass "pi: CLAUDE.md is a discovery source" || fail "pi: worktree CLAUDE.md missing"
grep -qxF "discovery	$T/pihome/proj/AGENTS.md" "$T/files-pi" \
  && pass "pi: a parent-directory AGENTS.md is a discovery source" || fail "pi: ancestor AGENTS.md missing"
grep -qxF "configured	$T/pihome/proj/wt/.pi/APPEND_SYSTEM.md" "$T/files-pi" \
  && pass "pi: .pi/APPEND_SYSTEM.md is a configured source" || fail "pi: .pi/APPEND_SYSTEM.md missing"

HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent "$KP_BIN/kingpin-scope" files --harness pi --worktree "$T/pihome/proj/wt" > "$T/files-pi"
grep -qxF "global	$T/pi-agent/AGENTS.md" "$T/files-pi" \
  && pass "pi: a PI_CODING_AGENT_DIR instruction file is a global source" || fail "pi: global AGENTS.md missing"

# Pi loads every discovered SKILL.md, and the extension's automatic trust is what
# admits a project's own skill directory, so a contract in a skill must fail the
# check (issue #93 review, H3).
neutral_skill() {
  printf -- '---\nname: %s\ndescription: neutral skill\n---\n\nNeutral skill body.\n' "$1"
}
mkdir -p "$T/pihome/proj/wt/.agents/skills/x" "$T/pihome/proj/wt/.pi/skills/y" "$T/pi-skills/z"
neutral_skill x > "$T/pihome/proj/wt/.agents/skills/x/SKILL.md"
neutral_skill y > "$T/pihome/proj/wt/.pi/skills/y/SKILL.md"
neutral_skill z > "$T/pi-skills/z/SKILL.md"
HOME=$T/pihome KINGPIN_SKILLS_DIR=$T/pi-skills "$KP_BIN/kingpin-scope" files --harness pi --worktree "$T/pihome/proj/wt" > "$T/files-pi"
grep -qxF "configured	$T/pihome/proj/wt/.agents/skills/x/SKILL.md" "$T/files-pi" \
  && pass "pi: a project .agents/skills SKILL.md is a configured source" || fail "pi: .agents/skills SKILL.md missing"
grep -qxF "configured	$T/pihome/proj/wt/.pi/skills/y/SKILL.md" "$T/files-pi" \
  && pass "pi: a project .pi/skills SKILL.md is a configured source" || fail "pi: .pi/skills SKILL.md missing"
grep -qxF "global	$T/pi-skills/z/SKILL.md" "$T/files-pi" \
  && pass "pi: a bridged skills SKILL.md is a global source" || fail "pi: bridged SKILL.md missing"
HOME=$T/pihome KINGPIN_SKILLS_DIR=$T/pi-skills "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" \
  && pass "pi: neutral skill files pass the check" || fail "pi: neutral skill files rejected"
persona_text > "$T/pihome/proj/wt/.agents/skills/x/SKILL.md"
err=$(HOME=$T/pihome KINGPIN_SKILLS_DIR=$T/pi-skills "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" 2>&1 || true)
if HOME=$T/pihome KINGPIN_SKILLS_DIR=$T/pi-skills "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" >/dev/null 2>&1; then
  fail "pi: a contract in a project skill passed the check"
else
  pass "pi: a contract in a project skill fails the check"
fi
echo "$err" | grep -q "$T/pihome/proj/wt/.agents/skills/x/SKILL.md" \
  && pass "pi: the refusal names the leaking skill file" || fail "pi: the skill refusal does not name the file: $err"
neutral_skill x > "$T/pihome/proj/wt/.agents/skills/x/SKILL.md"
persona_text > "$T/pi-skills/z/SKILL.md"
if HOME=$T/pihome KINGPIN_SKILLS_DIR=$T/pi-skills "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" >/dev/null 2>&1; then
  fail "pi: a contract in a bridged skill passed the check"
else
  pass "pi: a contract in a bridged skill fails the check"
fi
neutral_skill z > "$T/pi-skills/z/SKILL.md"

# Pi loads two more user-level skill locations: the Agent Skills directory
# ~/.agents/skills/, and the agent directory's skills/ (issue #93 review, M3).
# Neither is a worktree path, so a contract there is a global leak the user owns:
# `check` must refuse it and name the file.
mkdir -p "$T/pihome/.agents/skills/g" "$T/pi-agent/skills/h"
neutral_skill g > "$T/pihome/.agents/skills/g/SKILL.md"
neutral_skill h > "$T/pi-agent/skills/h/SKILL.md"
HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent KINGPIN_SKILLS_DIR=$T/pi-skills \
  "$KP_BIN/kingpin-scope" files --harness pi --worktree "$T/pihome/proj/wt" > "$T/files-pi"
grep -qxF "global	$T/pihome/.agents/skills/g/SKILL.md" "$T/files-pi" \
  && pass "pi: a home .agents/skills SKILL.md is a global source" || fail "pi: home .agents/skills SKILL.md missing"
grep -qxF "global	$T/pi-agent/skills/h/SKILL.md" "$T/files-pi" \
  && pass "pi: an agent-directory skills SKILL.md is a global source" || fail "pi: agent-directory skills SKILL.md missing"
HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent KINGPIN_SKILLS_DIR=$T/pi-skills \
  "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" \
  && pass "pi: neutral user-level skill files pass the check" || fail "pi: neutral user-level skill files rejected"
persona_text > "$T/pihome/.agents/skills/g/SKILL.md"
err=$(HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent KINGPIN_SKILLS_DIR=$T/pi-skills \
  "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" 2>&1 || true)
if HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent KINGPIN_SKILLS_DIR=$T/pi-skills \
  "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" >/dev/null 2>&1; then
  fail "pi: a contract in the home .agents/skills passed the check"
else
  pass "pi: a contract in the home .agents/skills fails the check"
fi
echo "$err" | grep -q "$T/pihome/.agents/skills/g/SKILL.md" \
  && pass "pi: the refusal names the home .agents skills file" || fail "pi: the refusal does not name it: $err"
neutral_skill g > "$T/pihome/.agents/skills/g/SKILL.md"
persona_text > "$T/pi-agent/skills/h/SKILL.md"
err=$(HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent KINGPIN_SKILLS_DIR=$T/pi-skills \
  "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" 2>&1 || true)
if HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent KINGPIN_SKILLS_DIR=$T/pi-skills \
  "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" >/dev/null 2>&1; then
  fail "pi: a contract in the agent-directory skills passed the check"
else
  pass "pi: a contract in the agent-directory skills fails the check"
fi
echo "$err" | grep -q "$T/pi-agent/skills/h/SKILL.md" \
  && pass "pi: the refusal names the agent-directory skill file" || fail "pi: the refusal does not name it: $err"
neutral_skill h > "$T/pi-agent/skills/h/SKILL.md"

HOME=$T/pihome "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" \
  && pass "pi: a neutral worktree with an appended preamble passes" || fail "pi: neutral worktree rejected"
! grep -qxF "discovery	$T/pihome/proj/wt/pre.md" "$T/files-pi" \
  && pass "pi: the preamble is not a discovered source (it arrives by --append-system-prompt)" || fail "pi: the preamble was listed as a source"

persona_text > "$T/pihome/proj/wt/AGENTS.md"
err=$(HOME=$T/pihome "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" 2>&1 || true)
echo "$err" | grep -q "$T/pihome/proj/wt/AGENTS.md" \
  && pass "pi: the check names the leaking AGENTS.md" || fail "pi: check did not name AGENTS.md: $err"
if HOME=$T/pihome "$KP_BIN/kingpin-scope" check --harness pi --worktree "$T/pihome/proj/wt" --preamble "$T/pihome/proj/wt/pre.md" >/dev/null 2>&1; then
  fail "pi: a contract in AGENTS.md passed the check"
else
  pass "pi: a contract in AGENTS.md fails the check"
fi
printf '# proj\nneutral instructions\n' > "$T/pihome/proj/wt/AGENTS.md"

# The doctor probe, driven by a stub: no pi binary is installed and no network is used.
cat > "$T/pi-ready" << 'PIREADY'
#!/usr/bin/env bash
case "${1:-}" in
  auth) printf '%s' '{"status":"ready","provider":"openrouter","authType":"api_key"}'; exit 0 ;;
esac
exit 1
PIREADY
cat > "$T/pi-notready" << 'PINOTREADY'
#!/usr/bin/env bash
case "${1:-}" in
  auth) printf '%s' '{"status":"not_ready","provider":"openrouter","reason":"credentials_not_configured"}'; exit 1 ;;
esac
exit 1
PINOTREADY
chmod +x "$T/pi-ready" "$T/pi-notready"

dr_rc=0
dr_out=$(HOME=$T/pihome KINGPIN_PI=$T/pi-ready "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" --provider openrouter 2>&1) || dr_rc=$?
[ "$dr_rc" -eq 0 ] && pass "doctor: a ready host exits 0" || fail "doctor ready rc=$dr_rc: $dr_out"
echo "$dr_out" | grep -q "^pi: $T/pi-ready$" && pass "doctor: prints the pi binary" || fail "doctor binary line: $dr_out"
echo "$dr_out" | grep -q "^credentials: ready (openrouter, api_key)$" && pass "doctor: prints ready credentials" || fail "doctor credentials line: $dr_out"
echo "$dr_out" | grep -q "^skills: " && pass "doctor: prints the skills directory" || fail "doctor skills line: $dr_out"
echo "$dr_out" | grep -q "^extension: .*worker/pi/kingpin-harness.ts$" && pass "doctor: prints the extension path" || fail "doctor extension line: $dr_out"
echo "$dr_out" | grep -q "^discovery	$T/pihome/proj/wt/AGENTS.md$" && pass "doctor: prints the source list too" || fail "doctor source list: $dr_out"

# Pi discovers a SKILL.md recursively, so a skill pack nested deeper than a direct
# child still counts (issue #93 review, L5).
mkdir -p "$T/doctor-skills/pack/one"
neutral_skill one > "$T/doctor-skills/pack/one/SKILL.md"
nested_rc=0
nested_out=$(HOME=$T/pihome KINGPIN_SKILLS_DIR=$T/doctor-skills KINGPIN_PI=$T/pi-ready \
  "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" --provider openrouter 2>&1) || nested_rc=$?
[ "$nested_rc" -eq 0 ] && echo "$nested_out" | grep -qxF "skills: $T/doctor-skills (1 skills)" \
  && pass "doctor: counts a nested SKILL.md recursively" || fail "doctor nested skill rc=$nested_rc: $nested_out"

notready_rc=0
notready_out=$(HOME=$T/pihome KINGPIN_PI=$T/pi-notready "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" --provider openrouter 2>&1) || notready_rc=$?
[ "$notready_rc" -eq 1 ] && echo "$notready_out" | grep -q "^credentials: not_ready (credentials_not_configured)$" \
  && pass "doctor: not_ready exits 1 and names the reason" || fail "doctor not_ready rc=$notready_rc: $notready_out"

unverified_rc=0
unverified_out=$(HOME=$T/pihome KINGPIN_PI=$T/pi-ready "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" 2>&1) || unverified_rc=$?
[ "$unverified_rc" -eq 0 ] && echo "$unverified_out" | grep -q "^credentials: unverified (no provider; .*holds no credentials" \
  && pass "doctor: no provider reports unverified, names the missing login and exits 0" || fail "doctor unverified rc=$unverified_rc: $unverified_out"

# The provider and model fall back to the project env the spawn reads (issue #93
# review, M1): the short form must check the pair the worker would launch with.
cat > "$T/pi-args" << 'PIARGS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${PI_ARGS_LOG:?}"
case "${1:-}" in
  auth) printf '%s' '{"status":"ready","provider":"openrouter","authType":"api_key"}'; exit 0 ;;
esac
exit 1
PIARGS
chmod +x "$T/pi-args"
env_rc=0
env_out=$(HOME=$T/pihome PI_PROVIDER=openrouter PI_MODEL=anthropic/claude-sonnet-4.5 PI_ARGS_LOG=$T/pi-args.log \
  KINGPIN_PI=$T/pi-args "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" 2>&1) || env_rc=$?
[ "$env_rc" -eq 0 ] && echo "$env_out" | grep -q "^credentials: ready (openrouter, api_key)$" \
  && pass "doctor: PI_PROVIDER from the environment is honoured" || fail "doctor env provider rc=$env_rc: $env_out"
grep -qx -- "--model" "$T/pi-args.log" && grep -qx -- "anthropic/claude-sonnet-4.5" "$T/pi-args.log" \
  && pass "doctor: PI_MODEL from the environment reaches pi auth check" || fail "doctor env model args: $(cat "$T/pi-args.log" 2>/dev/null)"

# A host with no login and a logged-in host must not print the same line. Pi writes an
# empty auth.json before the first login, so the empty object is still "no credentials".
mkdir -p "$T/pihome/.pi/agent"
printf '{}\n' > "$T/pihome/.pi/agent/auth.json"
empty_rc=0
empty_out=$(HOME=$T/pihome KINGPIN_PI=$T/pi-ready "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" 2>&1) || empty_rc=$?
[ "$empty_rc" -eq 0 ] && echo "$empty_out" | grep -q "holds no credentials" \
  && pass "doctor: an empty auth.json still reads as no login" || fail "doctor empty auth rc=$empty_rc: $empty_out"
printf '{"openrouter": {"type": "api_key"}}\n' > "$T/pihome/.pi/agent/auth.json"
login_rc=0
login_out=$(HOME=$T/pihome KINGPIN_PI=$T/pi-ready "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" 2>&1) || login_rc=$?
[ "$login_rc" -eq 0 ] && echo "$login_out" | grep -q "holds credentials" \
  && pass "doctor: a credential-bearing auth.json differs from a logged-out host" || fail "doctor logged-in rc=$login_rc: $login_out"
echo "$login_out" | grep -q "holds no credentials" && fail "doctor: a logged-in host still reports no credentials" || pass "doctor: the logged-in line does not claim no credentials"
# PI_CODING_AGENT_DIR moves where that file is read from.
agent_rc=0
agent_out=$(HOME=$T/pihome PI_CODING_AGENT_DIR=$T/pi-agent-login KINGPIN_PI=$T/pi-ready \
  "$KP_BIN/kingpin-scope" doctor --harness pi --worktree "$T/pihome/proj/wt" 2>&1) || agent_rc=$?
echo "$agent_out" | grep -q "holds no credentials" \
  && pass "doctor: PI_CODING_AGENT_DIR moves the auth.json it reads" || fail "doctor agent dir rc=$agent_rc: $agent_out"
rm -rf "$T/pihome/.pi"

# The issue's short form: no subcommand, with the harness.
short_rc=0
short_out=$(HOME=$T/pihome KINGPIN_PI=$T/pi-ready "$KP_BIN/kingpin-scope" --harness pi --provider openrouter --worktree "$T/pihome/proj/wt" 2>&1) || short_rc=$?
[ "$short_rc" -eq 0 ] && echo "$short_out" | grep -q "^credentials: ready (openrouter, api_key)$" \
  && pass "scope --harness pi with no subcommand runs the doctor" || fail "short doctor rc=$short_rc: $short_out"

missing_rc=0
missing_out=$(KINGPIN_PI=/nonexistent "$KP_BIN/kingpin-scope" doctor --harness pi 2>&1) || missing_rc=$?
[ "$missing_rc" -eq 1 ] && echo "$missing_out" | grep -q "^pi: MISSING " \
  && pass "doctor: a missing binary exits 1 and says MISSING" || fail "doctor missing rc=$missing_rc: $missing_out"

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

# A config the project already has in the worktree is merged into, never truncated: its
# own keys and instructions survive and the preamble is added once (issue #96 review, M2).
cat > "$T/setup-ocmerge.sh" << 'MERGE'
mkdir -p .opencode
printf '{"theme": "dark", "instructions": ["docs/own.md"]}\n' > .opencode/opencode.json
MERGE
chmod +x "$T/setup-ocmerge.sh"
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/proj" "$T/setup-ocmerge.sh" > "$KINGPIN_HOME/projects/demo-ocmerge.env"
"$KP_BIN/kingpin-spawn" demo-ocmerge --issue 405 --id scope-ocmerge --harness opencode >/dev/null
wt_merge=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/scope-ocmerge/task.env")
node -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const want = process.argv[2];
  const ok = cfg.theme === "dark" &&
    Array.isArray(cfg.instructions) &&
    cfg.instructions.includes("docs/own.md") &&
    cfg.instructions.filter((e) => e === want).length === 1;
  process.exit(ok ? 0 : 1);
' "$wt_merge/.opencode/opencode.json" "$KINGPIN_HOME/tasks/scope-ocmerge/preamble.md" \
  && pass "spawn merges the preamble into an existing opencode config" || fail "spawn truncated the existing opencode config"
[ -z "$(git -C "$wt_merge" status --porcelain)" ] && pass "the merged opencode worktree stays clean" || fail "merged opencode worktree dirty"

# A tracked opencode config cannot be hidden by an ignore rule, so rewriting it would start
# the worker on a dirty tree it could commit: the spawn refuses and names the file.
git init -q -b main "$T/ocrepo"
mkdir -p "$T/ocrepo/.opencode"
printf '{"instructions": ["docs/team.md"]}\n' > "$T/ocrepo/.opencode/opencode.json"
git -C "$T/ocrepo" add -A
git -C "$T/ocrepo" -c user.email=t@t -c user.name=t commit -qm init
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/ocrepo" "" > "$KINGPIN_HOME/projects/demo-ocbad.env"
rc=0
err=$("$KP_BIN/kingpin-spawn" demo-ocbad --issue 406 --id scope-ocbad --harness opencode 2>&1 >/dev/null) || rc=$?
[ "$rc" -ne 0 ] && pass "spawn refuses a project that tracks .opencode/opencode.json" || fail "spawn rewrote a tracked opencode config"
echo "$err" | grep -q "opencode.json is tracked" && pass "the refusal names the tracked config" || fail "the refusal does not name it: $err"
[ ! -d "$KINGPIN_HOME/tasks/scope-ocbad" ] && pass "the refused tracked-config spawn left no task folder" || fail "the refused spawn left a task folder"
! tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "scope-ocbad" && pass "the refused tracked-config spawn opened no window" || fail "the refused spawn opened a window"

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
"$KP_BIN/kingpin" "done" scope-ocmerge --force >/dev/null 2>&1 || true

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
# A stale copy is the contract, not the hook, so the warning must not blame the guard (L4).
err=$(env -u KINGPIN_SKIP_GUARD "$KP_BIN/kingpin-guard" warn --dir "$T/grepo" 2>&1 || true)
echo "$err" | grep -q "orchestrator contract is stale" && pass "warn names a stale contract instead of the guard" || fail "warn blamed the guard hook: $err"
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

# A JSONC opencode config is valid for OpenCode and not plain JSON: the install refuses
# it before it writes a copy, so a failed install cannot leave the contract untracked
# (issue #96 review, M3).
git init -q -b main "$T/jsoncrepo"
mkdir -p "$T/jsoncrepo/orchestrator" "$T/jsoncrepo/.opencode"
cp "$KP_ROOT/orchestrator/contract.md" "$T/jsoncrepo/orchestrator/contract.md"
printf '{\n  // the project documents itself\n  "instructions": ["docs/team.md"]\n}\n' > "$T/jsoncrepo/.opencode/opencode.json"
git -C "$T/jsoncrepo" add -A
git -C "$T/jsoncrepo" -c user.email=t@t -c user.name=t commit -qm init
err=$("$KP_BIN/kingpin-guard" install --dir "$T/jsoncrepo" 2>&1 >/dev/null || true)
echo "$err" | grep -q "not plain JSON" && pass "guard install rejects a JSONC opencode config" || fail "guard install did not reject JSONC: $err"
[ ! -e "$T/jsoncrepo/.claude/rules/kingpin-orchestrator.md" ] && pass "the rejected install wrote no contract copy" || fail "the rejected install left a contract copy"
grep -q "// the project documents itself" "$T/jsoncrepo/.opencode/opencode.json" && pass "the rejected install left the config untouched" || fail "the rejected install rewrote the config"
[ -z "$(git -C "$T/jsoncrepo" status --porcelain)" ] && pass "the rejected install leaves the checkout clean" || fail "the rejected install dirtied the checkout"
# `guard check` (and so `kingpin list` / `guard warn`) names a config it cannot read
# instead of printing a Node stack trace (issue #96 review, L1).
err=$("$KP_BIN/kingpin-guard" check --dir "$T/jsoncrepo" 2>&1 >/dev/null || true)
echo "$err" | grep -q "is not valid JSON" && pass "guard check names an unparseable opencode config" || fail "guard check did not name it: $err"
echo "$err" | grep -q "SyntaxError" && fail "guard check printed a Node stack trace" || pass "guard check prints no Node stack trace"

# A config that parses but has the wrong shape fails in the JSON step, after the copies
# are written: each copy is excluded as it is written, so the failure leaves no untracked
# contract the operator could commit (issue #96 review, M3).
git init -q -b main "$T/shaperepo"
mkdir -p "$T/shaperepo/orchestrator" "$T/shaperepo/.opencode"
cp "$KP_ROOT/orchestrator/contract.md" "$T/shaperepo/orchestrator/contract.md"
printf '{"instructions": "docs/team.md"}\n' > "$T/shaperepo/.opencode/opencode.json"
git -C "$T/shaperepo" add -A
git -C "$T/shaperepo" -c user.email=t@t -c user.name=t commit -qm init
err=$("$KP_BIN/kingpin-guard" install --dir "$T/shaperepo" 2>&1 >/dev/null || true)
echo "$err" | grep -q 'must be a JSON array' && pass "guard install rejects a wrong-shaped instructions value" || fail "guard install accepted it: $err"
[ -f "$T/shaperepo/.claude/rules/kingpin-orchestrator.md" ] && pass "the JSON step runs after the copies are written" || fail "the copies were never written"
[ -z "$(git -C "$T/shaperepo" status --porcelain)" ] && pass "a late install failure leaves the copies excluded" || fail "a late install failure left untracked copies"

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
