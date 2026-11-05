#!/usr/bin/env bash
# Verification test for Kingpin: kingpin wait and kingpin ack: blocking, wake filtering, exit codes.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "wait"
kp_test_bsd_shims
kp_test_project

# Test 0: the shims are for GNU hosts; on a BSD host they must stand down
mkdir -p "$T/bsd-host-bin"
cat > "$T/bsd-host-bin/date" << 'BSDEOF'
#!/usr/bin/env bash
# A BSD-shaped date: GNU -d is refused, everything else goes to the real tool.
case ${1:-} in -d*) exit 1 ;; esac
exec "$KP_TEST_REAL_DATE" "$@"
BSDEOF
chmod +x "$T/bsd-host-bin/date"
bsd_host_out=$(PATH="$T/bsd-host-bin:$PATH" bash -c '
  T=$(mktemp -d)
  . "$1/tests/lib.sh"
  before=$PATH
  kp_test_bsd_shims
  [ "$PATH" = "$before" ] && echo stood-aside || echo shimmed
' _ "$KP_ROOT")
[ "$bsd_host_out" = "stood-aside" ] && pass "the BSD shims stand down on a host whose own date is BSD" || fail "the BSD shims shadowed a BSD host's tools ($bsd_host_out)"

# A combined cluster such as `sed -Ei` is GNU-only too; BSD sed refuses it
mkdir -p "$T/sed-cluster"
echo a > "$T/sed-cluster/f"
set +e
sed -Ei 's/a/A/' "$T/sed-cluster/f" 2>"$T/sed-cluster.err"
sed_cluster_rc=$?
set -e
[ "$sed_cluster_rc" -ne 0 ] && grep -q "kp_test_sub" "$T/sed-cluster.err" && pass "the sed shim refuses a combined -Ei cluster" || fail "sed -Ei slipped through the shim (rc=$sed_cluster_rc)"
rm -rf "$T/sed-cluster" "$T/sed-cluster.err"

# Test 6: kingpin-wait blocking and kingpin ack single-event delivery
echo "=== Test 6: kingpin-wait blocking and kingpin ack single-event delivery ==="
task_w_dir="$KINGPIN_HOME/tasks/test-wait-1"
mkdir -p "$task_w_dir"
tmux new-window -d -t kingpin: -n test-wait-1
cat > "$task_w_dir/task.env" << ENV
PROJECT=demo-auto
HARNESS=claude
MODE=review
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:test-wait-1
ENV
touch "$task_w_dir/status"
echo 0 > "$task_w_dir/seen"

set +e
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1
initial_exit=$?
set -e
[ "$initial_exit" -eq 1 ] && pass "kingpin-wait --once exits 1 when fleet is quiet" || fail "kingpin-wait --once did not exit 1 (got $initial_exit)"

wait_log="$T/wait-test.log"
"$KP_BIN/kingpin" wait --timeout 10 > "$wait_log" 2>&1 &
wait_pid=$!
kp_holds_for 0.5 kill -0 "$wait_pid" && pass "kingpin-wait blocks while idle" || fail "kingpin-wait exited prematurely"

t_start=$(date +%s)
echo "needs-input: test question" >> "$task_w_dir/status"
set +e
wait "$wait_pid"
wait_res=$?
set -e
t_end=$(date +%s)
elapsed=$((t_end - t_start))
[ "$wait_res" -eq 0 ] && pass "background kingpin-wait exited 0 on status update" || fail "background kingpin-wait failed with exit $wait_res"
[ "$elapsed" -lt 5 ] && pass "kingpin-wait woke within 5s (${elapsed}s)" || fail "kingpin-wait took ${elapsed}s (>= 5s)"
grep -q "^test-wait-1 status" "$wait_log" && pass "wait output matched test-wait-1 status" || fail "wait output did not match test-wait-1 status"

out_before_ack=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$out_before_ack" | grep -q "^test-wait-1 status" && pass "event persisted before ack" || fail "event did not persist before ack"

"$KP_BIN/kingpin" ack test-wait-1
seen_val=$(cat "$task_w_dir/seen" 2>/dev/null | tr -d ' ' || echo 0)
[ "$seen_val" -eq 1 ] && pass "kingpin ack updated seen to 1" || fail "seen not updated (got $seen_val)"

set +e
out_after_ack=$("$KP_BIN/kingpin" wait --once 2>/dev/null)
ack_exit=$?
set -e
[ "$ack_exit" -eq 1 ] && [ -z "$out_after_ack" ] && pass "kingpin-wait --once exits 1 with no events after ack" || fail "event printed again after ack"

# Test quiet event (the last status is an acknowledged needs-input, so the pane must show activity first)
sleep 1.2
tmux send-keys -t kingpin:test-wait-1 "echo activity" Enter
sleep 1.2
now_ts=$(date +%s)
echo "$now_ts" > "$task_w_dir/stopped"
quiet_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$quiet_out" | grep -q "^test-wait-1 quiet" && pass "kingpin-wait detected quiet event" || fail "quiet event not detected (got: $quiet_out)"
"$KP_BIN/kingpin" ack test-wait-1
set +e
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1
quiet_exit=$?
set -e
[ "$quiet_exit" -eq 1 ] && pass "quiet event suppressed after ack" || fail "quiet event repeated after ack"

# Test exited event
tmux kill-window -t kingpin:test-wait-1 2>/dev/null || true
sleep 0.2
exit_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$exit_out" | grep -q "^test-wait-1 exited" && pass "kingpin-wait detected exited event" || fail "exited event not detected (got: $exit_out)"
"$KP_BIN/kingpin" ack test-wait-1
[ -f "$task_w_dir/seen_exited" ] && pass "seen_exited touched by kingpin ack" || fail "seen_exited not created"
set +e
"$KP_BIN/kingpin" wait --once >/dev/null 2>&1
exit_code_after=$?
set -e
[ "$exit_code_after" -eq 1 ] && pass "exited event suppressed after ack" || fail "exited event repeated after ack"

# Test ack --all
echo "merged: done" >> "$task_w_dir/status"
"$KP_BIN/kingpin" ack --all
seen_val_all=$(cat "$task_w_dir/seen" 2>/dev/null | tr -d ' ' || echo 0)
[ "$seen_val_all" -eq 2 ] && pass "kingpin ack --all updated seen to 2" || fail "seen not updated on ack --all"

rm -rf "$task_w_dir"

# Test 6d: the cursor carries the handled line's text, and only --rewind moves it
# back; a file shorter than the cursor raises a status event (issue #190).
echo "=== Test 6d: the cursor anchor and --rewind (#190) ==="
t6d_dir="$KINGPIN_HOME/tasks/t6d-ack"
mkdir -p "$t6d_dir"
t6d_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n t6d-ack)
cat > "$t6d_dir/task.env" << ENV
PROJECT=demo-auto
HARNESS=claude
MODE=review
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t6d-ack
TMUX_WINDOW_ID=$t6d_wid
ENV
printf 'issue: #190\nneeds-input: first\nfailed: second\n' > "$t6d_dir/status"
"$KP_BIN/kingpin-ack" --through 2 t6d-ack >/dev/null 2>&1 || true
[ "$(tr -d ' \n' < "$t6d_dir/seen")" = "2" ] \
  && pass "t6d: --through wrote the cursor" || fail "t6d: seen=$(cat "$t6d_dir/seen" 2>/dev/null || true)"
[ "$(sed -n 1p "$t6d_dir/seen_line" 2>/dev/null || true)" = "needs-input: first" ] \
  && pass "t6d: the cursor carries the handled line's own text" \
  || fail "t6d: anchor='$(sed -n 1p "$t6d_dir/seen_line" 2>/dev/null || true)'"
"$KP_BIN/kingpin-ack" --through 1 t6d-ack >/dev/null 2>&1 || true
[ "$(tr -d ' \n' < "$t6d_dir/seen")" = "2" ] \
  && pass "t6d: --through alone never moves the cursor backwards" \
  || fail "t6d: a plain --through rewound the cursor to $(cat "$t6d_dir/seen")"
"$KP_BIN/kingpin-ack" --through 1 --rewind t6d-ack >/dev/null 2>&1 || true
[ "$(tr -d ' \n' < "$t6d_dir/seen")" = "1" ] \
  && pass "t6d: --rewind moves the cursor to the line dispatch resumes at" \
  || fail "t6d: --rewind left seen=$(cat "$t6d_dir/seen")"
[ "$(sed -n 1p "$t6d_dir/seen_line" 2>/dev/null || true)" = "issue: #190" ] \
  && pass "t6d: --rewind re-anchors at the line it moved to" \
  || fail "t6d: rewind anchor='$(sed -n 1p "$t6d_dir/seen_line" 2>/dev/null || true)'"
kp_run t6d_out t6d_rc "$KP_BIN/kingpin-ack" --rewind t6d-ack
[ "$t6d_rc" -eq 2 ] && [ "$(tr -d ' \n' < "$t6d_dir/seen")" = "1" ] \
  && pass "t6d: --rewind without --through exits 2 and touches no cursor" \
  || fail "t6d: --rewind alone exited $t6d_rc: $t6d_out"

# A file shorter than its cursor is a rewrite, even for a record with no anchor.
printf 'issue: #190\n' > "$t6d_dir/status"
printf '3\n' > "$t6d_dir/seen"
rm -f "$t6d_dir/seen_line"
t6d_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$t6d_out" | grep -q "^t6d-ack status" \
  && pass "t6d: a status file shorter than its cursor raises a status event" \
  || fail "t6d: the truncated file raised no event (got: $t6d_out)"
# And the same file with its cursor in range stays quiet.
printf '1\n' > "$t6d_dir/seen"
set +e
t6d_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null)
t6d_rc=$?
set -e
[ "$t6d_rc" -eq 1 ] && [ -z "$t6d_out" ] \
  && pass "t6d: a cursor inside the file stays quiet" \
  || fail "t6d: an intact cursor raised an event (rc=$t6d_rc out=$t6d_out)"

# The anchor's own round trip: a handled line that ends in whitespace or holds a
# backslash has to match itself on the next pass, or every pass after the ack
# reports a rewrite and replays the file (issue #190).
t6d_anchor_case() {
  local label=$1 body=$2 resume out
  printf 'issue: #190\n%s\n' "$body" > "$t6d_dir/status"
  "$KP_BIN/kingpin-ack" --through 2 t6d-ack >/dev/null 2>&1 || true
  resume=$(bash -c '. "$1/lib/status.sh"; kp_status_cursor_resume "$2"' _ "$KP_ROOT" "$t6d_dir")
  [ "$resume" = "2" ] \
    && pass "t6d: $label" \
    || fail "t6d: $label (resume=$resume, seen_line='$(cat "$t6d_dir/seen_line" 2>/dev/null || true)')"
  out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
  [ -z "$out" ] \
    && pass "t6d: $label: the next wait pass stays quiet" \
    || fail "t6d: $label: the next wait pass raised '$out'"
}
t6d_anchor_case "an anchor holding a backslash matches its own line" 'feedback: rename \w+ to \d+'
t6d_anchor_case "an anchor ending in a space matches its own line" 'feedback: use the v2 API '

# ... and the supervisor logs no repair for it, on two consecutive passes.
t6d_watch_log="$T/t6d-watch.log"
: > "$t6d_watch_log"
"$KP_BIN/kingpin-watch" --once >> "$t6d_watch_log" 2>&1 || true
"$KP_BIN/kingpin-watch" --once >> "$t6d_watch_log" 2>&1 || true
grep -q "t6d-ack status file was rewritten" "$t6d_watch_log" \
  && fail "t6d: the handled anchor was repaired on every pass: $(cat "$t6d_watch_log")" \
  || pass "t6d: a handled anchor logs no repair on later passes"
tmux kill-window -t "$t6d_wid" 2>/dev/null || true
rm -rf "$t6d_dir"

# Test 6c: kingpin-wait ignores informational lines, holds repeated quiet, spares a launching window
echo "=== Test 6c: kingpin-wait wake filtering (#45) ==="
t45_dir="$KINGPIN_HOME/tasks/t45-wait"
mkdir -p "$t45_dir"
t45_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n t45-wait)
cat > "$t45_dir/task.env" << ENV
PROJECT=demo-auto
HARNESS=claude
MODE=review
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t45-wait
TMUX_WINDOW_ID=$t45_wid
ENV
: > "$t45_dir/status"
echo 0 > "$t45_dir/seen"

# issue: lines alone do not wake the waiter; the next real line does
echo "issue: #45 https://example/45" >> "$t45_dir/status"
set +e; t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t45_rc=$?; set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: a lone issue: line does not wake kingpin-wait" || fail "t45: issue: line woke the waiter (rc=$t45_rc out=$t45_out)"
echo "ready: branch=b review=APPROVE report=r" >> "$t45_dir/status"
t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t45_out" | grep -q "^t45-wait status" && pass "t45: ready: after an issue: line still wakes" || fail "t45: ready: did not wake ($t45_out)"
for t45_line in "needs-input: q" "fixed: high=0 report=r" "merged: pr=u" "cleanup-refused: x" "approved: x" "feedback: x"; do
  : > "$t45_dir/status"; echo 0 > "$t45_dir/seen"
  echo "$t45_line" >> "$t45_dir/status"
  "$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait status" && pass "t45: '${t45_line%%:*}:' wakes" || fail "t45: '${t45_line%%:*}:' did not wake"
done

# An acknowledged needs-input is not reported quiet again until the pane changes
: > "$t45_dir/status"; echo 0 > "$t45_dir/seen"; rm -f "$t45_dir/stopped" "$t45_dir/seen_stopped"
echo "needs-input: q" >> "$t45_dir/status"
"$KP_BIN/kingpin" ack t45-wait
[ -s "$t45_dir/seen_activity" ] && pass "t45: ack records the pane activity" || fail "t45: ack wrote no seen_activity"
sleep 1.2
date +%s > "$t45_dir/stopped"
set +e; t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t45_rc=$?; set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: acked needs-input is not reported quiet" || fail "t45: quiet repeated after needs-input ($t45_out)"
tmux send-keys -t "$t45_wid" "echo t45-activity" Enter
sleep 1.2
echo $(( $(date +%s) + 1 )) > "$t45_dir/stopped"
t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t45_out" | grep -q "^t45-wait quiet" && pass "t45: quiet returns once the pane shows activity" || fail "t45: quiet not reported after pane activity ($t45_out)"
# A pane that still lists background subagents is not quiet
tmux send-keys -t "$t45_wid" "echo '/tasks to see subagents'" Enter
sleep 1.2
tmux clear-history -t "$t45_wid" 2>/dev/null || true
echo $(( $(date +%s) + 5 )) > "$t45_dir/stopped"
t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t45_out" | grep -q "^t45-wait quiet" && fail "t45: quiet reported while subagents run" || pass "t45: a pane with background subagents is not quiet"
"$KP_BIN/kingpin" ack t45-wait
echo "needs-input: again" >> "$t45_dir/status"
"$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait status" && pass "t45: a new status line wakes after a hold" || fail "t45: new status did not wake"

# A window that is still being created is not exited; a gone window still is
"$KP_BIN/kingpin" ack t45-wait
tmux kill-window -t "$t45_wid"
sleep 0.2
: > "$t45_dir/launching"
set +e; t45_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t45_rc=$?; set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: a launching task is not reported exited" || fail "t45: launching task reported ($t45_out)"
kp_test_touch_ago "$t45_dir/launching" 600
"$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait exited" && pass "t45: a stale launching marker no longer hides a gone window" || fail "t45: stale marker hid exited"
# A stat that reads nothing is reported, never turned into age 0 (a false exited)
mkdir -p "$T/t45-badstat"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/t45-badstat/stat"
chmod +x "$T/t45-badstat/stat"
set +e
t45_out=$(PATH="$T/t45-badstat:$PATH" "$KP_BIN/kingpin" wait --once 2>"$T/t45-stat.err")
t45_rc=$?
set -e
[ "$t45_rc" -eq 1 ] && [ -z "$t45_out" ] && pass "t45: an unreadable mtime does not become age 0" || fail "t45: unreadable mtime reported ($t45_out)"
grep -q "cannot read the modification time" "$T/t45-stat.err" && pass "t45: the unreadable mtime is named on stderr" || fail "t45: no stderr warning for an unreadable mtime"
rm -rf "$T/t45-badstat"
rm -f "$t45_dir/launching"
"$KP_BIN/kingpin" wait --once 2>/dev/null | grep -q "^t45-wait exited" && pass "t45: a gone window is exited" || fail "t45: gone window not reported"
rm -rf "$t45_dir"

# Test 6b: kingpin-wait exit codes (timeout is not an error)
echo "=== Test 6b: kingpin-wait exit codes ==="
t6b_home="$T/kp-t6b"
mkdir -p "$t6b_home/tasks"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --timeout 1 2>"$T/t6b.err")
t6b_exit=$?
set -e
[ "$t6b_exit" -eq 0 ] && [ -z "$t6b_out" ] && [ ! -s "$T/t6b.err" ] && pass "kingpin-wait timeout exits 0 with empty stdout and stderr" || fail "timeout: exit $t6b_exit, out '$t6b_out', err '$(cat "$T/t6b.err")'"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --once 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -eq 1 ] && [ -z "$t6b_out" ] && pass "kingpin-wait --once with no events exits 1" || fail "--once no events: exit $t6b_exit, out '$t6b_out'"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --bogus 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -ne 0 ] && echo "$t6b_out" | grep -q "^kingpin-wait: " && pass "kingpin-wait bad argument exits non-zero with a message" || fail "bad arg: exit $t6b_exit, out '$t6b_out'"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_home" "$KP_BIN/kingpin-wait" --timeout abc 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -ne 0 ] && echo "$t6b_out" | grep -q "^kingpin-wait: " && pass "kingpin-wait bad --timeout exits non-zero with a message" || fail "bad timeout: exit $t6b_exit, out '$t6b_out'"
t6b_bad="$T/kp-t6b-bad"
mkdir -p "$t6b_bad"
echo "not a dir" > "$t6b_bad/tasks"
set +e
t6b_out=$(KINGPIN_HOME="$t6b_bad" "$KP_BIN/kingpin-wait" --timeout 1 2>&1)
t6b_exit=$?
set -e
[ "$t6b_exit" -ne 0 ] && echo "$t6b_out" | grep -q "^kingpin-wait: " && pass "kingpin-wait unusable fleet dir exits non-zero with a message" || fail "bad fleet dir: exit $t6b_exit, out '$t6b_out'"

kp_test_finish WAIT
