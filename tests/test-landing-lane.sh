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
  rm -f "$KINGPIN_HOME/projects/$2.landing" "$KINGPIN_HOME/projects/$2.landing_queue"
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

# An id is landable only when its task dir, task.env and a non-terminal event survive
expect_rc 1 "task_landable: a missing task is not landable" kp_landing_task_landable "$unit_home" unit-missing
mkdir -p "$unit_home/archive/unit-archived"
expect_rc 1 "task_landable: an archived-only task is not landable" kp_landing_task_landable "$unit_home" unit-archived
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

# A mutex left behind by a dead process is reclaimed instead of wedging the lane
unit_task unit-stale
unit_mutex="$unit_home/projects/unit-stale.landing.mutex"
mkdir -p "$unit_mutex"
sleep 0.01 &
unit_dead_pid=$!
wait "$unit_dead_pid" || true
echo "$unit_dead_pid" > "$unit_mutex/pid"
expect_rc 0 "acquire: a mutex whose pid is dead is reclaimed" kp_landing_acquire "$unit_home" unit-stale unit-stale
[ ! -d "$unit_mutex" ] && pass "acquire: the reclaimed mutex is gone" || fail "acquire: the stale mutex survived"
[ "$(cat "$unit_home/projects/unit-stale.landing" 2>/dev/null || true)" = "unit-stale" ] && pass "acquire: the reclaimed lane is claimed" || fail "acquire: the reclaimed lane is not claimed"

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
for i in 1 2 3 4 5; do
  project="demo-c$i"
  lane_task "c${i}a" "$project"
  lane_task "c${i}b" "$project"
  "$KP_BIN/kingpin-land" "c${i}a" >/dev/null 2>&1 &
  "$KP_BIN/kingpin-land" "c${i}b" >/dev/null 2>&1 &
  wait
  n=$(lane_markers "c${i}a" "c${i}b")
  holder=$(lane_holder "$project")
  other="c${i}b"
  [ "$holder" = "c${i}b" ] && other="c${i}a"
  if [ "$n" -eq 1 ] && [ -n "$holder" ] && [ -f "$KINGPIN_HOME/tasks/$holder/landing_sent" ] && grep -qxF "$other" "$KINGPIN_HOME/projects/$project.landing_queue" 2>/dev/null; then
    pass "round $i: one holder ($holder), one landing_sent, $other queued"
  else
    fail "round $i: markers=$n holder=$holder queue=$(lane_queue "$project")"
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

rm -rf "$T"/wt-lane-* "$KINGPIN_HOME/tasks/lane-"* "$KINGPIN_HOME/archive/lane-"*
rm -rf "$KINGPIN_HOME/projects/demo-"*

kp_test_finish LANDING-LANE
