#!/usr/bin/env bash
# Verification test for Kingpin: the project landing lane (issue #72) recovers
# from a dead worker window, a dead queue entry, a concurrent land and an entry
# appended after the holder released.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "landing-lane"
kp_test_stub_lavish

# shellcheck source=../lib/landing.sh
. "$KP_ROOT/lib/landing.sh"

# lane_task <id> <project> [status-line]: a review-mode task with its own worktree
# path, so kingpin done's slot guard never sees two live tasks sharing one.
lane_task() {
  local id=$1 project=$2 status=${3:-"ready: branch=b review=APPROVE report=none"} d
  d="$KINGPIN_HOME/tasks/$id"
  mkdir -p "$d" "$T/wt-lane-$id"
  cat > "$d/task.env" << EOF
TASK_ID=$id
PROJECT=$project
MODE=review
WORKTREE=$T/wt-lane-$id
ISSUE=72
TMUX_TARGET=kingpin:$id
EOF
  printf '%s\n' "$status" > "$d/status"
}
lane_window() { tmux new-window -d -t kingpin: -n "$1" cat; }
lane_holder() { cat "$KINGPIN_HOME/projects/$1.landing" 2>/dev/null || true; }
lane_queue() {
  local q="$KINGPIN_HOME/projects/$1.landing_queue"
  [ -f "$q" ] || return 0
  tr '\n' '|' < "$q" 2>/dev/null || true
}
lane_marker() { [ -f "$KINGPIN_HOME/tasks/$1/landing_sent" ] && echo yes || echo no; }
lane_markers() { # <id>...: how many of them carry landing_sent
  local id n=0
  for id in "$@"; do
    [ -f "$KINGPIN_HOME/tasks/$id/landing_sent" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
lane_drop() { # <id> <project>: kill the window and forget the task and its project files
  tmux kill-window -t "kingpin:$1" 2>/dev/null || true
  rm -rf "$KINGPIN_HOME/tasks/$1" "$T/wt-lane-$1"
  rm -rf "$KINGPIN_HOME/projects/$2.landing"*
}
expect_rc() { # <want> <description> <command...>
  local want=$1 desc=$2 rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$want" ] && pass "$desc (exit $rc)" || fail "$desc: exit $rc, want $want"
}

# t72a: the library's unit table, against a scratch fleet of its own
echo "=== t72a: lib/landing.sh unit table ==="
unit_home="$T/unit-home"
mkdir -p "$unit_home/tasks" "$unit_home/projects" "$unit_home/archive"
unit_task() { # <id> [status-line]
  mkdir -p "$unit_home/tasks/$1"
  printf 'TASK_ID=%s\n' "$1" > "$unit_home/tasks/$1/task.env"
  printf '%s\n' "${2:-ready: branch=b review=APPROVE report=none}" > "$unit_home/tasks/$1/status"
}

# A holder is live only while its task dir exists and its last event is not terminal
expect_rc 1 "holder_live: an empty holder is not live" kp_landing_holder_live "$unit_home" ""
expect_rc 1 "holder_live: a missing task dir is not live" kp_landing_holder_live "$unit_home" unit-gone
unit_task unit-terminal "merged: pr=x"
expect_rc 1 "holder_live: a merged: holder is not live" kp_landing_holder_live "$unit_home" unit-terminal
unit_task unit-live
expect_rc 0 "holder_live: a ready: holder is live" kp_landing_holder_live "$unit_home" unit-live

# The send time is the landing_sent marker's mtime: a worker event newer than
# that marker means the holder is not landing, while a status unchanged since
# the send keeps the lane. Explicit mtimes keep the cases independent of clock
# granularity.
unit_task unit-stale-ready
printf 'ready: branch=b review=APPROVE report=none\n' >> "$unit_home/tasks/unit-stale-ready/status"
touch -t 202601010000.00 "$unit_home/tasks/unit-stale-ready/landing_sent"
touch -t 202601010000.02 "$unit_home/tasks/unit-stale-ready/status"
expect_rc 1 "holder_live: a ready: appended after the send is not landing" kp_landing_holder_live "$unit_home" unit-stale-ready

unit_task unit-stale-needs
printf 'needs-input: question.md\n' >> "$unit_home/tasks/unit-stale-needs/status"
touch -t 202601010000.00 "$unit_home/tasks/unit-stale-needs/landing_sent"
touch -t 202601010000.02 "$unit_home/tasks/unit-stale-needs/status"
expect_rc 1 "holder_live: a needs-input: appended after the send is not landing" kp_landing_holder_live "$unit_home" unit-stale-needs

unit_task unit-stale-feedback
printf 'feedback: Request Changes: after the send\n' >> "$unit_home/tasks/unit-stale-feedback/status"
touch -t 202601010000.00 "$unit_home/tasks/unit-stale-feedback/landing_sent"
touch -t 202601010000.02 "$unit_home/tasks/unit-stale-feedback/status"
expect_rc 1 "holder_live: a feedback: appended after the send is not landing" kp_landing_holder_live "$unit_home" unit-stale-feedback

unit_task unit-mid-landing
touch -t 202601010000.00 "$unit_home/tasks/unit-mid-landing/status"
touch -t 202601010000.02 "$unit_home/tasks/unit-mid-landing/landing_sent"
expect_rc 0 "holder_live: a status unchanged since the send is still landing" kp_landing_holder_live "$unit_home" unit-mid-landing

unit_task unit-note-after-send
printf 'approved: by user via lavish dossier\n' >> "$unit_home/tasks/unit-note-after-send/status"
touch -t 202601010000.00 "$unit_home/tasks/unit-note-after-send/landing_sent"
touch -t 202601010000.02 "$unit_home/tasks/unit-note-after-send/status"
expect_rc 0 "holder_live: an approved: note after the send does not end a landing" kp_landing_holder_live "$unit_home" unit-note-after-send

# An id is landable only when its task dir, task.env and a non-terminal event survive
expect_rc 1 "task_landable: a missing task is not landable" kp_landing_task_landable "$unit_home" unit-missing
mkdir -p "$unit_home/archive/unit-archived"
expect_rc 1 "task_landable: an archived-only task is not landable" kp_landing_task_landable "$unit_home" unit-archived
# The link `kingpin done` leaves at tasks/<id> resolves a record that already
# landed. Everything the checks read through it still answers (task.env, a ready
# status), so only the link itself says the task is finished.
mkdir -p "$unit_home/archive/unit-link"
printf 'TASK_ID=unit-link\n' > "$unit_home/archive/unit-link/task.env"
printf 'ready: branch=b review=APPROVE report=none\n' > "$unit_home/archive/unit-link/status"
ln -s "$unit_home/archive/unit-link" "$unit_home/tasks/unit-link"
expect_rc 1 "holder_live: an archived dossier link is not live" kp_landing_holder_live "$unit_home" unit-link
expect_rc 1 "task_landable: an archived dossier link is not landable" kp_landing_task_landable "$unit_home" unit-link
unit_task unit-cleaned
touch "$unit_home/tasks/unit-cleaned/done_cleaned"
expect_rc 1 "task_landable: a cleaned-up task is not landable" kp_landing_task_landable "$unit_home" unit-cleaned
unit_task unit-sent
touch "$unit_home/tasks/unit-sent/landing_sent"
expect_rc 1 "task_landable: an already dispatched task is not landable" kp_landing_task_landable "$unit_home" unit-sent
unit_task unit-merged "merged: pr=x"
expect_rc 1 "task_landable: a finished task is not landable" kp_landing_task_landable "$unit_home" unit-merged
unit_task unit-ready
expect_rc 0 "task_landable: a ready task is landable" kp_landing_task_landable "$unit_home" unit-ready

# Acquire: free lane, another id, then the holder itself
expect_rc 0 "acquire: a free lane is claimed" kp_landing_acquire "$unit_home" unit-p unit-ready
[ "$(cat "$unit_home/projects/unit-p.landing" 2>/dev/null || true)" = "unit-ready" ] && pass "acquire: the holder file names the task" || fail "acquire: wrong holder: $(cat "$unit_home/projects/unit-p.landing" 2>/dev/null || true)"
unit_task unit-other
expect_rc 1 "acquire: a live holder blocks another task" kp_landing_acquire "$unit_home" unit-p unit-other
[ "$(cat "$unit_home/projects/unit-p.landing" 2>/dev/null || true)" = "unit-ready" ] && pass "acquire: the blocked task left the holder alone" || fail "acquire: the blocked task changed the holder"
expect_rc 0 "acquire: the current holder re-acquires" kp_landing_acquire "$unit_home" unit-p unit-ready

# Release: only the holder releases
expect_rc 1 "release: a non-holder is refused" kp_landing_release "$unit_home" unit-p unit-other
[ "$(cat "$unit_home/projects/unit-p.landing" 2>/dev/null || true)" = "unit-ready" ] && pass "release: the non-holder left the lock alone" || fail "release: the non-holder removed the lock"
expect_rc 0 "release: the holder releases" kp_landing_release "$unit_home" unit-p unit-ready
[ ! -f "$unit_home/projects/unit-p.landing" ] && pass "release: the lock file is gone" || fail "release: the lock file survived"

# Pop: drops unlandable ids, prints the next landable one, keeps the rest in order
unit_task unit-ready2
printf 'unit-gone\nunit-ready\nunit-ready2\n' > "$unit_home/projects/unit-pop.landing_queue"
unit_next=$(kp_landing_pop "$unit_home" unit-pop 2>"$T/unit-pop.err")
[ "$unit_next" = "unit-ready" ] && pass "pop: prints the next landable id" || fail "pop: printed '$unit_next', want unit-ready"
[ "$(tr '\n' '|' < "$unit_home/projects/unit-pop.landing_queue")" = "unit-ready2|" ] && pass "pop: removes the popped id and keeps the rest" || fail "pop: queue is $(tr '\n' '|' < "$unit_home/projects/unit-pop.landing_queue")"
grep -q "dropping unit-gone from the unit-pop queue" "$T/unit-pop.err" && pass "pop: names the dropped id on stderr" || fail "pop: no drop line: $(cat "$T/unit-pop.err")"

# A dossier link is dropped for being archived, not for a missing task dir: the
# reason is what tells an operator the task already landed.
printf 'unit-link\n' > "$unit_home/projects/unit-pop-link.landing_queue"
unit_link_next=$(kp_landing_pop "$unit_home" unit-pop-link 2>"$T/unit-pop-link.err")
[ -z "$unit_link_next" ] && pass "pop: an archived dossier link yields nothing to land" || fail "pop: printed '$unit_link_next' for an archived link"
grep -qx "kingpin-landing: dropping unit-link from the unit-pop-link queue: archived" "$T/unit-pop-link.err" \
  && pass "pop: the drop line says the task is archived" \
  || fail "pop: drop line for an archived link: $(cat "$T/unit-pop-link.err")"

# A mutex left behind by a dead process is reclaimed instead of wedging the lane
unit_task unit-stale
unit_mutex="$unit_home/projects/unit-stale.landing.mutex"
sleep 0.01 &
unit_dead_pid=$!
wait "$unit_dead_pid" || true
echo "$unit_dead_pid" > "$unit_mutex"
expect_rc 0 "acquire: a mutex whose pid is dead is reclaimed" kp_landing_acquire "$unit_home" unit-stale unit-stale
[ ! -e "$unit_mutex" ] && pass "acquire: the reclaimed mutex is gone" || fail "acquire: the stale mutex survived"
[ "$(cat "$unit_home/projects/unit-stale.landing" 2>/dev/null || true)" = "unit-stale" ] && pass "acquire: the reclaimed lane is claimed" || fail "acquire: the reclaimed lane is not claimed"

# The claim is atomic on its own: two claimants of one free lane, one winner.
unit_task unit-claim-a
unit_task unit-claim-b
unit_claim_ok=0
for _ in 1 2 3 4 5; do
  rm -f "$unit_home/projects/unit-claim.landing"
  ( _kp_landing_claim "$unit_home/projects/unit-claim.landing" unit-claim-a ) & ca=$!
  ( _kp_landing_claim "$unit_home/projects/unit-claim.landing" unit-claim-b ) & cb=$!
  rca=0; wait "$ca" || rca=$?
  rcb=0; wait "$cb" || rcb=$?
  [ $(((rca == 0) + (rcb == 0))) -eq 1 ] && unit_claim_ok=$((unit_claim_ok + 1))
done
[ "$unit_claim_ok" -eq 5 ] && pass "claim: two concurrent claimants, exactly one wins (5/5 rounds)" || fail "claim: only $unit_claim_ok of 5 rounds had exactly one winner"

# A stale holder is cleared by exactly one of two concurrent acquires.
unit_stale_ok=0
for _ in 1 2 3 4 5; do
  rm -rf "$unit_home/projects/unit-stale-lock.landing"*
  printf 'unit-gone\n' > "$unit_home/projects/unit-stale-lock.landing"
  ( kp_landing_acquire "$unit_home" unit-stale-lock unit-claim-a ) & sa=$!
  ( kp_landing_acquire "$unit_home" unit-stale-lock unit-claim-b ) & sb=$!
  rca=0; wait "$sa" || rca=$?
  rcb=0; wait "$sb" || rcb=$?
  [ $(((rca == 0) + (rcb == 0))) -eq 1 ] && unit_stale_ok=$((unit_stale_ok + 1))
done
[ "$unit_stale_ok" -eq 5 ] && pass "acquire: a stale holder is replaced by exactly one of two lands (5/5 rounds)" || fail "acquire: only $unit_stale_ok of 5 rounds had exactly one winner on a stale holder"

# A stale mutex reclaimed by two processes must not let both into the section:
# the reclaim renames it away, so the loser's rename fails instead of deleting
# the mutex the winner has just created.
unit_reclaim_ok=0
for _ in 1 2 3 4 5; do
  rm -rf "$unit_home/projects/unit-reclaim.landing"*
  echo "$unit_dead_pid" > "$unit_home/projects/unit-reclaim.landing.mutex"
  ( kp_landing_acquire "$unit_home" unit-reclaim unit-claim-a ) & ma=$!
  ( kp_landing_acquire "$unit_home" unit-reclaim unit-claim-b ) & mb=$!
  rca=0; wait "$ma" || rca=$?
  rcb=0; wait "$mb" || rcb=$?
  [ $(((rca == 0) + (rcb == 0))) -eq 1 ] && unit_reclaim_ok=$((unit_reclaim_ok + 1))
done
[ "$unit_reclaim_ok" -eq 5 ] && pass "acquire: a stale mutex reclaimed by two lands yields one holder (5/5 rounds)" || fail "acquire: only $unit_reclaim_ok of 5 rounds had exactly one winner with a stale mutex"
[ ! -e "$unit_home/projects/unit-reclaim.landing.mutex" ] && pass "acquire: the reclaimed mutex is gone" || fail "acquire: a mutex survived the reclaim"

# t72b: a dead worker window releases the lane (AC 1)
echo "=== t72b: a dead worker window releases the lane (AC 1) ==="
lane_task lane-dead demo-lane                  # no tmux window exists for it
lane_rc=0
lane_out=$("$KP_BIN/kingpin" land lane-dead 2>&1) || lane_rc=$?
[ "$lane_rc" -ne 0 ] && pass "land on a dead window exits $lane_rc (non-zero)" || fail "land on a dead window exited 0: $lane_out"
echo "$lane_out" | grep -q "could not send" && pass "the failure names the send that did not reach the worker" || fail "send failure not reported: $lane_out"
[ ! -f "$KINGPIN_HOME/projects/demo-lane.landing" ] && pass "no landing lock left behind" || fail "landing lock left behind: $(lane_holder demo-lane)"
[ ! -f "$KINGPIN_HOME/tasks/lane-dead/landing_sent" ] && pass "no landing_sent left behind" || fail "landing_sent left behind"

lane_task lane-next demo-lane
lane_window lane-next
"$KP_BIN/kingpin" land lane-next >/dev/null
[ "$(lane_holder demo-lane)" = "lane-next" ] && pass "the next land acquires the released lane" || fail "the next land did not acquire: holder=$(lane_holder demo-lane)"
[ "$(lane_marker lane-next)" = "yes" ] && pass "the next task received landing_sent" || fail "the next task's landing_sent is missing"
sleep 0.1
tmux capture-pane -pt kingpin:lane-next -S -5 | grep -q "/issue-flow-done 72" && pass "the next task was dispatched /issue-flow-done 72" || fail "no /issue-flow-done 72 in the next task's pane"
lane_drop lane-dead demo-lane
lane_drop lane-next demo-lane

# t72c: two concurrent lands take the lane exactly once (AC 3)
echo "=== t72c: two concurrent lands take the lane once (AC 3) ==="
cp -p "$KP_BIN/kingpin-send" "$T/kingpin-send.orig"
cat > "$KP_BIN/kingpin-send" << 'S'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${KINGPIN_HOME}/sent.log"
sleep 0.2
S
chmod +x "$KP_BIN/kingpin-send"
sent_file="$KINGPIN_HOME/sent.log"
: > "$sent_file"
# A pid that is certainly gone: the mutex each round starts as a stale one, which
# is what a land killed mid-section leaves behind. Two lands reclaiming it at
# once must still produce one holder, not two.
sleep 0.01 &
dead_land_pid=$!
wait "$dead_land_pid" || true
for i in 1 2 3 4 5; do
  project="demo-c$i"
  lane_task "c${i}a" "$project"
  lane_task "c${i}b" "$project"
  echo "$dead_land_pid" > "$KINGPIN_HOME/projects/$project.landing.mutex"
  "$KP_BIN/kingpin-land" "c${i}a" >"$T/c${i}a.out" 2>&1 & pa=$!
  "$KP_BIN/kingpin-land" "c${i}b" >"$T/c${i}b.out" 2>&1 & pb=$!
  rca=0; wait "$pa" || rca=$?
  rcb=0; wait "$pb" || rcb=$?
  n=$(lane_markers "c${i}a" "c${i}b")
  holder=$(lane_holder "$project")
  other="c${i}b"
  [ "$holder" = "c${i}b" ] && other="c${i}a"
  if [ "$n" -eq 1 ] && [ "$rca" -eq 0 ] && [ "$rcb" -eq 0 ] && [ -n "$holder" ] && [ -f "$KINGPIN_HOME/tasks/$holder/landing_sent" ] && grep -qxF "$other" "$KINGPIN_HOME/projects/$project.landing_queue" 2>/dev/null; then
    pass "round $i: one holder ($holder), one landing_sent, $other queued"
  else
    fail "round $i: markers=$n holder=$holder queue=$(lane_queue "$project") rc=$rca/$rcb a=$(tr '\n' ' ' < "$T/c${i}a.out") b=$(tr '\n' ' ' < "$T/c${i}b.out")"
  fi
done
sent_lines=$(wc -l < "$sent_file" | tr -d ' ')
[ "$sent_lines" -eq 5 ] && pass "the stub saw one dispatch per round ($sent_lines)" || fail "the stub saw $sent_lines dispatches, want 5"
cp -p "$T/kingpin-send.orig" "$KP_BIN/kingpin-send"
for i in 1 2 3 4 5; do
  lane_drop "c${i}a" "demo-c$i"
  lane_drop "c${i}b" "demo-c$i"
done

# t72d: watch --once drains a queue whose holder is gone (AC 2)
echo "=== t72d: watch --once drains a queue whose holder is gone (AC 2) ==="
lane_task lane-live demo-q
lane_window lane-live
mkdir -p "$KINGPIN_HOME/archive/lane-archived"
printf 'lane-archived\nlane-live\n' > "$KINGPIN_HOME/projects/demo-q.landing_queue"
"$KP_BIN/kingpin" watch --once >/dev/null 2>"$T/watch-q.err" || true
[ "$(lane_holder demo-q)" = "lane-live" ] && pass "the live entry after an archived one takes the lane" || fail "the live entry did not land: holder=$(lane_holder demo-q)"
[ "$(lane_marker lane-live)" = "yes" ] && pass "the live entry received landing_sent" || fail "the live entry's landing_sent is missing"
[ -z "$(lane_queue demo-q)" ] && pass "the queue is empty after the drain" || fail "the queue still holds $(lane_queue demo-q)"
! grep -qx "lane-archived" "$KINGPIN_HOME/projects/demo-q.landing_queue" && pass "the archived id is gone from the queue" || fail "the archived id is still queued"
grep -q "dropping lane-archived from the demo-q queue" "$T/watch-q.err" && pass "the drop is named on the watch console" || fail "no drop line on stderr: $(cat "$T/watch-q.err")"
sleep 0.1
tmux capture-pane -pt kingpin:lane-live -S -5 | grep -q "/issue-flow-done 72" && pass "the drained entry was dispatched /issue-flow-done 72" || fail "no /issue-flow-done 72 in the drained task's pane"
lane_drop lane-live demo-q

lane_task lane-live2 demo-q2
lane_window lane-live2
printf 'lane-never\nlane-live2\n' > "$KINGPIN_HOME/projects/demo-q2.landing_queue"
"$KP_BIN/kingpin" watch --once >/dev/null 2>"$T/watch-q2.err" || true
[ "$(lane_holder demo-q2)" = "lane-live2" ] && pass "the live entry after a never-existing one takes the lane" || fail "the live entry did not land: holder=$(lane_holder demo-q2)"
[ -z "$(lane_queue demo-q2)" ] && pass "the queue is empty after the second drain" || fail "the queue still holds $(lane_queue demo-q2)"
grep -q "dropping lane-never from the demo-q2 queue" "$T/watch-q2.err" && pass "the never-existing id is named on stderr" || fail "no drop line for lane-never: $(cat "$T/watch-q2.err")"
lane_drop lane-live2 demo-q2

# t72e: done's handoff skips a dead queue entry
echo "=== t72e: done's handoff skips a dead queue entry ==="
mkdir -p "$KINGPIN_HOME/tasks/lane-h1"
cat > "$KINGPIN_HOME/tasks/lane-h1/task.env" << EOF
TASK_ID=lane-h1
PROJECT=demo-h
PROJECT_PATH=$T/proj
WORKTREE=$T/missing-h1
BRANCH=x
TMUX_TARGET=kingpin:lane-h1
EOF
printf 'merged: pr=x\n' > "$KINGPIN_HOME/tasks/lane-h1/status"
echo "lane-h1" > "$KINGPIN_HOME/projects/demo-h.landing"
printf 'lane-gone\nlane-h2\n' > "$KINGPIN_HOME/projects/demo-h.landing_queue"
lane_task lane-h2 demo-h
lane_window lane-h2
"$KP_BIN/kingpin" "done" lane-h1 --force >/dev/null 2>&1 || true
[ "$(lane_holder demo-h)" = "lane-h2" ] && pass "the handoff skips the dead id and lands lane-h2" || fail "the handoff did not reach lane-h2: holder=$(lane_holder demo-h) queue=$(lane_queue demo-h)"
[ "$(lane_marker lane-h2)" = "yes" ] && pass "lane-h2 received landing_sent" || fail "lane-h2's landing_sent is missing"
[ -z "$(lane_queue demo-h)" ] && pass "the queue is empty after the handoff" || fail "the queue still holds $(lane_queue demo-h)"
[ -d "$KINGPIN_HOME/archive/lane-h1" ] && pass "the finished holder was archived" || fail "the finished holder was not archived"
lane_drop lane-h2 demo-h
rm -rf "$KINGPIN_HOME/archive/lane-h1"

# t72f: an entry appended after the holder released is picked up (AC 2, AC 1)
echo "=== t72f: an entry appended after the holder released is picked up (AC 2) ==="
lane_task lane-hold demo-d
lane_task lane-w demo-d
lane_window lane-w
echo "lane-hold" > "$KINGPIN_HOME/projects/demo-d.landing"
"$KP_BIN/kingpin" land lane-w >/dev/null
[ "$(lane_marker lane-w)" = "no" ] && pass "the late entry is queued, not dispatched" || fail "the late entry was dispatched while the lane was held"
[ "$(lane_holder demo-d)" = "lane-hold" ] && pass "the live holder still owns the lane" || fail "the holder changed: $(lane_holder demo-d)"
rm -f "$KINGPIN_HOME/projects/demo-d.landing"
"$KP_BIN/kingpin" watch --once >/dev/null 2>&1 || true
[ "$(lane_holder demo-d)" = "lane-w" ] && pass "watch --once picks up the entry whose holder released" || fail "watch did not pick it up: holder=$(lane_holder demo-d) queue=$(lane_queue demo-d)"
[ "$(lane_marker lane-w)" = "yes" ] && pass "the picked-up entry received landing_sent" || fail "the picked-up entry's landing_sent is missing"
[ -z "$(lane_queue demo-d)" ] && pass "the queue is empty after the pickup" || fail "the queue still holds $(lane_queue demo-d)"
lane_drop lane-w demo-d
lane_drop lane-hold demo-d

# A direct land acquires a released lane too (D7: a manual land does not drain first)
lane_task lane-hold2 demo-d2
lane_task lane-w2 demo-d2
lane_window lane-w2
echo "lane-hold2" > "$KINGPIN_HOME/projects/demo-d2.landing"
"$KP_BIN/kingpin" land lane-w2 >/dev/null
rm -f "$KINGPIN_HOME/projects/demo-d2.landing"
"$KP_BIN/kingpin" land lane-w2 >/dev/null
[ "$(lane_holder demo-d2)" = "lane-w2" ] && pass "a direct land acquires the released lane" || fail "the direct land did not acquire: holder=$(lane_holder demo-d2)"
[ "$(lane_marker lane-w2)" = "yes" ] && pass "the direct land dispatched the task" || fail "the direct land did not dispatch"
lane_drop lane-w2 demo-d2
lane_drop lane-hold2 demo-d2

# t72g: a holder that reported after its landing was sent releases the lane
echo "=== t72g: a stale holder releases the lane and the queue drains ==="
lane_task lane-stale demo-s
lane_task lane-queued demo-s
lane_window lane-queued
# The stale holder was sent the landing first, then its worker reported ready:
# again (it had answered a question). landing_sent predates that line.
touch -t 202601010000.00 "$KINGPIN_HOME/tasks/lane-stale/landing_sent"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$KINGPIN_HOME/tasks/lane-stale/status"
touch -t 202601010000.02 "$KINGPIN_HOME/tasks/lane-stale/status"
echo "lane-stale" > "$KINGPIN_HOME/projects/demo-s.landing"
printf 'lane-queued\n' > "$KINGPIN_HOME/projects/demo-s.landing_queue"
"$KP_BIN/kingpin" watch --once >/dev/null 2>"$T/watch-stale.err" || true
[ "$(lane_holder demo-s)" = "lane-queued" ] && pass "the stale holder released the lane to the queued task" || fail "the queue did not drain past the stale holder: holder=$(lane_holder demo-s) queue=$(lane_queue demo-s)"
[ "$(lane_marker lane-queued)" = "yes" ] && pass "the queued task received landing_sent after the release" || fail "the queued task's landing_sent is missing"
[ "$(lane_marker lane-stale)" = "no" ] && pass "the released holder's landing_sent is cleared, so it can land again" || fail "the released holder kept landing_sent"
expect_rc 0 "the released holder is landable again, so the queue or the dossier can restart it" kp_landing_task_landable "$KINGPIN_HOME" lane-stale
[ -z "$(lane_queue demo-s)" ] && pass "the queue is empty after the stale-holder drain" || fail "the queue still holds $(lane_queue demo-s)"
grep -qx "kingpin-landing: releasing stale landing holder lane-stale for project demo-s: a new ready: line arrived after the landing was sent" "$T/watch-stale.err" \
  && pass "the release names the stale holder and the reason" \
  || fail "no stale-holder release line: $(cat "$T/watch-stale.err")"
# The released task is landable again, but it is not in the queue and the lane is
# held by a live task, so a second pass neither releases it again nor lands it.
"$KP_BIN/kingpin" watch --once >/dev/null 2>"$T/watch-stale2.err" || true
[ "$(lane_holder demo-s)" = "lane-queued" ] && ! grep -q "releasing stale landing holder" "$T/watch-stale2.err" \
  && pass "the released task is not released again on the next pass" \
  || fail "the released task was released again: holder=$(lane_holder demo-s) err=$(cat "$T/watch-stale2.err")"
lane_drop lane-stale demo-s
lane_drop lane-queued demo-s

rm -rf "$T"/wt-lane-* "$KINGPIN_HOME/tasks/lane-"* "$KINGPIN_HOME/archive/lane-"*
rm -rf "$KINGPIN_HOME/projects/demo-"*

kp_test_finish LANDING-LANE
