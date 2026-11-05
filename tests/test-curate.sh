#!/usr/bin/env bash
# Verification test for Kingpin: kingpin curate: --help, dry run, failing and succeeding curators,
# trust recording, dead-window reaping, quote robustness.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "curate"
kp_test_project

# Test 8: kingpin curate lifecycle and quote robustness
echo "=== Test 8: kingpin curate lifecycle ==="
export KINGPIN_SKILLS_DIR=$T/skills
mkdir -p "$T/skills" "$KINGPIN_HOME/tasks/test-curate-1" "$KINGPIN_HOME/archive/test-curate-2"

# The applied marker's target check reads the skills origin and asks gh which
# repository and branch the PR belongs to, so the fixture is a real checkout with
# a GitHub origin and a gh stub. The origin names GitHub while an insteadOf
# rewrite keeps every fetch on a local bare repo, so no test reaches the network.
# The stub answers with the branch the curator record names.
git init -q --bare "$T/skills-origin.git"
git clone -q "$T/skills-origin.git" "$T/skills" 2>/dev/null
(
  cd "$T/skills" || exit 1
  git checkout -q -b main
  echo "# Skills" > SKILL.md
  git add SKILL.md
  git commit -qm "init"
  git push -q -u origin main
)
git -C "$T/skills" remote set-url origin https://github.com/laanhema/skills.git
git -C "$T/skills" config "url.$T/skills-origin.git.insteadOf" https://github.com/laanhema/skills.git
cat > "$T/bin/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  "pr view "*"--json baseRepository,headRefName"*)
    branch=$(sed -n 's/^BRANCH=//p' "${KINGPIN_HOME:?}/tasks/curator/task.env" 2>/dev/null | tail -n 1)
    printf 'laanhema/skills %s\n' "${branch:-main}"
    ;;
  "pr view "*"--json state"*) echo MERGED ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$T/bin/gh"
export KINGPIN_GH=$T/bin/gh

# A successful run leaves a live curator record awaiting review, and the next
# manual run must not overwrite it, so each round clears it the way an operator
# does once the PR is dealt with.
finish_curator_record() {
  "$KP_BIN/kingpin" "done" curator >/dev/null 2>&1 || true
}

tricky_critique="Special critique: 'single' and \"double\" and \$(echo subshell)"
echo "$tricky_critique" > "$KINGPIN_HOME/tasks/test-curate-1/critique"
echo "Simple archive critique" > "$KINGPIN_HOME/archive/test-curate-2/critique"

# 8.0 --help and an unknown flag must not launch a curator (issue #79)
cat > "$T/fake-curator-record" << EOF_REC
#!/usr/bin/env bash
printf 'argv=%s\n' "\$*" >> "$T/curator-calls.txt"
exit 0
EOF_REC
chmod +x "$T/fake-curator-record"
export KINGPIN_CURATOR_CMD="$T/fake-curator-record"

help_rc=0
help_out=$("$KP_BIN/kingpin" curate --help 2>&1) || help_rc=$?
[ "$help_rc" -eq 0 ] && pass "curate --help exits 0" || fail "curate --help exit=$help_rc"
echo "$help_out" | grep -q "^Usage: kingpin curate" && pass "curate --help prints usage" || fail "curate --help output: $help_out"
! tmux list-panes -t kingpin:curator >/dev/null 2>&1 && pass "curate --help launched no curator window" || fail "curate --help launched a curator window"
[ ! -f "$T/curator-calls.txt" ] && pass "curate --help ran no curator" || fail "curate --help ran the curator"

bad_rc=0
"$KP_BIN/kingpin" curate --bogus >/dev/null 2>"$T/bad-flag.err" || bad_rc=$?
[ "$bad_rc" -eq 2 ] && pass "curate --bogus exits 2" || fail "curate --bogus exit=$bad_rc"
grep -q "unknown argument" "$T/bad-flag.err" && pass "curate --bogus names the bad argument" || fail "curate --bogus stderr: $(cat "$T/bad-flag.err")"
[ ! -f "$T/curator-calls.txt" ] && pass "curate --bogus ran no curator" || fail "curate --bogus ran the curator"

# 8.1 Dry-run inspection: the previous run's inputs must survive byte for byte
mkdir -p "$KINGPIN_HOME/curator"
printf 'input sentinel\n' > "$KINGPIN_HOME/curator/curator-input.txt"
printf 'batch sentinel\n' > "$KINGPIN_HOME/curator/batch-critiques.txt"
printf 'launch sentinel\n' > "$KINGPIN_HOME/curator/launch.sh"
cp "$KINGPIN_HOME/curator/curator-input.txt" "$T/dry-input.before"
cp "$KINGPIN_HOME/curator/batch-critiques.txt" "$T/dry-batch.before"
cp "$KINGPIN_HOME/curator/launch.sh" "$T/dry-launch.before"
dry_curate_out=$("$KP_BIN/kingpin" curate --dry-run)
echo "$dry_curate_out" | grep -q "dry-run, 2 task(s) have pending critiques:" && pass "curate --dry-run listed pending count" || fail "curate --dry-run wrong output: $dry_curate_out"
[ -f "$KINGPIN_HOME/tasks/test-curate-1/critique" ] && [ -f "$KINGPIN_HOME/archive/test-curate-2/critique" ] && pass "dry-run preserved critique files" || fail "dry-run modified critique files"
cmp -s "$T/dry-input.before" "$KINGPIN_HOME/curator/curator-input.txt" && pass "dry-run left curator-input.txt byte-identical" || fail "dry-run rewrote curator-input.txt"
cmp -s "$T/dry-batch.before" "$KINGPIN_HOME/curator/batch-critiques.txt" && pass "dry-run left batch-critiques.txt byte-identical" || fail "dry-run rewrote batch-critiques.txt"
cmp -s "$T/dry-launch.before" "$KINGPIN_HOME/curator/launch.sh" && pass "dry-run left launch.sh byte-identical" || fail "dry-run rewrote launch.sh"

# 8.2 Failing curator leaves critiques pending and delivers quotes verbatim
cat > "$T/fake-curator-fail" << EOF_FAIL
#!/usr/bin/env bash
cat > "$T/curator-received.txt"
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

# 8.2a A failed run consumes nothing, so the next run replays its critiques
fail_replay=$("$KP_BIN/kingpin" curate --dry-run)
echo "$fail_replay" | grep -q "dry-run, 2 task(s) have pending critiques:" && pass "critiques pending after a failed run are replayed" || fail "failed-run critiques were not replayed: $fail_replay"
echo "$fail_replay" | grep -q -- "--- Task test-curate-1 ---" && echo "$fail_replay" | grep -q -- "--- Task test-curate-2 ---" && pass "the post-failure replay names both tasks" || fail "post-failure replay did not name both tasks: $fail_replay"

# 8.2b Trust for the skills dir is recorded before claude could hit the dialog
node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const dir = process.argv[2];
process.exit(cfg.projects && cfg.projects[dir] && cfg.projects[dir].hasTrustDialogAccepted === true ? 0 : 1);
' "$CLAUDE_CONFIG_DIR/.claude.json" "$(realpath "$KINGPIN_SKILLS_DIR")" \
  && pass "curate recorded claude trust for the skills dir" || fail "curate did not record claude trust for the skills dir"

# 8.2b2 A fresh config directory with no .claude.json still records trust (L1)
fresh_cfg="$T/cfg-fresh"
rm -rf "$fresh_cfg"
fresh_rc=0
fresh_out=$(CLAUDE_CONFIG_DIR="$fresh_cfg" "$KP_BIN/kingpin" curate 2>&1) || fresh_rc=$?
[ "$fresh_rc" -eq 0 ] && pass "curate survives a missing claude config store" || fail "curate with an empty CLAUDE_CONFIG_DIR exit=$fresh_rc: $fresh_out"
node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const dir = process.argv[2];
process.exit(cfg.projects && cfg.projects[dir] && cfg.projects[dir].hasTrustDialogAccepted === true ? 0 : 1);
' "$fresh_cfg/.claude.json" "$(realpath "$KINGPIN_SKILLS_DIR")" \
  && pass "curate created the store and recorded trust in it" || fail "curate did not record trust in a fresh config store"
# Let that failing curator's window close before the live-window test below.
for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done

# 8.2c A live curator is refused and left alone
cat > "$T/fake-curator-live" << EOF_LIVE
#!/usr/bin/env bash
: > "$T/curator-live-ran.txt"
exit 0
EOF_LIVE
chmod +x "$T/fake-curator-live"
export KINGPIN_CURATOR_CMD="$T/fake-curator-live"
tmux new-window -d -t kingpin: -n curator "sleep 300"
live_rc=0
live_err=$("$KP_BIN/kingpin" curate 2>&1 >/dev/null) || live_rc=$?
[ "$live_rc" -eq 1 ] && pass "live curator is refused with exit 1" || fail "live curator exit=$live_rc"
echo "$live_err" | grep -q "already active" && pass "live curator refusal names the active window" || fail "live curator stderr: $live_err"
[ ! -f "$T/curator-live-ran.txt" ] && pass "refused run launched no curator" || fail "refused run still launched a curator"
tmux list-panes -t kingpin:curator >/dev/null 2>&1 && pass "live curator window survived the refused run" || fail "refused run killed the live curator window"
[ -d "$KINGPIN_HOME/tasks/curator" ] && pass "the refused run left the stale curator record for a later reconcile" || fail "the refused run reconciled the stale record away"
tmux kill-window -t kingpin:curator 2>/dev/null || true

# 8.2d A curator whose launch.sh exited is reaped instead of blocking the next run
cat > "$T/fake-curator-reap" << EOF_REAP
#!/usr/bin/env bash
cat > "$T/curator-reap-received.txt"
exit 1
EOF_REAP
chmod +x "$T/fake-curator-reap"
export KINGPIN_CURATOR_CMD="$T/fake-curator-reap"
# remain-on-exit is what leaves a failed launch sitting in the window; without
# it tmux closes the window and the guard never sees it.
tmux set-option -g remain-on-exit on
tmux new-window -d -t kingpin: -n curator "bash -c 'exit 3'"
dead=0
for _ in $(seq 1 40); do
  dead=$(tmux list-panes -t kingpin:curator -F '#{pane_dead}' 2>/dev/null || echo 0)
  [ "$dead" = "1" ] && break
  sleep 0.1
done
[ "$dead" = "1" ] && pass "dead curator pane staged (pane_dead=1)" || fail "could not stage a dead curator pane"
reap_rc=0
reap_out=$("$KP_BIN/kingpin" curate 2>&1) || reap_rc=$?
[ "$reap_rc" -eq 0 ] && pass "curate reaped the dead curator window and continued" || fail "curate after a dead window exit=$reap_rc: $reap_out"
echo "$reap_out" | grep -q "reaped dead curator window" && pass "dead-window reap is reported" || fail "reap not reported: $reap_out"
for _ in $(seq 1 40); do
  [ -f "$T/curator-reap-received.txt" ] && break
  sleep 0.1
done
[ -f "$T/curator-reap-received.txt" ] && grep -qF "$tricky_critique" "$T/curator-reap-received.txt" && pass "new curator launched after the reap" || fail "no curator launched after the reap"
tmux set-option -g remain-on-exit off
tmux kill-window -t kingpin:curator 2>/dev/null || true

# 8.2e A curator reaped mid-run leaves its critiques pending
mkdir -p "$KINGPIN_HOME/tasks/test-curate-reaped"
echo "Reaped critique" > "$KINGPIN_HOME/tasks/test-curate-reaped/critique"
cat > "$T/fake-curator-sleep" << 'EOF_SLEEP'
#!/usr/bin/env bash
sleep 300
EOF_SLEEP
chmod +x "$T/fake-curator-sleep"
export KINGPIN_CURATOR_CMD="$T/fake-curator-sleep"
"$KP_BIN/kingpin" curate >/dev/null
tmux list-panes -t kingpin:curator >/dev/null 2>&1 || fail "sleeping curator window did not start"
tmux kill-window -t kingpin:curator 2>/dev/null || true
reaped_replay=$("$KP_BIN/kingpin" curate --dry-run)
echo "$reaped_replay" | grep -q "dry-run, 3 task(s) have pending critiques:" && pass "a reaped run leaves its critique pending" || fail "reaped run consumed its critique: $reaped_replay"
echo "$reaped_replay" | grep -q -- "--- Task test-curate-reaped ---" && pass "the reaped critique is replayed" || fail "reaped critique missing from the replay: $reaped_replay"

# 8.3 Succeeding curator archives critiques upon opening the PR
cat > "$T/fake-curator-success" << EOF_SUCC
#!/usr/bin/env bash
url="https://github.com/laanhema/skills/pull/7"
printf '%s\n' "\$url" > "$KINGPIN_HOME/curator/pr"
$KP_BIN/kingpin-curate --mark-applied "\$url"
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
pr_marker=""
for f in "$KINGPIN_HOME/tasks/test-curate-1"/critique.applied.*.pr; do
  [ -f "$f" ] && pr_marker=$f && break
done
[ -n "$pr_marker" ] && grep -qxF "https://github.com/laanhema/skills/pull/7" "$pr_marker" && pass "the applied marker records the PR URL" || fail "critique.applied.*.pr missing or wrong: ${pr_marker:-none}"

# 8.3a A successful run consumes its critiques, so the next run replays nothing
success_replay=$("$KP_BIN/kingpin" curate --dry-run)
echo "$success_replay" | grep -q "no pending skill critiques" && pass "a successful run's critiques are not replayed" || fail "successful-run critiques replayed: $success_replay"

# 8.3b A new critique in a consumed task is not hidden by the old stamp
echo "A later critique for the same task" > "$KINGPIN_HOME/tasks/test-curate-1/critique"
later_out=$("$KP_BIN/kingpin" curate --dry-run)
echo "$later_out" | grep -q "dry-run, 1 task(s) have pending critiques:" && pass "a new critique beside a consumed stamp is collected" || fail "the consumed stamp hid a new critique: $later_out"
echo "$later_out" | grep -q -- "--- Task test-curate-1 ---" && pass "the later critique is named in the replay" || fail "later critique missing from the replay: $later_out"
rm -f "$KINGPIN_HOME/tasks/test-curate-1/critique"
finish_curator_record

# 8.3c A task archived mid-run (what kingpin done does) is still consumed
mkdir -p "$KINGPIN_HOME/tasks/test-curate-3"
echo "Archived mid-run critique" > "$KINGPIN_HOME/tasks/test-curate-3/critique"
cat > "$T/fake-curator-slow" << EOF_SLOW
#!/usr/bin/env bash
sleep 2
url="https://github.com/laanhema/skills/pull/3"
printf '%s\n' "\$url" > "$KINGPIN_HOME/curator/pr"
$KP_BIN/kingpin-curate --mark-applied "\$url"
exit 0
EOF_SLOW
chmod +x "$T/fake-curator-slow"
export KINGPIN_CURATOR_CMD="$T/fake-curator-slow"
"$KP_BIN/kingpin" curate >/dev/null
launched=0
for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 && { launched=1; break; }
  sleep 0.1
done
[ "$launched" -eq 1 ] && pass "slow curator window is up before the archive" || fail "slow curator window did not start"
mv "$KINGPIN_HOME/tasks/test-curate-3" "$KINGPIN_HOME/archive/test-curate-3"
for _ in $(seq 1 80); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done
[ -f "$KINGPIN_HOME/archive/test-curate-3/critique.consumed" ] && pass "the archived critique carries a consumed stamp" || fail "no consumed stamp beside the archived critique"
[ ! -f "$KINGPIN_HOME/archive/test-curate-3/critique" ] && pass "the archived critique was archived after the run" || fail "archived critique still pending after a successful run"
archive_replay=$("$KP_BIN/kingpin" curate --dry-run)
echo "$archive_replay" | grep -q "no pending skill critiques" && pass "an archived consumed critique is not replayed" || fail "archived critique replayed: $archive_replay"
finish_curator_record

# 8.3d A critique rewritten mid-run is not consumed and is collected next time
mkdir -p "$KINGPIN_HOME/tasks/test-curate-4"
printf 'critique A: first version\n' > "$KINGPIN_HOME/tasks/test-curate-4/critique"
cat > "$T/fake-curator-midrun" << EOF_MIDRUN
#!/usr/bin/env bash
sleep 2
url="https://github.com/laanhema/skills/pull/4"
printf '%s\n' "\$url" > "$KINGPIN_HOME/curator/pr"
$KP_BIN/kingpin-curate --mark-applied "\$url"
exit 0
EOF_MIDRUN
chmod +x "$T/fake-curator-midrun"
export KINGPIN_CURATOR_CMD="$T/fake-curator-midrun"
"$KP_BIN/kingpin" curate >/dev/null
launched=0
for _ in $(seq 1 40); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 && { launched=1; break; }
  sleep 0.1
done
[ "$launched" -eq 1 ] && pass "mid-run curator window is up before the rewrite" || fail "mid-run curator window did not start"
printf 'critique B: rewritten while the curator ran\n' > "$KINGPIN_HOME/tasks/test-curate-4/critique"
for _ in $(seq 1 80); do
  tmux list-panes -t kingpin:curator >/dev/null 2>&1 || break
  sleep 0.1
done
[ ! -f "$KINGPIN_HOME/tasks/test-curate-4/critique.consumed" ] && pass "a critique rewritten mid-run is not stamped consumed" || fail "mid-run rewrite was stamped consumed"
[ -f "$KINGPIN_HOME/tasks/test-curate-4/critique" ] && pass "a critique rewritten mid-run stays pending" || fail "mid-run rewrite was renamed applied"
midrun_replay=$("$KP_BIN/kingpin" curate --dry-run)
echo "$midrun_replay" | grep -q "dry-run, 1 task(s) have pending critiques:" && pass "the mid-run rewrite is collected by the next dry run" || fail "mid-run rewrite was not collected: $midrun_replay"
echo "$midrun_replay" | grep -qF "critique B: rewritten while the curator ran" && pass "the replay carries the rewritten critique" || fail "replay did not carry the rewrite: $midrun_replay"
rm -rf "$KINGPIN_HOME/tasks/test-curate-4"
finish_curator_record

# 8.4 Empty check
empty_curate_out=$("$KP_BIN/kingpin" curate)
echo "$empty_curate_out" | grep -q "no pending skill critiques" && pass "curate reports no pending skill critiques" || fail "curate did not report empty"

kp_test_finish CURATE
