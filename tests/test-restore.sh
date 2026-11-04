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

# The fake harness: answers `session list` from the fixture the case wrote, records the
# argv a launch really received (one word per line, so the resume brief is readable as
# text), prints every line it reads, appends one status line when it is asked to report,
# and stays on stdin like a real TUI. It runs on node, not on a shell, so
# `#{pane_current_command}` really does stop being a plain shell name once a placeholder
# window is reclaimed.
cat > "$T/fake-harness" << 'F'
#!/usr/bin/env node
const fs = require("fs");
const readline = require("readline");
const args = process.argv.slice(2);
const taskDir = process.env.KINGPIN_TASK_DIR || "";
if (args[0] === "session" && args[1] === "list") {
  const fixture = process.env.KP_TEST_OPENCODE_SESSIONS;
  if (!fixture || !fs.existsSync(fixture)) process.exit(1);
  let text = fs.readFileSync(fixture, "utf8");
  // Honor `-n` like the real listing does, so a case can exceed the requested cap.
  const capAt = args.indexOf("-n");
  const cap = capAt === -1 ? NaN : Number(args[capAt + 1]);
  if (Number.isFinite(cap)) {
    let rows = null;
    try { rows = JSON.parse(text); } catch {}
    if (Array.isArray(rows)) text = JSON.stringify(rows.slice(0, cap));
  }
  process.stdout.write(text, () => process.exit(0));
}
if (taskDir) fs.writeFileSync(`${taskDir}/fake-argv`, args.join("\n"));
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  console.log(`got: ${line}`);
  if (line === "report" && taskDir) {
    fs.appendFileSync(`${taskDir}/status`, `waiting: test ${taskDir}\n`);
  }
});
F
chmod +x "$T/fake-harness"
export KINGPIN_AGY=$T/fake-harness
# The pi harness stand-in for the provider/model case and the opencode/claude stand-ins
# for the session cases: the launch script the restore generates is the assertion, and no
# real harness binary is needed.
export KINGPIN_PI=$T/fake-harness
export KINGPIN_OPENCODE=$T/fake-harness
export KINGPIN_CLAUDE=$T/fake-harness

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

# wait_for_pane_command <window-id> <command>: a fresh pane reports `tmux` for a moment
# before its command settles, and the shell-name fallback in lib/tmux.sh reads that
# value, so a case about a plain-shell window waits for the shell first.
wait_for_pane_command() {
  local win=$1 want=$2
  for _ in $(seq 1 50); do
    [ "$(tmux list-panes -t "$win" -F '#{pane_current_command}' 2>/dev/null | head -n 1)" = "$want" ] && return 0
    sleep 0.05
  done
  return 1
}

snapshot() { # <dir>: a stable listing of every path and file content
  ( cd "$1" && find . -type f | sort | xargs sha256sum; find . | sort )
}

set_sessions() { # <json>: the rows the fake harness answers `session list` with
  printf '%s\n' "$1" > "$T/opencode-sessions.json"
  export KP_TEST_OPENCODE_SESSIONS=$T/opencode-sessions.json
}

session_json() { # <directory> <updated-epoch-seconds> <id> <title>: one fixture row
  printf '{"id":"%s","title":"%s","updated":%s,"directory":"%s"}' "$3" "$4" "$(( $2 * 1000 ))" "$1"
}

fake_argv_has() { waited_line "$1/fake-argv" "$2"; }

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
echo "$r1_out" | grep -qF "started a new session (agy cannot report an existing session)" \
  && pass "the OK line says agy cannot report an existing session" \
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
# back by the cleanup, so this stub only lives for the refusal and --force cases. A later
# case that installs it again calls treehouse_stub (test 10 removes it).
export KP_TEST_TREEHOUSE_STATUS=$T/treehouse-status.json
treehouse_stub() {
  cat > "$T/bin/treehouse" << 'TREESTUB'
#!/usr/bin/env bash
case "${1:-}" in
  status) cat "${KP_TEST_TREEHOUSE_STATUS:?}" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
TREESTUB
  chmod +x "$T/bin/treehouse"
}
treehouse_stub
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
    printf 'TMUX_SOCKET=%s\n' "$KINGPIN_TMUX_SOCKET"
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
# Test 11: a legacy record with no harness.pid is DEAD from the pane's command alone
echo "=== Test 11: list marks a shell window DEAD without a harness.pid ==="
"$KP_BIN/kingpin" restore >/dev/null 2>&1 || fail "restoring the fleet for the legacy DEAD case failed"
d=$(mk_fixture k-legacy "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
k_legacy_win=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n k-legacy 'exec bash')
wait_for_pane_command "$k_legacy_win" bash || fail "the k-legacy window never settled on a shell"
d=$(mk_fixture k-mismatch "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
tmux new-window -d -t kingpin: -n k-mismatch 'exec sleep 300' >/dev/null
# A live pid that is not the pane pid: the recorded harness is not in the window.
printf '%s\n' "$$" > "$KINGPIN_HOME/tasks/k-mismatch/harness.pid"
# A live record with no status file at all: DEAD must not depend on the status guard.
d=$(mk_fixture k-statusless "$T/fixture-wt")
rm -f "$d/status"
k_statusless_win=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n k-statusless 'exec bash')
wait_for_pane_command "$k_statusless_win" bash || fail "the k-statusless window never settled on a shell"
list_out=$("$KP_BIN/kingpin" list 2>/dev/null)
row=$(grep '^k-legacy ' <<< "$list_out" || true)
grep -q 'DEAD' <<< "$row" && pass "a record with no harness.pid whose window runs a shell shows DEAD" || fail "k-legacy row: $row"
row=$(grep '^k-mismatch ' <<< "$list_out" || true)
grep -q 'DEAD' <<< "$row" && pass "a harness.pid outside the pane shows DEAD" || fail "k-mismatch row: $row"
row=$(grep '^k-statusless ' <<< "$list_out" || true)
grep -q 'DEAD' <<< "$row" && pass "a live record with no status file still shows DEAD" || fail "k-statusless row: $row"
grep -q '^Fleet: 3 live task(s) have no live window; run kingpin restore$' <<< "$list_out" \
  && pass "every dead record is counted in the restore hint" \
  || fail "restore hint in: $list_out"
rm -rf "$KINGPIN_HOME/tasks/k-legacy" "$KINGPIN_HOME/tasks/k-mismatch" "$KINGPIN_HOME/tasks/k-statusless"
tmux kill-window -t 'kingpin:=k-legacy' 2>/dev/null || true
tmux kill-window -t 'kingpin:=k-mismatch' 2>/dev/null || true
tmux kill-window -t 'kingpin:=k-statusless' 2>/dev/null || true
list_out=$("$KP_BIN/kingpin" list 2>/dev/null)
! grep -q '^Fleet:' <<< "$list_out" && pass "the hint clears once the dead records are gone" || fail "stale restore hint: $list_out"

# ---------------------------------------------------------------------------
# Test 12: a restored pi task relaunches on the provider and model it had
echo "=== Test 12: restore keeps a pi task's provider and model ==="
printf 'PI_PROVIDER=openrouter\nPI_MODEL=anthropic/claude-sonnet-4.5\n' >> "$KINGPIN_HOME/projects/demo-auto.env"
"$KP_BIN/kingpin-spawn" demo-auto --issue 149 --id p1 --harness pi >/dev/null
p1="$KINGPIN_HOME/tasks/p1"
[ "$(env_get "$p1/task.env" PI_PROVIDER)" = openrouter ] \
  && pass "the spawn records PI_PROVIDER in task.env" || fail "task.env: $(cat "$p1/task.env")"
[ "$(env_get "$p1/task.env" PI_MODEL)" = anthropic/claude-sonnet-4.5 ] \
  && pass "the spawn records PI_MODEL in task.env" || fail "task.env: $(cat "$p1/task.env")"
restart_tmux
p1_rc=0
"$KP_BIN/kingpin" restore p1 >/dev/null 2>"$T/p1.err" || p1_rc=$?
[ "$p1_rc" -eq 0 ] && pass "the pi task is restored" || fail "restore p1 exited $p1_rc: $(cat "$T/p1.err")"
grep -q -- '--provider openrouter' "$p1/launch.sh" \
  && pass "the restored pi launch keeps --provider" || fail "launch.sh: $(cat "$p1/launch.sh")"
grep -q -- '--model anthropic/claude-sonnet-4.5' "$p1/launch.sh" \
  && pass "the restored pi launch keeps --model" || fail "launch.sh: $(cat "$p1/launch.sh")"
# The override case: a task with no recorded pi keys, forced to pi for this run.
r6_rc=0
"$KP_BIN/kingpin" restore r6 --harness pi >/dev/null 2>"$T/r6pi.err" || r6_rc=$?
[ "$r6_rc" -eq 0 ] && pass "--harness pi restores an agy task" || fail "restore r6 --harness pi exited $r6_rc: $(cat "$T/r6pi.err")"
grep -qF "has no subagent tool" "$r6/preamble.md" \
  && pass "a --harness pi restore writes the pi sentence into the preamble" \
  || fail "the preamble has no pi sentence: $(tail -n 3 "$r6/preamble.md")"
[ "$(env_get "$r6/task.env" HARNESS)" = pi ] \
  && pass "the harness override is recorded" || fail "task.env: $(cat "$r6/task.env")"
! grep -q -- '--provider' "$r6/launch.sh" \
  && pass "an unset provider passes no flag" || fail "launch.sh: $(cat "$r6/launch.sh")"

# ---------------------------------------------------------------------------
# Test 13: a window name another live task claims is never respawned
echo "=== Test 13: restore never takes over another live task's window ==="
treehouse_stub
leased_json
d_a=$(mk_fixture k-claim-a "$T/fixture-wt" "TMUX_TARGET=kingpin:shared"); printf 'issue: #149\n' > "$d_a/status"
d_b=$(mk_fixture k-claim-b "$T/fixture-wt" "TMUX_TARGET=kingpin:shared"); printf 'issue: #149\n' > "$d_b/status"
cp "$d_b/task.env" "$T/k-claim-b.env.before"
tmux has-session -t '=kingpin' 2>/dev/null || tmux new-session -d -s kingpin -n home
shared_win=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n shared -c "$T/fixture-wt" 'exec bash')
wait_for_pane_command "$shared_win" bash || fail "the shared window never settled on a shell"
shared_pid=$(tmux list-panes -t "$shared_win" -F '#{pane_pid}' | head -n 1)
k_claim_rc=0
k_claim_err=$("$KP_BIN/kingpin" restore k-claim-b 2>&1 >/dev/null) || k_claim_rc=$?
[ "$k_claim_rc" -eq 1 ] && pass "a restore of a window name another live task claims exits 1" || fail "restore exited $k_claim_rc: $k_claim_err"
grep -q "refused k-claim-b:" <<< "$k_claim_err" && pass "the refusal names the task" || fail "stderr: $k_claim_err"
grep -qF "window kingpin:shared is also named by the live task k-claim-a" <<< "$k_claim_err" \
  && pass "the refusal names the other task" || fail "stderr: $k_claim_err"
[ "$(tmux list-panes -t "$shared_win" -F '#{pane_pid}' | head -n 1)" = "$shared_pid" ] \
  && pass "the other task's pane process survived" || fail "the shared window's pane was replaced"
[ "$(tmux list-panes -t "$shared_win" -F '#{pane_current_command}' | head -n 1)" = bash ] \
  && pass "the other task's window still runs its own shell" || fail "the shared pane no longer runs bash"
cmp -s "$d_b/task.env" "$T/k-claim-b.env.before" \
  && pass "the refusal left task.env byte-identical" || fail "the refusal rewrote task.env"
rm -rf "$d_a" "$d_b"
tmux kill-window -t "$shared_win" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 14: a missing session is recreated by exact name, not by prefix
echo "=== Test 14: restore recreates the recorded session exactly ==="
treehouse_stub
leased_json
d=$(mk_fixture k-session "$T/fixture-wt"); printf 'issue: #149\n' > "$d/status"
tmux kill-session -t '=kingpin' 2>/dev/null || true
tmux new-session -d -s kingpin-workers -n home
k_session_rc=0
"$KP_BIN/kingpin" restore k-session >/dev/null 2>"$T/k-session.err" || k_session_rc=$?
[ "$k_session_rc" -eq 0 ] && pass "the task is restored when no session carries its own name" || fail "restore exited $k_session_rc: $(cat "$T/k-session.err")"
tmux has-session -t '=kingpin' 2>/dev/null && pass "restore created a session named exactly kingpin" || fail "no session named exactly kingpin"
if tmux list-windows -t '=kingpin' -F '#{window_name}' 2>/dev/null | grep -qxF k-session; then
  pass "the window lives in the kingpin session"
else
  fail "the window is not in kingpin: $(tmux list-windows -t '=kingpin' -F '#{window_name}' 2>/dev/null)"
fi
if tmux list-windows -t '=kingpin-workers' -F '#{window_name}' 2>/dev/null | grep -qxF k-session; then
  fail "the window landed in the kingpin-workers session"
else
  pass "the window did not land in the kingpin-workers session"
fi
rm -rf "$d"
tmux kill-window -t 'kingpin:=k-session' 2>/dev/null || true
tmux kill-session -t '=kingpin-workers' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 15: a restored task resumes the session it already had
echo "=== Test 15: restore resumes the session the task already has ==="
treehouse_stub
leased_json
now=$(date +%s)
set_sessions "[$(session_json "$T/fixture-wt" $((now - 30)) ses_task168 "Issue #168 workflow"),$(session_json "$T/other-wt" $((now - 30)) ses_other "Another worktree")]"
d=$(mk_fixture t-resume "$T/fixture-wt" "HARNESS=opencode"); printf 'issue: #168\n' > "$d/status"
t_resume_rc=0
t_resume_out=$("$KP_BIN/kingpin" restore t-resume 2>"$T/t-resume.err") || t_resume_rc=$?
[ "$t_resume_rc" -eq 0 ] && pass "restore of an opencode task exits 0" || fail "restore exited $t_resume_rc: $(cat "$T/t-resume.err")"
grep -q -- '--session ses_task168' "$d/launch.sh" 2>/dev/null \
  && pass "launch.sh resumes with --session and the task's id" \
  || fail "launch.sh has no --session: $(cat "$d/launch.sh" 2>/dev/null)"
fake_argv_has "$d" --session && pass "the harness received --session" || fail "fake argv: $(cat "$d/fake-argv" 2>/dev/null)"
fake_argv_has "$d" ses_task168 && pass "the harness received the session id as its own argv word" || fail "fake argv: $(cat "$d/fake-argv" 2>/dev/null)"
fake_argv_has "$d" "# Kingpin resume brief" && pass "the whole resume brief still arrives" || fail "fake argv: $(cat "$d/fake-argv" 2>/dev/null)"
echo "$t_resume_out" | grep -q "resumed session ses_task168" \
  && pass "the OK line names the resumed session" || fail "restore OK line: $t_resume_out"
grep -qF "session this task already had" "$d/resume-prompt.txt" \
  && pass "the brief says the earlier conversation was resumed" \
  || fail "brief: $(head -n 6 "$d/resume-prompt.txt")"
[ "$(env_get "$d/task.env" HARNESS_SESSION)" = ses_task168 ] \
  && pass "task.env records HARNESS_SESSION" || fail "task.env: $(cat "$d/task.env")"
t_resume_win=$(env_get "$d/task.env" TMUX_WINDOW_ID)
t_resume_pid=$(tmux list-panes -t "$t_resume_win" -F '#{pane_pid}' 2>/dev/null | head -n 1)
[ -n "$t_resume_pid" ] && [ "$(cat "$d/harness.pid" 2>/dev/null || true)" = "$t_resume_pid" ] \
  && pass "harness.pid is the resumed pane pid" \
  || fail "harness.pid '$(cat "$d/harness.pid" 2>/dev/null || true)' is not the pane pid '$t_resume_pid'"
window_named t-resume && pass "the resumed task has its window" || fail "no window named t-resume"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-resume' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 16: two live sessions are refused without --force
echo "=== Test 16: two live sessions are refused without --force ==="
treehouse_stub
leased_json
now=$(date +%s)
set_sessions "[$(session_json "$T/fixture-wt" $((now - 300)) ses_older "Older live"),$(session_json "$T/fixture-wt" $((now - 60)) ses_newer "Newer live")]"
d=$(mk_fixture t-two "$T/fixture-wt" "HARNESS=opencode"); printf 'issue: #168\n' > "$d/status"
t_two_before=$(snapshot "$d")
t_two_rc=0
t_two_err=$("$KP_BIN/kingpin" restore t-two 2>&1 >/dev/null) || t_two_rc=$?
[ "$t_two_rc" -eq 1 ] && pass "two live sessions refuse the restore" || fail "restore exited $t_two_rc: $t_two_err"
grep -q "refused t-two:" <<< "$t_two_err" && pass "the refusal names the task" || fail "stderr: $t_two_err"
grep -q "ses_older" <<< "$t_two_err" && pass "the refusal names the older live session" || fail "stderr: $t_two_err"
grep -q "ses_newer" <<< "$t_two_err" && pass "the refusal names the newer live session" || fail "stderr: $t_two_err"
grep -qF "last active" <<< "$t_two_err" && pass "the refusal gives an age for each session" || fail "stderr: $t_two_err"
window_named t-two && fail "the refused restore created a window" || pass "the refused restore created no window"
[ "$(snapshot "$d")" = "$t_two_before" ] && pass "the refusal left the task folder unchanged" || fail "the refusal changed the task folder"
t_two_frc=0
t_two_frc_out=$("$KP_BIN/kingpin" restore t-two --force 2>"$T/t-two-force.err") || t_two_frc=$?
[ "$t_two_frc" -eq 0 ] && pass "--force restores past two live sessions" || fail "--force exited $t_two_frc: $(cat "$T/t-two-force.err")"
echo "$t_two_frc_out" | grep -q "resumed session ses_newer" && pass "--force resumes the newest live session" || fail "--force OK line: $t_two_frc_out"
grep -q -- '--session ses_newer' "$d/launch.sh" && pass "the forced launch carries the newest session" || fail "launch.sh: $(cat "$d/launch.sh" 2>/dev/null)"
grep -q "ses_older" "$T/t-two-force.err" && pass "--force names the session it leaves running" || fail "stderr: $(cat "$T/t-two-force.err")"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-two' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 17: no session starts fresh
echo "=== Test 17: no session starts fresh ==="
treehouse_stub
leased_json
set_sessions '[]'
d=$(mk_fixture t-fresh "$T/fixture-wt" "HARNESS=opencode"); printf 'issue: #168\n' > "$d/status"
t_fresh_rc=0
t_fresh_out=$("$KP_BIN/kingpin" restore t-fresh 2>"$T/t-fresh.err") || t_fresh_rc=$?
[ "$t_fresh_rc" -eq 0 ] && pass "a task with no session is restored" || fail "restore exited $t_fresh_rc: $(cat "$T/t-fresh.err")"
grep -q -- '--session' "$d/launch.sh" 2>/dev/null && fail "a fresh launch carries --session: $(cat "$d/launch.sh")" || pass "a fresh launch carries no --session"
echo "$t_fresh_out" | grep -q "started a new session" && pass "the OK line says it started a new session" || fail "restore OK line: $t_fresh_out"
fake_argv_has "$d" "# Kingpin resume brief" && pass "the fresh launch still receives the brief" || fail "fake argv: $(cat "$d/fake-argv" 2>/dev/null)"
grep -qF "You have no memory" "$d/resume-prompt.txt" && pass "the fresh brief keeps the no-memory wording" || fail "brief: $(head -n 6 "$d/resume-prompt.txt")"
t_fresh_win=$(env_get "$d/task.env" TMUX_WINDOW_ID)
[ -n "$t_fresh_win" ] && tmux list-panes -t "$t_fresh_win" -F '#{pane_pid}' >/dev/null 2>&1 \
  && pass "TMUX_WINDOW_ID names the fresh window" || fail "recorded window id '$t_fresh_win' does not resolve"
t_fresh_pid=$(tmux list-panes -t "$t_fresh_win" -F '#{pane_pid}' 2>/dev/null | head -n 1)
[ -n "$t_fresh_pid" ] && [ "$(cat "$d/harness.pid" 2>/dev/null || true)" = "$t_fresh_pid" ] \
  && pass "harness.pid is the fresh pane pid" || fail "harness.pid is not the pane pid"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-fresh' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 18: the recorded session wins over a newer one
echo "=== Test 18: the recorded session wins over a newer one ==="
treehouse_stub
leased_json
now=$(date +%s)
set_sessions "[$(session_json "$T/fixture-wt" $((now - 7200)) ses_recorded "Recorded session"),$(session_json "$T/fixture-wt" $((now - 3600)) ses_newer "Newer session")]"
d=$(mk_fixture t-recorded "$T/fixture-wt" "HARNESS=opencode" "HARNESS_SESSION=ses_recorded"); printf 'issue: #168\n' > "$d/status"
t_recorded_rc=0
t_recorded_out=$("$KP_BIN/kingpin" restore t-recorded 2>"$T/t-recorded.err") || t_recorded_rc=$?
[ "$t_recorded_rc" -eq 0 ] && pass "the task with a recorded session is restored" || fail "restore exited $t_recorded_rc: $(cat "$T/t-recorded.err")"
grep -q -- '--session ses_recorded' "$d/launch.sh" && pass "the recorded session is the one resumed" || fail "launch.sh: $(cat "$d/launch.sh" 2>/dev/null)"
grep -q -- 'ses_newer' "$d/launch.sh" && fail "the newer session was chosen over the recorded one" || pass "the newer session was not chosen"
echo "$t_recorded_out" | grep -q "resumed session ses_recorded" && pass "the OK line names the recorded session" || fail "restore OK line: $t_recorded_out"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-recorded' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 19: claude resumes through its transcript store
echo "=== Test 19: claude resumes through its transcript store ==="
treehouse_stub
leased_json
claude_slug=$(printf '%s' "$T/fixture-wt" | sed 's/[^A-Za-z0-9-]/-/g')
claude_id=11111111-1111-4111-8111-111111111111
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$claude_slug"
printf '{"type":"user"}\n' > "$CLAUDE_CONFIG_DIR/projects/$claude_slug/$claude_id.jsonl"
d=$(mk_fixture t-claude "$T/fixture-wt" "HARNESS=claude"); printf 'issue: #168\n' > "$d/status"
t_claude_rc=0
t_claude_out=$("$KP_BIN/kingpin" restore t-claude 2>"$T/t-claude.err") || t_claude_rc=$?
[ "$t_claude_rc" -eq 0 ] && pass "the claude task is restored" || fail "restore exited $t_claude_rc: $(cat "$T/t-claude.err")"
grep -q -- '--continue' "$d/launch.sh" && pass "the claude launch continues the directory's conversation" || fail "launch.sh: $(cat "$d/launch.sh" 2>/dev/null)"
echo "$t_claude_out" | grep -q "resumed session $claude_id" && pass "the OK line names the detected transcript" || fail "restore OK line: $t_claude_out"
[ "$(env_get "$d/task.env" HARNESS_SESSION)" = "$claude_id" ] && pass "the transcript id is recorded for a later change" || fail "task.env: $(cat "$d/task.env")"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-claude' 2>/dev/null || true
# A claude task whose store holds no transcript starts fresh.
d=$(mk_fixture t-claude-new "$T/fixture-wt" "HARNESS=claude"); printf 'issue: #168\n' > "$d/status"
t_claude_new_rc=0
t_claude_new_out=$(CLAUDE_CONFIG_DIR=$T/cfg-empty "$KP_BIN/kingpin" restore t-claude-new 2>"$T/t-claude-new.err") || t_claude_new_rc=$?
[ "$t_claude_new_rc" -eq 0 ] && pass "a claude task with no transcript is restored" || fail "restore exited $t_claude_new_rc: $(cat "$T/t-claude-new.err")"
grep -q -- '--continue' "$d/launch.sh" 2>/dev/null && fail "an empty store still passed --continue" || pass "an empty store passes no --continue"
echo "$t_claude_new_out" | grep -q "started a new session" && pass "the empty store starts a new session" || fail "restore OK line: $t_claude_new_out"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-claude-new' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 20: a --harness override never abandons a live session
echo "=== Test 20: a --harness override never abandons a live session ==="
treehouse_stub
leased_json
now=$(date +%s)
set_sessions "[$(session_json "$T/fixture-wt" $((now - 45)) ses_live "Live opencode session")]"
d=$(mk_fixture t-override "$T/fixture-wt" "HARNESS=opencode"); printf 'issue: #168\n' > "$d/status"
t_override_before=$(snapshot "$d")
t_override_rc=0
t_override_err=$("$KP_BIN/kingpin" restore t-override --harness agy 2>&1 >/dev/null) || t_override_rc=$?
[ "$t_override_rc" -eq 1 ] && pass "the override of a live recorded session is refused" || fail "restore exited $t_override_rc: $t_override_err"
grep -q "refused t-override:" <<< "$t_override_err" && pass "the refusal names the task" || fail "stderr: $t_override_err"
grep -q "ses_live" <<< "$t_override_err" && pass "the refusal names the live session it would abandon" || fail "stderr: $t_override_err"
grep -qF -- "--harness agy would add a second live session" <<< "$t_override_err" && pass "the refusal says why the override is unsafe" || fail "stderr: $t_override_err"
window_named t-override && fail "the refused override created a window" || pass "the refused override created no window"
[ "$(snapshot "$d")" = "$t_override_before" ] && pass "the refused override left the task folder unchanged" || fail "the refusal changed the task folder"
t_override_frc=0
t_override_frc_err=$("$KP_BIN/kingpin" restore t-override --harness agy --force 2>&1 >/dev/null) || t_override_frc=$?
[ "$t_override_frc" -eq 0 ] && pass "--force launches the override anyway" || fail "--force exited $t_override_frc: $t_override_frc_err"
grep -q "ses_live" <<< "$t_override_frc_err" && pass "--force notes the session it leaves running" || fail "stderr: $t_override_frc_err"
grep -q -- '--prompt-interactive' "$d/launch.sh" && pass "the forced launch runs the overriding harness" || fail "launch.sh: $(cat "$d/launch.sh" 2>/dev/null)"
grep -q -- '--session' "$d/launch.sh" 2>/dev/null && fail "the overriding harness received a resume flag it cannot use" || pass "the overriding harness gets no resume flag"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-override' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 21: a listing that fills the cap is disclosed as truncated, not read as none
echo "=== Test 21: a truncated session listing is disclosed in the OK line ==="
treehouse_stub
leased_json
# 1000 rows for another worktree fill the cap, and the task's own session is the 1001st,
# so a listing of exactly the cap length must not be read as "this task has no session".
# shellcheck disable=SC2016 # single quotes are intentional: the program runs in node
set_sessions "$(node -e '
  const now = Math.floor(Date.now() / 1000);
  const rows = [];
  for (let i = 1; i <= 1000; i++) {
    rows.push({ id: `ses_other_${i}`, title: `Other worktree ${i}`, updated: (now - i) * 1000, directory: process.argv[1] });
  }
  rows.push({ id: "ses_beyond_cap", title: "Task session beyond the cap", updated: (now - 2000) * 1000, directory: process.argv[2] });
  process.stdout.write(JSON.stringify(rows));
' "$T/other-wt" "$T/fixture-wt")"
d=$(mk_fixture t-truncated "$T/fixture-wt" "HARNESS=opencode"); printf 'issue: #168\n' > "$d/status"
t_truncated_rc=0
t_truncated_out=$("$KP_BIN/kingpin" restore t-truncated 2>"$T/t-truncated.err") || t_truncated_rc=$?
[ "$t_truncated_rc" -eq 0 ] && pass "a task outside a truncated listing is still restored" || fail "restore exited $t_truncated_rc: $(cat "$T/t-truncated.err")"
grep -q -- '--session' "$d/launch.sh" 2>/dev/null && fail "a truncated listing resumed a session: $(cat "$d/launch.sh")" || pass "a truncated listing starts no session it cannot see"
echo "$t_truncated_out" | grep -qF "the list was truncated" && pass "the OK line says the listing was truncated" || fail "restore OK line: $t_truncated_out"
echo "$t_truncated_out" | grep -qF "did not report its sessions" && fail "the OK line claims the harness reported nothing" || pass "the OK line does not claim the harness reported no sessions"
rm -rf "$d"
tmux kill-window -t 'kingpin:=t-truncated' 2>/dev/null || true

# ---------------------------------------------------------------------------

kp_test_finish RESTORE
