#!/usr/bin/env bash
# Verification test for the Pi worker extension (lib/pi-harness.mjs): the turn-end
# stop call, the skills bridge, and the per-worktree trust answer.
#
# No `pi` binary and no network: the Pi API is a fake object that records handlers,
# and every case runs under plain `node`. tests/test-harnesses.sh covers the launch
# argv with a stub binary; this suite covers what the handlers do.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "pi-harness"

export PI_MODULE="file://$KP_ROOT/lib/pi-harness.mjs"
export HOME="$T/fakehome"
mkdir -p "$HOME"

# The fake Pi API records one handler per event; the driver then invokes the one
# the case names, exactly as Pi would at that point in the session.
cat > "$T/drive.mjs" << 'DRIVER'
const { registerPiHarness } = await import(process.env.PI_MODULE);
const api = {
  handlers: {},
  on(event, handler) {
    this.handlers[event] = handler;
  },
};
registerPiHarness(api, process.env);
const mode = process.argv[2];
if (mode === "discover") {
  const result = await api.handlers.resources_discover({ cwd: process.cwd(), reason: "startup" }, {});
  console.log(JSON.stringify(result.skillPaths));
} else if (mode === "settled") {
  await api.handlers.agent_settled({}, {});
  console.log("settled-ok");
} else if (mode === "trust") {
  const result = await api.handlers.project_trust({ cwd: process.argv[3] || "" }, {});
  console.log(JSON.stringify(result));
}
DRIVER

# Test 1: resources_discover bridges the skills directory
echo "=== Test 1: skills bridge ==="
mkdir -p "$T/skills"
out=$(env -u KINGPIN_SKILLS_DIR KINGPIN_SKILLS_DIR="$T/skills" node "$T/drive.mjs" discover)
[ "$out" = "[\"$T/skills\"]" ] && pass "resources_discover returns KINGPIN_SKILLS_DIR" || fail "skills dir: $out"

out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR node "$T/drive.mjs" discover)
[ "$out" = "[\"$HOME/.claude/skills\"]" ] && pass "resources_discover defaults to ~/.claude/skills" || fail "default skills dir: $out"

# Test 2: agent_settled runs the shared stop hook
echo "=== Test 2: turn end runs bin/kingpin-stop ==="
mkdir -p "$T/root/bin" "$T/task"
cat > "$T/root/bin/kingpin-stop" << 'STOP'
#!/usr/bin/env bash
printf 'task=%s root=%s\n' "${KINGPIN_TASK_DIR:-}" "${KINGPIN_ROOT:-}" > "${STOP_MARKER:?}"
STOP
chmod +x "$T/root/bin/kingpin-stop"

out=$(env -u KINGPIN_WORKTREE -u KINGPIN_SKILLS_DIR \
  KINGPIN_TASK_DIR="$T/task" KINGPIN_ROOT="$T/root" STOP_MARKER="$T/stop-marker" \
  node "$T/drive.mjs" settled)
[ "$out" = "settled-ok" ] && pass "agent_settled returns without throwing" || fail "settled output: $out"
[ "$(cat "$T/stop-marker" 2>/dev/null)" = "task=$T/task root=$T/root" ] \
  && pass "agent_settled invokes the fixture stop script with the task env" || fail "stop marker: $(cat "$T/stop-marker" 2>/dev/null)"
grep -q "agent_settled" "$T/task/harness-events.log" 2>/dev/null \
  && pass "the event log records agent_settled" || fail "no agent_settled breadcrumb"

# Test 3: no task dir, no stop call
echo "=== Test 3: no task dir means no stop call ==="
rm -f "$T/stop-marker"
kp_run out rc env -u KINGPIN_TASK_DIR -u KINGPIN_SKILLS_DIR -u KINGPIN_WORKTREE \
  KINGPIN_ROOT="$T/root" STOP_MARKER="$T/stop-marker" \
  node "$T/drive.mjs" settled
[ "$rc" -eq 0 ] && [ "$out" = "settled-ok" ] && pass "agent_settled without a task dir exits 0" || fail "rc=$rc out=$out"
[ ! -e "$T/stop-marker" ] && pass "no stop script runs without KINGPIN_TASK_DIR" || fail "the stop script ran without a task dir"

# Test 4: a missing root or a failing hook warns, never throws
echo "=== Test 4: the stop call fails soft ==="
kp_run out rc env -u KINGPIN_SKILLS_DIR -u KINGPIN_WORKTREE -u KINGPIN_ROOT \
  KINGPIN_TASK_DIR="$T/task" \
  node "$T/drive.mjs" settled
[ "$rc" -eq 0 ] && echo "$out" | grep -q "settled-ok" && pass "an unset KINGPIN_ROOT does not throw" || fail "unset root rc=$rc out=$out"
echo "$out" | grep -q "stop hook unavailable (KINGPIN_ROOT unset)" && pass "an unset KINGPIN_ROOT is named on stderr" || fail "no warning for an unset root: $out"

kp_run out rc env -u KINGPIN_SKILLS_DIR -u KINGPIN_WORKTREE \
  KINGPIN_TASK_DIR="$T/task" KINGPIN_ROOT="$T/no-root" \
  node "$T/drive.mjs" settled
[ "$rc" -eq 0 ] && pass "a missing kingpin-stop does not throw" || fail "missing binary rc=$rc out=$out"
echo "$out" | grep -q "stop hook failed" && pass "a missing kingpin-stop is named on stderr" || fail "no warning for a missing binary: $out"

mkdir -p "$T/root-fail/bin"
cat > "$T/root-fail/bin/kingpin-stop" << 'FAIL'
#!/usr/bin/env bash
echo "the stop script failed on purpose" >&2
exit 1
FAIL
chmod +x "$T/root-fail/bin/kingpin-stop"
kp_run out rc env -u KINGPIN_SKILLS_DIR -u KINGPIN_WORKTREE \
  KINGPIN_TASK_DIR="$T/task" KINGPIN_ROOT="$T/root-fail" \
  node "$T/drive.mjs" settled
[ "$rc" -eq 0 ] && pass "a failing stop hook does not throw" || fail "failing hook rc=$rc out=$out"
echo "$out" | grep -q "stop hook failed" && pass "a failing stop hook is named on stderr" || fail "no warning for a failing hook: $out"

# Test 5: project_trust answers yes for the leased worktree only
echo "=== Test 5: trust is scoped to the worktree ==="
mkdir -p "$T/wt/nested"
out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR \
  KINGPIN_WORKTREE="$T/wt" node "$T/drive.mjs" trust "$T/wt/nested")
[ "$out" = '{"trusted":"yes"}' ] && pass "a cwd under the worktree is trusted" || fail "nested trust: $out"

out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR \
  KINGPIN_WORKTREE="$T/wt" node "$T/drive.mjs" trust "$T/wt")
[ "$out" = '{"trusted":"yes"}' ] && pass "the worktree root itself is trusted" || fail "root trust: $out"

out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR \
  KINGPIN_WORKTREE="$T/wt" node "$T/drive.mjs" trust "$T/elsewhere")
[ "$out" = '{"trusted":"undecided"}' ] && pass "a cwd outside the worktree is undecided" || fail "outside trust: $out"

out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR -u KINGPIN_WORKTREE \
  node "$T/drive.mjs" trust "$T/wt")
[ "$out" = '{"trusted":"undecided"}' ] && pass "no KINGPIN_WORKTREE means undecided" || fail "unset worktree trust: $out"

# A prefix that only looks like the worktree is not inside it (a sibling name).
mkdir -p "$T/wt-other"
out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR \
  KINGPIN_WORKTREE="$T/wt" node "$T/drive.mjs" trust "$T/wt-other")
[ "$out" = '{"trusted":"undecided"}' ] && pass "a sibling with the worktree's name as a prefix is undecided" || fail "sibling trust: $out"

# A symlink into the worktree resolves to the worktree, so it is trusted.
ln -s "$T/wt/nested" "$T/link-into-wt"
out=$(env -u KINGPIN_SKILLS_DIR -u KINGPIN_TASK_DIR \
  KINGPIN_WORKTREE="$T/wt" node "$T/drive.mjs" trust "$T/link-into-wt")
[ "$out" = '{"trusted":"yes"}' ] && pass "a symlink into the worktree is trusted on its realpath" || fail "symlink trust: $out"

kp_test_finish PI-HARNESS
