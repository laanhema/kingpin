#!/usr/bin/env bash
# Verification suite for Kingpin issue #221: a merged task's pull request checks are read,
# recorded and shown, so a worker that merges on a red rollup does not archive as clean.
#
# A fake gh answers `pr view <url> --json statusCheckRollup` with a fixture rollup per
# pull request number and records every call, so no case reaches GitHub. The suite drives
# the real `kingpin-watch --once` and the real `kingpin-done` against local bare remotes
# (a verified merge needs an ancestor commit on origin). Covered: a green and an empty
# rollup (silent), a red one (FAILED, the note, the `kingpin list` row, the `OK:` clause and
# the stderr warning), a pending one, the AFK hold and its manual release, an AFK green
# archive, an unreadable pull request (a gh failure, a missing gh) that never fails or holds
# the cleanup, one gh call however often the line replays, a `merged:` line with no `pr=`,
# a forced cleanup that reads nothing, the classifier table, and the status kinds the
# change must leave alone (including the `checks:` note not hiding `merged:`), and
# `kingpin run`, which names a red or pending merge and leaves an AFK hold in place.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "merged-checks"
kp_test_bsd_shims
kp_test_project
kp_test_stub_treehouse
# shellcheck source=../lib/status.sh
. "$KP_ROOT/lib/status.sh"

WATCH_LOG="$T/watch.log"
GH_LOG="$T/gh.log"
GH_ROLLUPS="$T/rollups"
GH_FAIL="$T/gh-fail"
: > "$WATCH_LOG"
: > "$GH_LOG"
mkdir -p "$GH_ROLLUPS"
export KP_TEST_GH_LOG="$GH_LOG" KP_TEST_GH_ROLLUPS="$GH_ROLLUPS" KP_TEST_GH_FAIL="$GH_FAIL"

# The fake: answers only `pr view <url> --json statusCheckRollup`, with the fixture file
# named after the last path segment of the URL, or fails when the flag file exists.
cat > "$T/bin/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KP_TEST_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "pr view")
    if [ -f "${KP_TEST_GH_FAIL:?}" ]; then
      echo "gh: could not resolve host: api.github.com" >&2
      exit 1
    fi
    f="${KP_TEST_GH_ROLLUPS:?}/${3##*/}.json"
    [ -f "$f" ] || { echo "gh: no fixture for $3" >&2; exit 1; }
    cat "$f"
    ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$T/bin/gh"

# The project: a clone of a bare origin whose main every task's branch is merged into, so
# `kingpin done` verifies the merge from the ancestor check.
REMOTE="$T/remote.git"
REPO="$T/mc-repo"
git init --bare -q -b main "$REMOTE"
git clone -q "$REMOTE" "$REPO" 2>/dev/null
(
  cd "$REPO" || exit 1
  git checkout -q -b main
  git config user.name Tester
  git config user.email test@example.com
  echo base > base.txt
  git add base.txt
  git commit -qm base
  git push -q -u origin main
  git remote set-head origin main
)

PR_N=100
MK_URL=''
# kp_run assigns these by name; declare them for shellcheck.
out='' rc=0 list_out='' list_rc=0
rollup() { # <number> <json>
  printf '%s\n' "$2" > "$GH_ROLLUPS/$1.json"
}
GREEN='{"statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"docs","status":"COMPLETED","conclusion":"NEUTRAL"},{"name":"opt","status":"COMPLETED","conclusion":"SKIPPED"}]}'
RED='{"statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"test (done)","status":"COMPLETED","conclusion":"FAILURE"}]}'
RED_STATUS='{"statusCheckRollup":[{"context":"ci/legacy","state":"ERROR"}]}'
PENDING='{"statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"test","status":"IN_PROGRESS","conclusion":null}]}'
PENDING_AND_RED='{"statusCheckRollup":[{"name":"test","status":"QUEUED","conclusion":null},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'

# mk_task <id> <rollup-json|-> [status-line]: a merged, verifiable task with its own
# window (so a sweep never reads it as exited) and a pull request number of its own.
# The fixture is written under that number; "-" writes none. Sets MK_URL.
mk_task() {
  local id=$1 json=$2 line=${3:-} wt
  PR_N=$((PR_N + 1))
  MK_URL="https://github.com/example/demo/pull/$PR_N"
  [ "$json" = "-" ] || rollup "$PR_N" "$json"
  wt="$T/wt-$id"
  git -C "$REPO" fetch -q origin
  git -C "$REPO" worktree add -q "$wt" -b "feature/$id" main
  git -C "$wt" config user.name Tester
  git -C "$wt" config user.email test@example.com
  echo "work $id" > "$wt/$id.txt"
  git -C "$wt" add "$id.txt"
  git -C "$wt" commit -qm "work $id"
  git -C "$wt" push -q origin "feature/$id"
  git -C "$REPO" merge -q --ff-only "feature/$id"
  git -C "$REPO" push -q origin main
  tmux new-window -d -t kingpin: -n "$id" 'exec cat'
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << ENVEOF
TASK_ID=$id
PROJECT=demo-mc
MODE=review
PROJECT_PATH=$REPO
WORKTREE=$wt
BRANCH=feature/$id
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
HARNESS=claude
ENVEOF
  [ -n "$line" ] || line="merged: pr=$MK_URL"
  printf 'issue: #221\n%s\n' "$line" > "$KINGPIN_HOME/tasks/$id/status"
}

run_watch() { "$KP_BIN/kingpin-watch" --once >> "$WATCH_LOG" 2>&1 || true; }

gh_pr_calls() { grep -c '^pr view ' "$GH_LOG" || true; }
gh_calls_for() { grep -cF "pull/$1 " "$GH_LOG" || true; }

# rec <id>: the record's directory, live or archived.
rec() {
  if [ -d "$KINGPIN_HOME/archive/$1" ]; then
    printf '%s\n' "$KINGPIN_HOME/archive/$1"
  else
    printf '%s\n' "$KINGPIN_HOME/tasks/$1"
  fi
}
is_archived() { [ -f "$KINGPIN_HOME/archive/$1/done_cleaned" ]; }
is_live() { [ -d "$KINGPIN_HOME/tasks/$1" ] && [ ! -L "$KINGPIN_HOME/tasks/$1" ] && [ ! -f "$KINGPIN_HOME/tasks/$1/done_cleaned" ]; }
checks_lines() { grep -c '^checks:' "$(rec "$1")/status" || true; }
result_word() { sed -n 1p "$(rec "$1")/checks.result" 2>/dev/null || true; }
result_detail() { sed -n 3p "$(rec "$1")/checks.result" 2>/dev/null || true; }
last_status() { tail -n 1 "$(rec "$1")/status"; }

afk_on() { "$KP_BIN/kingpin" afk on --ttl 1h >/dev/null; }
afk_off() { "$KP_BIN/kingpin" afk off >/dev/null 2>&1 || true; }

# Test 1: a green rollup is silent. The task archives, no checks: line, no clause.
echo "=== Test 1: a green rollup records PASSED and nothing visible ==="
mk_task g1 "$GREEN"
run_watch
is_archived g1 && pass "green: the task archived" || fail "green: g1 not archived: $(tail -5 "$WATCH_LOG")"
[ "$(result_word g1)" = PASSED ] && pass "green: checks.result reads PASSED" || fail "green: result is '$(result_word g1)'"
[ "$(checks_lines g1)" = 0 ] && pass "green: no checks: line" || fail "green: a checks: line was written: $(cat "$(rec g1)/status")"
[ "$(gh_calls_for "$PR_N")" = 1 ] && pass "green: one gh call" || fail "green: gh was called $(gh_calls_for "$PR_N") times"
mk_task g2 "$GREEN"
kp_run out rc "$KP_BIN/kingpin-done" g2
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -qi "checks"; then
  pass "green: kingpin done has no checks clause"
else
  fail "green: done said: $out"
fi

# Test 2: an empty rollup and a missing key are PASSED, with the same silence.
echo "=== Test 2: an empty or missing rollup is PASSED ==="
mk_task e1 '{"statusCheckRollup":[]}'
mk_task e2 '{}'
run_watch
for id in e1 e2; do
  if is_archived "$id" && [ "$(result_word "$id")" = PASSED ] && [ "$(checks_lines "$id")" = 0 ]; then
    pass "$id: archived, PASSED, no note"
  else
    fail "$id: state '$(result_word "$id")' lines $(checks_lines "$id")"
  fi
done

# Test 3: a red rollup. The note, the list row, the OK: clause, the warning, exit 0.
echo "=== Test 3: a red rollup is recorded, listed and named by kingpin done ==="
mk_task r1 "$RED"
r1_url=$MK_URL
run_watch
is_archived r1 && pass "red: the cleanup still archived the task" || fail "red: r1 not archived"
[ "$(result_word r1)" = FAILED ] && pass "red: checks.result reads FAILED" || fail "red: result '$(result_word r1)'"
[ "$(result_detail r1)" = "test (done)" ] && pass "red: the failing check is named" || fail "red: detail '$(result_detail r1)'"
[ "$(last_status r1)" = "checks: pr=$r1_url checks=FAILED" ] \
  && pass "red: the status ends with the checks: note" || fail "red: status ends '$(last_status r1)'"
[ "$(checks_lines r1)" = 1 ] && pass "red: exactly one note" || fail "red: $(checks_lines r1) notes"
kp_run list_out list_rc "$KP_BIN/kingpin" list --all
if printf '%s\n' "$list_out" | grep -F "r1 " | grep -qF "checks: pr=$r1_url checks=FAILED"; then
  pass "red: kingpin list --all shows the note in the row"
else
  fail "red: list (rc $list_rc) row: $(printf '%s\n' "$list_out" | grep -F 'r1 ' || true)"
fi
[ "$(kp_status_last "$(rec r1)/status")" = "merged: pr=$r1_url" ] \
  && pass "red: kp_status_last still returns the merged: line" || fail "red: last event is '$(kp_status_last "$(rec r1)/status")'"
kp_task_is_finished "$(rec r1)" && pass "red: the record is still finished" || fail "red: the record is not finished"

mk_task r2 "$RED"
r2_url=$MK_URL
kp_run out rc "$KP_BIN/kingpin-done" r2
[ "$rc" = 0 ] && pass "red: kingpin done exits 0" || fail "red: kingpin done exited $rc: $out"
if printf '%s' "$out" | grep -qF "OK: cleaned up task r2" && printf '%s' "$out" | grep -qF "; pull request checks FAILED ($r2_url)"; then
  pass "red: the OK: line names the failed checks"
else
  fail "red: OK line: $out"
fi
mk_task r3 "$RED"
"$KP_BIN/kingpin-done" r3 > "$T/r3.out" 2> "$T/r3.err" || true
if grep -qF "kingpin-done: warning: the checks on $MK_URL were FAILED when the task merged" "$T/r3.err" \
   && ! grep -qF "warning" "$T/r3.out"; then
  pass "red: the warning is on stderr only"
else
  fail "red: stderr '$(cat "$T/r3.err")' stdout '$(cat "$T/r3.out")'"
fi

mk_task r4 "$RED_STATUS"
run_watch
if [ "$(result_word r4)" = FAILED ] && [ "$(result_detail r4)" = "ci/legacy" ]; then
  pass "red: a commit status ERROR reads FAILED"
else
  fail "red: r4 result '$(result_word r4)' '$(result_detail r4)'"
fi

# Test 4: a pending rollup is PENDING; a pending plus a red entry is FAILED.
echo "=== Test 4: pending and mixed rollups ==="
mk_task p1 "$PENDING"
p1_url=$MK_URL
mk_task p2 "$PENDING_AND_RED"
run_watch
if [ "$(result_word p1)" = PENDING ] && [ "$(last_status p1)" = "checks: pr=$p1_url checks=PENDING" ]; then
  pass "pending: PENDING recorded and noted"
else
  fail "pending: '$(result_word p1)' / '$(last_status p1)'"
fi
[ "$(result_word p2)" = FAILED ] && pass "pending plus red reads FAILED" || fail "mixed: '$(result_word p2)'"
mk_task p3 "$PENDING"
kp_run out rc "$KP_BIN/kingpin-done" p3
printf '%s' "$out" | grep -qF "; pull request checks still PENDING at merge (" \
  && pass "pending: the OK: line says still PENDING" || fail "pending: OK line: $out"

# Test 5: AFK armed. Red and pending hold, green archives, a manual done releases.
echo "=== Test 5: AFK holds a FAILED or PENDING merged task ==="
afk_on
mk_task a1 "$RED"
a1_url=$MK_URL
mk_task a2 "$PENDING"
mk_task a3 "$GREEN"
run_watch
for id in a1 a2; do
  is_live "$id" && pass "$id: held, the task directory stays live" || fail "$id: was cleaned up under AFK"
  [ ! -f "$KINGPIN_HOME/tasks/$id/done_cleaned" ] && pass "$id: no done_cleaned" || fail "$id: done_cleaned exists"
done
grep -qF "[kingpin-watch] a1 merged but its pull request checks are FAILED (afk on); holding the cleanup for the operator: kingpin done a1" "$WATCH_LOG" \
  && pass "the supervisor log names the hold and the command" || fail "no hold line for a1: $(grep ' a1 ' "$WATCH_LOG" || true)"
grep -qF "a2 merged but its pull request checks are PENDING" "$WATCH_LOG" \
  && pass "the PENDING hold is named" || fail "no hold line for a2"
is_archived a3 && pass "AFK: a green rollup archives" || fail "AFK: a3 was held"
[ "$(last_status a1)" = "checks: pr=$a1_url checks=FAILED" ] \
  && pass "the held task carries the checks: note" || fail "held a1 status ends '$(last_status a1)'"
run_watch
grep -qF "a1 merged with checks that were not green: checks: pr=$a1_url checks=FAILED" "$WATCH_LOG" \
  && pass "the checks: note is logged for the operator" || fail "the checks: note was not logged"
kp_run list_out list_rc "$KP_BIN/kingpin" list
if printf '%s\n' "$list_out" | grep -F "a1 " | grep -qF "checks: pr=$a1_url checks=FAILED"; then
  pass "kingpin list shows the held task's note"
else
  fail "list (rc $list_rc) row: $(printf '%s\n' "$list_out" | grep -F 'a1 ' || true)"
fi
kp_run out rc "$KP_BIN/kingpin-done" a1
if [ "$rc" = 0 ] && is_archived a1 && printf '%s' "$out" | grep -qF "pull request checks FAILED"; then
  pass "a manual kingpin done archives the held task with the warning"
else
  fail "manual done: rc $rc: $out"
fi
afk_off

# Test 6: AFK off, red rollup: the cleanup runs and the result is recorded.
echo "=== Test 6: without AFK a red rollup archives ==="
mk_task o1 "$RED"
run_watch
if is_archived o1 && [ "$(result_word o1)" = FAILED ]; then
  pass "AFK off: red archives and is recorded"
else
  fail "AFK off: o1 state '$(result_word o1)'"
fi

# Test 7: an unreadable pull request is recorded and never fails or holds the cleanup.
echo "=== Test 7: an unreadable pull request ==="
: > "$GH_FAIL"
mk_task u1 "$GREEN"
run_watch
is_archived u1 && pass "unreadable: the cleanup archived the task" || fail "unreadable: u1 not archived"
[ "$(result_word u1)" = UNREADABLE ] && pass "unreadable: checks.result reads UNREADABLE" || fail "unreadable: '$(result_word u1)'"
case "$(result_detail u1)" in
  *"could not resolve host"*) pass "unreadable: the reason is recorded" ;;
  *) fail "unreadable: reason '$(result_detail u1)'" ;;
esac
[ "$(checks_lines u1)" = 0 ] && pass "unreadable: no status note" || fail "unreadable: a note was written"
mk_task u2 "$GREEN"
kp_run out rc "$KP_BIN/kingpin-done" u2
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "; pull request checks not read (gh pr view failed: gh: could not resolve host"; then
  pass "unreadable: kingpin done exits 0 and names the reason"
else
  fail "unreadable: rc $rc: $out"
fi
afk_on
mk_task u3 "$GREEN"
run_watch
is_archived u3 && pass "unreadable: AFK does not hold" || fail "unreadable: u3 held under AFK"
afk_off
rm -f "$GH_FAIL"
mk_task u4 "$GREEN"
KINGPIN_GH="$T/bin/gh-does-not-exist" run_watch
if is_archived u4 && [ "$(result_word u4)" = UNREADABLE ] && grep -q 'is not available' "$(rec u4)/checks.result"; then
  pass "a missing gh is UNREADABLE and the cleanup completes"
else
  fail "missing gh: '$(result_word u4)'"
fi
mk_task u5 "$GREEN"
before=$(gh_pr_calls)
kp_run out rc env KINGPIN_GH="$T/bin/gh-does-not-exist" "$KP_BIN/kingpin-done" u5
if [ "$rc" = 0 ] && [ "$(gh_pr_calls)" = "$before" ] && printf '%s' "$out" | grep -qF "pull request checks not read ("; then
  pass "done with a missing gh exits 0 and calls nothing"
else
  fail "done with a missing gh: rc $rc: $out"
fi
# Node absent: a PATH of symlinks to every tool the cleanup needs except node. When that
# PATH cannot run the cleanup at all on a host, the case says so instead of guessing.
node_free="$T/nonode-bin"
mkdir -p "$node_free"
for tool in bash env git sed tr head tail grep cat mktemp mv rm date dirname basename awk wc sleep ln touch mkdir cp ps kill tmux treehouse gh lavish-axi stat uname id cut sort readlink ls; do
  src=$(PATH="$T/bin:$PATH" command -v "$tool" 2>/dev/null || true)
  if [ -n "$src" ]; then ln -sf "$src" "$node_free/$tool"; fi
done
mk_task u6 "$GREEN"
before=$(gh_pr_calls)
kp_run out rc env PATH="$node_free" "$KP_BIN/kingpin-done" u6
if is_archived u6; then
  if [ "$(result_word u6)" = UNREADABLE ] && grep -q 'node is not available' "$(rec u6)/checks.result" && [ "$(gh_pr_calls)" = "$before" ]; then
    pass "a missing node is UNREADABLE and the cleanup completes"
  else
    fail "no node: '$(result_word u6)' $out"
  fi
else
  pass "no node: skipped (a PATH without node cannot run the cleanup here: $out)"
fi

# Test 8: idempotence. One gh call however often the line replays.
echo "=== Test 8: the rollup is read once ==="
afk_on
mk_task i1 "$RED"
i1_n=$PR_N
run_watch
run_watch
# Replay the merged: line: put the cursor back to the line before it.
printf '1\n' > "$KINGPIN_HOME/tasks/i1/seen"
sed -n 1p "$KINGPIN_HOME/tasks/i1/status" > "$KINGPIN_HOME/tasks/i1/seen_line"
run_watch
[ "$(gh_calls_for "$i1_n")" = 1 ] && pass "a replayed merged: line makes one gh call" || fail "gh calls for i1: $(gh_calls_for "$i1_n")"
[ "$(checks_lines i1)" = 1 ] && pass "a replay appends one checks: line" || fail "i1 has $(checks_lines i1) checks: lines"
kp_run out rc "$KP_BIN/kingpin-done" i1
[ "$(gh_calls_for "$i1_n")" = 1 ] && pass "kingpin done reuses the recorded result" || fail "done re-read the rollup"
printf '%s' "$out" | grep -qF "pull request checks FAILED" && pass "done names a result the supervisor recorded" || fail "done: $out"
afk_off

# Test 9: a merged: line with no pr= reads nothing.
echo "=== Test 9: no pr= field ==="
mk_task n1 "$GREEN" "merged: landed by hand"
before=$(gh_pr_calls)
run_watch
if is_archived n1 && [ "$(gh_pr_calls)" = "$before" ] && [ ! -f "$(rec n1)/checks.result" ]; then
  pass "no pr=: no gh call, no result file, still archived"
else
  fail "no pr=: calls $(( $(gh_pr_calls) - before )), files: $(ls "$(rec n1)")"
fi

# Test 10: a --force cleanup of a task nobody checked makes no pr view call.
echo "=== Test 10: --force reads nothing ==="
mk_task f1 "$RED"
before=$(gh_pr_calls)
kp_run out rc "$KP_BIN/kingpin-done" f1 --force
if [ "$rc" = 0 ] && is_archived f1 && [ "$(gh_pr_calls)" = "$before" ] && [ ! -f "$(rec f1)/checks.result" ]; then
  pass "--force: archived with no pr view call"
else
  fail "--force: rc $rc calls $(( $(gh_pr_calls) - before )): $out"
fi

# Test 11: the classifier, one rollup per row.
echo "=== Test 11: the classifier table ==="
classify() { printf '%s' "$1" | node "$KP_ROOT/lib/pr-checks.mjs" | head -n 1; }
while IFS='|' read -r want json; do
  [ -n "$want" ] || continue
  got=$(classify "$json")
  [ "$got" = "$want" ] && pass "classifier: $want for $json" || fail "classifier: expected $want, got '$got' for $json"
done << 'TABLE'
PASSED|{"statusCheckRollup":[]}
PASSED|{}
PASSED|{"statusCheckRollup":null}
PASSED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"NEUTRAL"},{"status":"COMPLETED","conclusion":"SKIPPED"},{"state":"SUCCESS"}]}
FAILED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}
FAILED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"CANCELLED"}]}
FAILED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"TIMED_OUT"}]}
FAILED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"ACTION_REQUIRED"}]}
FAILED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"STARTUP_FAILURE"}]}
FAILED|{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"STALE"}]}
FAILED|{"statusCheckRollup":[{"state":"FAILURE"}]}
FAILED|{"statusCheckRollup":[{"state":"ERROR"}]}
PENDING|{"statusCheckRollup":[{"status":"IN_PROGRESS"}]}
PENDING|{"statusCheckRollup":[{"status":"QUEUED"}]}
PENDING|{"statusCheckRollup":[{"state":"PENDING"}]}
PENDING|{"statusCheckRollup":[{"state":"EXPECTED"}]}
FAILED|{"statusCheckRollup":[{"state":"EXPECTED"},{"status":"COMPLETED","conclusion":"FAILURE"}]}
TABLE
bad_rc=0
printf 'not json' | node "$KP_ROOT/lib/pr-checks.mjs" >/dev/null 2>&1 || bad_rc=$?
[ "$bad_rc" = 1 ] && pass "classifier: invalid JSON exits 1" || fail "classifier: invalid JSON exit $bad_rc"

# Test 12: the other status kinds dispatch as before, and the note does not hide merged:.
echo "=== Test 12: other status kinds and the checks: note ==="
mk_task k1 "$GREEN" "ready: branch=b review=APPROVE report=none"
# needs-input: comes last: a cleanup-refused: last event is retried by the supervisor.
for extra in "cleanup-refused: dirty" "approved: via dossier" "feedback: please redo" "fixed: branch=b review=APPROVE report=none" "failed: boom" "needs-input: which flag?"; do
  printf '%s\n' "$extra" >> "$KINGPIN_HOME/tasks/k1/status"
done
before=$(gh_pr_calls)
run_watch
[ "$(gh_pr_calls)" = "$before" ] && pass "no other status kind makes a gh call" || fail "a gh call came from another kind"
is_live k1 && pass "none of them archives the task" || fail "k1 was archived by another status kind"
mk_task k2 "$GREEN"
k2_status="$KINGPIN_HOME/tasks/k2/status"
printf 'checks: pr=%s checks=FAILED\n' "$MK_URL" >> "$k2_status"
[ "$(kp_status_last "$k2_status")" = "merged: pr=$MK_URL" ] \
  && pass "a trailing checks: note leaves merged: the last event" || fail "last event moved to '$(kp_status_last "$k2_status")'"
[ "$(kp_status_worker_events "$k2_status")" = 2 ] \
  && pass "the note is not counted as a worker event" || fail "worker events: $(kp_status_worker_events "$k2_status")"
[ "$(kp_task_state "$k2_status" dead)" != DEAD ] \
  && pass "kp_task_state does not read the task as DEAD" || fail "kp_task_state read the task as DEAD"
kp_task_is_finished "$KINGPIN_HOME/tasks/k2" && pass "the task is still finished" || fail "the checks: note unfinished the task"
kp_run out rc "$KP_BIN/kingpin" restore k2
if printf '%s' "$out" | grep -qF "merged: pr=$MK_URL; run kingpin done k2"; then
  pass "restore treats the task as finished"
else
  fail "restore (rc $rc) said: $out"
fi

# Test 13: kingpin run. A scratch copy of the tree whose kingpin-spawn only names a task
# that mk_task already made, so `run` drives the real supervisor pass and the real cleanup.
# A red or pending merge is named on stderr instead of the clean line, an AFK-armed run
# does not clean it up behind the supervisor's hold, and a green merge keeps the clean line.
echo "=== Test 13: kingpin run reports the checks of a merged task ==="
RUN_COPY="$T/run-copy"
mkdir -p "$RUN_COPY"
tar -C "$KP_ROOT" --exclude=.git --exclude=.agents -cf - bin lib worker orchestrator | tar -xf - -C "$RUN_COPY"
cat > "$RUN_COPY/bin/kingpin-spawn" << 'SPEOF'
#!/usr/bin/env bash
echo "OK: spawned ${KP_TEST_RUN_ID:?} in a stub"
SPEOF
chmod +x "$RUN_COPY/bin/kingpin-spawn"
run_task() { # <id>
  KP_TEST_RUN_ID=$1 kp_run out rc timeout 60 "$RUN_COPY/bin/kingpin" run demo-mc --text x --id "$1"
}

afk_off
mk_task q1 "$RED"
run_task q1
if [ "$rc" = 0 ] && is_archived q1 && printf '%s' "$out" | grep -qF "kingpin run: q1 merged and cleaned up, but pull request checks FAILED ($MK_URL)" \
   && ! printf '%s' "$out" | grep -qF "OK: q1 merged and cleaned up successfully."; then
  pass "run: a red merge is named and the clean line is not printed"
else
  fail "run q1 (rc $rc): $out"
fi
mk_task q2 "$PENDING"
run_task q2
if [ "$rc" = 0 ] && is_archived q2 && printf '%s' "$out" | grep -qF "but pull request checks still PENDING at merge" \
   && ! printf '%s' "$out" | grep -qF "OK: q2 merged and cleaned up successfully."; then
  pass "run: a pending merge is named"
else
  fail "run q2 (rc $rc): $out"
fi
# Negative control: a green merge keeps the clean line and says nothing about checks.
mk_task q3 "$GREEN"
run_task q3
if [ "$rc" = 0 ] && is_archived q3 && printf '%s' "$out" | grep -qF "OK: q3 merged and cleaned up successfully." \
   && ! printf '%s' "$out" | grep -qF "checks"; then
  pass "run: a green merge prints the clean line only"
else
  fail "run q3 (rc $rc): $out"
fi
# The direct cleanup path: the supervisor pass inside run has nothing to dispatch (its
# cursor is past the merged: line), so run itself reaches kingpin-done.
mk_task q4 "$RED"
printf '2\n' > "$KINGPIN_HOME/tasks/q4/seen"
sed -n 2p "$KINGPIN_HOME/tasks/q4/status" > "$KINGPIN_HOME/tasks/q4/seen_line"
run_task q4
if [ "$rc" = 0 ] && is_archived q4 && printf '%s' "$out" | grep -qF "but pull request checks FAILED"; then
  pass "run: the direct cleanup names a red merge too"
else
  fail "run q4 (rc $rc): $out"
fi
# AFK armed: the red merge stays live, run exits 1 naming the hold; green still archives.
afk_on
mk_task q5 "$RED"
run_task q5
if [ "$rc" = 1 ] && is_live q5 && [ ! -f "$KINGPIN_HOME/tasks/q5/done_cleaned" ] \
   && printf '%s' "$out" | grep -qF "kingpin run: q5 merged but pull request checks FAILED" \
   && printf '%s' "$out" | grep -qF "the cleanup is held for the operator: kingpin done q5" \
   && ! printf '%s' "$out" | grep -qF "merged and cleaned up"; then
  pass "run under AFK: a red merge is held and run exits 1"
else
  fail "run q5 (rc $rc): $out"
fi
mk_task q6 "$GREEN"
run_task q6
if [ "$rc" = 0 ] && is_archived q6 && printf '%s' "$out" | grep -qF "OK: q6 merged and cleaned up successfully."; then
  pass "run under AFK: a green merge archives with the clean line"
else
  fail "run q6 (rc $rc): $out"
fi
afk_off

kp_test_finish MERGED-CHECKS
