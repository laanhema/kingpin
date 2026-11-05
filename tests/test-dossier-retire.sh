#!/usr/bin/env bash
# Verification test for Kingpin: a finished task's review dossier stops looking live
# (issue #186). `kingpin done` marks the archived page and ends its session, the
# supervisor sweeps the records that finished without that step, and `kingpin list`
# names both leftovers.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "dossier-retire"
kp_test_project
# The synthetic worktrees below were never leased from a pool, so the real
# `treehouse return` refuses them.
kp_test_stub_treehouse
# Every stub call this suite allows must name one of its own fixtures: a call for
# another task is still caught at kp_test_finish.
kp_test_expect_lavish_calls '*d186-*'

PAGE="$KP_ROOT/assets/lavish/worker-dossier/template.html"

# mk_task <id> <status>: a task record with the shipped dossier template as its page.
# The worktree is dirty, so an unforced `kingpin done` is refused and `--force` cleans.
mk_task() {
  local id=$1 status=$2 d wt
  d="$KINGPIN_HOME/tasks/$id"
  wt="$T/wt-$id"
  mkdir -p "$d" "$wt"
  git -C "$wt" init -q
  echo dirty > "$wt/uncommitted.txt"
  cp "$PAGE" "$d/report.html"
  cat > "$d/task.env" << ENVEOF
TASK_ID=$id
PROJECT=demo-d186
HARNESS=claude
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$wt
BRANCH=kingpin/$id
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
ENVEOF
  printf '%s\n' "$status" > "$d/status"
}

# ack_fixture <id>: move the record's cursor past its status line, so a `watch --once`
# pass does not dispatch the line as a fleet event and the assertions see only the
# sweep.
ack_fixture() {
  local d="$KINGPIN_HOME/tasks/$1"
  wc -l < "$d/status" | tr -d ' ' > "$d/seen"
}

# mk_min_task <id> <status>: the same record with a one-line page that has no <main>,
# so the helper's fallback host and its single-quoted handler are both exercised.
# The page is deliberately bare: it exists to test the rewrite, not to pass `check`.
mk_min_task() {
  local id=$1 status=$2 d wt
  d="$KINGPIN_HOME/tasks/$id"
  wt="$T/wt-$id"
  mkdir -p "$d" "$wt"
  git -C "$wt" init -q
  echo dirty > "$wt/uncommitted.txt"
  printf '%s\n' "<html><body><h1>$id</h1><button type=\"button\" onclick='kpAction(\"kingpin land $id\", \"Land\")'>Approve &amp; Land</button></body></html>" > "$d/report.html"
  cat > "$d/task.env" << ENVEOF
TASK_ID=$id
PROJECT=demo-d186
HARNESS=claude
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$wt
BRANCH=kingpin/$id
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
ENVEOF
  printf '%s\n' "$status" > "$d/status"
}

# end_calls <id>: how many `end` calls the Lavish stub recorded for a task.
end_calls() {
  grep -c "^end .*$1" "$KP_TEST_LAVISH_CALLS_LOG" 2>/dev/null || true
}

# Test 1 (the reproduction): a merged task's page is retired by done.
echo "=== Test 1: kingpin done marks the archived page and ends its session ==="
mk_task d186-merged "merged: pr=https://github.com/laanhema/kingpin/pull/219"
t1_out='' t1_rc=0
kp_run t1_out t1_rc "$KP_BIN/kingpin-done" d186-merged --force
t1_page="$KINGPIN_HOME/archive/d186-merged/report.html"
[ "$t1_rc" -eq 0 ] && [ -f "$t1_page" ] \
  && pass "t1: done archived the task and its dossier page" \
  || fail "t1: done exited $t1_rc without an archived page: $t1_out"
grep -q 'data-kingpin-finished' "$t1_page" 2>/dev/null \
  && pass "t1: the archived page carries the finished marker" \
  || fail "t1: the archived page carries no finished marker"
grep -q 'pull/219' "$t1_page" 2>/dev/null \
  && pass "t1: the banner names the merged PR" \
  || fail "t1: the banner does not name the merged PR"
! grep -qE '<button[^>]*onclick="kp(Action|RequestChanges)\(' "$t1_page" 2>/dev/null \
  && pass "t1: no decision button keeps a live handler" \
  || fail "t1: a decision button still carries its handler"
[ "$(grep -cE '<button[^>]*[[:space:]]disabled' "$t1_page" 2>/dev/null || true)" -eq 2 ] \
  && pass "t1: both decision buttons are disabled" \
  || fail "t1: a decision button is not disabled"
grep -q 'data-kp-finished-hide class="card-custom' "$t1_page" 2>/dev/null \
  && grep -q 'data-kp-finished-hide class="badge badge-success' "$t1_page" 2>/dev/null \
  && grep -q '\[data-kp-finished-hide\] { display: none' "$t1_page" 2>/dev/null \
  && pass "t1: the finished page hides the decision bar and the ready badge" \
  || fail "t1: the decision chrome is not hidden on the archived page"
grep -q 'window.kpAction = function' "$t1_page" 2>/dev/null \
  && pass "t1: the page replaces the decision handlers with no-ops" \
  || fail "t1: the decision handler stub is missing"
case "$t1_out" in
  *"marked its dossier finished"*) pass "t1: the OK: line says the dossier was marked" ;;
  *) fail "t1: the OK: line does not name the dossier mark: $t1_out" ;;
esac
[ -f "$KINGPIN_HOME/archive/d186-merged/dossier.ended" ] \
  && pass "t1: done records that the dossier session ended" \
  || fail "t1: done left no dossier.ended marker"
t1_chk='' t1_chk_rc=0
kp_run t1_chk t1_chk_rc "$KP_BIN/kingpin-report" check "$t1_page"
[ "$t1_chk_rc" -eq 0 ] \
  && pass "t1: the archived page still passes kingpin-report check" \
  || fail "t1: the archived page fails kingpin-report check: $t1_chk"

# Test 2: a second cleanup is a no-op and leaves one banner.
echo "=== Test 2: a second done on the archived task changes nothing ==="
before_banner=$(grep -c 'data-kingpin-finished' "$t1_page" 2>/dev/null || true)
t2_out='' t2_rc=0
kp_run t2_out t2_rc "$KP_BIN/kingpin-done" d186-merged --force
[ "$t2_rc" -eq 0 ] && case "$t2_out" in
  *"already cleaned up"*) pass "t2: a second done exits at the archive" ;;
  *) fail "t2: a second done did not report the archive: $t2_out" ;;
esac || fail "t2: a second done exited $t2_rc: $t2_out"
[ "$(grep -c 'data-kingpin-finished' "$t1_page" 2>/dev/null || true)" = "$before_banner" ] \
  && [ "$before_banner" -eq 1 ] \
  && pass "t2: the page still carries exactly one banner" \
  || fail "t2: the page holds $before_banner banner(s)"

# Test 3: a refused cleanup leaves the page alone.
echo "=== Test 3: a refused cleanup leaves the page alone ==="
mk_task d186-dirty "ready: branch=b review=APPROVE report=none"
t3_out='' t3_rc=0
kp_run t3_out t3_rc "$KP_BIN/kingpin-done" d186-dirty
[ "$t3_rc" -eq 1 ] \
  && pass "t3: done refused the dirty worktree" \
  || fail "t3: done exited $t3_rc on a dirty worktree: $t3_out"
printf '%s\n' "$t3_out" | grep -q 'uncommitted changes' \
  && pass "t3: the refusal names the uncommitted changes" \
  || fail "t3: the refusal reason is missing: $t3_out"
! grep -q 'data-kingpin-finished' "$KINGPIN_HOME/tasks/d186-dirty/report.html" 2>/dev/null \
  && pass "t3: the refused task's page carries no marker" \
  || fail "t3: a refused cleanup marked the page"
rm -rf "$KINGPIN_HOME/tasks/d186-dirty" "$T/wt-d186-dirty"

# Test 4: list names the leftovers.
echo "=== Test 4: kingpin list names an open dossier and a missing listener ==="
printf '%s\n' "https://lavish.example/session/abc" > "$KINGPIN_HOME/archive/d186-merged/dossier.url"
rm -f "$KINGPIN_HOME/archive/d186-merged/dossier.ended"
mk_task d186-live "ready: branch=b review=APPROVE report=none"
# Auto mode never had a listener, so the sweep leaves this fixture alone, and its
# ready: line is already acked, so no later sweep dispatches it as a fleet event.
kp_test_sub "$KINGPIN_HOME/tasks/d186-live/task.env" 's/^MODE=review$/MODE=auto/'
ack_fixture d186-live
t4_out='' t4_rc=0
kp_run t4_out t4_rc "$KP_BIN/kingpin" list
[ "$t4_rc" -eq 0 ] && pass "t4: kingpin list exits 0" || fail "t4: kingpin list exited $t4_rc: $t4_out"
printf '%s\n' "$t4_out" | grep -q 'Dossiers left open on finished tasks' \
  && pass "t4: list prints the open-dossier section" \
  || fail "t4: list prints no open-dossier section: $t4_out"
printf '%s\n' "$t4_out" | grep 'd186-merged' | grep -q 'lavish.example/session/abc' \
  && pass "t4: the section names the finished task and its session URL" \
  || fail "t4: the section does not name the open dossier: $t4_out"
printf '%s\n' "$t4_out" | grep -q 'd186-live.*(no listener)' \
  && pass "t4: a live dossier with no listener is named as such" \
  || fail "t4: the review line does not say (no listener): $t4_out"

# Test 5: watch ends the leftover session once.
echo "=== Test 5: kingpin watch ends the leftover session once ==="
: > "$KP_TEST_LAVISH_CALLS_LOG"
t5_out='' t5_rc=0
kp_run t5_out t5_rc "$KP_BIN/kingpin-watch" --once
[ "$t5_rc" -eq 0 ] && pass "t5: watch --once exits 0" || fail "t5: watch --once exited $t5_rc: $t5_out"
[ "$(end_calls d186-merged)" -eq 1 ] \
  && pass "t5: the sweep called end once for the finished task" \
  || fail "t5: the sweep recorded $(end_calls d186-merged) end call(s)"
grep -qF "end $KINGPIN_HOME/tasks/d186-merged/report.html" "$KP_TEST_LAVISH_CALLS_LOG" \
  && pass "t5: the end call names the dossier link a session holds" \
  || fail "t5: the end call does not name the dossier link: $(cat "$KP_TEST_LAVISH_CALLS_LOG")"
[ -f "$KINGPIN_HOME/archive/d186-merged/dossier.ended" ] \
  && pass "t5: the sweep records the ended session" \
  || fail "t5: the sweep wrote no dossier.ended marker"
printf '%s\n' "$t5_out" | grep -q 'ended the leftover dossier session' \
  && pass "t5: the sweep logs the end it made" \
  || fail "t5: the sweep logs no end line: $t5_out"
t5_list='' t5_list_rc=0
kp_run t5_list t5_list_rc "$KP_BIN/kingpin" list
[ "$t5_list_rc" -eq 0 ] && pass "t5: list exits 0 after the sweep" || fail "t5: list exited $t5_list_rc: $t5_list"
! printf '%s\n' "$t5_list" | grep -A100 'Dossiers left open on finished tasks' | grep -q 'd186-merged' \
  && pass "t5: list stops naming the dossier once it is ended" \
  || fail "t5: list still names the ended dossier: $t5_list"
t5_before=$(wc -l < "$KP_TEST_LAVISH_CALLS_LOG" | tr -d ' ')
t5_again='' t5_again_rc=0
kp_run t5_again t5_again_rc "$KP_BIN/kingpin-watch" --once
[ "$t5_again_rc" -eq 0 ] && pass "t5: a second watch --once exits 0" || fail "t5: a second watch --once exited $t5_again_rc: $t5_again"
[ "$(wc -l < "$KP_TEST_LAVISH_CALLS_LOG" | tr -d ' ')" = "$t5_before" ] \
  && [ "$(end_calls d186-merged)" -eq 1 ] \
  && pass "t5: a second sweep makes no second end call" \
  || fail "t5: a second sweep recorded another call: $(cat "$KP_TEST_LAVISH_CALLS_LOG")"
rm -rf "$KINGPIN_HOME/tasks/d186-live" "$T/wt-d186-live"

# Test 6: a failed: record is retired without done.
echo "=== Test 6: the sweep retires a failed task without done ==="
mk_task d186-failed "failed: verify stopped"
ack_fixture d186-failed
t6_out='' t6_rc=0
kp_run t6_out t6_rc "$KP_BIN/kingpin-watch" --once
[ "$t6_rc" -eq 0 ] && pass "t6: watch --once exits 0" || fail "t6: watch --once exited $t6_rc: $t6_out"
t6_page="$KINGPIN_HOME/tasks/d186-failed/report.html"
grep -q 'data-kingpin-finished' "$t6_page" 2>/dev/null \
  && pass "t6: the sweep marks a failed task's page" \
  || fail "t6: the sweep left the failed task's page unmarked"
grep -q 'finished without a merge' "$t6_page" 2>/dev/null \
  && pass "t6: the banner says the task finished without a merge" \
  || fail "t6: the banner does not report the failed state"
! grep -q 'Merged in' "$t6_page" 2>/dev/null \
  && pass "t6: the failed task's banner names no merge" \
  || fail "t6: the failed task's banner claims a merge"

# Test 7: no page, no call.
echo "=== Test 7: a finished record with no page records no end call ==="
mkdir -p "$KINGPIN_HOME/tasks/d186-nopage"
printf '%s\n' "merged: pr=https://github.com/laanhema/kingpin/pull/219" > "$KINGPIN_HOME/tasks/d186-nopage/status"
printf '%s\n' "https://lavish.example/session/nopage" > "$KINGPIN_HOME/tasks/d186-nopage/dossier.url"
ack_fixture d186-nopage
t7_before=$(end_calls d186-nopage)
t7_out='' t7_rc=0
kp_run t7_out t7_rc "$KP_BIN/kingpin-watch" --once
[ "$t7_rc" -eq 0 ] && pass "t7: watch --once exits 0" || fail "t7: watch --once exited $t7_rc: $t7_out"
[ "$(end_calls d186-nopage)" -eq "$t7_before" ] && [ "$t7_before" -eq 0 ] \
  && pass "t7: no end call is made for a record with no page" \
  || fail "t7: an end call was made for a record with no page"
[ ! -f "$KINGPIN_HOME/tasks/d186-nopage/dossier.ended" ] \
  && pass "t7: no dossier.ended marker is written without a page" \
  || fail "t7: a dossier.ended marker appeared without a page"
# The list section promises that kingpin watch ends the session, so a record the sweep
# skips must not be named there (issue #186 review L2).
t7_list='' t7_list_rc=0
kp_run t7_list t7_list_rc "$KP_BIN/kingpin" list
[ "$t7_list_rc" -eq 0 ] && pass "t7: list exits 0" || fail "t7: list exited $t7_list_rc: $t7_list"
! printf '%s\n' "$t7_list" | grep -A100 'Dossiers left open on finished tasks' | grep -q 'd186-nopage' \
  && pass "t7: list does not name a record the sweep cannot end" \
  || fail "t7: list still names the record with no page: $t7_list"

# Test 8: a minimal page is marked through the fallback host and the quote rule.
echo "=== Test 8: a minimal page with no <main> and a single-quoted handler ==="
mk_min_task d186-min "merged: pr=https://github.com/laanhema/kingpin/pull/219"
t8_out='' t8_rc=0
kp_run t8_out t8_rc "$KP_BIN/kingpin-done" d186-min --force
t8_page="$KINGPIN_HOME/archive/d186-min/report.html"
[ "$t8_rc" -eq 0 ] && [ -f "$t8_page" ] \
  && pass "t8: done archived the minimal page" \
  || fail "t8: done exited $t8_rc without an archived page: $t8_out"
[ "$(sed -n '2p' "$t8_page")" = '<!-- kingpin:finished -->' ] \
  && pass "t8: the banner follows <body> on a page with no <main>" \
  || fail "t8: the banner is not the first child of <body>: $(head -n 3 "$t8_page")"
! grep -q 'onclick' "$t8_page" 2>/dev/null \
  && pass "t8: the single-quoted handler is removed" \
  || fail "t8: the single-quoted handler survives"
grep -qE '<button[^>]*[[:space:]]disabled' "$t8_page" 2>/dev/null \
  && pass "t8: the minimal page's button is disabled" \
  || fail "t8: the minimal page's button is not disabled"

# Test 9: a hand-archived record whose work is not finished is left alone.
echo "=== Test 9: the sweep leaves a hand-archived unfinished record alone ==="
mk_task d186-archived "ready: branch=b review=APPROVE report=none"
mkdir -p "$KINGPIN_HOME/archive"
mv "$KINGPIN_HOME/tasks/d186-archived" "$KINGPIN_HOME/archive/d186-archived"
ln -s "$KINGPIN_HOME/archive/d186-archived" "$KINGPIN_HOME/tasks/d186-archived"
printf '%s\n' "https://lavish.example/session/archived" > "$KINGPIN_HOME/archive/d186-archived/dossier.url"
t9_before=$(end_calls d186-archived)
t9_out='' t9_rc=0
kp_run t9_out t9_rc "$KP_BIN/kingpin-watch" --once
[ "$t9_rc" -eq 0 ] && pass "t9: watch --once exits 0" || fail "t9: watch --once exited $t9_rc: $t9_out"
t9_page="$KINGPIN_HOME/archive/d186-archived/report.html"
! grep -q 'data-kingpin-finished' "$t9_page" 2>/dev/null \
  && pass "t9: the unfinished archived page carries no finished marker" \
  || fail "t9: the sweep marked a hand-archived unfinished record"
[ "$(end_calls d186-archived)" -eq "$t9_before" ] && [ "$t9_before" -eq 0 ] \
  && [ ! -f "$KINGPIN_HOME/archive/d186-archived/dossier.ended" ] \
  && pass "t9: the sweep ends no session for the unfinished archived record" \
  || fail "t9: the sweep recorded an end call for the unfinished archived record"
rm -rf "$KINGPIN_HOME/tasks/d186-archived" "$KINGPIN_HOME/archive/d186-archived" "$T/wt-d186-archived"

# Test 10: a refused cleanup still leaves a recoverable --force path.
echo "=== Test 10: done --force marks a record whose cleanup was refused ==="
mk_task d186-refused "merged: pr=https://github.com/laanhema/kingpin/pull/219"
printf '%s\n' "cleanup-refused: worktree has uncommitted changes" >> "$KINGPIN_HOME/tasks/d186-refused/status"
t10_out='' t10_rc=0
kp_run t10_out t10_rc "$KP_BIN/kingpin-done" d186-refused --force
t10_page="$KINGPIN_HOME/archive/d186-refused/report.html"
[ "$t10_rc" -eq 0 ] && [ -f "$t10_page" ] \
  && pass "t10: done --force archived the refused record" \
  || fail "t10: done exited $t10_rc without an archived page: $t10_out"
grep -q 'data-kingpin-finished' "$t10_page" 2>/dev/null \
  && pass "t10: the archived page carries the finished marker" \
  || fail "t10: the archived page carries no finished marker: $t10_out"
grep -q 'Nothing on this page can be sent' "$t10_page" 2>/dev/null \
  && pass "t10: the banner says nothing on the page can be sent" \
  || fail "t10: the banner is not the finished banner"
! grep -q 'Merged in' "$t10_page" 2>/dev/null \
  && pass "t10: the banner claims no merge the record could not verify" \
  || fail "t10: the banner claims a merge for a cleanup that was refused"
! printf '%s\n' "$t10_out" | grep -q -- '--state must be' \
  && pass "t10: the helper accepted the finished state" \
  || fail "t10: the helper rejected the finished state: $t10_out"

kp_test_finish DOSSIER-RETIRE
