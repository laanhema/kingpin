#!/usr/bin/env bash
# Verification test for Kingpin: kingpin curate: dry run, failing and succeeding curators, quote robustness.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "curate"
kp_test_project

# Test 8: kingpin curate lifecycle and quote robustness
echo "=== Test 8: kingpin curate lifecycle ==="
export KINGPIN_SKILLS_DIR=$T/skills
mkdir -p "$T/skills" "$KINGPIN_HOME/tasks/test-curate-1" "$KINGPIN_HOME/archive/test-curate-2"

tricky_critique="Special critique: 'single' and \"double\" and \$(echo subshell)"
echo "$tricky_critique" > "$KINGPIN_HOME/tasks/test-curate-1/critique"
echo "Simple archive critique" > "$KINGPIN_HOME/archive/test-curate-2/critique"

# 8.1 Dry-run inspection
dry_curate_out=$("$KP_BIN/kingpin" curate --dry-run)
echo "$dry_curate_out" | grep -q "dry-run, 2 task(s) have pending critiques:" && pass "curate --dry-run listed pending count" || fail "curate --dry-run wrong output: $dry_curate_out"
[ -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "dry-run preserved critique files" || fail "dry-run modified critique files"

# 8.2 Failing curator leaves critiques pending and delivers quotes verbatim
cat > "$T/fake-curator-fail" << EOF_FAIL
#!/usr/bin/env bash
printf "%s\n" "\$1" > "$T/curator-received.txt"
exit 1
EOF_FAIL
chmod +x "$T/fake-curator-fail"

export KINGPIN_CURATOR_CMD="$T/fake-curator-fail"
"$KP_BIN/kingpin" curate >/dev/null

for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done

[ -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "failing curator left critiques pending" || fail "failing curator archived critiques"
[ -f "$T/curator-received.txt" ] && grep -qF "$tricky_critique" "$T/curator-received.txt" && pass "critique reached curator verbatim with special quotes and subshell" || fail "critique text corrupted or not received"

# 8.3 Succeeding curator archives critiques upon writing curator-result
cat > "$T/fake-curator-success" << EOF_SUCC
#!/usr/bin/env bash
echo "applied: updated skill definition" > "$KINGPIN_HOME/curator-result"
exit 0
EOF_SUCC
chmod +x "$T/fake-curator-success"

export KINGPIN_CURATOR_CMD="$T/fake-curator-success"
"$KP_BIN/kingpin" curate >/dev/null

for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done

[ ! -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ ! -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "succeeding curator archived pending critiques" || fail "critiques still pending after success"
ls "$KINGPIN_HOME/tasks/test-curate-1"/critique.applied.* >/dev/null 2>&1 && ls "$KINGPIN_HOME/archive/test-curate-2"/critique.applied.* >/dev/null 2>&1 && pass "applied archive files created" || fail "missing critique.applied.* files"

# 8.4 Empty check
empty_curate_out=$("$KP_BIN/kingpin" curate)
echo "$empty_curate_out" | grep -q "no pending skill critiques" && pass "curate reports no pending skill critiques" || fail "curate did not report empty"

kp_test_finish CURATE
