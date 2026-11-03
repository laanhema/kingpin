#!/usr/bin/env bash
# Verification test for Kingpin: kingpin done: refused cleanup, archive, slot guard, branch cleanup, live-worker status.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "done"
kp_test_project

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
TMUX_TARGET=kingpin:$id
EOF12
  echo "$last_status" > "$KINGPIN_HOME/tasks/$id/status"
}

# 12.1 A successful cleanup moves the task dir from tasks/ to archive/
t12_make_task t12-merged "$t12_slot_a" "merged: pr=x"
echo "critique from archived task" > "$KINGPIN_HOME/tasks/t12-merged/critique"
"$KP_BIN/kingpin-done" t12-merged --force >/dev/null
[ ! -d "$KINGPIN_HOME/tasks/t12-merged" ] && [ -f "$KINGPIN_HOME/archive/t12-merged/task.env" ] && [ -f "$KINGPIN_HOME/archive/t12-merged/done_cleaned" ] && pass "kingpin-done moved the task dir into the archive" || fail "task dir not archived"

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
[ ! -d "$KINGPIN_HOME/tasks/t12-reuse" ] && [ -f "$KINGPIN_HOME/archive/t12-reuse/marker" ] && [ -f "$KINGPIN_HOME/archive/t12-reuse.2/done_cleaned" ] && pass "reused task id archived beside the earlier record" || fail "reused task id was not archived safely"

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
[ -d "$KINGPIN_HOME/archive/t19-merged" ] && [ ! -d "$KINGPIN_HOME/tasks/t19-merged" ] && pass "t19: done --force archived the task" || fail "t19: task not archived"
t19_ack_rc=0
t19_ack=$("$KP_BIN/kingpin" ack t19-merged 2>&1) || t19_ack_rc=$?
[ "$t19_ack_rc" -eq 0 ] && echo "$t19_ack" | grep -qi "archived" && pass "t19: ack on an archived task exits 0 with a note" || fail "t19: ack on an archived task (rc=$t19_ack_rc): $t19_ack"
t19_ack_rc=0
"$KP_BIN/kingpin" ack t19-no-such-task >/dev/null 2>&1 || t19_ack_rc=$?
[ "$t19_ack_rc" -eq 1 ] && pass "t19: ack on an unknown task still fails" || fail "t19: ack on an unknown task exited $t19_ack_rc"

tmux kill-window -t kingpin:t19-merged 2>/dev/null || true
rm -rf "$KINGPIN_HOME/archive/t19-"* "$KINGPIN_HOME/tasks/t19-"* "$T"/wt-t19-*
unset KINGPIN_LAVISH

kp_test_finish DONE
