#!/usr/bin/env bash
# Verification test for Kingpin: kingpin done: refused cleanup, archive, slot guard, branch cleanup, live-worker status.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "done"
kp_test_bsd_shims
kp_test_project
# The synthetic worktrees below were never leased from a pool, so the real
# `treehouse return` refuses them; every fixture prepends its own stub where it
# cares about the call (t16, Tests 20-23).
kp_test_stub_treehouse

# The issue readout (issue #170) asks gh about the issue a finished task names.
# The suite's remotes are local bare repos, so a fake gh answers instead, records
# every call, and can fail a close on demand.
GH_LOG="$T/gh.log"
GH_STATE="$T/gh-issue-state"
GH_CLOSE_FAILS="$T/gh-close-fails"
: > "$GH_LOG"
printf 'OPEN\n' > "$GH_STATE"
rm -f "$GH_CLOSE_FAILS"
cat > "$T/bin/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KP_TEST_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "issue view")
    cat "${KP_TEST_GH_STATE:?}"
    ;;
  "issue close")
    if [ -f "${KP_TEST_GH_CLOSE_FAILS:-/nonexistent}" ]; then exit 1; fi
    printf 'CLOSED\n' > "${KP_TEST_GH_STATE:?}"
    ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$T/bin/gh"
# A gh whose `issue view` fails answers the unreadable-state arm; the missing-command
# arm points KINGPIN_GH at a name that does not exist.
cat > "$T/bin/gh-view-fails" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KP_TEST_GH_LOG:?}"
exit 1
GHEOF
chmod +x "$T/bin/gh-view-fails"
export KP_TEST_GH_LOG="$GH_LOG" KP_TEST_GH_STATE="$GH_STATE" KP_TEST_GH_CLOSE_FAILS="$GH_CLOSE_FAILS"
# Test 19's kingpin-done opens and ends each t19-* report.html session through the
# default Lavish stub; every recorded call must name one of those tasks, so a call for
# anything else is still caught.
kp_test_expect_lavish_calls '*t19-*'

# Test 10: Refused cleanup handling and landing queue preservation
echo "=== Test 10: Refused cleanup handling and landing queue preservation ==="
t10_dir1="$KINGPIN_HOME/tasks/t10-dirty"
t10_dir2="$KINGPIN_HOME/tasks/t10-queued"
mkdir -p "$t10_dir1" "$t10_dir2"

t10_wt1="$T/wt-t10-1"
t10_wt2="$T/wt-t10-2"
mkdir -p "$t10_wt1" "$t10_wt2"
git -C "$t10_wt1" init -q
git -C "$t10_wt2" init -q

(
  cd "$t10_wt1"
  git checkout -qb main
  git config user.name "Tester"
  git config user.email "test@example.com"
  echo "initial" > init.txt
  git add init.txt
  git commit -qm "initial commit"
)

t10_remote="$T/remote-t10.git"
git init --bare -q "$t10_remote"
(
  cd "$t10_wt1"
  git remote add origin "$t10_remote"
  git push -q origin main
  git branch -u origin/main main
)

cat > "$t10_dir1/task.env" << EOF
TASK_ID=t10-dirty
PROJECT=demo-t10
PROJECT_PATH=$t10_wt1
WORKTREE=$t10_wt1
BRANCH=feature-t10-1
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t10-dirty
EOF
echo "dirty uncommitted changes" > "$t10_wt1/uncommitted.txt"
echo "ready: branch=feature-t10-1 review=APPROVE report=none" > "$t10_dir1/status"

cat > "$t10_dir2/task.env" << EOF
TASK_ID=t10-queued
PROJECT=demo-t10
PROJECT_PATH=$t10_wt2
WORKTREE=$t10_wt2
BRANCH=feature-t10-2
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t10-queued
EOF
echo "ready: branch=feature-t10-2 review=APPROVE report=none" > "$t10_dir2/status"

tmux new-window -d -t kingpin: -n t10-dirty cat
tmux new-window -d -t kingpin: -n t10-queued cat

# 1. Task 1 lands and acquires landing lock
"$KP_BIN/kingpin" land t10-dirty >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-t10.landing" ] && pass "t10-dirty acquired landing lock" || fail "t10-dirty landing lock missing"

# 2. Task 2 attempts to land and gets queued
"$KP_BIN/kingpin" land t10-queued >/dev/null
grep -qx "t10-queued" "$KINGPIN_HOME/projects/demo-t10.landing_queue" 2>/dev/null && pass "t10-queued added to landing_queue" || fail "t10-queued not queued"

# 3. Simulate Task 1 reporting merged
echo "merged: pr=https://github.com/example/demo/pull/1" >> "$t10_dir1/status"

# 4. Run kingpin-watch --once (which will run kingpin-done t10-dirty)
"$KP_BIN/kingpin" watch --once >/dev/null 2>&1 || true

# Assert AC 1: done_cleaned is NOT written on refused cleanup
[ ! -f "$t10_dir1/done_cleaned" ] && pass "done_cleaned not written on refused cleanup" || fail "done_cleaned prematurely written on refused cleanup"

# Assert AC 2: A refused cleanup appears as a task event with refusal reason
grep -q "^cleanup-refused:" "$t10_dir1/status" && pass "cleanup-refused recorded in status" || fail "cleanup-refused not found in status"
refusal_reason=$(tail -n 1 "$t10_dir1/status")
echo "$refusal_reason" | grep -q "uncommitted changes" && pass "refusal reason captured in status event" || fail "refusal reason missing: $refusal_reason"

# Assert AC 3: Refused cleanup does not leave landing lock held forever; next queued task can land
holder=$(cat "$KINGPIN_HOME/projects/demo-t10.landing" 2>/dev/null || true)
[ "$holder" = "t10-queued" ] && pass "landing lock handed off to next queued task t10-queued" || fail "landing lock not handed off: holder=$holder"
[ -f "$t10_dir2/landing_sent" ] && pass "t10-queued received landing dispatch" || fail "t10-queued landing_sent missing"

# Assert dedupe: the watch cycle (event + retry) and repeated refusals add one status line only
refused_count=$(grep -c "^cleanup-refused:" "$t10_dir1/status" || true)
[ "$refused_count" = "1" ] && pass "watch cycle recorded exactly one cleanup-refused line" || fail "expected 1 cleanup-refused line after watch cycle, got $refused_count"
"$KP_BIN/kingpin-done" t10-dirty >/dev/null 2>&1 || true
"$KP_BIN/kingpin-done" t10-dirty >/dev/null 2>&1 || true
refused_count=$(grep -c "^cleanup-refused:" "$t10_dir1/status" || true)
[ "$refused_count" = "1" ] && pass "repeated refusals do not append duplicate cleanup-refused lines" || fail "duplicate cleanup-refused lines: $refused_count"

# Assert the refusal is a task event the orchestrator sees via kingpin-wait
wait_out=$("$KP_BIN/kingpin-wait" --once 2>/dev/null || true)
echo "$wait_out" | grep -q "^t10-dirty status" && pass "kingpin-wait reports the cleanup-refused event" || fail "kingpin-wait did not report t10-dirty: $wait_out"
"$KP_BIN/kingpin-ack" t10-dirty >/dev/null 2>&1 || true

# Assert a repeated refusal by a task that no longer holds the lock leaves the queue order alone
printf 't10-other\nt10-other2\n' > "$KINGPIN_HOME/projects/demo-t10.landing_queue"
"$KP_BIN/kingpin-done" t10-dirty >/dev/null 2>&1 || true
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing_queue")" = "$(printf 't10-other\nt10-other2')" ] && pass "repeated refusal does not pop the landing queue" || fail "landing queue changed by non-holder refusal: $(cat "$KINGPIN_HOME/projects/demo-t10.landing_queue")"
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-queued" ] && pass "repeated refusal leaves the lock holder alone" || fail "lock holder changed by non-holder refusal"
rm -f "$KINGPIN_HOME/projects/demo-t10.landing_queue"

# Assert automatic retry: once the cause clears, kingpin-watch completes the cleanup
rm -f "$t10_wt1/uncommitted.txt"
"$KP_BIN/kingpin" watch --once >/dev/null 2>&1 || true
[ -f "$KINGPIN_HOME/archive/t10-dirty/done_cleaned" ] && pass "kingpin-watch retried the refused cleanup and archived the task with done_cleaned" || fail "refused cleanup was not retried by kingpin-watch"
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-queued" ] && pass "retried cleanup left the new lock holder alone" || fail "retried cleanup disturbed the landing lock"

# Assert kingpin-land treats a lock holder in a terminal status as free
t10_dir3="$KINGPIN_HOME/tasks/t10-land"
t10_hold="$KINGPIN_HOME/tasks/t10-holder"
mkdir -p "$t10_dir3" "$t10_hold"
tmux new-window -d -t kingpin: -n t10-land cat
cat > "$t10_dir3/task.env" << EOF2
TASK_ID=t10-land
PROJECT=demo-t10
MODE=review
WORKTREE=$t10_wt2
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t10-land
EOF2
echo "ready: branch=b review=APPROVE report=none" > "$t10_dir3/status"
for terminal in "merged: pr=x" "failed: boom" "cleanup-refused: r"; do
  echo "$terminal" > "$t10_hold/status"
  echo "t10-holder" > "$KINGPIN_HOME/projects/demo-t10.landing"
  rm -f "$t10_dir3/landing_sent"
  "$KP_BIN/kingpin" land t10-land >/dev/null 2>&1 || true
  [ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-land" ] && [ -f "$t10_dir3/landing_sent" ] && pass "land takes the lock from a '${terminal%%:*}' holder" || fail "land blocked by a '${terminal%%:*}' holder"
done
echo "ready: branch=b review=APPROVE report=none" > "$t10_hold/status"
echo "t10-holder" > "$KINGPIN_HOME/projects/demo-t10.landing"
rm -f "$t10_dir3/landing_sent"
"$KP_BIN/kingpin" land t10-land >/dev/null 2>&1 || true
[ "$(cat "$KINGPIN_HOME/projects/demo-t10.landing")" = "t10-holder" ] && [ ! -f "$t10_dir3/landing_sent" ] && pass "land still queues behind a live holder" || fail "land overtook a live holder"
tmux kill-window -t kingpin:t10-land 2>/dev/null || true
rm -rf "$t10_dir3" "$t10_hold"

# 5. Force cleanup of a dirty worktree succeeds and touches done_cleaned
t10_dir4="$KINGPIN_HOME/tasks/t10-force"
mkdir -p "$t10_dir4"
# Its own worktree: t10-queued still holds wt2 and the slot guard protects it
t10_wt3="$T/wt-t10-3"
mkdir -p "$t10_wt3"
git -C "$t10_wt3" init -q
cat > "$t10_dir4/task.env" << EOF2
TASK_ID=t10-force
PROJECT=demo-t10
PROJECT_PATH=$t10_wt1
WORKTREE=$t10_wt3
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t10-force
EOF2
echo "merged: pr=x" > "$t10_dir4/status"
echo "dirty" > "$t10_wt3/uncommitted.txt"
"$KP_BIN/kingpin-done" t10-force >/dev/null 2>&1 && fail "dirty cleanup was not refused" || pass "dirty cleanup refused without --force"
[ ! -f "$t10_dir4/done_cleaned" ] && pass "no done_cleaned after refusal without --force" || fail "done_cleaned written despite refusal"
"$KP_BIN/kingpin" "done" t10-force --force >/dev/null
[ -f "$KINGPIN_HOME/archive/t10-force/done_cleaned" ] && pass "kingpin-done --force created done_cleaned and archived the task" || fail "done_cleaned missing in archive after force cleanup"
rm -rf "$t10_dir4" "$KINGPIN_HOME/archive/t10-force" "$KINGPIN_HOME/archive/t10-dirty" "$t10_wt3"

tmux kill-window -t kingpin:t10-dirty 2>/dev/null || true
tmux kill-window -t kingpin:t10-queued 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t10.landing" "$KINGPIN_HOME/projects/demo-t10.landing_queue"
rm -rf "$t10_dir1" "$t10_dir2" "$t10_wt1" "$t10_wt2" "$t10_remote"

kp_test_stub_lavish

# Test 12: archive finished tasks, hide them from list, and guard shared worktree slots
echo "=== Test 12: archive finished tasks and slot guard ==="
t12_repo="$T/t12-repo"
mkdir -p "$t12_repo"
git -C "$t12_repo" init -q
t12_slot_a="$T/t12-slot-a"
t12_slot_b="$T/t12-slot-b"
mkdir -p "$t12_slot_a" "$t12_slot_b"
git -C "$t12_slot_a" init -q
git -C "$t12_slot_b" init -q

t12_make_task() {
  local id=$1 worktree=$2 last_status=$3
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF12
TASK_ID=$id
PROJECT=demo-t12
PROJECT_PATH=$t12_repo
WORKTREE=$worktree
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
EOF12
  echo "$last_status" > "$KINGPIN_HOME/tasks/$id/status"
}

# 12.1 A successful cleanup moves the task dir from tasks/ to archive/
t12_make_task t12-merged "$t12_slot_a" "merged: pr=x"
echo "critique from archived task" > "$KINGPIN_HOME/tasks/t12-merged/critique"
"$KP_BIN/kingpin-done" t12-merged --force >/dev/null
[ -L "$KINGPIN_HOME/tasks/t12-merged" ] && [ -f "$KINGPIN_HOME/archive/t12-merged/task.env" ] && [ -f "$KINGPIN_HOME/archive/t12-merged/done_cleaned" ] && pass "kingpin-done moved the task dir into the archive behind a dossier link" || fail "task dir not archived"

# 12.2 list hides finished tasks by default; --all shows them
t12_make_task t12-live "$t12_slot_b" "ready: branch=b review=APPROVE report=none"
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "t12-live" && ! echo "$list_out" | grep -q "t12-merged" && pass "list shows the live task and hides the merged one" || fail "list output wrong: $list_out"
list_all=$("$KP_BIN/kingpin" list --all)
echo "$list_all" | grep -q "t12-live" && echo "$list_all" | grep -q "t12-merged.*(archived)" && pass "list --all shows live and archived tasks" || fail "list --all output wrong: $list_all"
"$KP_BIN/kingpin" list --bogus >/dev/null 2>&1 && fail "list accepted an unknown flag" || pass "list rejects an unknown flag"

# 12.3 Archived critiques are still collected by curate
export KINGPIN_SKILLS_DIR=$T/skills
mkdir -p "$T/skills"
t12_curate=$("$KP_BIN/kingpin" curate --dry-run)
echo "$t12_curate" | grep -q "critique from archived task" && pass "curate collects the critique of an archived task" || fail "curate missed the archived critique: $t12_curate"

# 12.4 Cleanup is idempotent for an archived task
"$KP_BIN/kingpin-done" t12-merged >/dev/null 2>&1 && pass "kingpin-done on an archived task is a no-op" || fail "kingpin-done failed on an archived task"

# 12.5 Slot guard: refuse, even with --force, while another unfinished task holds the worktree
t12_make_task t12-old "$t12_slot_b" "merged: pr=y"
"$KP_BIN/kingpin-done" t12-old --force >/dev/null 2>&1 && fail "cleanup released a slot held by an unfinished task" || pass "kingpin-done --force refused a slot held by an unfinished task"
[ -d "$KINGPIN_HOME/tasks/t12-old" ] && [ ! -d "$KINGPIN_HOME/archive/t12-old" ] && pass "refused cleanup left the record in place" || fail "refused cleanup moved the record"
grep -q "^cleanup-refused: .*t12-live" "$KINGPIN_HOME/tasks/t12-old/status" && pass "refusal names the holding task" || fail "refusal reason missing"
[ -d "$t12_slot_b" ] && pass "held worktree still exists" || fail "held worktree was removed"
# Once the holder is finished the slot is no longer guarded
echo "merged: pr=z" >> "$KINGPIN_HOME/tasks/t12-live/status"
"$KP_BIN/kingpin-done" t12-old --force >/dev/null 2>&1 && [ -d "$KINGPIN_HOME/archive/t12-old" ] && pass "cleanup proceeds once the other task is finished" || fail "cleanup still refused after the holder finished"

# 12.6 A reused task id is archived beside the earlier record instead of overwriting it
mkdir -p "$KINGPIN_HOME/archive/t12-reuse"
echo "earlier" > "$KINGPIN_HOME/archive/t12-reuse/marker"
t12_make_task t12-reuse "$t12_slot_a" "merged: pr=r"
"$KP_BIN/kingpin-done" t12-reuse --force >/dev/null 2>&1
[ -L "$KINGPIN_HOME/tasks/t12-reuse" ] && [ -f "$KINGPIN_HOME/archive/t12-reuse/marker" ] && [ -f "$KINGPIN_HOME/archive/t12-reuse.2/done_cleaned" ] && pass "reused task id archived beside the earlier record" || fail "reused task id was not archived safely"

rm -rf "$KINGPIN_HOME/archive/t12-reuse" "$KINGPIN_HOME/archive/t12-reuse.2" "$KINGPIN_HOME/tasks/t12-live" "$KINGPIN_HOME/archive/t12-merged" "$KINGPIN_HOME/archive/t12-old" "$t12_repo" "$t12_slot_a" "$t12_slot_b"
unset KINGPIN_SKILLS_DIR

# Test 16: cleanup removes the branch the worker actually used, locally and on the remote
echo "=== Test 16: branch cleanup (switched branch, remote deletion) ==="
t16_remote="$T/t16-remote.git"
t16_repo="$T/t16-repo"
t16_stub="$T/t16-stub"
mkdir -p "$t16_stub"
git init --bare -q -b main "$t16_remote"
git init -q -b main "$t16_repo"
git -C "$t16_repo" config user.name Tester
git -C "$t16_repo" config user.email test@example.com
echo init > "$t16_repo/init.txt"
git -C "$t16_repo" add init.txt
git -C "$t16_repo" commit -qm init
git -C "$t16_repo" remote add origin "$t16_remote"
git -C "$t16_repo" push -q origin main
git -C "$t16_repo" remote set-head origin main >/dev/null 2>&1
# Stand-in for `treehouse return`: frees the slot by removing the worktree.
cat > "$t16_stub/treehouse" << 'EOF16'
#!/usr/bin/env bash
wt=${!#}
git worktree remove --force "$wt"
EOF16
chmod +x "$t16_stub/treehouse"

t16_make_task() {
  local id=$1 recorded=$2 actual=$3 merged=$4
  local wt="$T/t16-wt-$id"
  git -C "$t16_repo" fetch -q origin
  git -C "$t16_repo" merge -q --ff-only origin/main
  git -C "$t16_repo" branch "$recorded" main
  git -C "$t16_repo" worktree add -q "$wt" "$recorded"
  git -C "$wt" config user.name Tester
  git -C "$wt" config user.email test@example.com
  if [ "$actual" != "$recorded" ]; then git -C "$wt" checkout -qb "$actual"; fi
  echo "$id" > "$wt/$id.txt"
  git -C "$wt" add "$id.txt"
  git -C "$wt" commit -qm "work $id"
  git -C "$wt" push -q origin "$actual"
  if [ "$merged" = yes ]; then
    git -C "$t16_repo" fetch -q origin
    git -C "$t16_repo" push -q origin "refs/remotes/origin/$actual:refs/heads/main"
  fi
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF16T
TASK_ID=$id
PROJECT=demo-t16
PROJECT_PATH=$t16_repo
WORKTREE=$wt
BRANCH=$recorded
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
EOF16T
  echo "merged: pr=x" > "$KINGPIN_HOME/tasks/$id/status"
}
t16_local() { git -C "$t16_repo" show-ref --verify --quiet "refs/heads/$1"; }
t16_remote_has() { git -C "$t16_repo" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }

# The worker moved off kingpin/<id> to another branch, and its work is merged
t16_make_task t16-switch kingpin/t16-switch feature/t16-switch yes
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-switch >/dev/null 2>&1 && pass "t16: cleanup of a task on a switched branch succeeds" || fail "t16: cleanup of a switched branch failed"
! t16_local feature/t16-switch && pass "t16: local branch the worker used is deleted" || fail "t16: switched local branch survived cleanup"
! t16_local kingpin/t16-switch && pass "t16: recorded local branch is deleted" || fail "t16: recorded local branch survived cleanup"
! t16_remote_has feature/t16-switch && pass "t16: remote branch is deleted after the merge check passes" || fail "t16: remote branch survived cleanup"
t16_local main && t16_remote_has main && pass "t16: default branch is untouched" || fail "t16: default branch was removed"

# A branch that is already gone from the remote is not an error
t16_make_task t16-gone kingpin/t16-gone kingpin/t16-gone yes
git -C "$t16_repo" push -q origin --delete kingpin/t16-gone
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-gone >/dev/null 2>&1 && pass "t16: missing remote branch is not an error" || fail "t16: cleanup failed on a missing remote branch"
[ -f "$KINGPIN_HOME/archive/t16-gone/done_cleaned" ] && pass "t16: task archived despite the missing remote branch" || fail "t16: task not archived"

# Unmerged work: cleanup is refused and nothing is deleted
t16_make_task t16-unmerged kingpin/t16-unmerged feature/t16-unmerged no
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-unmerged >/dev/null 2>&1 && fail "t16: unmerged cleanup was not refused" || pass "t16: unmerged cleanup is refused"
t16_local feature/t16-unmerged && t16_remote_has feature/t16-unmerged && pass "t16: nothing deleted when the merge check fails" || fail "t16: branch deleted despite the refused cleanup"

# --force skips the merge check, so the remote branch stays
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t16-unmerged --force >/dev/null 2>&1 || true
t16_remote_has feature/t16-unmerged && pass "t16: --force leaves the unverified remote branch alone" || fail "t16: --force deleted the remote branch"

# Test 19: a refused kingpin done keeps a live worker's status; done stops the listener; ack on an archived task is a no-op
echo "=== Test 19: refused done vs live worker status, listener cleanup, ack on archived task ==="
kp_test_stub_lavish
mk_t19() {
  local name=$1 status=$2 wt d
  d="$KINGPIN_HOME/tasks/$name"
  wt="$T/wt-$name"
  mkdir -p "$d" "$wt"
  git -C "$wt" init -q
  echo dirty > "$wt/uncommitted.txt"
  echo "<html><body>$name</body></html>" > "$d/report.html"
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t19
HARNESS=claude
MODE=review
PROJECT_PATH=$wt
WORKTREE=$wt
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
ENVEOF
  printf '%s\n' "$status" > "$d/status"
  tmux new-window -d -t kingpin: -n "$name" cat
}

# (a) live worker waiting on needs-input: a refused done must not mask it
mk_t19 t19-live "needs-input: which flag should I use?"
if "$KP_BIN/kingpin-done" t19-live >"$T/t19-live.out" 2>&1; then
  fail "t19: done on a dirty live worker was not refused"
else
  pass "t19: done on a dirty live worker is refused"
fi
grep -q "uncommitted changes" "$T/t19-live.out" && pass "t19: the refusal reason is still printed" || fail "t19: refusal reason missing: $(cat "$T/t19-live.out")"
[ "$(tail -n 1 "$KINGPIN_HOME/tasks/t19-live/status")" = "needs-input: which flag should I use?" ] && pass "t19: live worker's last status is still needs-input" || fail "t19: live worker's status replaced: $(tail -n 1 "$KINGPIN_HOME/tasks/t19-live/status")"
! grep -q "^cleanup-refused:" "$KINGPIN_HOME/tasks/t19-live/status" && pass "t19: no cleanup-refused line recorded for a live worker" || fail "t19: cleanup-refused recorded for a live worker"
t19_list=$("$KP_BIN/kingpin" list)
echo "$t19_list" | grep "^t19-live " | grep -q "needs-input" && ! echo "$t19_list" | grep "^t19-live " | grep -q "cleanup-refused" && pass "t19: kingpin list still shows needs-input" || fail "t19: kingpin list masks needs-input: $t19_list"
tmux kill-window -t kingpin:t19-live 2>/dev/null || true

# A refusal must not stop the listener of a worker that is still live
mk_t19 t19-ready "ready: branch=b review=APPROVE report=none"
"$KP_BIN/kingpin-listen" t19-ready --background
t19r_pid=$(cat "$KINGPIN_HOME/tasks/t19-ready/listener.pid" 2>/dev/null || true)
[ -n "$t19r_pid" ] && kill -0 "$t19r_pid" 2>/dev/null && pass "t19: listener running for the ready task" || fail "t19: listener not running for the ready task"
"$KP_BIN/kingpin-done" t19-ready >/dev/null 2>&1 && fail "t19: done on a dirty ready task was not refused" || true
kill -0 "$t19r_pid" 2>/dev/null && pass "t19: refused done leaves a live worker's listener alone" || fail "t19: listener of a live worker was stopped"
[ "$(tail -n 1 "$KINGPIN_HOME/tasks/t19-ready/status")" = "ready: branch=b review=APPROVE report=none" ] && pass "t19: ready status kept" || fail "t19: ready status replaced"
rm -f "$T/wt-t19-ready/uncommitted.txt"
"$KP_BIN/kingpin-done" t19-ready --force >/dev/null 2>&1 || true
tmux kill-window -t kingpin:t19-ready 2>/dev/null || true

# (b) finished task: a refusal still reports cleanup-refused, and the listener is stopped
mk_t19 t19-merged "merged: pr=https://example.invalid/pull/1"
"$KP_BIN/kingpin-listen" t19-merged --background
t19m_pid=$(cat "$KINGPIN_HOME/tasks/t19-merged/listener.pid" 2>/dev/null || true)
[ -n "$t19m_pid" ] && kill -0 "$t19m_pid" 2>/dev/null && pass "t19: listener running for the merged task" || fail "t19: listener not running for the merged task"
t19_list=$("$KP_BIN/kingpin" list)
echo "$t19_list" | grep -q "listening: pid $t19m_pid" && pass "t19: list shows the merged task as listening before done" || fail "t19: list does not show the listener before done"
"$KP_BIN/kingpin-done" t19-merged >/dev/null 2>&1 && fail "t19: done on a dirty merged task was not refused" || true
tail -n 1 "$KINGPIN_HOME/tasks/t19-merged/status" | grep -q "^cleanup-refused: .*uncommitted changes" && pass "t19: refusal on a finished task still reports cleanup-refused" || fail "t19: cleanup-refused missing on a finished task: $(tail -n 1 "$KINGPIN_HOME/tasks/t19-merged/status")"
for _ in $(seq 1 40); do kill -0 "$t19m_pid" 2>/dev/null || break; sleep 0.05; done
kill -0 "$t19m_pid" 2>/dev/null && fail "t19: listener of the merged task still running after done" || pass "t19: done stopped the listener of the merged task"
[ ! -f "$KINGPIN_HOME/tasks/t19-merged/listener.pid" ] && pass "t19: listener.pid removed" || fail "t19: listener.pid left behind"
t19_list=$("$KP_BIN/kingpin" list)
! echo "$t19_list" | grep -q "listening" && pass "t19: kingpin list no longer shows listening" || fail "t19: kingpin list still shows listening"

# (b2) the listener's approved:/feedback: notes after merged: are not worker events: still a finished task
mk_t19 t19-approved "merged: pr=https://example.invalid/pull/2"
echo "approved: by user via lavish dossier" >> "$KINGPIN_HOME/tasks/t19-approved/status"
"$KP_BIN/kingpin-done" t19-approved >/dev/null 2>&1 && fail "t19: done on a dirty merged+approved task was not refused" || true
grep -q "^cleanup-refused: .*uncommitted changes" "$KINGPIN_HOME/tasks/t19-approved/status" && pass "t19: cleanup-refused recorded after a trailing approved: note" || fail "t19: cleanup-refused missing after approved: note: $(cat "$KINGPIN_HOME/tasks/t19-approved/status")"
tmux kill-window -t kingpin:t19-approved 2>/dev/null || true

# (c) ack on an archived task is a no-op with a note; an unknown task is still an error
"$KP_BIN/kingpin" "done" t19-merged --force >/dev/null 2>&1 || true
[ -d "$KINGPIN_HOME/archive/t19-merged" ] && [ -L "$KINGPIN_HOME/tasks/t19-merged" ] && pass "t19: done --force archived the task behind its dossier link" || fail "t19: task not archived"
t19_ack_rc=0
t19_ack=$("$KP_BIN/kingpin" ack t19-merged 2>&1) || t19_ack_rc=$?
[ "$t19_ack_rc" -eq 0 ] && echo "$t19_ack" | grep -qi "archived" && pass "t19: ack on an archived task exits 0 with a note" || fail "t19: ack on an archived task (rc=$t19_ack_rc): $t19_ack"
t19_ack_rc=0
"$KP_BIN/kingpin" ack t19-no-such-task >/dev/null 2>&1 || t19_ack_rc=$?
[ "$t19_ack_rc" -eq 1 ] && pass "t19: ack on an unknown task still fails" || fail "t19: ack on an unknown task exited $t19_ack_rc"

tmux kill-window -t kingpin:t19-merged 2>/dev/null || true
rm -rf "$KINGPIN_HOME/archive/t19-"* "$KINGPIN_HOME/tasks/t19-"* "$T"/wt-t19-*
# Put the default stub back rather than unsetting KINGPIN_LAVISH: an unset value
# resolves the real lavish-axi from PATH again (issue #129).
kp_test_stub_lavish

# Test 20: two concurrent cleanups call treehouse return once and archive once
echo "=== Test 20: cleanup is single-flight ==="
t20_repo="$T/t20-repo"
t20_wt="$T/t20-wt"
t20_calls="$T/t20-calls"
mkdir -p "$t20_repo" "$t20_wt" "$T/t20-stub"
git -C "$t20_repo" init -q
git -C "$t20_wt" init -q
cat > "$T/t20-stub/treehouse" << 'EOF20'
#!/usr/bin/env bash
printf 'return %s\n' "$*" >> "$RECORDED_RETURNS"
sleep 1
git worktree remove --force "${!#}" 2>/dev/null || rm -rf "${!#}"
EOF20
chmod +x "$T/t20-stub/treehouse"
t20_make_task() {
  mkdir -p "$KINGPIN_HOME/tasks/$1"
  cat > "$KINGPIN_HOME/tasks/$1/task.env" << EOF20T
TASK_ID=$1
PROJECT=demo-t20
PROJECT_PATH=$t20_repo
WORKTREE=$t20_wt
BRANCH=kingpin/$1
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$1
EOF20T
}
t20_make_task t20-race
echo "merged: pr=x" > "$KINGPIN_HOME/tasks/t20-race/status"
: > "$t20_calls"
export RECORDED_RETURNS="$t20_calls"
PATH="$T/t20-stub:$PATH" "$KP_BIN/kingpin-done" t20-race --force >"$T/t20-a.out" 2>&1 &
t20_p1=$!
PATH="$T/t20-stub:$PATH" "$KP_BIN/kingpin-done" t20-race --force >"$T/t20-b.out" 2>&1 &
t20_p2=$!
t20_rc1=0
t20_rc2=0
wait "$t20_p1" || t20_rc1=$?
wait "$t20_p2" || t20_rc2=$?
unset RECORDED_RETURNS
# The run that loses the lock says so and exits 0 (README.md, `kingpin done`):
# `kingpin run` and `kingpin-watch` branch on this exit code.
[ "$t20_rc1" -eq 0 ] && [ "$t20_rc2" -eq 0 ] \
  && pass "t20: both concurrent done runs exit 0 (the loser defers)" \
  || fail "t20: concurrent done exit codes were $t20_rc1 and $t20_rc2, expected 0 and 0"
t20_returns=$(wc -l < "$t20_calls" | tr -d ' ')
[ "$t20_returns" = "1" ] && pass "t20: two concurrent done runs called treehouse return once" || fail "t20: treehouse return called $t20_returns times"
t20_archives=$(find "$KINGPIN_HOME/archive" -maxdepth 1 -name 't20-race*' | wc -l | tr -d ' ')
[ "$t20_archives" = "1" ] && pass "t20: two concurrent done runs produced one archive" || fail "t20: $t20_archives archives of t20-race"
! grep -q "cannot touch" "$T/t20-a.out" "$T/t20-b.out" && pass "t20: no marker write hit a missing task dir" || fail "t20: marker write failed after the task dir moved: $(cat "$T/t20-a.out" "$T/t20-b.out")"

# A lock left by a dead process is reclaimed, so a crashed cleanup cannot wedge the task
t20_make_task t20-stale
echo "merged: pr=y" > "$KINGPIN_HOME/tasks/t20-stale/status"
mkdir -p "$KINGPIN_HOME/locks"
printf '999999\n' > "$KINGPIN_HOME/locks/t20-stale.cleanup"
PATH="$T/t20-stub:$PATH" "$KP_BIN/kingpin-done" t20-stale --force >/dev/null 2>&1 \
  && pass "t20: a stale cleanup lock is reclaimed" || fail "t20: a stale cleanup lock wedged the cleanup"
[ -f "$KINGPIN_HOME/archive/t20-stale/done_cleaned" ] && pass "t20: the task with a stale lock was archived" || fail "t20: the task with a stale lock was not archived"

# Test 21: a failed treehouse return refuses instead of archiving, and the
# refusal records a lease-lost marker that makes a retry a cheap no-op
echo "=== Test 21: a lost lease refuses cleanup ==="
t21_remote="$T/t21-remote.git"
t21_repo="$T/t21-repo"
t21_wt="$T/t21-wt"
t21_returns="$T/t21-returns"
t21_git_calls="$T/t21-git-calls"
mkdir -p "$T/t21-stub"
# A real repo with a real merged worktree, so the merge check passes and the run
# reaches `treehouse return`. Only the pool refuses the return: that is the lost
# lease. A fixture that fails the merge check instead would never exercise the
# network calls the retry must skip.
git init --bare -q -b main "$t21_remote"
git init -q -b main "$t21_repo"
git -C "$t21_repo" config user.name Tester
git -C "$t21_repo" config user.email test@example.com
echo base > "$t21_repo/base.txt"
git -C "$t21_repo" add base.txt
git -C "$t21_repo" commit -qm base
git -C "$t21_repo" remote add origin "$t21_remote"
git -C "$t21_repo" push -q -u origin main
git -C "$t21_repo" remote set-head origin main >/dev/null 2>&1
git -C "$t21_repo" worktree add -q "$t21_wt" -b feature/t21 main
git -C "$t21_wt" config user.name Tester
git -C "$t21_wt" config user.email test@example.com
echo work > "$t21_wt/work.txt"
git -C "$t21_wt" add work.txt
git -C "$t21_wt" commit -qm "work t21"
git -C "$t21_wt" push -q origin feature/t21
git -C "$t21_repo" fetch -q origin
git -C "$t21_repo" merge -q --ff-only origin/feature/t21
git -C "$t21_repo" push -q origin main
cat > "$T/t21-stub/treehouse" << 'EOF21'
#!/usr/bin/env bash
printf 'return %s\n' "$*" >> "${KP_TREEHOUSE_CALLS:-/dev/null}"
echo "treehouse: worktree ${!#} is not managed by treehouse"
exit 1
EOF21
chmod +x "$T/t21-stub/treehouse"
# Records the git subcommands that would go to the network, then delegates.
t21_real_git=$(command -v git)
mkdir -p "$T/t21-net"
cat > "$T/t21-net/git" << EOF21G
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*|*" ls-remote "*) printf '%s\n' "\$*" >> "\${KP_T21_GIT_CALLS:-/dev/null}" ;;
esac
exec "$t21_real_git" "\$@"
EOF21G
chmod +x "$T/t21-net/git"
mkdir -p "$KINGPIN_HOME/tasks/t21-lost"
cat > "$KINGPIN_HOME/tasks/t21-lost/task.env" << EOF21T
TASK_ID=t21-lost
PROJECT=demo-t21
PROJECT_PATH=$t21_repo
WORKTREE=$t21_wt
BRANCH=kingpin/t21-lost
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t21-lost
EOF21T
echo "merged: pr=z" > "$KINGPIN_HOME/tasks/t21-lost/status"
KP_TREEHOUSE_CALLS="$t21_returns" PATH="$T/t21-stub:$PATH" "$KP_BIN/kingpin-done" t21-lost >"$T/t21.out" 2>&1 \
  && fail "t21: a failed treehouse return exited 0" || pass "t21: a failed treehouse return exits nonzero"
[ -d "$KINGPIN_HOME/tasks/t21-lost" ] && [ ! -d "$KINGPIN_HOME/archive/t21-lost" ] \
  && pass "t21: the task stays in tasks/ after a lost lease" || fail "t21: the task was archived after a lost lease"
[ ! -f "$KINGPIN_HOME/tasks/t21-lost/done_cleaned" ] && pass "t21: no done_cleaned after a lost lease" || fail "t21: done_cleaned written after a lost lease"
grep -q "^cleanup-refused: .*$t21_wt" "$KINGPIN_HOME/tasks/t21-lost/status" \
  && pass "t21: cleanup-refused names the lost worktree lease" || fail "t21: cleanup-refused does not name the lease: $(tail -n 1 "$KINGPIN_HOME/tasks/t21-lost/status")"
grep -q "not managed by treehouse" "$KINGPIN_HOME/tasks/t21-lost/status" \
  && pass "t21: cleanup-refused carries treehouse's reason" || fail "t21: treehouse's reason missing from the refusal"
[ -f "$KINGPIN_HOME/tasks/t21-lost/lease-lost" ] \
  && pass "t21: the lost-lease refusal records a lease-lost marker" || fail "t21: no lease-lost marker after a failed return"
grep -q "not managed by treehouse" "$KINGPIN_HOME/tasks/t21-lost/lease-lost" \
  && pass "t21: the marker holds the refusal reason" || fail "t21: the marker does not hold the reason: $(cat "$KINGPIN_HOME/tasks/t21-lost/lease-lost" 2>/dev/null)"

# A retry that carries the marker re-emits the recorded refusal and stops: no
# treehouse return, no git fetch, no git ls-remote, no second status line.
: > "$t21_git_calls"
t21_retry_rc=0
KP_TREEHOUSE_CALLS="$t21_returns" KP_T21_GIT_CALLS="$t21_git_calls" \
  PATH="$T/t21-net:$T/t21-stub:$PATH" "$KP_BIN/kingpin-done" t21-lost >"$T/t21-retry.out" 2>&1 \
  || t21_retry_rc=$?
[ "$t21_retry_rc" -eq 1 ] && pass "t21: a retried lost-lease cleanup still exits 1" \
  || fail "t21: a retried lost-lease cleanup exited $t21_retry_rc, expected 1"
grep -q "not managed by treehouse" "$T/t21-retry.out" \
  && pass "t21: the retry re-emits the recorded refusal" || fail "t21: the retry did not re-emit the recorded reason: $(cat "$T/t21-retry.out")"
[ ! -s "$t21_git_calls" ] && pass "t21: the retry makes no git fetch or ls-remote call" \
  || fail "t21: the retry went to the network: $(cat "$t21_git_calls")"
[ "$(wc -l < "$t21_returns" | tr -d ' ')" = "1" ] && pass "t21: the retry makes no second treehouse return call" \
  || fail "t21: the retry called treehouse return $(wc -l < "$t21_returns" | tr -d ' ') times"

KP_TREEHOUSE_CALLS="$t21_returns" PATH="$T/t21-stub:$PATH" "$KP_BIN/kingpin" watch --once >/dev/null 2>&1 || true
[ "$(grep -c '^cleanup-refused:' "$KINGPIN_HOME/tasks/t21-lost/status")" = "1" ] \
  && pass "t21: the supervisor retry adds no duplicate refusal line" || fail "t21: retries duplicated the refusal line"
[ "$(wc -l < "$t21_returns" | tr -d ' ')" = "1" ] && pass "t21: the supervisor retry makes no further treehouse return call" \
  || fail "t21: the supervisor retry called treehouse return $(wc -l < "$t21_returns" | tr -d ' ') times"
[ -d "$KINGPIN_HOME/tasks/t21-lost" ] && pass "t21: the retry left the task in place" || fail "t21: the retry archived a task whose lease is lost"

# --force bypasses the marker and attempts the cleanup again; a working pool then
# archives the task and leaves no stale marker behind.
mkdir -p "$T/t21-ok"
cat > "$T/t21-ok/treehouse" << 'EOF21OK'
#!/usr/bin/env bash
printf 'return %s\n' "$*" >> "$KP_TREEHOUSE_CALLS"
exit 0
EOF21OK
chmod +x "$T/t21-ok/treehouse"
t21_before_force=$(wc -l < "$t21_returns" | tr -d ' ')
KP_TREEHOUSE_CALLS="$t21_returns" PATH="$T/t21-ok:$PATH" "$KP_BIN/kingpin-done" t21-lost --force >"$T/t21-force.out" 2>&1 \
  && pass "t21: --force re-attempts the cleanup of a lost lease" || fail "t21: --force did not re-attempt the cleanup: $(cat "$T/t21-force.out")"
t21_after_force=$(wc -l < "$t21_returns" | tr -d ' ')
[ "$t21_after_force" = "$((t21_before_force + 1))" ] && pass "t21: the forced cleanup called treehouse return again" \
  || fail "t21: the forced cleanup made $((t21_after_force - t21_before_force)) return calls instead of one"
tail -n 1 "$t21_returns" | grep -q -- "--force" \
  && pass "t21: --force is passed on to treehouse return" || fail "t21: --force was not passed on: $(tail -n 1 "$t21_returns")"
[ -f "$KINGPIN_HOME/archive/t21-lost/done_cleaned" ] && pass "t21: the forced cleanup archived the task" \
  || fail "t21: the forced cleanup did not archive the task"
[ ! -f "$KINGPIN_HOME/archive/t21-lost/lease-lost" ] && pass "t21: no stale lease-lost marker travels into the archive" \
  || fail "t21: the archived record carries a stale lease-lost marker"

# Test 22: a master-default repo without origin/HEAD verifies and cleans
echo "=== Test 22: master default without origin/HEAD ==="
t22_remote="$T/t22-remote.git"
t22_repo="$T/t22-repo"
t22_wt="$T/t22-wt"
git init --bare -q -b master "$t22_remote"
git init -q -b master "$t22_repo"
git -C "$t22_repo" config user.name Tester
git -C "$t22_repo" config user.email test@example.com
echo base > "$t22_repo/base.txt"
git -C "$t22_repo" add base.txt
git -C "$t22_repo" commit -qm base
git -C "$t22_repo" remote add origin "$t22_remote"
git -C "$t22_repo" push -q -u origin master
# The issue's repo: master is the default and no origin/HEAD was ever recorded.
git -C "$t22_repo" remote set-head origin -d >/dev/null 2>&1 || true
rm -f "$t22_repo/.git/refs/remotes/origin/HEAD"
git -C "$t22_repo" worktree add -q "$t22_wt" -b feature/t22 master
git -C "$t22_wt" config user.name Tester
git -C "$t22_wt" config user.email test@example.com
echo work > "$t22_wt/work.txt"
git -C "$t22_wt" add work.txt
git -C "$t22_wt" commit -qm "work t22"
git -C "$t22_wt" push -q origin feature/t22
git -C "$t22_repo" merge -q --ff-only feature/t22
git -C "$t22_repo" push -q origin master
mkdir -p "$KINGPIN_HOME/tasks/t22"
cat > "$KINGPIN_HOME/tasks/t22/task.env" << EOF22
TASK_ID=t22
PROJECT=demo-t22
PROJECT_PATH=$t22_repo
WORKTREE=$t22_wt
BRANCH=feature/t22
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t22
EOF22
echo "merged: pr=m" > "$KINGPIN_HOME/tasks/t22/status"
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t22 >"$T/t22.out" 2>&1 \
  && pass "t22: a merged commit is verified in a master-default repo with no origin/HEAD" \
  || fail "t22: cleanup refused a merged commit: $(cat "$T/t22.out")"
[ -f "$KINGPIN_HOME/archive/t22/done_cleaned" ] && pass "t22: the task was archived" || fail "t22: the task was not archived"
git -C "$t22_repo" show-ref --verify --quiet refs/heads/master && pass "t22: the default branch survives" || fail "t22: master was deleted"
! git -C "$t22_repo" ls-remote --exit-code --heads origin feature/t22 >/dev/null 2>&1 \
  && pass "t22: the merged feature branch was deleted on the remote" || fail "t22: the remote feature branch survived"

# Test 23: a failed git fetch is reported, and does not silently refuse everything
echo "=== Test 23: a failed git fetch is reported ==="
t23_remote="$T/t23-remote.git"
t23_repo="$T/t23-repo"
t23_wt="$T/t23-wt"
git init --bare -q -b main "$t23_remote"
git clone -q "$t23_remote" "$t23_repo" 2>/dev/null
(
  cd "$t23_repo" || exit 1
  git checkout -q -b main
  git config user.name Tester
  git config user.email test@example.com
  echo base > base.txt
  git add base.txt
  git commit -qm base
  git push -q -u origin main
  git remote set-head origin main
)
git -C "$t23_repo" worktree add -q "$t23_wt" -b feature/t23 main
git -C "$t23_wt" config user.name Tester
git -C "$t23_wt" config user.email test@example.com
echo work > "$t23_wt/work.txt"
git -C "$t23_wt" add work.txt
git -C "$t23_wt" commit -qm "work t23"
git -C "$t23_wt" push -q origin feature/t23
git -C "$t23_repo" merge -q --ff-only feature/t23
git -C "$t23_repo" push -q origin main
git -C "$t23_repo" fetch -q origin
t23_make_task() {
  mkdir -p "$KINGPIN_HOME/tasks/$1"
  cat > "$KINGPIN_HOME/tasks/$1/task.env" << EOF23
TASK_ID=$1
PROJECT=demo-t23
PROJECT_PATH=$t23_repo
WORKTREE=$t23_wt
BRANCH=feature/t23
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$1
EOF23
  echo "merged: pr=n" > "$KINGPIN_HOME/tasks/$1/status"
}
# (a) the last-known ref already proves the merge: cleanup succeeds and says so
t23_make_task t23-offline
git -C "$t23_repo" remote set-url origin "$T/t23-no-such-remote.git"
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t23-offline >"$T/t23-a.out" 2>&1 \
  && pass "t23: cleanup succeeds on the last-known refs when fetch fails" || fail "t23: cleanup failed offline: $(cat "$T/t23-a.out")"
grep -q "git fetch origin failed" "$T/t23-a.out" && pass "t23: the failed fetch is reported on stderr" || fail "t23: the failed fetch was silent: $(cat "$T/t23-a.out")"
[ -f "$KINGPIN_HOME/archive/t23-offline/done_cleaned" ] && pass "t23: the offline task was archived" || fail "t23: the offline task was not archived"
# (b) the ref cannot prove it: the refusal names the fetch failure, not just the merge
t23_make_task t23-stale
git -C "$t23_repo" worktree add -q "$T/t23-wt2" -b feature/t23-stale main
git -C "$T/t23-wt2" config user.name Tester
git -C "$T/t23-wt2" config user.email test@example.com
echo more > "$T/t23-wt2/more.txt"
git -C "$T/t23-wt2" add more.txt
git -C "$T/t23-wt2" commit -qm "unmerged work"
kp_test_sub "$KINGPIN_HOME/tasks/t23-stale/task.env" "s|^WORKTREE=.*|WORKTREE=$T/t23-wt2|"
git -C "$t23_repo" update-ref -d refs/remotes/origin/main
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t23-stale >"$T/t23-b.out" 2>&1 \
  && fail "t23: an unverifiable cleanup was not refused" || pass "t23: an unverifiable cleanup is refused"
grep -q "the last git fetch failed" "$KINGPIN_HOME/tasks/t23-stale/status" \
  && pass "t23: the refusal names the failed fetch" || fail "t23: the refusal hides the fetch failure: $(tail -n 1 "$KINGPIN_HOME/tasks/t23-stale/status")"
[ ! -d "$KINGPIN_HOME/archive/t23-stale" ] && pass "t23: the unverifiable task stays in tasks/" || fail "t23: the unverifiable task was archived"

# Test 24: a finished task's issue is closed after a verified merge, or named in
# the OK: line (issue #170). merged: is the line the supervisor acts on, so a
# worker that left the issue open has no later step to close it.
echo "=== Test 24: kingpin done reads the issue a finished task names ==="
t24_remote="$T/t24-remote.git"
t24_repo="$T/t24-repo"
git init --bare -q -b main "$t24_remote"
git clone -q "$t24_remote" "$t24_repo" 2>/dev/null
(
  cd "$t24_repo" || exit 1
  git checkout -q -b main
  git config user.name Tester
  git config user.email test@example.com
  echo base > base.txt
  git add base.txt
  git commit -qm base
  git push -q -u origin main
  git remote set-head origin main
)
t24_make_task() { # <id> <issue|-> <merged yes|no>
  local id=$1 issue=$2 merged=$3 wt issue_line
  wt="$T/t24-wt-$id"
  git -C "$t24_repo" fetch -q origin
  git -C "$t24_repo" worktree add -q "$wt" -b "feature/$id" main
  git -C "$wt" config user.name Tester
  git -C "$wt" config user.email test@example.com
  echo "work $id" > "$wt/$id.txt"
  git -C "$wt" add "$id.txt"
  git -C "$wt" commit -qm "work $id"
  git -C "$wt" push -q origin "feature/$id"
  if [ "$merged" = yes ]; then
    git -C "$t24_repo" merge -q --ff-only "feature/$id"
    git -C "$t24_repo" push -q origin main
  fi
  # "-" writes a record with no ISSUE line at all, the shape a curator record and a
  # record from before issue #170 have.
  issue_line="ISSUE=$issue"
  [ "$issue" = "-" ] && issue_line="# no ISSUE line"
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF24
TASK_ID=$id
PROJECT=demo-t24
PROJECT_PATH=$t24_repo
WORKTREE=$wt
BRANCH=feature/$id
$issue_line
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
EOF24
  echo "merged: pr=https://github.com/example/demo/pull/1" > "$KINGPIN_HOME/tasks/$id/status"
}

# (a) merged, still open, and the close fails: the OK: line says so
t24_make_task t24-open 164 yes
: > "$GH_LOG"
printf 'OPEN\n' > "$GH_STATE"
touch "$GH_CLOSE_FAILS"
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-open >"$T/t24-open.out" 2>&1 \
  && pass "t24: cleanup succeeds when the issue close fails" || fail "t24: cleanup failed: $(cat "$T/t24-open.out")"
grep -q "issue #164 is still open" "$T/t24-open.out" \
  && pass "t24: the OK: line reports the issue left open" || fail "t24: the OK: line hides the open issue: $(cat "$T/t24-open.out")"
[ -f "$KINGPIN_HOME/archive/t24-open/done_cleaned" ] && pass "t24: the task archived despite the open issue" || fail "t24: the task was not archived"
grep -q "^issue close 164$" "$GH_LOG" && pass "t24: done tried to close the issue" || fail "t24: done never tried to close the issue: $(cat "$GH_LOG")"

# (b) merged and still open: done closes it and says so
t24_make_task t24-closed 164 yes
: > "$GH_LOG"
printf 'OPEN\n' > "$GH_STATE"
rm -f "$GH_CLOSE_FAILS"
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-closed >"$T/t24-closed.out" 2>&1 \
  && pass "t24: cleanup succeeds after closing the issue" || fail "t24: cleanup failed: $(cat "$T/t24-closed.out")"
grep -q "closed issue #164 after the merge" "$T/t24-closed.out" \
  && pass "t24: the OK: line says the issue was closed" || fail "t24: the OK: line does not name the close: $(cat "$T/t24-closed.out")"
grep -q "^issue close 164$" "$GH_LOG" && pass "t24: the issue was closed through gh" || fail "t24: gh saw no close: $(cat "$GH_LOG")"

# (c) an issue already closed needs no close call
t24_make_task t24-already 164 yes
: > "$GH_LOG"
printf 'CLOSED\n' > "$GH_STATE"
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-already >"$T/t24-already.out" 2>&1 \
  && pass "t24: cleanup succeeds when the issue is already closed" || fail "t24: cleanup failed: $(cat "$T/t24-already.out")"
grep -q "issue #164 is closed" "$T/t24-already.out" \
  && pass "t24: the OK: line says the issue is closed" || fail "t24: the OK: line does not say closed: $(cat "$T/t24-already.out")"
! grep -q "^issue close" "$GH_LOG" && pass "t24: a closed issue is not closed again" || fail "t24: done closed an already closed issue: $(cat "$GH_LOG")"

# (d) no verified merge: never close, and say the issue was not checked
t24_make_task t24-forced 164 no
: > "$GH_LOG"
printf 'OPEN\n' > "$GH_STATE"
PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-forced --force >"$T/t24-forced.out" 2>&1 \
  && pass "t24: --force cleanup succeeds on an unmerged task" || fail "t24: --force cleanup failed: $(cat "$T/t24-forced.out")"
grep -q "issue #164 not checked (the merge was not verified)" "$T/t24-forced.out" \
  && pass "t24: an unverified merge reports the issue as unchecked" || fail "t24: the unverified merge says nothing: $(cat "$T/t24-forced.out")"
! grep -q "^issue close" "$GH_LOG" && pass "t24: an unverified merge never closes the issue" || fail "t24: an unverified merge closed the issue: $(cat "$GH_LOG")"
! grep -q "^issue view" "$GH_LOG" && pass "t24: an unverified merge asks gh nothing" || fail "t24: an unverified merge called gh: $(cat "$GH_LOG")"

# (e) a record that names no issue never picks up an ISSUE from the caller's
# environment: only the record is read, so a stray export cannot become the target
t24_make_task t24-norecord - yes
: > "$GH_LOG"
printf 'OPEN\n' > "$GH_STATE"
ISSUE=999 PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-norecord >"$T/t24-norecord.out" 2>&1 \
  && pass "t24: cleanup succeeds for a record with no issue" || fail "t24: cleanup failed: $(cat "$T/t24-norecord.out")"
! grep -q "999" "$GH_LOG" && pass "t24: an inherited ISSUE never reaches gh" || fail "t24: gh was called for the inherited ISSUE: $(cat "$GH_LOG")"
[ -s "$GH_LOG" ] && fail "t24: a record with no issue still called gh: $(cat "$GH_LOG")" || pass "t24: a record with no issue asks gh nothing"
! grep -q "issue #" "$T/t24-norecord.out" && pass "t24: a record with no issue gets no issue readout" || fail "t24: a record with no issue got a readout: $(cat "$T/t24-norecord.out")"

# (f) gh is not installed: the readout says so and the cleanup still succeeds
t24_make_task t24-nogh 164 yes
: > "$GH_LOG"
KINGPIN_GH=gh-does-not-exist PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-nogh >"$T/t24-nogh.out" 2>&1 \
  && pass "t24: cleanup succeeds without gh" || fail "t24: cleanup failed without gh: $(cat "$T/t24-nogh.out")"
grep -q "issue #164 not checked (gh-does-not-exist is not available)" "$T/t24-nogh.out" \
  && pass "t24: a missing gh is named in the OK: line" || fail "t24: a missing gh is not named: $(cat "$T/t24-nogh.out")"
[ -s "$GH_LOG" ] && fail "t24: a missing gh still reached the real one: $(cat "$GH_LOG")" || pass "t24: a missing gh is never called"

# (g) gh is there but the state cannot be read: the readout says so
t24_make_task t24-unreadable 164 yes
: > "$GH_LOG"
KINGPIN_GH="$T/bin/gh-view-fails" PATH="$t16_stub:$PATH" "$KP_BIN/kingpin-done" t24-unreadable >"$T/t24-unreadable.out" 2>&1 \
  && pass "t24: cleanup succeeds when the issue state is unreadable" || fail "t24: cleanup failed: $(cat "$T/t24-unreadable.out")"
grep -q "issue #164 state could not be read (check that it is closed)" "$T/t24-unreadable.out" \
  && pass "t24: an unreadable issue state is named in the OK: line" || fail "t24: an unreadable state is not named: $(cat "$T/t24-unreadable.out")"
grep -q "^issue view 164" "$GH_LOG" && pass "t24: the failing read was attempted" || fail "t24: gh saw no read: $(cat "$GH_LOG")"
! grep -q "^issue close" "$GH_LOG" && pass "t24: an unreadable state never closes the issue" || fail "t24: an unreadable state closed the issue: $(cat "$GH_LOG")"

printf 'OPEN\n' > "$GH_STATE"
rm -f "$GH_CLOSE_FAILS"
rm -rf "$KINGPIN_HOME/archive/t24-open" "$KINGPIN_HOME/archive/t24-closed" "$KINGPIN_HOME/archive/t24-already" "$KINGPIN_HOME/archive/t24-forced"
rm -rf "$KINGPIN_HOME/archive/t24-norecord" "$KINGPIN_HOME/archive/t24-nogh" "$KINGPIN_HOME/archive/t24-unreadable"
rm -rf "$T/t24-wt-t24-open" "$T/t24-wt-t24-closed" "$T/t24-wt-t24-already" "$T/t24-wt-t24-forced" "$t24_repo" "$t24_remote"
rm -rf "$T/t24-wt-t24-norecord" "$T/t24-wt-t24-nogh" "$T/t24-wt-t24-unreadable"

kp_test_finish DONE
