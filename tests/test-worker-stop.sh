#!/usr/bin/env bash
# Verification test for Kingpin: a worker's stop always leaves an outcome (issue #102).
#
# Covers the shared Stop hook (bin/kingpin-stop) in all four harnesses, the
# failed:/waiting: lines it appends, the fail-soft contract, and the STATE column of
# `kingpin list`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "worker-stop"
kp_test_project
# The watcher below legitimately arms dossier listeners for the kp102-* report.html
# tasks this suite leaves in the fleet; every recorded call must name one of them, so a
# call for any other task is still caught. The real binary is never expected, which is
# what Test 5b proves.
kp_test_expect_lavish_calls '*kp102-*'

# The real Claude Code Stop command, read from the tracked settings file.
claude_stop_cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks.Stop[0].hooks[0].command)' "$KP_ROOT/worker/hooks.json")
run_claude_stop() { # <task-dir>
  KINGPIN_TASK_DIR=$1 KINGPIN_ROOT=$KP_ROOT bash -c "$claude_stop_cmd"
}

# One live window stands in for the worker pane, so `kingpin list` sees the tasks as live.
probe_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n kp102-probe 'exec bash')
[ -n "$probe_wid" ] && pass "probe window created ($probe_wid)" || fail "could not create the probe window"

mk_task() { # <id> <harness> [window-id]; prints the task dir
  local d="$KINGPIN_HOME/tasks/$1"
  local win=${3:-$probe_wid}
  mkdir -p "$d"
  cat > "$d/task.env" << ENV
TASK_ID=$1
PROJECT=demo-auto
HARNESS=$2
MODE=review
TMUX_TARGET=kingpin:$1
TMUX_WINDOW_ID=$win
CREATED=$(date -Iseconds)
ENV
  : > "$d/status"
  printf '%s\n' "$d"
}

# Test 1: a silent stop gets a failed line, the exact line the issue names
echo "=== Test 1: a silent stop gets a failed line ==="
d=$(mk_task kp102-silent claude)
run_claude_stop "$d"
grep -qx 'failed: no status: stopped without reporting' "$d/status" && pass "a worker that stops without a status gets the failed line" || fail "silent stop status: $(cat "$d/status")"
[ -s "$d/stopped" ] && pass "the stop hook still records the stopped timestamp" || fail "the stop hook did not write stopped"
[ "$(wc -l < "$d/status" | tr -d ' ')" = "1" ] && pass "the failed line is written once" || fail "silent stop has $(wc -l < "$d/status") lines"

# A second stop without a new line does not pile up duplicate failed lines
run_claude_stop "$d"
[ "$(wc -l < "$d/status" | tr -d ' ')" = "1" ] && pass "a repeated silent stop adds no second failed line" || fail "duplicate failed lines: $(cat "$d/status")"

# Test 2: a status written this turn is never overwritten
echo "=== Test 2: a status written this turn survives ==="
d=$(mk_task kp102-ready claude)
printf 'ready: branch=b review=APPROVE report=r.md\n' > "$d/status"
before=$(cat "$d/status")
run_claude_stop "$d"
[ "$(cat "$d/status")" = "$before" ] && pass "the hook never overwrites a status written this turn" || fail "status rewritten: $(cat "$d/status")"
[ -s "$d/stopped" ] && pass "the stop is recorded even when the worker reported" || fail "no stopped marker for a reporting worker"

d=$(mk_task kp102-needs-fresh claude)
printf 'needs-input: which option?\n' > "$d/status"
before=$(cat "$d/status")
run_claude_stop "$d"
[ "$(cat "$d/status")" = "$before" ] && pass "a needs-input: written this turn is kept as it is" || fail "needs-input rewritten: $(cat "$d/status")"

# A status written after an earlier stop belongs to this turn, so it is kept too.
echo "=== Test 2b: a status newer than the last stop survives ==="
d=$(mk_task kp102-next-turn claude)
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$d/stopped"
touch -d '10 seconds ago' "$d/stopped"
printf 'fixed: high=1 report=r.md\n' > "$d/status"
before=$(cat "$d/status")
run_claude_stop "$d"
[ "$(cat "$d/status")" = "$before" ] && pass "a status newer than the last stop is kept" || fail "status after an older stop: $(cat "$d/status")"
[ "$(wc -l < "$d/status" | tr -d ' ')" = "1" ] && pass "no line is added for a turn that reported" || fail "extra lines after an older stop: $(cat "$d/status")"

# Test 2c: a listener note is not the worker's report (issue #102 review H1)
echo "=== Test 2c: a listener note does not count as the worker's report ==="
cat > "$T/kp102-lavish" << 'LAVISH'
#!/usr/bin/env bash
case "${1:-}" in
  poll)
    printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  Request Changes: tighten the wording"
    ;;
  reply) : ;;
  *) echo "OK: opened" ;;
esac
LAVISH
chmod +x "$T/kp102-lavish"
d=$(mk_task kp102-note claude)
printf 'ready: branch=b review=APPROVE report=r.md\n' > "$d/status"
echo '<html><body>dossier</body></html>' > "$d/report.html"
run_claude_stop "$d"
KINGPIN_LAVISH=$T/kp102-lavish "$KP_BIN/kingpin" listen kp102-note --once >/dev/null 2>&1
grep -qx 'feedback: Request Changes: tighten the wording' "$d/status" && pass "the listener appends its feedback note" || fail "no feedback note: $(cat "$d/status")"
run_claude_stop "$d"
grep -qx "waiting: feedback $d/feedback.md" "$d/status" && pass "a silent stop after a listener note is marked waiting, not failed" || fail "stop after a listener note: $(cat "$d/status")"
! grep -q '^failed:' "$d/status" && pass "a stop after a listener note is not marked failed" || fail "false failed line: $(cat "$d/status")"

# Test 2d: a note that arrives after the worker's report leaves that report alone
# (review M2). The note must not move the turn boundary the report already owns,
# or the next stop appends a waiting: line over a ready:/fixed: nobody has read.
echo "=== Test 2d: a note after the worker's report keeps the report ==="
d=$(mk_task kp102-note-after claude)
printf 'ready: branch=b review=APPROVE report=r.md\n' > "$d/status"
echo '<html><body>dossier</body></html>' > "$d/report.html"
run_claude_stop "$d"
# The report below is this turn's, written after the stop it follows. Backdate the
# boundary first (as Test 2b does) so the two writes cannot share one mtime tick:
# with equal mtimes `-nt` is false, the listener note moves the boundary, and the
# next stop appends a waiting: line over the report (review H1).
touch -d '5 seconds ago' "$d/stopped"
printf 'fixed: high=0 report=r.md\n' >> "$d/status"
KINGPIN_LAVISH=$T/kp102-lavish "$KP_BIN/kingpin" listen kp102-note-after --once >/dev/null 2>&1
grep -qx 'feedback: Request Changes: tighten the wording' "$d/status" && pass "the listener appends its note after a report" || fail "no note after a report: $(cat "$d/status")"
run_claude_stop "$d"
! grep -q '^waiting:' "$d/status" && pass "a note after a report gets no waiting line" || fail "waiting line over a report: $(cat "$d/status")"
! grep -q '^failed:' "$d/status" && pass "a note after a report is not marked failed" || fail "failed line over a report: $(cat "$d/status")"
grep -qx 'fixed: high=0 report=r.md' "$d/status" && pass "the worker's report survives the note and the stop" || fail "report lost: $(cat "$d/status")"
[ "$(wc -l < "$d/status" | tr -d ' ')" = "3" ] && pass "the turn keeps one report line and the note" || fail "status lines: $(cat "$d/status")"

# Test 3: a repeated stop while waiting is recorded as waiting, not failed
echo "=== Test 3: a waiting stop is marked waiting ==="
d=$(mk_task kp102-waiting claude)
printf 'needs-input: which option?\n' > "$d/status"
touch -d '10 seconds ago' "$d/status"
date +%s > "$d/stopped"
run_claude_stop "$d"
grep -qx 'needs-input: which option?' "$d/status" && pass "the worker's needs-input: line survives" || fail "needs-input lost: $(cat "$d/status")"
grep -qx "waiting: needs-input $d/question.md" "$d/status" && pass "a repeated waiting stop appends waiting: needs-input <question path>" || fail "no waiting line: $(cat "$d/status")"
! grep -q '^failed:' "$d/status" && pass "a waiting stop is not marked failed" || fail "waiting stop was marked failed: $(cat "$d/status")"
run_claude_stop "$d"
[ "$(wc -l < "$d/status" | tr -d ' ')" = "2" ] && pass "a second waiting stop adds no duplicate waiting line" || fail "duplicate waiting lines: $(cat "$d/status")"

# Test 3b: a stop with background agents still running is not a failure, in every
# harness that has them (review L3). Each harness marks a live turn or a background
# agent differently, and a wrong pattern silently brings the false failure line back.
# Pi is not in this loop: it has no background agents and its extension runs this hook
# before the TUI repaints, so its pane marker is never the stop decision (Test 3c).
echo "=== Test 3b: a working pane is not marked failed (claude, agy, opencode) ==="
for h in claude agy opencode; do
  case "$h" in
    claude)
      marker='Waiting for 1 background agent to finish'
      win_cmd='printf "Waiting for 1 background agent to finish\n"; exec bash'
      ;;
    agy)
      marker='esc to cancel'
      win_cmd='printf "working\nesc to cancel\n"; exec bash'
      ;;
    opencode)
      marker='Interrupt'
      win_cmd='printf "working\nInterrupt\n"; exec bash'
      ;;
  esac
  working_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "kp102-working-$h" "$win_cmd")
  [ -n "$working_wid" ] && pass "working-marker window created ($h, $working_wid)" || fail "could not create the working-marker window ($h)"
  for _ in $(seq 1 30); do
    tmux capture-pane -pt "$working_wid" 2>/dev/null | grep -qF "$marker" && break
    sleep 0.1
  done
  d=$(mk_task "kp102-working-$h" "$h" "$working_wid")
  run_claude_stop "$d"
  [ ! -s "$d/status" ] && pass "$h: a pane that shows a working marker gets no failed line" || fail "$h: working worker marked: $(cat "$d/status")"
  [ -s "$d/stopped" ] && pass "$h: the stop is still recorded while background agents run" || fail "$h: no stopped marker for a working stop"
  tmux kill-window -t "$working_wid" 2>/dev/null || true
  # Once the marker is gone, the same task's next stop is a real silent stop.
  run_claude_stop "$d"
  grep -qx 'failed: no status: stopped without reporting' "$d/status" && pass "$h: the next stop after the marker clears is marked failed" || fail "$h: no failed line after the marker cleared: $(cat "$d/status")"
done

# Test 3c: a pi pane still showing the working rule does not hold back the outcome line
# (issue #93 review, H4). The extension runs kingpin-stop from `agent_settled`, before
# Pi repaints, so the rule is visible while the turn is already over; gating on it
# would drop the failed: line every silent pi turn.
echo "=== Test 3c: a pi working pane still gets the failed line ==="
pi_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n kp102-working-pi \
  'printf "── ⠏ Working ─────────────────────────\n"; exec bash')
[ -n "$pi_wid" ] && pass "working-marker window created (pi, $pi_wid)" || fail "could not create the working-marker window (pi)"
for _ in $(seq 1 30); do
  tmux capture-pane -pt "$pi_wid" 2>/dev/null | grep -qF '── ⠏ Working' && break
  sleep 0.1
done
d=$(mk_task kp102-working-pi pi "$pi_wid")
run_claude_stop "$d"
grep -qx 'failed: no status: stopped without reporting' "$d/status" \
  && pass "pi: a working pane still gets the failed line" || fail "pi: working pane held back the failed line: $(cat "$d/status")"
[ -s "$d/stopped" ] && pass "pi: the stop is still recorded" || fail "pi: no stopped marker"
# The shared marker list still covers pi for kingpin-wait and kingpin-launch-check,
# whose pane is live, so the exemption above is the stop hook's alone.
# shellcheck source=../lib/status.sh
. "$KP_ROOT/lib/status.sh"
kp_pane_shows_working '── ⠏ Working ─────────────────────────' pi \
  && pass "pi: the shared marker list still recognizes the working rule" || fail "pi: the shared marker list lost the pi arm"
tmux kill-window -t "$pi_wid" 2>/dev/null || true

# Test 4: the hook fails soft
echo "=== Test 4: the hook fails soft ==="
d=$(mk_task kp102-unwritable claude)
rm -f "$d/status"
mkdir "$d/status"
out=$(run_claude_stop "$d" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && pass "an unwritable status does not fail the stop hook" || fail "unwritable status exited $rc"
echo "$out" | grep -q "cannot append the missing status" && pass "an unwritable status is named on stderr" || fail "no warning for an unwritable status: $out"
[ -s "$d/stopped" ] && pass "the stopped marker is still written when the status write fails" || fail "stopped missing after a failed append"

out=$(KINGPIN_TASK_DIR="$T/kp102-missing" KINGPIN_ROOT=$KP_ROOT bash -c "$claude_stop_cmd" 2>&1) || true
echo "$out" | grep -q "KINGPIN_TASK_DIR is unset or not a directory" && pass "a missing task dir is reported on stderr" || fail "no warning for a missing task dir: $out"
out=$(KINGPIN_TASK_DIR="$d" KINGPIN_ROOT="$T/kp102-no-root" bash -c "$claude_stop_cmd" 2>&1) || true
echo "$out" | grep -q "stop hook unavailable" && pass "a missing kingpin-stop is reported, not silenced" || fail "no warning for a missing helper: $out"

# Test 5: kingpin list marks WAITING, SILENT and Unseen
echo "=== Test 5: kingpin list STATE column ==="
d=$(mk_task kp102-list-wait claude)
printf 'needs-input: choose one\n' > "$d/status"
echo 1 > "$d/seen"
d=$(mk_task kp102-list-silent claude)
printf 'failed: no status: stopped without reporting\n' > "$d/status"
echo 1 > "$d/seen"
d=$(mk_task kp102-list-plain claude)
printf 'issue: #102\n' > "$d/status"
echo 1 > "$d/seen"
d=$(mk_task kp102-list-unseen claude)
printf 'issue: #102\nready: branch=b review=APPROVE report=r.md\n' > "$d/status"
echo 0 > "$d/seen"

list_out=$("$KP_BIN/kingpin" list 2>/dev/null)
row=$(grep '^kp102-list-wait ' <<< "$list_out" || true)
grep -q 'WAITING' <<< "$row" && pass "a live waiting task shows WAITING" || fail "waiting row: $row"
row=$(grep '^kp102-list-silent ' <<< "$list_out" || true)
grep -q 'SILENT' <<< "$row" && pass "a live silently stopped task shows SILENT" || fail "silent row: $row"
row=$(grep '^kp102-list-plain ' <<< "$list_out" || true)
! grep -qE 'WAITING|SILENT' <<< "$row" && pass "a normal live task shows no state marker" || fail "plain row: $row"
row=$(grep '^kp102-list-unseen ' <<< "$list_out" || true)
grep -q 'Unseen: 2' <<< "$row" && pass "unacknowledged events show as Unseen: N" || fail "unseen row: $row"
grep -q 'STATE' <<< "$list_out" && pass "the list header names the STATE column" || fail "no STATE header: $list_out"

# The supervisor prints the waiting event instead of dropping it
d=$(mk_task kp102-watch claude)
printf 'waiting: needs-input /some/question.md\n' > "$d/status"
watch_out=$("$KP_BIN/kingpin-watch" --once 2>/dev/null || true)
grep -q "\[kingpin-watch\] kp102-watch is waiting: needs-input /some/question.md" <<< "$watch_out" && pass "kingpin-watch reports a waiting task" || fail "no waiting event from watch: $watch_out"

# Test 5b: the watcher's dossier listener must never resolve the real lavish-axi (issue
# #129). kp_test_setup puts a recorder first on PATH for the whole suite; it logs a real
# call and exits 1, and kp_test_finish fails on that log. The stub is expected to run
# here: the task below is a review task with a report.html, so the guard is about which
# binary got resolved.
echo "=== Test 5b: the watcher never resolves the real lavish-axi ==="
# Positive control: an empty log proves nothing unless the recorder really records.
lavish_before=$(cat "$KP_TEST_LAVISH_REAL_LOG" 2>/dev/null || true)
lavish-axi poll /control/report.html --owner kingpin:control >/dev/null 2>&1 || true
grep -Fq "poll /control/report.html" "$KP_TEST_LAVISH_REAL_LOG" \
  && pass "the real-call recorder logs a real lavish-axi call" \
  || fail "the real-call recorder logged nothing: $(cat "$KP_TEST_LAVISH_REAL_LOG" 2>/dev/null || true)"
printf '%s' "$lavish_before" > "$KP_TEST_LAVISH_REAL_LOG"

d=$(mk_task kp102-guard claude)
printf 'ready: branch=b review=APPROVE report=none\n' > "$d/status"
echo '<html><body>guard dossier</body></html>' > "$d/report.html"
"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  if grep -Fq "$d/report.html" "$KP_TEST_LAVISH_CALLS_LOG" 2>/dev/null; then break; fi
  sleep 0.05
done
grep -Fq "$d/report.html" "$KP_TEST_LAVISH_CALLS_LOG" 2>/dev/null \
  && pass "the watcher armed its listener against the default lavish-axi stub" \
  || fail "the watcher never reached the default stub for $d/report.html (calls: $(cat "$KP_TEST_LAVISH_CALLS_LOG" 2>/dev/null || true))"
[ ! -s "$KP_TEST_LAVISH_REAL_LOG" ] \
  && pass "the watcher never resolved the real lavish-axi" \
  || fail "the watcher ran the real lavish-axi: $(cat "$KP_TEST_LAVISH_REAL_LOG")"

# A call the suite did not declare fails the run, and the failure names the arguments.
printf 'poll %s --owner kingpin:kp102-guard --takeover\n' "$d/report.html" > "$T/unexpected-lavish.log"
if KP_TEST_LAVISH_CALLS_EXPECTED=0 KP_TEST_LAVISH_CALLS_LOG="$T/unexpected-lavish.log" \
     kp_test_check_lavish_calls > "$T/unexpected-lavish.out" 2>&1; then
  fail "an undeclared default-stub call did not fail the suite"
else
  grep -Fq "poll $d/report.html --owner kingpin:kp102-guard --takeover" "$T/unexpected-lavish.out" \
    && pass "an undeclared stub call fails the suite and names the arguments" \
    || fail "the undeclared-call failure does not name the arguments: $(cat "$T/unexpected-lavish.out")"
fi

# A real call fails the run too, whatever the suite declared, and names the arguments.
printf 'poll %s --owner kingpin:real\n' "$d/report.html" > "$T/real-call.log"
if KP_TEST_LAVISH_REAL_LOG="$T/real-call.log" kp_test_check_lavish_calls > "$T/real-call.out" 2>&1; then
  fail "a real lavish-axi call did not fail the suite"
else
  grep -Fq "poll $d/report.html --owner kingpin:real" "$T/real-call.out" \
    && pass "a real lavish-axi call fails the suite and names the arguments" \
    || fail "the real-call failure does not name the arguments: $(cat "$T/real-call.out")"
fi

# Test 6: the hook is wired into all four harnesses
echo "=== Test 6: all four harnesses ==="
cat > "$T/kp102-harness" << 'H'
#!/usr/bin/env bash
exec bash
H
chmod +x "$T/kp102-harness"
export KINGPIN_CLAUDE=$T/kp102-harness KINGPIN_AGY=$T/kp102-harness KINGPIN_OPENCODE=$T/kp102-harness KINGPIN_PI=$T/kp102-harness

# Claude Code: the tracked settings file runs the shared helper
grep -q 'kingpin-stop' "$KP_ROOT/worker/hooks.json" && pass "claude Stop hook runs kingpin-stop" || fail "claude Stop hook does not run kingpin-stop"
"$KP_BIN/kingpin-spawn" demo-auto --issue 102 --id kp102-claude --harness claude >/dev/null
d="$KINGPIN_HOME/tasks/kp102-claude"
: > "$d/status"
rm -f "$d/stopped"
run_claude_stop "$d"
grep -qx 'failed: no status: stopped without reporting' "$d/status" && pass "claude: a silent stop leaves the failed line" || fail "claude silent stop: $(cat "$d/status")"

# agy: the generated .agents/hooks.json runs it, with KINGPIN_ROOT exported by the launcher
"$KP_BIN/kingpin-spawn" demo-auto --issue 102 --id kp102-agy --harness agy >/dev/null
d="$KINGPIN_HOME/tasks/kp102-agy"
wt_agy=$(sed -n 's/^WORKTREE=//p' "$d/task.env")
grep -q 'kingpin-stop' "$wt_agy/.agents/hooks.json" && pass "agy Stop hook runs kingpin-stop" || fail "agy Stop hook does not run kingpin-stop"
grep -q '^export KINGPIN_ROOT=' "$d/launch.sh" && pass "agy launcher exports KINGPIN_ROOT for the hook" || fail "agy launcher does not export KINGPIN_ROOT"
agy_stop_cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).kingpin.Stop[0].command)' "$wt_agy/.agents/hooks.json")
: > "$d/status"
rm -f "$d/stopped"
KINGPIN_TASK_DIR=$d KINGPIN_ROOT=$KP_ROOT bash -c "$agy_stop_cmd"
grep -qx 'failed: no status: stopped without reporting' "$d/status" && pass "agy: a silent stop leaves the failed line" || fail "agy silent stop: $(cat "$d/status")"

# OpenCode: the generated plugin calls it, through KINGPIN_ROOT
"$KP_BIN/kingpin-spawn" demo-auto --issue 102 --id kp102-open --harness opencode >/dev/null
d="$KINGPIN_HOME/tasks/kp102-open"
wt_oc=$(sed -n 's/^WORKTREE=//p' "$d/task.env")
grep -q 'kingpin-stop' "$wt_oc/.opencode/plugins/kingpin-stop.js" && pass "opencode Stop plugin calls kingpin-stop" || fail "opencode plugin does not call kingpin-stop"
grep -q '^export KINGPIN_ROOT=' "$d/launch.sh" && pass "opencode launcher exports KINGPIN_ROOT for the plugin" || fail "opencode launcher does not export KINGPIN_ROOT"
: > "$d/status"
rm -f "$d/stopped"
OC_PLUGIN="$wt_oc/.opencode/plugins/kingpin-stop.js" KINGPIN_TASK_DIR=$d KINGPIN_ROOT=$KP_ROOT node --input-type=module -e '
const mod = await import(process.env.OC_PLUGIN);
const plugin = await mod.KingpinStop();
await plugin.event({ event: { type: "session.idle" } });
'
grep -qx 'failed: no status: stopped without reporting' "$d/status" && pass "opencode: a silent stop leaves the failed line" || fail "opencode silent stop: $(cat "$d/status")"

# Pi: the launcher loads the checkout extension, which runs kingpin-stop on agent_settled.
"$KP_BIN/kingpin-spawn" demo-auto --issue 102 --id kp102-pi --harness pi >/dev/null
d="$KINGPIN_HOME/tasks/kp102-pi"
grep -q 'worker/pi/kingpin-harness.ts' "$d/launch.sh" && pass "pi launcher loads the extension that runs kingpin-stop" || fail "pi launcher does not load the extension"
grep -q '^export KINGPIN_ROOT=' "$d/launch.sh" && pass "pi launcher exports KINGPIN_ROOT for the extension" || fail "pi launcher does not export KINGPIN_ROOT"
: > "$d/status"
rm -f "$d/stopped"
PI_MODULE="file://$KP_ROOT/lib/pi-harness.mjs" KINGPIN_TASK_DIR=$d KINGPIN_ROOT=$KP_ROOT node --input-type=module -e '
const { registerPiHarness } = await import(process.env.PI_MODULE);
const api = { handlers: {}, on(event, handler) { this.handlers[event] = handler; } };
registerPiHarness(api, process.env);
await api.handlers.agent_settled({}, {});
'
grep -qx 'failed: no status: stopped without reporting' "$d/status" && pass "pi: a silent stop leaves the failed line" || fail "pi silent stop: $(cat "$d/status")"

tmux kill-window -t "$probe_wid" 2>/dev/null || true

kp_test_finish WORKER-STOP
