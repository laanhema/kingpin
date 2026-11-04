#!/usr/bin/env bash
# Verification test for Kingpin: kingpin restore, the DEAD list state, and the shared
# window resolver after a tmux server restart (issue #149).
#
# The suite has two fixture families. A task that `kingpin spawn` leased has a real
# worktree, a real treehouse lease and a real launch.sh, so the happy path runs the
# production code end to end. A hand-made task record with a controlled worktree and a
# `treehouse` stub on PATH drives the refusals, --force and --dry-run, where the point
# is what restore declines to do.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "restore"
kp_test_project

# The fake harness: prints every line it reads, appends one status line when it is
# asked to report, and stays on stdin like a real TUI. It ignores its argv. It runs on
# node, not on a shell, so `#{pane_current_command}` really does stop being a plain
# shell name once a placeholder window is reclaimed.
cat > "$T/fake-harness" << 'F'
#!/usr/bin/env node
const fs = require("fs");
const readline = require("readline");
const taskDir = process.env.KINGPIN_TASK_DIR || "";
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  console.log(`got: ${line}`);
  if (line === "report" && taskDir) {
    fs.appendFileSync(`${taskDir}/status`, `waiting: test ${taskDir}\n`);
  }
});
F
chmod +x "$T/fake-harness"
export KINGPIN_AGY=$T/fake-harness

env_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# The restart every case starts from: the private tmux server dies, a fresh one starts
# with the home window, exactly what an operator sees after tmux crashes.
restart_tmux() {
  tmux kill-server 2>/dev/null || true
  # A new-session that races the dying server prints "server exited unexpectedly" and
  # exits 1: wait for the socket to be gone, then start the fresh server with a retry.
  for _ in $(seq 1 50); do
    tmux list-sessions >/dev/null 2>&1 || break
    sleep 0.05
  done
  for _ in $(seq 1 20); do
    tmux new-session -d -s kingpin -n home 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

window_named() { tmux list-windows -t kingpin -F '#{window_name}' 2>/dev/null | grep -qxF -- "$1"; }

pane_has_line() { # <window-name> <wanted line>
  local want=$2
  for _ in $(seq 1 50); do
    tmux capture-pane -pJt "kingpin:=$1" -S -200 2>/dev/null | grep -qxF -- "$want" && return 0
    sleep 0.1
  done
  return 1
}

waited_line() { # <file> <wanted line>: poll a file for one exact line
  local want=$2
  for _ in $(seq 1 50); do
    grep -qxF -- "$want" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

snapshot() { # <dir>: a stable listing of every path and file content
  ( cd "$1" && find . -type f | sort | xargs sha256sum; find . | sort )
}

spawn_task() { # <id>
  "$KP_BIN/kingpin-spawn" demo-auto --issue 149 --id "$1" --harness agy >/dev/null
  printf '%s\n' "$KINGPIN_HOME/tasks/$1"
}

# ---------------------------------------------------------------------------
# Test 1: a gone window is recreated in its own worktree and on its own branch
echo "=== Test 1: a gone window comes back in its worktree and branch ==="
r1=$(spawn_task r1)
r1_env="$r1/task.env"
r1_wt=$(env_get "$r1_env" WORKTREE)
r1_branch=$(env_get "$r1_env" BRANCH)
r1_stale=$(env_get "$r1_env" TMUX_WINDOW_ID)
cp "$r1/status" "$T/r1.status.before"
restart_tmux
# A filler window takes the first free id, so the restored window cannot land on the
# stale one by accident: the assertion below is about the record, not about luck.
tmux new-window -d -t kingpin: -n filler 'exec cat' >/dev/null
r1_rc=0
r1_out=$("$KP_BIN/kingpin" restore r1 2>"$T/r1.err") || r1_rc=$?
[ "$r1_rc" -eq 0 ] && pass "restore exits 0 for a live task whose window is gone" || fail "restore exited $r1_rc: $(cat "$T/r1.err")"
window_named r1 && pass "restore created a window named after the task" || fail "no window named r1 after restore"
r1_new=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="r1"{print $1}')
r1_now=$(env_get "$r1_env" TMUX_WINDOW_ID)
[ -n "$r1_new" ] && [ "$r1_now" = "$r1_new" ] && pass "restore recorded the new window id ($r1_new)" || fail "record says '$r1_now', window is '$r1_new'"
[ "$r1_now" != "$r1_stale" ] && pass "the recorded id differs from the stale one ($r1_stale -> $r1_now)" || fail "the recorded id is still the stale $r1_stale"
r1_path=$(tmux display-message -p -t "$r1_new" '#{pane_current_path}')
r1_wt_real=$(cd "$r1_wt" && pwd -P)
[ "$r1_path" = "$r1_wt_real" ] && pass "the window runs in the task's own worktree" || fail "pane path '$r1_path' is not '$r1_wt_real'"
r1_branch_now=$(git -C "$r1_wt" branch --show-current)
[ "$r1_branch_now" = "$r1_branch" ] && pass "the worktree is still on the task's branch ($r1_branch)" || fail "branch '$r1_branch_now' is not '$r1_branch'"
r1_pane_pid=$(tmux list-panes -t "$r1_new" -F '#{pane_pid}' | head -n 1)
[ "$(cat "$r1/harness.pid" 2>/dev/null || true)" = "$r1_pane_pid" ] && pass "harness.pid is the pane pid" || fail "harness.pid '$(cat "$r1/harness.pid" 2>/dev/null || true)' is not the pane pid '$r1_pane_pid'"
cmp -s "$r1/status" "$T/r1.status.before" && pass "restore leaves the status file byte-identical" || fail "restore changed the status file"
echo "$r1_out" | grep -q "^OK: restored r1 (agy) in kingpin:r1 ($r1_new) on $r1_branch" \
  && pass "the OK line names the id, harness, window, id and branch" \
  || fail "restore OK line: $r1_out"

# ---------------------------------------------------------------------------
# Test 2: a same-named placeholder is respawned in place, keeping its id
echo "=== Test 2: a resurrected placeholder is reclaimed, not duplicated ==="
r2=$(spawn_task r2)
r2_env="$r2/task.env"
r2_wt=$(env_get "$r2_env" WORKTREE)
restart_tmux
r2_ph=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n r2 'exec bash')
r2_rc=0
"$KP_BIN/kingpin" restore r2 >/dev/null 2>"$T/r2.err" || r2_rc=$?
[ "$r2_rc" -eq 0 ] && pass "restore exits 0 for a placeholder window" || fail "restore exited $r2_rc: $(cat "$T/r2.err")"
r2_same=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="r2"{print $1}')
[ "$r2_same" = "$r2_ph" ] && pass "the placeholder window id survived ($r2_ph)" || fail "window id changed ($r2_ph -> '$r2_same')"
[ "$(tmux list-windows -t kingpin -F '#{window_name}' | grep -cxF r2)" = "1" ] && pass "exactly one window carries the task's name" || fail "duplicate r2 windows"
r2_cmd=$(tmux list-panes -t "$r2_ph" -F '#{pane_current_command}' | head -n 1)
case $r2_cmd in bash|sh|zsh|dash|ksh|fish) fail "the pane still runs a plain shell ($r2_cmd)";; *) pass "the pane no longer runs a plain shell ($r2_cmd)";; esac
r2_pane_pid=$(tmux list-panes -t "$r2_ph" -F '#{pane_pid}' | head -n 1)
[ "$(cat "$r2/harness.pid" 2>/dev/null || true)" = "$r2_pane_pid" ] && pass "harness.pid follows the respawned pane" || fail "harness.pid does not match the new pane pid"
[ "$(env_get "$r2_env" TMUX_WINDOW_ID)" = "$r2_ph" ] && pass "the record keeps the reclaimed window id" || fail "record id '$(env_get "$r2_env" TMUX_WINDOW_ID)' is not '$r2_ph'"
git -C "$r2_wt" status --porcelain | grep -qv '^$' && fail "restore left the worktree dirty: $(git -C "$r2_wt" status --porcelain)" || pass "the restored worktree is clean"

# ---------------------------------------------------------------------------
# Test 3: a stale id that names a foreign window is not followed
echo "=== Test 3: a stale id that names another window is not followed ==="
r3=$(spawn_task r3)
r3_env="$r3/task.env"
r3_stale=$(env_get "$r3_env" TMUX_WINDOW_ID)
restart_tmux
claimed=''
for _ in $(seq 1 40); do
  w=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "throwaway-$RANDOM" 'exec cat')
  if [ "$w" = "$r3_stale" ]; then claimed=$w; break; fi
done
[ -n "$claimed" ] && pass "a throwaway window now carries the stale id ($r3_stale)" || fail "could not give the stale id to a throwaway window"
claimed_before=$(tmux capture-pane -pJt "$claimed" -S -50 2>/dev/null || true)
r3_rc=0
"$KP_BIN/kingpin" restore r3 >/dev/null 2>"$T/r3.err" || r3_rc=$?
[ "$r3_rc" -eq 0 ] && pass "restore exits 0 for a task whose stale id was taken" || fail "restore exited $r3_rc: $(cat "$T/r3.err")"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin" send r3 report >/dev/null
pane_has_line r3 'got: report' && pass "kingpin send reaches the task's own pane" || fail "the task's pane never printed 'got: report'"
claimed_after=$(tmux capture-pane -pJt "$claimed" -S -50 2>/dev/null || true)
[ "$claimed_before" = "$claimed_after" ] && pass "the window holding the stale id was left untouched" || fail "the stale id's window received the text"
r3_new=$(env_get "$r3_env" TMUX_WINDOW_ID)
[ "$r3_new" != "$r3_stale" ] && pass "restore repaired the recorded id ($r3_stale -> $r3_new)" || fail "the record still names the stale $r3_stale"

# ---------------------------------------------------------------------------
# Test 4: a second restore starts nothing twice
echo "=== Test 4: a second restore never starts a second harness ==="
r3_pid_before=$(cat "$r3/harness.pid")
r4_rc=0
r4_out=$("$KP_BIN/kingpin" restore r3 2>&1) || r4_rc=$?
[ "$r4_rc" -eq 0 ] && pass "a repeat restore exits 0" || fail "repeat restore exited $r4_rc: $r4_out"
echo "$r4_out" | grep -q "^OK: r3 is already live" && pass "a repeat restore reports the task as already live" || fail "repeat restore output: $r4_out"
[ "$(tmux list-windows -t kingpin -F '#{window_name}' | grep -cxF r3)" = "1" ] && pass "the task still has exactly one window" || fail "repeat restore created a second window"
[ "$(cat "$r3/harness.pid")" = "$r3_pid_before" ] && pass "the harness pid is unchanged" || fail "repeat restore replaced the harness pid"
# Test 2 restarted the server after r1 was restored, so one no-argument run brings r1
# back; a second one then has nothing left to do.
"$KP_BIN/kingpin" restore >/dev/null 2>&1 || true
r4_all=$("$KP_BIN/kingpin" restore 2>&1) || true
echo "$r4_all" | grep -qE "^OK: 0 restored, [0-9]+ already live$" && pass "restore with no ids restores nothing a second time" || fail "no-argument restore output: $r4_all"
for id in r1 r2 r3; do
  [ "$(tmux list-windows -t kingpin -F '#{window_name}' | grep -cxF "$id")" = "1" ]     && pass "$id still has exactly one window after a second fleet-wide restore"     || fail "$id has more than one window after a second fleet-wide restore"
done

# ---------------------------------------------------------------------------
# Test 5: the send round trip and the status protocol work on a restored task
echo "=== Test 5: send, peek and wait work on a restored task ==="
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin" send r1 report >/dev/null
waited_line "$r1/status" "waiting: test $r1" && pass "the restored harness appended its status line" || fail "no status line from the restored harness: $(cat "$r1/status")"
r5_peek=$("$KP_BIN/kingpin" peek r1 --lines 20)
echo "$r5_peek" | grep -qxF 'got: report' && pass "kingpin peek prints the restored pane" || fail "peek output: $r5_peek"
r5_wait=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$r5_wait" | grep -q '^r1 status$' && pass "kingpin wait reports the restored task's status event" || fail "wait output: $r5_wait"

# ---------------------------------------------------------------------------
# Test 6: the resume brief says where the work stands and what to do next
echo "=== Test 6: the resume brief maps the last status line to a next step ==="
r6=$(spawn_task r6)
r6_env="$r6/task.env"
r6_wt=$(env_get "$r6_env" WORKTREE)
r6_branch=$(env_get "$r6_env" BRANCH)
printf 'ready: branch=%s review=APPROVE report=%s/report.html\n' "$r6_branch" "$r6" > "$r6/status"
r7=$(spawn_task r7)
printf 'fixed: high=0 report=%s/report.html\n' "$r7" > "$r7/status"
mkdir -p "$KINGPIN_HOME/projects"
printf 'r7\n' > "$KINGPIN_HOME/projects/demo-auto.landing"
: > "$r7/landing_sent"
restart_tmux
"$KP_BIN/kingpin" restore r6 >/dev/null 2>"$T/r6.err" || fail "restore r6 failed: $(cat "$T/r6.err")"
"$KP_BIN/kingpin" restore r7 >/dev/null 2>"$T/r7.err" || fail "restore r7 failed: $(cat "$T/r7.err")"
brief="$r6/resume-prompt.txt"
grep -qF "Task id: r6" "$brief" && pass "the brief names the task" || fail "brief: $(cat "$brief")"
grep -qF "Worktree: $r6_wt" "$brief" && pass "the brief names the worktree" || fail "brief does not name the worktree"
grep -qF "Branch: $r6_branch" "$brief" && pass "the brief names the branch" || fail "brief does not name the branch"
grep -qF "Last status line: ready: branch=$r6_branch review=APPROVE" "$brief" && pass "the brief carries the last status line" || fail "brief does not carry the last status line"
grep -qF "the review stands" "$brief" && pass "a ready: task's brief says the review stands" || fail "brief for a ready: task: $(cat "$brief")"
grep -qF "$r6/report.html" "$brief" && pass "the brief points at the dossier" || fail "brief does not name the dossier"
grep -qF "Never run kingpin spawn, lock, land, done, listen or send" "$brief" && pass "the brief repeats the house rules" || fail "brief does not repeat the house rules"
r7_brief="$r7/resume-prompt.txt"
grep -qF "never re-run kingpin land" "$r7_brief" && pass "a landing-lane task's brief says the merge may already have happened" || fail "brief for the landing holder: $(cat "$r7_brief")"
grep -qF "resume-prompt.txt" "$r6/launch.sh" && ! grep -qF "/prompt.txt" "$r6/launch.sh" \
  && pass "launch.sh reads the resume brief, not the original prompt" \
  || fail "launch.sh prompt path: $(grep -c . "$r6/launch.sh") lines"

# ---------------------------------------------------------------------------
# Test 7: a task that cannot be brought back is refused and left alone
echo "=== Test 7: restore refuses by name and changes nothing ==="
# A controlled pool: the stub answers `status --json` (and anything else) with the JSON
# in KP_TEST_TREEHOUSE_STATUS. The real binary is needed for the spawns above and is put
# back by the cleanup, so this stub only lives for the refusal and --force cases.
cat > "$T/bin/treehouse" << 'TREESTUB'
#!/usr/bin/env bash
case "${1:-}" in
  status) cat "${KP_TEST_TREEHOUSE_STATUS:?}" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
TREESTUB
chmod +x "$T/bin/treehouse"
export KP_TEST_TREEHOUSE_STATUS=$T/treehouse-status.json
mk_fixture() { # <id> <worktree> [extra KEY=value...]
  local id=$1 wt=$2
  shift 2
  local d="$KINGPIN_HOME/tasks/$id" kv
  mkdir -p "$d"
  {
    printf 'TASK_ID=%s\n' "$id"
    printf 'PROJECT=demo-auto\n'
    printf 'PROJECT_PATH=%s\n' "$T/proj"
    printf 'HARNESS=agy\nMODE=review\n'
    printf 'WORKTREE=%s\n' "$wt"
    printf 'TMUX_TARGET=kingpin:%s\n' "$id"
    printf 'CREATED=%s\n' "$(date -Iseconds)"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$d/task.env"
  : > "$d/status"
  printf '%s\n' "$d"
}
# A real linked worktree for the cases that must reach the lease check.
git -C "$T/proj" worktree add -q -b kingpin/t-fixture "$T/fixture-wt" main
fixture_wt_real=$(cd "$T/fixture-wt" && pwd -P)
leased_json() { printf '[{"name":"1","path":"%s","status":"leased","branch":"kingpin/t-fixture"}]\n' "$fixture_wt_real" > "$KP_TEST_TREEHOUSE_STATUS"; }
available_json() { printf '[{"name":"1","path":"%s","status":"available","branch":"kingpin/t-fixture"}]\n' "$fixture_wt_real" > "$KP_TEST_TREEHOUSE_STATUS"; }
refuse_case() { # <id> <expected reason fragment> <setup function>
  local id=$1 want=$2 setup=$3 d="$KINGPIN_HOME/tasks/$1" before rc=0 err
  before=$(snapshot "$d")
  "$setup" >/dev/null 2>&1 || true
  err=$("$KP_BIN/kingpin" restore "$id" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -eq 1 ] && pass "$id: restore exits 1" || fail "$id: restore exited $rc"
  printf '%s' "$err" | grep -q "refused $id:" && pass "$id: the refusal names the task" || fail "$id: stderr: $err"
  printf '%s' "$err" | grep -qF -- "$want" && pass "$id: the refusal says '$want'" || fail "$id: refusal does not say '$want': $err"
  window_named "$id" && fail "$id: a window was created" || pass "$id: no window was created"
  [ "$(snapshot "$d")" = "$before" ] && pass "$id: the task folder is unchanged" || fail "$id: the task folder changed"
}
available_json
d=$(mk_fixture t-no-wt "$T/no-such-worktree"); printf 'issue: #149\n' > "$d/status"
refuse_case t-no-wt "worktree missing" true
rm -rf "$d"
d=$(mk_fixture t-available "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
refuse_case t-available "no longer leased" available_json
rm -rf "$d"
d=$(mk_fixture t-curator "$T/fixture-wt" "NO_LEASE=1"); printf 'issue: #149\n' > "$d/status"
refuse_case t-curator "curator task; run kingpin curate" leased_json
rm -rf "$d"
d=$(mk_fixture t-merged "$T/fixture-wt"); printf 'merged: pr=https://example.invalid/pr/1\n' > "$d/status"
refuse_case t-merged "run kingpin done t-merged" leased_json
rm -rf "$d"
d=$(mk_fixture t-failed "$T/fixture-wt"); printf 'failed: a gate stopped the run\n' > "$d/status"
refuse_case t-failed "spawn a new task" leased_json
rm -rf "$d"

# ---------------------------------------------------------------------------
# Test 8: --force covers the advisory refusals only
echo "=== Test 8: --force proceeds on advisory refusals, never on a missing worktree ==="
# A task whose harness is really in its window: no --force means leave it alone.
leased_json
d=$(mk_fixture t-live "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
t_live_win=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n t-live -c "$T/fixture-wt" 'exec sleep 300')
t_live_pid=$(tmux list-panes -t "$t_live_win" -F '#{pane_pid}' | head -n 1)
printf '%s\n' "$t_live_pid" > "$d/harness.pid"
t_live_out=$("$KP_BIN/kingpin" restore t-live 2>&1) || true
echo "$t_live_out" | grep -q "^OK: t-live is already live" && pass "a task whose harness is in its window is left alone" || fail "restore output: $t_live_out"
[ "$(tmux list-panes -t "$t_live_win" -F '#{pane_current_command}')" = sleep ] && pass "its pane was not replaced" || fail "the live pane was replaced without --force"
t_live_frc=$("$KP_BIN/kingpin" restore t-live --force 2>&1) || fail "restore --force failed: $t_live_frc"
echo "$t_live_frc" | grep -q "^OK: restored t-live" && pass "--force restores a task that still looks alive" || fail "--force output: $t_live_frc"
t_live_new_pid=$(tmux list-panes -t "$t_live_win" -F '#{pane_pid}' | head -n 1)
[ "$t_live_new_pid" != "$t_live_pid" ] && pass "--force replaced the pane process" || fail "--force left the same pane pid"
[ "$(cat "$d/harness.pid")" = "$t_live_new_pid" ] && pass "--force recorded the new harness pid" || fail "--force did not record the pane pid"
rm -rf "$d"
# An unverifiable lease proceeds with --force.
available_json
d=$(mk_fixture t-forced "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
t_forced_rc=0
"$KP_BIN/kingpin" restore t-forced --force >/dev/null 2>"$T/t-forced.err" || t_forced_rc=$?
[ "$t_forced_rc" -eq 0 ] && pass "--force restores a task whose lease cannot be verified" || fail "--force exited $t_forced_rc: $(cat "$T/t-forced.err")"
window_named t-forced && pass "the forced restore created its window" || fail "no window for t-forced"
rm -rf "$d"
# A missing worktree stays refused even with --force.
d=$(mk_fixture t-no-wt-force "$T/no-such-worktree"); printf 'issue: #149\n' > "$d/status"
t_no_wt_rc=0
t_no_wt_err=$("$KP_BIN/kingpin" restore t-no-wt-force --force 2>&1 >/dev/null) || t_no_wt_rc=$?
[ "$t_no_wt_rc" -eq 1 ] && printf '%s' "$t_no_wt_err" | grep -q "worktree missing" \
  && pass "--force still refuses a missing worktree" \
  || fail "--force on a missing worktree: rc=$t_no_wt_rc: $t_no_wt_err"
rm -rf "$d"

# ---------------------------------------------------------------------------
# Test 9: --dry-run prints the plan and writes nothing
echo "=== Test 9: --dry-run writes nothing ==="
leased_json
d=$(mk_fixture t-dry "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
cp "$d/task.env" "$T/t-dry.env.before"
t_dry_out=$("$KP_BIN/kingpin" restore t-dry --dry-run 2>&1) || fail "dry run failed: $t_dry_out"
echo "$t_dry_out" | grep -q "^would restore t-dry (agy) in kingpin:t-dry on kingpin/t-fixture" \
  && pass "--dry-run prints the planned restore" \
  || fail "dry-run output: $t_dry_out"
window_named t-dry && fail "--dry-run created a window" || pass "--dry-run created no window"
cmp -s "$d/task.env" "$T/t-dry.env.before" && pass "--dry-run leaves task.env byte-identical" || fail "--dry-run rewrote task.env"
[ ! -e "$d/launch.sh" ] && [ ! -e "$d/resume-prompt.txt" ] && pass "--dry-run writes no launch files" || fail "--dry-run wrote launch files"
rm -rf "$d"

# ---------------------------------------------------------------------------
# Test 10: kingpin list marks a live task whose window is gone DEAD
echo "=== Test 10: list shows DEAD and the restore hint ==="
rm -f "$T/bin/treehouse"
# Every task back on the fleet first, so the only dead window is the fixture below.
restart_tmux
"$KP_BIN/kingpin" restore >/dev/null 2>&1 || fail "restoring the whole fleet for the list case failed"
d=$(mk_fixture t-dead "$T/fixture-wt"); printf 'needs-input: which option?\n' > "$d/status"
list_out=$("$KP_BIN/kingpin" list 2>/dev/null)
row=$(grep '^t-dead ' <<< "$list_out" || true)
grep -q 'DEAD' <<< "$row" && pass "a task whose window is gone shows DEAD" || fail "t-dead row: $row"
grep -q '^Fleet: 1 live task(s) have no live window; run kingpin restore$' <<< "$list_out" \
  && pass "list prints the restore hint" \
  || fail "no restore hint in: $list_out"
rm -rf "$d"
list_out=$("$KP_BIN/kingpin" list 2>/dev/null)
! grep -q '^Fleet:' <<< "$list_out" && pass "the hint disappears once no live task is dead" || fail "stale restore hint: $list_out"
r1_row=$(grep '^r1 ' <<< "$list_out" || true)
[ -n "$r1_row" ] && ! grep -q 'DEAD' <<< "$r1_row" && pass "a task with a live harness does not show DEAD" || fail "r1 row: $r1_row"

# ---------------------------------------------------------------------------

kp_test_finish RESTORE
