#!/usr/bin/env bash
# Verification test for Kingpin: a landed task keeps a resolvable dossier path, and
# the live fleet never treats the archived task as a task (issue #115).
#
# The checked contract: `kingpin done` leaves a symlink at tasks/<id> for the
# archive, the dossier opens through it, and list/wait/watch/land/listen/spawn/ack
# all read that path as finished, so nothing dispatches, lands or cleans it twice.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "archive-link"
kp_test_project
# The fixtures below were never leased from a pool, so the real `treehouse return`
# refuses them; the cleanup under test is about archiving, not the lease.
kp_test_stub_treehouse

# A logging Lavish stand-in: the suite must never reach the real Lavish server, and
# the final reply is half of what issue #115 asks for.
cat > "$T/mock-lavish" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/lavish.log"
case "\${1:-}" in
  poll) sleep 0.2 ;;
  *) echo "OK" ;;
esac
EOF
chmod +x "$T/mock-lavish"
export KINGPIN_LAVISH="$T/mock-lavish"
lav_log() { cat "$T/lavish.log" 2>/dev/null || true; }

# mk_task <id> <last-status>: a review-mode record with a dossier and a worktree.
mk_task() {
  local id=$1 status=$2 d="$KINGPIN_HOME/tasks/$1" wt="$T/wt-$1"
  mkdir -p "$d" "$wt"
  git -C "$wt" init -q
  printf '<html><body>dossier for %s</body></html>\n' "$id" > "$d/report.html"
  cat > "$d/task.env" << ENVEOF
TASK_ID=$id
PROJECT=demo-auto
HARNESS=claude
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$wt
TMUX_TARGET=kingpin:$id
ENVEOF
  printf '%s\n' "$status" > "$d/status"
}

echo "=== Test 1: kingpin done keeps the dossier path, and answers it once ==="
mk_task t1 "merged: pr=https://example.invalid/pull/1"
if "$KP_BIN/kingpin-done" t1 >"$T/t1.out" 2>&1; then
  pass "t1: done archived the merged task"
else
  fail "t1: done failed: $(cat "$T/t1.out")"
fi
[ -L "$KINGPIN_HOME/tasks/t1" ] && pass "t1: done left a symlink at the task path" || fail "t1: no symlink at tasks/t1"
[ "$(readlink "$KINGPIN_HOME/tasks/t1")" = "$(cd "$KINGPIN_HOME/archive/t1" && pwd -P)" ] && pass "t1: the link names the archive by its resolved path" || fail "t1: link target is $(readlink "$KINGPIN_HOME/tasks/t1" 2>/dev/null)"
grep -q "dossier for t1" "$KINGPIN_HOME/tasks/t1/report.html" 2>/dev/null \
  && pass "t1: the dossier reopens through the old path" \
  || fail "t1: tasks/t1/report.html does not resolve"

t1_reply_count=$(lav_log | grep -c '^reply ' || true)
[ "$t1_reply_count" = "1" ] && pass "t1: the merge posts one final Lavish reply" || fail "t1: expected 1 reply, got $t1_reply_count"
lav_log | grep '^reply ' | grep -q "t1 landed" && lav_log | grep '^reply ' | grep -q "archived at $KINGPIN_HOME/archive/t1" \
  && pass "t1: the reply names the task and the archive" \
  || fail "t1: reply text does not name the archive: $(lav_log | grep '^reply ' || true)"
lav_log | grep -q '^end ' && pass "t1: the session is ended after the reply" || fail "t1: no end call"

# A fleet can run under a relative KINGPIN_HOME (nothing requires an absolute one).
# The link target must still be absolute: taken straight from the relative archive
# path it would resolve against tasks/ and dangle, and the dossier would be dead
# again in exactly the configuration the link exists for.
echo "=== Test 1b: a relative KINGPIN_HOME still leaves a resolvable dossier link ==="
rel_root="$T/rel-home"
mkdir -p "$rel_root/kp/tasks/r1" "$T/wt-r1"
git -C "$T/wt-r1" init -q
printf '<html><body>dossier for r1</body></html>\n' > "$rel_root/kp/tasks/r1/report.html"
cat > "$rel_root/kp/tasks/r1/task.env" << ENVEOF
TASK_ID=r1
PROJECT=demo-auto
HARNESS=claude
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$T/wt-r1
TMUX_TARGET=kingpin:r1
ENVEOF
printf 'merged: pr=https://example.invalid/pull/3\n' > "$rel_root/kp/tasks/r1/status"
rel_rc=0
( cd "$rel_root" && KINGPIN_HOME=kp "$KP_BIN/kingpin-done" r1 ) >"$T/t1rel.out" 2>&1 || rel_rc=$?
[ "$rel_rc" -eq 0 ] && pass "t1r: done exits 0 under a relative KINGPIN_HOME" || fail "t1r: done exited $rel_rc: $(cat "$T/t1rel.out")"
rel_base=$(cd "$rel_root" && pwd -P)
rel_target=$(readlink "$rel_root/kp/tasks/r1" 2>/dev/null || true)
[ -L "$rel_root/kp/tasks/r1" ] && pass "t1r: done left a link at the relative task path" || fail "t1r: no link at kp/tasks/r1: $rel_target"
[ "$rel_target" = "$rel_base/kp/archive/r1" ] && pass "t1r: the link target is absolute" || fail "t1r: link target is $rel_target, want $rel_base/kp/archive/r1"
grep -q "dossier for r1" "$rel_root/kp/tasks/r1/report.html" 2>/dev/null \
  && pass "t1r: the dossier resolves through the relative-home link" \
  || fail "t1r: kp/tasks/r1/report.html does not resolve"

echo "=== Test 2: cleanup stays idempotent, and the archive is the record ==="
# The archive's entries, one line, for a before/after comparison.
archive_entries() { find "$1" -mindepth 1 -maxdepth 1 -print | sed 's|.*/||' | sort | tr '\n' ' '; }
archive_marker_before=$(archive_entries "$KINGPIN_HOME/archive/t1")
if "$KP_BIN/kingpin-done" t1 >"$T/t1-again.out" 2>&1; then
  pass "t2: a second done on the archived task exits 0"
else
  fail "t2: a second done failed: $(cat "$T/t1-again.out")"
fi
grep -q "already cleaned up" "$T/t1-again.out" && pass "t2: the second run says it is already cleaned up" || fail "t2: second run said: $(cat "$T/t1-again.out")"
[ "$(archive_entries "$KINGPIN_HOME/archive/t1")" = "$archive_marker_before" ] && pass "t2: the second run left the archive untouched" || fail "t2: the archive changed: $(archive_entries "$KINGPIN_HOME/archive/t1")"
[ ! -e "$KINGPIN_HOME/archive/t1.2" ] && pass "t2: no second archive of the same task" || fail "t2: a duplicate archive was created"

# The slot guard reads tasks/*/task.env, which the dossier link still matches: an
# archived task holds no lease, so it must not guard a slot from the next task.
mk_task t1b "merged: pr=https://example.invalid/pull/2"
kp_test_sub "$KINGPIN_HOME/tasks/t1b/task.env" "s|^WORKTREE=.*|WORKTREE=$T/wt-t1|"
if "$KP_BIN/kingpin-done" t1b --force >"$T/t1b.out" 2>&1; then
  pass "t2: a task reusing the archived task's worktree cleans up"
else
  fail "t2: the slot guard read the archived task as a holder: $(cat "$T/t1b.out")"
fi
[ -f "$KINGPIN_HOME/archive/t1b/done_cleaned" ] && pass "t2: the reusing task reached the archive" || fail "t2: the reusing task was not archived"
rm -rf "$KINGPIN_HOME/archive/t1b" "$KINGPIN_HOME/tasks/t1b"

echo "=== Test 3: list shows the archived task once, never as live ==="
t1_live_rows=$("$KP_BIN/kingpin" list 2>/dev/null | grep -c '^t1 ' || true)
[ "$t1_live_rows" = "0" ] && pass "t3: list has no live row for the archived task" || fail "t3: list showed $t1_live_rows live row(s)"
t1_all_rows=$("$KP_BIN/kingpin" list --all 2>/dev/null | grep -c '^t1 ' || true)
[ "$t1_all_rows" = "1" ] && pass "t3: list --all shows the archived task exactly once" || fail "t3: list --all showed $t1_all_rows row(s)"
"$KP_BIN/kingpin" list --all 2>/dev/null | grep '^t1 ' | grep -q '(archived)' && pass "t3: the row is marked (archived)" || fail "t3: the row is not marked archived"

echo "=== Test 4: kingpin wait reports no event for the archived task ==="
# The status carries an event the cursor never acknowledged: an unguarded wait
# reports it, so this is the assertion that fails without the fix.
[ -s "$KINGPIN_HOME/tasks/t1/status" ] && [ ! -f "$KINGPIN_HOME/tasks/t1/seen" ] \
  && pass "t4: the archived record still holds unseen events" \
  || fail "t4: fixture has no unseen events to ignore"
set +e
wait_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null)
wait_rc=$?
set -e
! printf '%s\n' "$wait_out" | grep -q '^t1 ' && pass "t4: wait printed no event for the archived task" || fail "t4: wait printed: $wait_out"
[ "$wait_rc" -eq 1 ] && pass "t4: wait --once exits 1 on the quiet fleet it now sees" || fail "t4: wait --once exited $wait_rc"

echo "=== Test 5: kingpin watch never resurrects an archived task ==="
# Hand-archive a review-ready record: the status itself invites a dispatch
# (landing in auto mode, a dossier listener in review mode).
mk_task t2 "ready: branch=b review=APPROVE report=none"
mkdir -p "$KINGPIN_HOME/archive"
mv "$KINGPIN_HOME/tasks/t2" "$KINGPIN_HOME/archive/t2"
ln -s "$KINGPIN_HOME/archive/t2" "$KINGPIN_HOME/tasks/t2"
watch_out=$("$KP_BIN/kingpin" watch --once 2>&1 || true)
! printf '%s\n' "$watch_out" | grep -q "t2" && pass "t5: watch dispatched nothing for the archived task" || fail "t5: watch said: $watch_out"
[ ! -f "$KINGPIN_HOME/archive/t2/landing_sent" ] && [ ! -f "$KINGPIN_HOME/archive/t2/listener.pid" ] \
  && pass "t5: no landing and no listener started for it" \
  || fail "t5: the archived task was dispatched"
[ ! -f "$KINGPIN_HOME/archive/t2/lease-lost" ] && pass "t5: no cleanup was attempted for it" || fail "t5: watch tried to clean it up"
rm -rf "$KINGPIN_HOME/tasks/t2" "$KINGPIN_HOME/archive/t2" "$T/wt-t2"

echo "=== Test 6: listen and land resolve an archived id ==="
listen_out=$("$KP_BIN/kingpin-listen" t1 2>&1) && listen_rc=0 || listen_rc=$?
[ "$listen_rc" -eq 0 ] && pass "t6: listen on an archived id exits 0" || fail "t6: listen exited $listen_rc: $listen_out"
printf '%s\n' "$listen_out" | grep -q "finished" && printf '%s\n' "$listen_out" | grep -q "$KINGPIN_HOME/archive/t1" \
  && pass "t6: listen says the task is finished and names the archive" \
  || fail "t6: listen said: $listen_out"

land_out=$("$KP_BIN/kingpin-land" t1 2>&1) && land_rc=0 || land_rc=$?
[ "$land_rc" -eq 0 ] && pass "t6: land on an archived id exits 0" || fail "t6: land exited $land_rc: $land_out"
printf '%s\n' "$land_out" | grep -q "nothing to land" && pass "t6: land says there is nothing to land" || fail "t6: land said: $land_out"
[ ! -f "$KINGPIN_HOME/archive/t1/landing_sent" ] && pass "t6: land dispatched nothing" || fail "t6: land created landing_sent"
lock_files=$(find "$KINGPIN_HOME/projects" -maxdepth 1 -name '*.landing' | wc -l | tr -d ' ')
[ "$lock_files" = "0" ] && pass "t6: land took no project landing lock" || fail "t6: land left a landing lock behind"

echo "=== Test 7: ack and spawn treat the archived id as finished ==="
ack_out=$("$KP_BIN/kingpin-ack" t1 2>&1) && ack_rc=0 || ack_rc=$?
[ "$ack_rc" -eq 0 ] && pass "t7: ack on the archived id exits 0" || fail "t7: ack exited $ack_rc: $ack_out"
printf '%s\n' "$ack_out" | grep -q "already archived" && pass "t7: ack says the task is archived" || fail "t7: ack said: $ack_out"
[ ! -f "$KINGPIN_HOME/archive/t1/seen" ] && pass "t7: ack wrote no cursor into the archive" || fail "t7: ack wrote seen into the archive"

set +e
spawn_out=$("$KP_BIN/kingpin" spawn demo-auto --issue 115 --id t1 2>&1)
spawn_rc=$?
set -e
[ "$spawn_rc" -ne 0 ] && pass "t7: spawn refuses an archived task id" || fail "t7: spawn accepted an archived id"
printf '%s\n' "$spawn_out" | grep -q "already finished and archived at $KINGPIN_HOME/archive/t1" \
  && pass "t7: spawn names the archive it refused" \
  || fail "t7: spawn said: $spawn_out"
[ -L "$KINGPIN_HOME/tasks/t1" ] && [ ! -d "$KINGPIN_HOME/archive/t1/.opencode" ] && [ ! -d "$KINGPIN_HOME/archive/t1/.agents" ] \
  && pass "t7: the refused spawn wrote no harness files into the archive" \
  || fail "t7: the refused spawn touched the archive"

# A dangling dossier link (its archive deleted by hand) is still a taken name for
# the generated id: the spawn steps to the -2 suffix instead of stopping on the
# link and refusing an id the caller never chose. The lease request names the id,
# so it is where the choice shows.
dangling=kp-dangling-dossier-link
ln -s "$KINGPIN_HOME/archive/$dangling" "$KINGPIN_HOME/tasks/$dangling"
KP_TREEHOUSE_CALLS="$T/dangling-treehouse.log" "$KP_BIN/kingpin" spawn demo-auto \
  --text "Dangling dossier link" >"$T/t7-dangling.out" 2>&1 || true
! grep -q "already finished and archived" "$T/t7-dangling.out" \
  && pass "t7: the auto id does not refuse a name taken only by a dangling link" \
  || fail "t7: the spawn stopped on the dangling link: $(cat "$T/t7-dangling.out")"
grep -q -- '--lease -b kingpin/kp-dangling-dossier-link-2' "$T/dangling-treehouse.log" 2>/dev/null \
  && pass "t7: the auto id steps past the dangling link to -2" \
  || fail "t7: no lease request for the -2 id: $(cat "$T/dangling-treehouse.log" 2>/dev/null || true)"
rm -f "$KINGPIN_HOME/tasks/$dangling"

echo "=== Test 8: a running listener answers its own archived task and stops ==="
mk_task t3 "ready: branch=b review=APPROVE report=none"
"$KP_BIN/kingpin-listen" t3 >"$T/t3-listener.log" 2>&1 &
t3_pid=$!
t3_ready=0
for _ in $(seq 1 60); do
  [ -f "$KINGPIN_HOME/tasks/t3/listener.pid" ] && { t3_ready=1; break; }
  sleep 0.05
done
[ "$t3_ready" -eq 1 ] && pass "t8: the listener is running for the live task" || fail "t8: the listener never started: $(cat "$T/t3-listener.log")"
# Archive the record under the running listener, exactly as a cleanup would.
mv "$KINGPIN_HOME/tasks/t3" "$KINGPIN_HOME/archive/t3"
ln -s "$KINGPIN_HOME/archive/t3" "$KINGPIN_HOME/tasks/t3"
t3_stopped=0
for _ in $(seq 1 120); do
  kill -0 "$t3_pid" 2>/dev/null || { t3_stopped=1; break; }
  sleep 0.05
done
[ "$t3_stopped" -eq 1 ] && pass "t8: the listener stopped once its task was archived" || fail "t8: the listener kept polling an archived task"
# Never leave a listener behind if it did not stop: it is this suite's own child.
kill "$t3_pid" 2>/dev/null || true
wait "$t3_pid" 2>/dev/null || true
lav_log | grep '^reply ' | grep -q "t3 landed" && pass "t8: the listener posted one final reply naming the task" || fail "t8: no final reply from the listener: $(lav_log | grep '^reply ' || true)"
lav_log | grep '^reply ' | grep -q "archive/t3" && pass "t8: the listener's reply names the archive" || fail "t8: the listener's reply does not name the archive"

rm -rf "$KINGPIN_HOME/archive/t1" "$KINGPIN_HOME/tasks/t1" "$KINGPIN_HOME/archive/t3" "$KINGPIN_HOME/tasks/t3" "$T"/wt-t1 "$T"/wt-t3

kp_test_finish "ARCHIVE-LINK"
