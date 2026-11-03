#!/usr/bin/env bash
# Verification test for Kingpin: lib/status.sh: the shared status protocol and its callers.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "status"
kp_test_project

kp_test_stub_lavish

# t62: lib/status.sh owns the status protocol; one answer to "does a listener note count?"
echo "=== Test t62: shared status helper (lib/status.sh) ==="
# shellcheck source=../lib/status.sh
. "$KP_ROOT/lib/status.sh"
t62_dir=$T/t62; mkdir -p "$t62_dir"
t62_st=$t62_dir/status
printf '%s\n' "ready: branch=b review=APPROVE report=r" "feedback: Request Changes: x" "approved: by user via lavish dossier" > "$t62_st"
[ "$(kp_status_last "$t62_st")" = "ready: branch=b review=APPROVE report=r" ] && pass "t62: kp_status_last skips approved:/feedback: notes" || fail "t62: kp_status_last = $(kp_status_last "$t62_st")"
[ "$(kp_status_newest "$t62_st")" = "approved: by user via lavish dossier" ] && pass "t62: kp_status_newest keeps the newest note" || fail "t62: kp_status_newest = $(kp_status_newest "$t62_st")"
[ "$(kp_status_worker_events "$t62_st")" = "1" ] && pass "t62: notes are not worker events" || fail "t62: kp_status_worker_events = $(kp_status_worker_events "$t62_st")"
: > "$t62_dir/empty"
[ -z "$(kp_status_last "$t62_dir/empty")" ] && [ -z "$(kp_status_last "$t62_dir/missing")" ] && [ -z "$(kp_status_newest "$t62_dir/missing")" ] && pass "t62: empty and missing status files give no line" || fail "t62: empty/missing status gave a line"
printf '%s\n' "approved: x" > "$t62_dir/notes-only"
[ -z "$(kp_status_last "$t62_dir/notes-only")" ] && [ "$(kp_status_worker_events "$t62_dir/notes-only")" = "0" ] && pass "t62: a file of notes only has no worker event" || fail "t62: notes-only file reported an event"
for t62_l in "merged: pr=u" "failed: no status: x" "cleanup-refused: x"; do
  kp_status_is_terminal "$t62_l" && pass "t62: '${t62_l%%:*}:' is terminal" || fail "t62: '${t62_l%%:*}:' not terminal"
done
for t62_l in "ready: b" "needs-input: q" "fixed: high=0" "approved: x" "feedback: x" "issue: #1" ""; do
  kp_status_is_terminal "$t62_l" && fail "t62: '$t62_l' counted as terminal" || pass "t62: '${t62_l%%:*}' is not terminal"
done
printf '%s\n' "MODE=review" "HARNESS=agy" "HARNESS=claude" "EMPTY=" "PATH_X=a=b" > "$t62_dir/task.env"
[ "$(kp_env_get "$t62_dir/task.env" HARNESS)" = "claude" ] && pass "t62: kp_env_get returns the last assignment" || fail "t62: kp_env_get HARNESS = $(kp_env_get "$t62_dir/task.env" HARNESS)"
[ "$(kp_env_get "$t62_dir/task.env" PATH_X)" = "a=b" ] && [ -z "$(kp_env_get "$t62_dir/task.env" EMPTY)" ] && [ -z "$(kp_env_get "$t62_dir/task.env" NOPE)" ] && [ -z "$(kp_env_get "$t62_dir/nofile" MODE)" ] && pass "t62: kp_env_get handles = in values, empty, absent and missing file" || fail "t62: kp_env_get edge cases"
# Callers share that answer: a listener note after merged: leaves the task finished for kingpin-wait
# (a raw last line would report the dead window as exited).
t62_task=$KINGPIN_HOME/tasks/t62-wait
mkdir -p "$t62_task"
printf 'PROJECT=demo-auto\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:t62-wait\n' > "$t62_task/task.env"
printf '%s\n' "merged: pr=u" "approved: by user via lavish dossier" > "$t62_task/status"
echo 2 > "$t62_task/seen"
set +e; t62_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t62_rc=$?; set -e
[ "$t62_rc" -eq 1 ] && [ -z "$t62_out" ] && pass "t62: kingpin-wait treats merged: + approved: note as finished" || fail "t62: kingpin-wait rc=$t62_rc out=$t62_out"
# kingpin list shows the newest line, notes included
"$KP_BIN/kingpin" list 2>/dev/null | grep '^t62-wait ' | grep -q "approved: by user via lavish dossier" && pass "t62: kingpin list shows the newest status line" || fail "t62: kingpin list row: $("$KP_BIN/kingpin" list 2>/dev/null | grep '^t62-wait ')"
rm -rf "$t62_task" "$t62_dir"

kp_test_finish STATUS
