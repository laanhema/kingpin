#!/usr/bin/env bash
# Verification test for Kingpin: session-scoped AFK auto-landing (issue #94).
#
# Covers the state lifecycle (`on --ttl`, the 8-hour default, `status`, `off`), the
# expiry and dead-pid rules, `lock release` clearing the state, the `kingpin list`
# line, the clean-land path and its audit note, the listener's no-double-land
# markers, every refusal (findings, unreadable verdict, needs-input, cleanup-refused,
# failed), the unchanged behaviour with AFK off or expired, the Stop-hook turn
# boundary the note must not move, a disarmed fix pass that lands without a note,
# an auto-mode NITS pass that gains one, the review branch AFK keeps from starting
# a dossier listener, a queued landing that gains no note, the pid 0/1 and
# leading-zero TTL guards, and the report-check warning the AFK branch shares with
# the review branch.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "afk"
kp_test_project

AFK_FILE="$KINGPIN_HOME/afk"
WATCH_LOG="$T/watch.log"
SENDS="$T/sends"
: > "$WATCH_LOG"
mkdir -p "$SENDS"

# The real Claude Code Stop command, read from the tracked settings file, so the
# turn-boundary test drives the same hook a worker does.
claude_stop_cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks.Stop[0].hooks[0].command)' "$KP_ROOT/worker/hooks.json")
run_claude_stop() { # <task-dir>
  KINGPIN_TASK_DIR=$1 KINGPIN_ROOT=$KP_ROOT bash -c "$claude_stop_cmd"
}

# A worker window records every line it receives into $SENDS/<id>. A bare `cat`
# pane would show a send twice (the tty echoes it and cat writes it back), which
# makes a count assertion useless, so the suite counts real input lines instead.
cat > "$T/recorder" <<'REC'
#!/usr/bin/env bash
exec cat >> "${1:?recorder needs a file}"
REC
chmod +x "$T/recorder"

# mk_task <id> [worktree] [mode] [project]: a review- or auto-mode task whose
# window records each send, so the suite can count what the fleet dispatched.
mk_task() {
  local id=$1 worktree=${2:-$T/proj} mode=${3:-review} project=${4:-demo-afk-$1}
  local d="$KINGPIN_HOME/tasks/$id"
  mkdir -p "$d"
  tmux new-window -d -t kingpin: -n "$id" "$T/recorder" "$SENDS/$id"
  cat > "$d/task.env" << EOF
TASK_ID=$id
PROJECT=$project
MODE=$mode
WORKTREE=$worktree
PROJECT_PATH=$T/proj
ISSUE=94
HARNESS=claude
TMUX_TARGET=kingpin:$id
EOF
  printf 'issue: #94\n' > "$d/status"
}

# hold_lane <project> <holder>: make <holder> the project's live landing holder,
# so a later kingpin-land for the same project queues instead of starting.
hold_lane() {
  local project=$1 holder=$2
  mkdir -p "$KINGPIN_HOME/projects"
  printf '%s\n' "$holder" > "$KINGPIN_HOME/projects/$project.landing"
}

watch_once() {
  "$KP_BIN/kingpin" watch --once >> "$WATCH_LOG" 2>&1 || true
  sleep 0.2
}

send_count() { # <id> <literal text>
  local n
  [ -f "$SENDS/$1" ] || { echo 0; return 0; }
  n=$(grep -cF -- "$2" "$SENDS/$1" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

sends_of() { # <id>: the lines a task's window received, for a failure message
  [ -f "$SENDS/$1" ] || { echo '(none)'; return 0; }
  tr '\n' '|' < "$SENDS/$1"
}

status_count() { # <id> <regex>
  local n
  n=$(grep -cE -- "$2" "$KINGPIN_HOME/tasks/$1/status" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

no_landing() { # <id> <label>
  local d="$KINGPIN_HOME/tasks/$1"
  [ ! -f "$d/landing_sent" ] && [ ! -f "$d/approve_pending" ] \
    && pass "$2: no landing was dispatched" \
    || fail "$2: a landing marker appeared"
  [ "$(status_count "$1" '^approved: auto \(afk\)$')" = "0" ] \
    && pass "$2: no approved: auto (afk) note" \
    || fail "$2: the status gained an AFK approval note"
}

# Test 1: state lifecycle
echo "=== Test 1: afk on, status, off ==="
[ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] && pass "status is off before arming" || fail "initial status: $("$KP_BIN/kingpin" afk status)"
[ ! -f "$AFK_FILE" ] && pass "no state file before arming" || fail "$AFK_FILE exists before arming"

on_out=$("$KP_BIN/kingpin" afk on --ttl 90m)
[ -f "$AFK_FILE" ] && pass "afk on writes session state" || fail "afk on wrote no state file"
afk_pid=$(sed -n 1p "$AFK_FILE")
afk_start=$(sed -n 2p "$AFK_FILE")
afk_expiry=$(sed -n 3p "$AFK_FILE")
case "$afk_pid" in ''|*[!0-9]*) fail "state line 1 is not a pid: $afk_pid" ;; *) pass "state line 1 records a pid ($afk_pid)" ;; esac
kill -0 "$afk_pid" 2>/dev/null && pass "the recorded holder pid is live" || fail "recorded pid $afk_pid is not live"
[ "$((afk_expiry - afk_start))" = "5400" ] && pass "--ttl 90m sets a 90-minute expiry" || fail "expiry span: $((afk_expiry - afk_start))"
echo "$on_out" | grep -qE "^AFK: on until [0-9]{2}:[0-9]{2} \(pid $afk_pid\)$" && pass "afk on prints the armed line" || fail "afk on printed: $on_out"
status_out=$("$KP_BIN/kingpin" afk status)
[ "$status_out" = "$on_out" ] && pass "status reports the same armed line" || fail "status: $status_out"

"$KP_BIN/kingpin" afk off >/dev/null
[ ! -f "$AFK_FILE" ] && pass "afk off clears the state" || fail "afk off left $AFK_FILE"
[ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] && pass "status is off after off" || fail "status after off: $("$KP_BIN/kingpin" afk status)"

# Test 1b: plain `afk on` arms the 8-hour default
echo "=== Test 1b: plain afk on arms 8 hours ==="
on_out=$("$KP_BIN/kingpin" afk on)
afk_pid=$(sed -n 1p "$AFK_FILE")
afk_start=$(sed -n 2p "$AFK_FILE")
afk_expiry=$(sed -n 3p "$AFK_FILE")
[ "$((afk_expiry - afk_start))" = "28800" ] \
  && pass "the default arm is 28800 seconds (8 hours)" \
  || fail "default TTL span: $((afk_expiry - afk_start)), want 28800"
echo "$on_out" | grep -qE "^AFK: on until [0-9]{2}:[0-9]{2} \(pid $afk_pid\)$" \
  && pass "afk on prints the armed line with the default expiry" \
  || fail "plain afk on printed: $on_out"
"$KP_BIN/kingpin" afk off >/dev/null

# Test 1c: a leading zero in a TTL segment is not octal (review L6)
echo "=== Test 1c: --ttl 08h is eight hours ==="
ttl_rc=0
"$KP_BIN/kingpin" afk on --ttl 08h >/dev/null 2>"$T/ttl-err" || ttl_rc=$?
[ "$ttl_rc" -eq 0 ] && pass "--ttl 08h is accepted" || fail "--ttl 08h exited $ttl_rc: $(cat "$T/ttl-err")"
if [ "$ttl_rc" -eq 0 ]; then
  [ "$(( $(sed -n 3p "$AFK_FILE") - $(sed -n 2p "$AFK_FILE") ))" = "28800" ] \
    && pass "08h parses as 28800 seconds" || fail "08h parsed to the wrong span"
fi
"$KP_BIN/kingpin" afk off >/dev/null
"$KP_BIN/kingpin" afk on --ttl 01h30m >/dev/null \
  && pass "--ttl 01h30m is accepted" || fail "--ttl 01h30m was refused"
[ "$(( $(sed -n 3p "$AFK_FILE") - $(sed -n 2p "$AFK_FILE") ))" = "5400" ] \
  && pass "01h30m parses as 5400 seconds" || fail "01h30m parsed to the wrong span"
"$KP_BIN/kingpin" afk off >/dev/null

# Test 2: bad --ttl values are refused without writing state
echo "=== Test 2: bad --ttl is an argument error ==="
for bad in 90 0m 4x 1h30 ''; do
  ttl_rc=0
  "$KP_BIN/kingpin" afk on --ttl "$bad" >/dev/null 2>&1 || ttl_rc=$?
  [ "$ttl_rc" -eq 2 ] && pass "--ttl '$bad' exits 2" || fail "--ttl '$bad' exited $ttl_rc, want 2"
  [ ! -f "$AFK_FILE" ] && pass "--ttl '$bad' wrote no state" || fail "--ttl '$bad' wrote state"
done
"$KP_BIN/kingpin" afk on --ttl 1h30m >/dev/null && pass "--ttl 1h30m is accepted" || fail "--ttl 1h30m was refused"
[ "$(( $(sed -n 3p "$AFK_FILE") - $(sed -n 2p "$AFK_FILE") ))" = "5400" ] \
  && pass "1h30m is 5400 seconds" || fail "1h30m parsed wrong"
"$KP_BIN/kingpin" afk off >/dev/null

# Test 3: kingpin list shows the line only while armed
echo "=== Test 3: kingpin list shows AFK only while armed ==="
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "AFK:" && fail "list showed AFK while off: $list_out" || pass "list shows nothing while AFK is off"
"$KP_BIN/kingpin" afk on --ttl 2h >/dev/null
afk_pid=$(sed -n 1p "$AFK_FILE")
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -qE "^AFK: on until [0-9]{2}:[0-9]{2} \(pid $afk_pid\)$" \
  && pass "list shows the armed line with expiry and pid" \
  || fail "list did not show the AFK line: $list_out"

# Test 4: an expired TTL reads as off everywhere
echo "=== Test 4: an expired arm reads as off ==="
now=$(date +%s)
printf '%s\n%s\n%s\n' "$afk_pid" "$((now - 7200))" "$((now - 10))" > "$AFK_FILE"
[ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] && pass "status reports off after expiry" || fail "status after expiry: $("$KP_BIN/kingpin" afk status)"
"$KP_BIN/kingpin" list | grep -q "AFK:" && fail "list showed an expired arm" || pass "list shows nothing for an expired arm"

# Test 5: a dead holder pid reads as off
echo "=== Test 5: a dead holder pid reads as off ==="
# A pid that is provably gone: `wait` reaps it, so kill -0 must fail.
sleep 0.01 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
now=$(date +%s)
printf '%s\n%s\n%s\n' "$dead_pid" "$now" "$((now + 3600))" > "$AFK_FILE"
kill -0 "$dead_pid" 2>/dev/null && fail "the dead test pid $dead_pid is still live" || pass "a dead holder pid was recorded ($dead_pid)"
[ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] && pass "status reports off when the holder pid is gone" || fail "status with a dead pid: $("$KP_BIN/kingpin" afk status)"
"$KP_BIN/kingpin" list | grep -q "AFK:" && fail "list showed a dead arm" || pass "list shows nothing for a dead arm"

# Test 5b: a recorded pid of 0 or 1 is not a session holder (review L2)
echo "=== Test 5b: pid 0 and pid 1 read as off ==="
for bad_pid in 0 1; do
  now=$(date +%s)
  printf '%s\n%s\n%s\n' "$bad_pid" "$now" "$((now + 3600))" > "$AFK_FILE"
  [ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] \
    && pass "pid $bad_pid reads off in status" || fail "pid $bad_pid read armed"
  "$KP_BIN/kingpin" list | grep -q "AFK:" \
    && fail "list showed an arm held by pid $bad_pid" || pass "list shows nothing for pid $bad_pid"
done

# Test 6: kingpin lock release clears AFK
echo "=== Test 6: lock release clears AFK ==="
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire >/dev/null 2>&1
"$KP_BIN/kingpin" afk on >/dev/null
[ -f "$AFK_FILE" ] && pass "AFK is armed beside the orchestrator lock" || fail "AFK did not arm beside the lock"
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock release >/dev/null
[ ! -f "$AFK_FILE" ] && pass "lock release cleared the AFK state" || fail "lock release left $AFK_FILE"
[ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] && pass "AFK reads off after the lock release" || fail "AFK survived the lock release"

# Test 7: a clean verdict lands once, gains the audit note, and cannot loop
echo "=== Test 7: a clean verdict auto-lands once ==="
"$KP_BIN/kingpin" afk on >/dev/null
mk_task t-clean
# The cursor starts at the informational issue: line, as it would for a supervisor
# that restarted after the worker reported ready while nobody was watching.
printf '1\n' > "$KINGPIN_HOME/tasks/t-clean/seen"
printf 'ready: branch=kingpin/t-clean review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-clean/status"
watch_once
t_clean="$KINGPIN_HOME/tasks/t-clean"
[ -f "$t_clean/landing_sent" ] && pass "the clean verdict was landed through kingpin-land" || fail "landing_sent missing after AFK"
[ "$(send_count t-clean "/issue-flow-done 94")" = "1" ] && pass "the worker received /issue-flow-done" || fail "sends: $(sends_of t-clean)"
[ "$(status_count t-clean '^approved: auto \(afk\)$')" = "1" ] && pass "the status gained approved: auto (afk)" || fail "status: $(cat "$t_clean/status" | tr '\n' ' ')"
[ "$(tr -d ' \n' < "$t_clean/seen")" = "2" ] && pass "the ready: line was acknowledged" || fail "seen=$(cat "$t_clean/seen" 2>/dev/null)"
watch_once
grep -q "auto-landed by AFK" "$WATCH_LOG" && pass "watch reports the AFK note without re-landing" || fail "the AFK note was not dispatched"
[ "$(send_count t-clean "/issue-flow-done 94")" = "1" ] && pass "a second pass sends nothing (the note cannot loop)" || fail "the note re-landed the task (sends: $(sends_of t-clean))"
[ "$(status_count t-clean '^approved: auto \(afk\)$')" = "1" ] && pass "the audit note stays single" || fail "the audit note was appended again"
watch_once
[ "$(send_count t-clean "/issue-flow-done 94")" = "1" ] && pass "an idle pass sends nothing more" || fail "an idle pass re-sent the landing"

# Test 7b: an AFK note must not move the Stop hook's turn boundary (review H1).
# The note is written after the worker's first stop and before the next turn, so a
# raw append would make that silent turn look reported and hide the failed: line.
echo "=== Test 7b: an AFK note keeps the Stop hook's turn boundary ==="
mk_task t-stopnote
printf '1\n' > "$KINGPIN_HOME/tasks/t-stopnote/seen"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-stopnote/status"
# Turn 1 ends normally: the ready: line is this turn's report.
run_claude_stop "$KINGPIN_HOME/tasks/t-stopnote"
grep -q '^failed:' "$KINGPIN_HOME/tasks/t-stopnote/status" && fail "the reporting turn was marked failed" || pass "t-stopnote: the reporting turn is not marked failed"
# AFK lands and appends its note in the gap between the turns.
watch_once
t_stopnote="$KINGPIN_HOME/tasks/t-stopnote"
[ "$(status_count t-stopnote '^approved: auto \(afk\)$')" = "1" ] && pass "t-stopnote: the AFK note was appended" || fail "t-stopnote: no AFK note: $(tr '\n' '|' < "$t_stopnote/status")"
# Turn 2 ends with no status line. The note must not pass for this turn's report.
run_claude_stop "$t_stopnote"
grep -qx 'failed: no status: stopped without reporting' "$t_stopnote/status" \
  && pass "t-stopnote: a silent turn after the AFK note still gets the failed line" \
  || fail "t-stopnote: the AFK note hid the silent turn: $(tr '\n' '|' < "$t_stopnote/status")"
# Control: the same two-turn shape with no AFK note must end with the same line.
mk_task t-stopctrl
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-stopctrl/status"
run_claude_stop "$KINGPIN_HOME/tasks/t-stopctrl"
run_claude_stop "$KINGPIN_HOME/tasks/t-stopctrl"
grep -qx 'failed: no status: stopped without reporting' "$KINGPIN_HOME/tasks/t-stopctrl/status" \
  && pass "t-stopctrl: a silent turn with no AFK note gets the failed line" \
  || fail "t-stopctrl: the control task lost its failed line: $(tr '\n' '|' < "$KINGPIN_HOME/tasks/t-stopctrl/status")"
tmux kill-window -t kingpin:t-stopnote 2>/dev/null || true
tmux kill-window -t kingpin:t-stopctrl 2>/dev/null || true
rm -rf "$t_stopnote" "$KINGPIN_HOME/tasks/t-stopctrl"

# Test 7c: an armed AFK keeps the review branch from starting a dossier listener
echo "=== Test 7c: an armed AFK skips the review listener branch ==="
mk_task t-dossier
t_dossier="$KINGPIN_HOME/tasks/t-dossier"
echo '<html><body>AFK dossier</body></html>' > "$t_dossier/report.html"
printf '1\n' > "$t_dossier/seen"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$t_dossier/status"
watch_once
[ -f "$t_dossier/landing_sent" ] && pass "t-dossier: AFK landed the clean verdict" || fail "t-dossier: no landing"
[ ! -f "$t_dossier/listener.pid" ] && pass "t-dossier: no dossier listener was armed" || fail "t-dossier: a listener started beside the AFK landing"
grep -q "ready for review (lavish-axi" "$WATCH_LOG" \
  && fail "t-dossier: the review branch also ran for the AFK line" \
  || pass "t-dossier: the review branch did not run"

# Test 7d: the AFK clean branch warns about a dossier that fails report check (review L4)
echo "=== Test 7d: an AFK landing warns about a failing dossier ==="
mk_task t-report
t_report="$KINGPIN_HOME/tasks/t-report"
printf '<html><body>AFK dossier without diffs</body></html>\n' > "$t_report/report.html"
printf '1\n' > "$t_report/seen"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$t_report/status"
watch_once
[ -f "$t_report/landing_sent" ] && pass "t-report: the clean verdict landed" || fail "t-report: no landing"
grep -q "WARNING t-report report.html fails kingpin report check" "$WATCH_LOG" \
  && pass "t-report: the AFK branch warns about the failing dossier" \
  || fail "t-report: the AFK branch landed without the report-check warning"

# Test 8: the listener's markers stop a second land
echo "=== Test 8: listener markers stop a second land ==="
mk_task t-sent
touch "$KINGPIN_HOME/tasks/t-sent/landing_sent"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-sent/status"
mk_task t-pending
printf '2\n' > "$KINGPIN_HOME/tasks/t-pending/approve_pending"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-pending/status"
watch_once
[ "$(send_count t-sent "/issue-flow-done")" = "0" ] && pass "landing_sent blocks the AFK land" || fail "AFK landed over landing_sent"
[ "$(send_count t-pending "/issue-flow-done")" = "0" ] && pass "approve_pending blocks the AFK land" || fail "AFK landed over approve_pending"
[ "$(status_count t-sent '^approved: auto \(afk\)$')" = "0" ] && [ "$(status_count t-pending '^approved: auto \(afk\)$')" = "0" ] \
  && pass "neither blocked task gained an AFK note" || fail "a blocked task gained an AFK note"
grep -q "a landing or fix pass is already under way" "$WATCH_LOG" && pass "watch names the marker that blocked it" || fail "the blocked line was not reported"

# Test 9: findings verdicts start the fix pass and never land
echo "=== Test 9: findings verdicts start the fix pass only ==="
mk_task t-nits
printf 'ready: branch=b review=APPROVE WITH NITS report=r.md\n' >> "$KINGPIN_HOME/tasks/t-nits/status"
mk_task t-changes
printf 'ready: branch=b review=NEEDS CHANGES report=r.md\n' >> "$KINGPIN_HOME/tasks/t-changes/status"
watch_once
for id in t-nits t-changes; do
  d="$KINGPIN_HOME/tasks/$id"
  [ "$(send_count "$id" "/fix-findings $T/proj/r.md")" = "1" ] \
    && pass "$id: /fix-findings was sent" || fail "$id: the fix pass was not started (sends: $(sends_of "$id"))"
  [ -f "$d/landing_in_progress" ] && pass "$id: landing_in_progress is set" || fail "$id: landing_in_progress missing"
  [ -f "$d/afk_fix_pass" ] && pass "$id: the fix pass is marked AFK-owned" || fail "$id: afk_fix_pass missing"
  no_landing "$id" "$id"
done

# Test 9b: a clean fixed: line lands the AFK fix pass and notes it once
echo "=== Test 9b: a clean fixed: lands the AFK fix pass once ==="
printf 'fixed: high=0 report=r.md\n' >> "$KINGPIN_HOME/tasks/t-nits/status"
watch_once
t_nits="$KINGPIN_HOME/tasks/t-nits"
[ -f "$t_nits/landing_sent" ] && pass "t-nits: the clean fixed: started the landing" || fail "t-nits: landing_sent missing after the fix pass"
[ "$(send_count t-nits "/issue-flow-done 94")" = "1" ] && pass "t-nits: the worker received /issue-flow-done" || fail "t-nits: sends: $(sends_of t-nits)"
[ "$(status_count t-nits '^approved: auto \(afk\)$')" = "1" ] && pass "t-nits: approved: auto (afk) was appended once" || fail "t-nits: status: $(tr '\n' '|' < "$t_nits/status")"
[ ! -f "$t_nits/afk_fix_pass" ] && pass "t-nits: the fix-pass marker was cleared" || fail "t-nits: afk_fix_pass survived the landing"

watch_once
[ "$(send_count t-nits "/issue-flow-done 94")" = "1" ] && [ "$(status_count t-nits '^approved: auto \(afk\)$')" = "1" ] \
  && pass "t-nits: a second pass adds no send and no note" \
  || fail "t-nits: a second pass duplicated the landing or the note"
printf 'fixed: high=0 report=r.md\n' >> "$t_nits/status"
watch_once
[ "$(send_count t-nits "/issue-flow-done 94")" = "1" ] && pass "t-nits: a repeated fixed: line sends nothing" || fail "t-nits: a repeated fixed: line re-landed (sends: $(sends_of t-nits))"
[ "$(status_count t-nits '^approved: auto \(afk\)$')" = "1" ] && pass "t-nits: a repeated fixed: line adds no note" || fail "t-nits: a repeated fixed: line noted again"

# Test 9c: a fix pass that leaves High findings asks for a re-review, with no note
echo "=== Test 9c: a findings fixed: asks for a re-review, with no note ==="
printf 'fixed: high=2 report=r2.md\n' >> "$KINGPIN_HOME/tasks/t-changes/status"
watch_once
t_changes="$KINGPIN_HOME/tasks/t-changes"
[ "$(send_count t-changes "/review --issue 94")" = "1" ] && pass "t-changes: /review was sent" || fail "t-changes: sends: $(sends_of t-changes)"
[ "$(send_count t-changes "/issue-flow-done")" = "0" ] && pass "t-changes: no landing was sent" || fail "t-changes: a landing was sent with High findings open"
[ "$(status_count t-changes '^approved: auto \(afk\)$')" = "0" ] && pass "t-changes: no note while High findings remain" || fail "t-changes: an AFK note was written too early"
[ -f "$t_changes/afk_fix_pass" ] && pass "t-changes: the marker stays for the re-review" || fail "t-changes: the marker was dropped on the /review request"

printf 'ready: branch=b review=APPROVE report=none\n' >> "$t_changes/status"
watch_once
[ "$(send_count t-changes "/issue-flow-done 94")" = "1" ] && pass "t-changes: the clean re-review lands" || fail "t-changes: the re-review did not land"
[ "$(status_count t-changes '^approved: auto \(afk\)$')" = "1" ] && pass "t-changes: the re-review adds the note once" || fail "t-changes: status: $(tr '\n' '|' < "$t_changes/status")"
[ ! -f "$t_changes/afk_fix_pass" ] && pass "t-changes: the leftover marker was cleared" || fail "t-changes: the leftover marker survived the landing"
printf 'fixed: high=0 report=r.md\n' >> "$t_changes/status"
watch_once
[ "$(send_count t-changes "/issue-flow-done 94")" = "1" ] && pass "t-changes: a replayed fixed: line sends nothing" || fail "t-changes: a replayed fixed: line re-landed (sends: $(sends_of t-changes))"
[ "$(status_count t-changes '^approved: auto \(afk\)$')" = "1" ] && pass "t-changes: the leftover marker cannot add a second note" || fail "t-changes: a second AFK note appeared"

# Test 9d: a fix pass from a dossier approval gains no AFK note
echo "=== Test 9d: a dossier approval's fix pass gains no AFK note ==="
mk_task t-approval
touch "$KINGPIN_HOME/tasks/t-approval/landing_in_progress" "$KINGPIN_HOME/tasks/t-approval/afk_fix_pass"
printf '2\n' > "$KINGPIN_HOME/tasks/t-approval/approve_pending"
printf 'fixed: high=0 report=r.md\n' >> "$KINGPIN_HOME/tasks/t-approval/status"
watch_once
t_approval="$KINGPIN_HOME/tasks/t-approval"
[ "$(status_count t-approval '^approved: auto \(afk\)$')" = "0" ] && pass "t-approval: the listener-owned pass gets no AFK note" || fail "t-approval: an AFK note was written over a dossier approval"
[ ! -f "$t_approval/afk_fix_pass" ] && pass "t-approval: AFK dropped its stale claim on the pass" || fail "t-approval: afk_fix_pass survived"
[ "$(send_count t-approval "/issue-flow-done 94")" = "1" ] && pass "t-approval: the existing branch still lands the approval" || fail "t-approval: sends: $(sends_of t-approval)"

# Test 9e: a disarmed arm still lands the fixed: line, with no note (review M1)
echo "=== Test 9e: a disarmed AFK lands a fixed: line with no note ==="
mk_task t-disarmed
t_disarmed="$KINGPIN_HOME/tasks/t-disarmed"
printf 'ready: branch=b review=APPROVE WITH NITS report=r.md\n' >> "$t_disarmed/status"
watch_once
[ -f "$t_disarmed/afk_fix_pass" ] && pass "t-disarmed: the fix pass started AFK-owned" || fail "t-disarmed: afk_fix_pass missing"
"$KP_BIN/kingpin" afk off >/dev/null
printf 'fixed: high=0 report=r.md\n' >> "$t_disarmed/status"
watch_once
[ -f "$t_disarmed/landing_sent" ] && pass "t-disarmed: the existing branch landed the fixed: line" || fail "t-disarmed: the fixed: line did not land"
[ "$(send_count t-disarmed "/issue-flow-done 94")" = "1" ] && pass "t-disarmed: the worker received /issue-flow-done" || fail "t-disarmed: sends: $(sends_of t-disarmed)"
[ "$(status_count t-disarmed '^approved: auto \(afk\)$')" = "0" ] && pass "t-disarmed: no AFK note after the arm was cleared" || fail "t-disarmed: an AFK note claimed a landing after afk off"
[ ! -f "$t_disarmed/afk_fix_pass" ] && pass "t-disarmed: the stale AFK claim was dropped" || fail "t-disarmed: afk_fix_pass survived the disarm"

# Test 9f: an auto-mode NITS pass gains the note on its clean fixed: (review M2)
echo "=== Test 9f: an auto-mode NITS pass gains the note ==="
"$KP_BIN/kingpin" afk on >/dev/null
mk_task t-auto "$T/proj" auto
t_auto="$KINGPIN_HOME/tasks/t-auto"
printf 'ready: branch=b review=APPROVE WITH NITS report=r.md\n' >> "$t_auto/status"
watch_once
[ -f "$t_auto/afk_fix_pass" ] && pass "t-auto: the auto-mode pass is marked AFK-started" || fail "t-auto: afk_fix_pass missing"
no_landing t-auto "auto NITS pass"
printf 'fixed: high=0 report=r.md\n' >> "$t_auto/status"
watch_once
[ -f "$t_auto/landing_sent" ] && pass "t-auto: the clean fixed: landed the pass" || fail "t-auto: no landing"
[ "$(status_count t-auto '^approved: auto \(afk\)$')" = "1" ] && pass "t-auto: exactly one approved: auto (afk) note" || fail "t-auto: notes: $(tr '\n' '|' < "$t_auto/status")"
[ ! -f "$t_auto/afk_fix_pass" ] && pass "t-auto: the marker was cleared after the note" || fail "t-auto: afk_fix_pass survived the landing"

# Test 9g: a clean landing that only queued gains no note (review L1)
echo "=== Test 9g: a queued clean landing gains no note ==="
mk_task t-lane-holder "$T/proj" review demo-afk-lane
mk_task t-lane-queued "$T/proj" review demo-afk-lane
hold_lane demo-afk-lane t-lane-holder
t_lane="$KINGPIN_HOME/tasks/t-lane-queued"
printf '1\n' > "$t_lane/seen"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$t_lane/status"
watch_once
[ -f "$t_lane/landing_sent" ] && fail "t-lane-queued: a queued landing wrote landing_sent" || pass "t-lane-queued: the landing only queued"
grep -qxF t-lane-queued "$KINGPIN_HOME/projects/demo-afk-lane.landing_queue" 2>/dev/null \
  && pass "t-lane-queued: the task is in the project queue" || fail "t-lane-queued: the task was not queued"
[ "$(status_count t-lane-queued '^approved: auto \(afk\)$')" = "0" ] \
  && pass "t-lane-queued: the queued clean landing gains no note" || fail "t-lane-queued: the queued landing gained a note"

# Test 9h: a fixed: landing that only queued clears its marker (review L1)
echo "=== Test 9h: a queued fixed: landing clears afk_fix_pass ==="
mk_task t-lane-fixed "$T/proj" review demo-afk-lane
t_lanefix="$KINGPIN_HOME/tasks/t-lane-fixed"
touch "$t_lanefix/afk_fix_pass"
printf '1\n' > "$t_lanefix/seen"
printf 'fixed: high=0 report=r.md\n' >> "$t_lanefix/status"
watch_once
[ -f "$t_lanefix/landing_sent" ] && fail "t-lane-fixed: a queued landing wrote landing_sent" || pass "t-lane-fixed: the landing only queued"
grep -qxF t-lane-fixed "$KINGPIN_HOME/projects/demo-afk-lane.landing_queue" 2>/dev/null \
  && pass "t-lane-fixed: the task is in the project queue" || fail "t-lane-fixed: the task was not queued"
[ ! -f "$t_lanefix/afk_fix_pass" ] && pass "t-lane-fixed: the queued fixed: line cleared its marker" || fail "t-lane-fixed: afk_fix_pass survived the queue path"
[ "$(status_count t-lane-fixed '^approved: auto \(afk\)$')" = "0" ] \
  && pass "t-lane-fixed: the queued landing gains no note" || fail "t-lane-fixed: the queued landing gained a note"

# Test 9i: an AFK note alone does not claim a later fixed: line (review L3)
echo "=== Test 9i: an AFK note alone does not claim a fixed: line ==="
mk_task t-noteonly
t_noteonly="$KINGPIN_HOME/tasks/t-noteonly"
printf 'approved: auto (afk)\n' >> "$t_noteonly/status"
printf '2\n' > "$t_noteonly/seen"
printf 'fixed: high=0 report=r.md\n' >> "$t_noteonly/status"
watch_once
[ ! -f "$t_noteonly/landing_sent" ] && pass "t-noteonly: the note alone did not land the fixed: line" || fail "t-noteonly: an AFK note alone landed the fixed: line"
[ "$(send_count t-noteonly "/issue-flow-done")" = "0" ] && pass "t-noteonly: no landing was sent" || fail "t-noteonly: sends: $(sends_of t-noteonly)"

# Test 10: an unreadable verdict holds
echo "=== Test 10: an unreadable verdict holds ==="
mk_task t-unknown
printf 'ready: branch=b review=LGTM report=r.md\n' >> "$KINGPIN_HOME/tasks/t-unknown/status"
watch_once
[ "$(send_count t-unknown "/issue-flow-done")" = "0" ] && [ "$(send_count t-unknown "/fix-findings")" = "0" ] \
  && pass "nothing was dispatched for an unreadable verdict" || fail "an unreadable verdict dispatched a command"
no_landing t-unknown "unreadable verdict"
grep -q "review verdict cannot be read (afk on); holding" "$WATCH_LOG" && pass "watch names the hold" || fail "the unreadable verdict was not named"

# Test 11: needs-input waits for the operator
echo "=== Test 11: needs-input waits ==="
mk_task t-input
printf 'needs-input: which API shape?\n' >> "$KINGPIN_HOME/tasks/t-input/status"
watch_once
no_landing t-input "needs-input"
[ "$(send_count t-input "/issue-flow-done")" = "0" ] && pass "needs-input dispatched nothing" || fail "needs-input dispatched a landing"

# Test 12: cleanup-refused is retried without force and never landed
echo "=== Test 12: cleanup-refused is not forced ==="
mk_task t-refused "$T/afk-refused-wt"
printf 'probe lease was lost\n' > "$KINGPIN_HOME/tasks/t-refused/lease-lost"
printf 'cleanup-refused: probe lease was lost\n' >> "$KINGPIN_HOME/tasks/t-refused/status"
watch_once
t_ref="$KINGPIN_HOME/tasks/t-refused"
[ -d "$t_ref" ] && [ ! -L "$t_ref" ] && pass "the refused task record is still live" || fail "the cleanup archived or removed the task"
[ ! -f "$t_ref/done_cleaned" ] && pass "the cleanup did not force itself through" || fail "done_cleaned appeared on a refused cleanup"
[ "$(status_count t-refused '^cleanup-refused:')" = "1" ] && pass "the refusal was not duplicated" || fail "status: $(cat "$t_ref/status" | tr '\n' ' ')"
no_landing t-refused "cleanup-refused"

# Test 13: failed is left alone
echo "=== Test 13: failed is left alone ==="
mk_task t-failed
printf 'failed: probe failure\n' >> "$KINGPIN_HOME/tasks/t-failed/status"
watch_once
no_landing t-failed "failed"
[ "$(send_count t-failed "/issue-flow-done")" = "0" ] && pass "failed dispatched nothing" || fail "failed dispatched a landing"

# Test 14: AFK off or expired lands nothing
echo "=== Test 14: off or expired auto-lands nothing ==="
"$KP_BIN/kingpin" afk off >/dev/null
mk_task t-off
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-off/status"
watch_once
no_landing t-off "afk off"
[ "$(send_count t-off "/issue-flow-done")" = "0" ] && pass "AFK off sent nothing" || fail "AFK off landed a task"

now=$(date +%s)
printf '%s\n%s\n%s\n' "$$" "$((now - 7200))" "$((now - 10))" > "$AFK_FILE"
mk_task t-expired
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/t-expired/status"
watch_once
no_landing t-expired "expired"
[ "$(send_count t-expired "/issue-flow-done")" = "0" ] && pass "an expired arm sent nothing" || fail "an expired arm landed a task"
[ "$("$KP_BIN/kingpin" afk status)" = "AFK: off" ] && pass "status reads off for the expired arm" || fail "status: $("$KP_BIN/kingpin" afk status)"

kp_test_finish AFK
