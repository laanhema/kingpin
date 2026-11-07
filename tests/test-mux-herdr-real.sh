#!/usr/bin/env bash
# The opt-in real-Herdr suite (issue #144): drives lib/mux.sh's Herdr backend
# against the real herdr binary, in a private named session, never the operator's.
#
# It self-skips when `herdr` is not installed, so the CI leg is green on a runner
# without it. Everything it creates lives in `herdr --session kp-mux-test-$$`,
# which it starts headless and stops on exit.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if ! command -v herdr >/dev/null 2>&1; then
  echo "SKIP: herdr is not installed"
  exit 0
fi

kp_test_setup "mux-herdr-real"

# The fake herdr that tests/lib.sh installs is the default; this suite asks for the
# real binary through a wrapper that records the call, and declares that on purpose.
kp_test_allow_real_herdr
mkdir -p "$T/herdr-real-bin"
ln -sf "$T/bin/herdr-real" "$T/herdr-real-bin/herdr"
export PATH="$T/herdr-real-bin:$PATH"

# shellcheck source=../lib/mux.sh
. "$KP_ROOT/lib/mux.sh"

SESSION="kp-mux-test-$$"
server_pid=''
cleanup() {
  herdr --session "$SESSION" server stop >/dev/null 2>&1 || true
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  kp_test_cleanup
}
trap cleanup EXIT

# json_get <expression>: read JSON on stdin, print the expression over `v`.
json_get() {
  node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  const v = JSON.parse(raw);
  const out = Function("v", "return (" + process.argv[1] + ");")(v);
  if (Array.isArray(out)) { for (const item of out) console.log(item); }
  else console.log(out);
});
' "$1"
}

wait_for() { # <tries> <function> [args...]
  local tries=${1:?}
  shift
  local fn=${1:?}
  shift
  for _ in $(seq 1 "$tries"); do
    "$fn" "$@" && return 0
    sleep 0.2
  done
  return 1
}

capture_has() { # <pane-id> <text>
  kp_mux_capture "${1:?}" --tail 40 2>/dev/null | grep -qF -- "${2:?}"
}

activity_differs() { # <pane-id> <token>
  [ "$(kp_mux_activity "${1:?}" 2>/dev/null)" != "${2:?}" ]
}

foreground_is() { # <pane-id> <word>
  [ "$(kp_mux_foreground_command "${1:?}" 2>/dev/null)" = "${2:?}" ]
}

echo "--- Test 1: a private session answers ---"
herdr --session "$SESSION" server > "$T/herdr-server.log" 2>&1 &
server_pid=$!
if wait_for 100 herdr --session "$SESSION" api snapshot >/dev/null 2>&1; then
  pass "t1: the private session $SESSION answers api snapshot"
else
  fail "t1: the private session never answered: $(cat "$T/herdr-server.log")"
  kp_test_finish MUX-HERDR-REAL
fi
case "$SESSION" in
  kp-mux-test-*) pass "t1: the session is private to this run" ;;
  *) fail "t1: session name '$SESSION' is not private" ;;
esac

echo "--- Test 2: create a workspace and a task tab ---"
ws_json=$(herdr --session "$SESSION" workspace create --cwd "$T" --label kp-mux-test --no-focus)
ws_id=$(printf '%s' "$ws_json" | json_get 'v.result.workspace.workspace_id')
[ -n "$ws_id" ] && pass "t2: the workspace was created ($ws_id)" || fail "t2: no workspace id: $ws_json"
label="kp-mux-t$$-1"
tab_json=$(herdr --session "$SESSION" tab create --workspace "$ws_id" --cwd "$T" --label "$label" --no-focus)
pane_id=$(printf '%s' "$tab_json" | json_get 'v.result.root_pane.pane_id')
[ -n "$pane_id" ] && pass "t2: the task tab has a pane ($pane_id)" || fail "t2: no pane id: $tab_json"

task_dir="$KINGPIN_HOME/tasks/t-real"
mkdir -p "$task_dir"
printf 'TASK_ID=t-real\nPROJECT=local\nMUX=herdr\nMUX_SESSION=%s\nMUX_TARGET=%s\nMUX_LABEL=%s\n' \
  "$SESSION" "$pane_id" "$label" > "$task_dir/task.env"

echo "--- Test 3: kp_mux_find resolves the pane by label ---"
if kp_mux_find "$task_dir"; then
  [ "$KP_MUX" = herdr ] && [ "$KP_WINDOW_ID" = "$pane_id" ] \
    && pass "t3: find resolves the pane and publishes the backend" \
    || fail "t3: find published mux=$KP_MUX id=$KP_WINDOW_ID"
else
  fail "t3: find failed for a live pane"
fi
[ "$KP_MUX_SESSION" = "$SESSION" ] && pass "t3: find publishes the record's session" || fail "t3: session '$KP_MUX_SESSION'"

echo "--- Test 4: capture reads the pane text ---"
marker="kp144-real-capture-$$"
herdr --session "$SESSION" pane run "$pane_id" "echo $marker" >/dev/null
if wait_for 50 capture_has "$pane_id" "$marker"; then
  pass "t4: capture reads the text a command printed"
else
  fail "t4: capture never showed the marker"
fi

echo "--- Test 5: send text and Enter reach the pane ---"
sent="kp144-real-send-$$"
kp_mux_send_text "$pane_id" "echo $sent"
kp_mux_send_enter "$pane_id"
if wait_for 50 capture_has "$pane_id" "$sent"; then
  pass "t5: send-text plus enter typed and submitted a line"
else
  fail "t5: the sent line never reached the pane"
fi

echo "--- Test 6: activity moves when the pane output moves ---"
token1=$(kp_mux_activity "$pane_id")
herdr --session "$SESSION" pane run "$pane_id" "echo activity-$$" >/dev/null
if wait_for 50 activity_differs "$pane_id" "$token1"; then
  pass "t6: the activity token changes with new output"
else
  fail "t6: the activity token never changed (token $token1)"
fi

echo "--- Test 7: a running command is the foreground command ---"
herdr --session "$SESSION" pane run "$pane_id" 'sleep 30' >/dev/null
if wait_for 50 foreground_is "$pane_id" sleep; then
  pass "t7: process-info names the running command"
else
  fail "t7: foreground command read '$(kp_mux_foreground_command "$pane_id")'"
fi
rm -f "$task_dir/harness.pid"
kp_mux_harness_live "$task_dir" \
  && pass "t7: a running command is a live harness without harness.pid" \
  || fail "t7: a running command read as no harness"
printf '1\n' > "$task_dir/harness.pid"
kp_mux_harness_live "$task_dir" \
  && fail "t7: a foreign harness.pid read as live" \
  || pass "t7: a pid that is not in the pane is not this harness"
rm -f "$task_dir/harness.pid"

echo "--- Test 8: a rename keeps the pane id ---"
kp_mux_rename "$pane_id" "$label-renamed"
[ "$(kp_mux_target_state "$pane_id")" = alive ] && pass "t8: the pane survived the rename" || fail "t8: the pane is gone after a rename"
renamed=$(herdr --session "$SESSION" pane get "$pane_id" | json_get 'v.result.pane.label')
[ "$renamed" = "$label-renamed" ] && pass "t8: the pane carries the new label" || fail "t8: pane label reads '$renamed'"
kp_mux_record_label "$task_dir" "$label-renamed"
grep -qx "MUX_LABEL=$label-renamed" "$task_dir/task.env" && pass "t8: the record carries the new label" || fail "t8: record label: $(grep MUX_LABEL "$task_dir/task.env")"
if kp_mux_find "$task_dir"; then
  [ "$KP_WINDOW_ID" = "$pane_id" ] && pass "t8: find follows the rename by label" || fail "t8: find published '$KP_WINDOW_ID'"
else
  fail "t8: find failed after a rename"
fi

echo "--- Test 9: a cross-workspace move renumbers the pane, the label still resolves ---"
before_id=$pane_id
moved=$(herdr --session "$SESSION" pane move "$pane_id" --new-workspace --no-focus)
after_id=$(printf '%s' "$moved" | json_get 'v.result.move_result.pane.pane_id')
if [ -n "$after_id" ] && [ "$after_id" != "$before_id" ]; then
  pass "t9: the move renumbers the pane ($before_id -> $after_id)"
else
  fail "t9: the pane id did not change: '$after_id'"
fi
if kp_mux_find "$task_dir"; then
  [ "$KP_WINDOW_ID" = "$after_id" ] && pass "t9: find resolves the moved pane by its label" || fail "t9: find published '$KP_WINDOW_ID', expected '$after_id'"
else
  fail "t9: find failed after a cross-workspace move"
fi
grep -qx "MUX_TARGET=$after_id" "$task_dir/task.env" && pass "t9: the stale id is rewritten in the record" || fail "t9: record target: $(grep MUX_TARGET "$task_dir/task.env")"

echo "--- Test 10: close leaves no pane behind ---"
kp_mux_kill "$after_id"
state=$(kp_mux_target_state "$after_id")
[ "$state" = none ] && pass "t10: the closed pane reads none" || fail "t10: closed pane read '$state'"
if herdr --session "$SESSION" pane list | grep -qF "$after_id"; then
  fail "t10: pane list still names the closed pane"
else
  pass "t10: pane list drops the closed pane"
fi

echo "--- Test 11: a real spawn, ready:, restore and done on the private session ---"
kp_test_project

# The worker harness: appends one ready: line to its task's status, then stays on stdin
# like a real TUI, so harness.pid keeps naming a live process.
cat > "$T/ready-harness" << 'READYEOF'
#!/usr/bin/env bash
if [ -n "${KINGPIN_TASK_DIR:-}" ]; then
  printf '%s\n' 'ready: branch=kingpin/test review=APPROVE report=/tmp/unused.md' >> "$KINGPIN_TASK_DIR/status"
fi
exec cat
READYEOF
chmod +x "$T/ready-harness"
export KINGPIN_AGY=$T/ready-harness

real_record() { sed -n "s/^$2=//p" "$KINGPIN_HOME/tasks/$1/task.env" 2>/dev/null | tail -n 1; }
task_has_ready() { grep -q '^ready:' "$1/status" 2>/dev/null; }
real_mux() { KP_MUX=herdr KP_MUX_SESSION="$SESSION" "$@"; }

t11_spawn='' t11_spawn_rc=0
t11_spawn=$(env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$SESSION" \
  "$KP_BIN/kingpin" spawn demo-auto --issue 149 --id t-real-spawn --harness agy 2>&1) || t11_spawn_rc=$?
[ "$t11_spawn_rc" -eq 0 ] \
  && pass "t11: a real Herdr spawn succeeds" \
  || fail "t11: spawn exited $t11_spawn_rc: $t11_spawn"
t11_dir="$KINGPIN_HOME/tasks/t-real-spawn"
[ "$(real_record t-real-spawn MUX)" = herdr ] \
  && pass "t11: the record names MUX=herdr" \
  || fail "t11: record: $(cat "$t11_dir/task.env" 2>/dev/null || true)"
[ "$(real_record t-real-spawn MUX_SESSION)" = "$SESSION" ] \
  && pass "t11: the record names the private session" \
  || fail "t11: MUX_SESSION is '$(real_record t-real-spawn MUX_SESSION)'"
grep -qx 'MUX_LABEL=t-real-spawn' "$t11_dir/task.env" \
  && pass "t11: the record names the pane label" \
  || fail "t11: MUX_LABEL: $(grep MUX_LABEL "$t11_dir/task.env" 2>/dev/null || true)"
t11_target=$(real_record t-real-spawn MUX_TARGET)
[ -n "$t11_target" ] \
  && pass "t11: the record names the created pane" \
  || fail "t11: MUX_TARGET missing: $(cat "$t11_dir/task.env" 2>/dev/null || true)"
[ "$(real_mux kp_mux_target_state "$t11_target")" = alive ] \
  && pass "t11: the spawned pane is live" \
  || fail "t11: pane state '$(real_mux kp_mux_target_state "$t11_target")'"
t11_label=$(herdr --session "$SESSION" pane get "$t11_target" | json_get 'v.result.pane.label')
[ "$t11_label" = t-real-spawn ] \
  && pass "t11: the pane carries the task id as its label" \
  || fail "t11: pane label '$t11_label'"
if wait_for 100 kp_mux_harness_live "$t11_dir"; then
  pass "t11: kp_mux_harness_live finds the launched harness"
else
  fail "t11: no live harness: pid '$(cat "$t11_dir/harness.pid" 2>/dev/null || echo none)'"
fi
if wait_for 100 task_has_ready "$t11_dir"; then
  pass "t11: the worker reported ready:"
else
  fail "t11: status: $(cat "$t11_dir/status" 2>/dev/null || true)"
fi

# The recreate leg: close the pane, then restore it from the record.
real_mux kp_mux_kill "$t11_target"
[ "$(real_mux kp_mux_target_state "$t11_target")" = none ] \
  && pass "t11: the closed pane reads none" \
  || fail "t11: closed pane read '$(real_mux kp_mux_target_state "$t11_target")'"
kp_mux_harness_live "$t11_dir" \
  && fail "t11: a closed pane read as a live harness" \
  || pass "t11: a closed pane is not a live harness"
t11_restore='' t11_restore_rc=0
t11_restore=$(env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$SESSION" \
  "$KP_BIN/kingpin" restore t-real-spawn 2>&1) || t11_restore_rc=$?
[ "$t11_restore_rc" -eq 0 ] \
  && pass "t11: restore exits 0 for the Herdr record" \
  || fail "t11: restore exited $t11_restore_rc: $t11_restore"
t11_new=$(real_record t-real-spawn MUX_TARGET)
[ -n "$t11_new" ] && [ "$t11_new" != "$t11_target" ] \
  && pass "t11: restore records a new pane ($t11_target -> $t11_new)" \
  || fail "t11: MUX_TARGET is '$t11_new' (was '$t11_target'): $t11_restore"
[ "$(real_mux kp_mux_target_state "$t11_new")" = alive ] \
  && pass "t11: the recreated pane is live" \
  || fail "t11: new pane state '$(real_mux kp_mux_target_state "$t11_new")'"
t11_label=$(herdr --session "$SESSION" pane get "$t11_new" | json_get 'v.result.pane.label')
[ "$t11_label" = t-real-spawn ] \
  && pass "t11: the recreated pane carries the task label" \
  || fail "t11: pane label '$t11_label'"
grep -qF 'Your worker terminal is gone' "$t11_dir/resume-prompt.txt" \
  && pass "t11: the resume brief was written" \
  || fail "t11: no resume brief: $(head -n 3 "$t11_dir/resume-prompt.txt" 2>/dev/null || true)"
if wait_for 100 kp_mux_harness_live "$t11_dir"; then
  pass "t11: the restored harness is live"
else
  fail "t11: restored harness not live: pid '$(cat "$t11_dir/harness.pid" 2>/dev/null || echo none)'"
fi

# The operator's own session must never be named: every recorded call is the private one.
t11_off=$(awk -v s="--session $SESSION " 'index($0, s) != 1 { print }' "$KP_TEST_HERDR_REAL_LOG" || true)
[ -z "$t11_off" ] \
  && pass "t11: every herdr call named the private session" \
  || fail "t11: calls outside $SESSION: $t11_off"

t11_done='' t11_done_rc=0
t11_done=$(env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$SESSION" \
  "$KP_BIN/kingpin" "done" t-real-spawn --force 2>&1) || t11_done_rc=$?
[ "$t11_done_rc" -eq 0 ] \
  && pass "t11: kingpin done cleans the real Herdr task" \
  || fail "t11: done exited $t11_done_rc: $t11_done"
[ "$(real_mux kp_mux_target_state "$t11_new")" = none ] \
  && pass "t11: done closed the restored pane" \
  || fail "t11: pane state after done '$(real_mux kp_mux_target_state "$t11_new")'"

kp_test_finish MUX-HERDR-REAL
