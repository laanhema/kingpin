#!/usr/bin/env bash
# Verification test for Kingpin: kingpin lock: lifecycle, collisions, stale locks, recorded harness, parallel acquire race, atomic publish, release ownership.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "lock"
kp_test_project

# Test 7: kingpin lock lifecycle
echo "=== Test 7: kingpin lock lifecycle ==="
lock_status_init=$("$KP_BIN/kingpin" lock status)
[ "$lock_status_init" = "lock: free" ] && pass "initial lock status free" || fail "initial lock status not free: $lock_status_init"

# Start long-lived background process holding the lock
(
  "$KP_BIN/kingpin" lock acquire >/dev/null
  sleep 30
) &
holder_pid=$!

# Wait briefly for lock acquisition
for _ in 1 2 3 4 5; do
  [ -f "$KINGPIN_HOME/orchestrator.lock" ] && break
  sleep 0.1
done

lock_status_held=$("$KP_BIN/kingpin" lock status)
echo "$lock_status_held" | grep -q "lock: held by pid $holder_pid" && pass "lock reported held by parent pid" || fail "lock not held by parent: $lock_status_held"

# Collision rejection: second acquire from different process must exit 1 and name holder
acquire_rc=0
acquire_err=$( ("$KP_BIN/kingpin" lock acquire) 2>&1 ) || acquire_rc=$?
[ "$acquire_rc" -ne 0 ] && echo "$acquire_err" | grep -q "another live kingpin orchestrator session holds the lock (pid $holder_pid)" && pass "second acquire rejected with holder pid" || fail "second acquire did not reject: $acquire_err"

# Collision rejection: check from different process must exit 1 and name holder
check_rc=0
check_err=$( ("$KP_BIN/kingpin" lock check) 2>&1 ) || check_rc=$?
[ "$check_rc" -ne 0 ] && echo "$check_err" | grep -q "another live kingpin orchestrator session holds the lock (pid $holder_pid)" && pass "check rejected with holder pid" || fail "check did not reject: $check_err"

# Kill holder process and verify auto-freeing
kill -9 "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

lock_status_stale=$("$KP_BIN/kingpin" lock status)
[ "$lock_status_stale" = "lock: stale" ] && pass "lock reports stale after holder dies" || fail "lock not stale after holder dies: $lock_status_stale"

# Re-acquire lock over stale lock
reacquire_out=$("$KP_BIN/kingpin" lock acquire)
echo "$reacquire_out" | grep -q "lock: acquired" && pass "re-acquire over stale lock succeeded" || fail "re-acquire failed: $reacquire_out"

# Release lock
"$KP_BIN/kingpin" lock release >/dev/null
lock_status_released=$("$KP_BIN/kingpin" lock status)
[ "$lock_status_released" = "lock: free" ] && pass "lock release returned state to free" || fail "lock not free after release: $lock_status_released"

# Test 7b: lock records the harness of the session that holds it
echo "=== Test 7b: kingpin lock harness ==="
lock_file=$KINGPIN_HOME/orchestrator.lock

# Start a long-lived holder that runs `kingpin lock acquire <args>` under the env given in $1.
start_holder() {
  local envs=$1; shift
  (
    # shellcheck disable=SC2086 # $envs is a list of VAR=value words and must word-split
    env $envs "$KP_BIN/kingpin" lock acquire "$@" >/dev/null 2>&1
    sleep 30
  ) &
  holder_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(head -n 1 "$lock_file" 2>/dev/null)" = "$holder_pid" ] && break
    sleep 0.1
  done
}
stop_holder() {
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}

# A holder with no recognisable agent records no harness
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "A=1"
[ "$("$KP_BIN/kingpin" lock status)" = "lock: held by pid $holder_pid" ] && pass "unrecognised holder shows no harness in status" || fail "status: $("$KP_BIN/kingpin" lock status)"
[ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "lock harness is empty without a recorded harness" || fail "unexpected harness"
stop_holder

# --harness flag
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "A=1" --harness agy
[ "$("$KP_BIN/kingpin" lock status)" = "lock: held by pid $holder_pid (agy)" ] && pass "--harness agy recorded and shown in status" || fail "status: $("$KP_BIN/kingpin" lock status)"
[ "$("$KP_BIN/kingpin" lock harness)" = "agy" ] && pass "lock harness prints agy for a live holder" || fail "harness: $("$KP_BIN/kingpin" lock harness)"
[ "$(head -n 1 "$lock_file")" = "$holder_pid" ] && pass "pid stays on line 1 of the lock file" || fail "lock line 1: $(head -n 1 "$lock_file")"
stop_holder

# Stale lock: recorded harness is ignored
[ "$("$KP_BIN/kingpin" lock status)" = "lock: stale" ] && pass "status stale after the harness holder dies" || fail "status: $("$KP_BIN/kingpin" lock status)"
[ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "stale lock reports no harness" || fail "stale lock still reports a harness"

# Re-acquire over the stale lock without a harness drops the old record
start_holder "A=1"
[ -z "$("$KP_BIN/kingpin" lock harness)" ] && [ "$(wc -l < "$lock_file")" -eq 1 ] && pass "re-acquire over a stale lock rewrites the whole file" || fail "old harness survived re-acquire"
stop_holder

# KINGPIN_HARNESS env, and the flag beating the env
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "KINGPIN_HARNESS=opencode"
[ "$("$KP_BIN/kingpin" lock harness)" = "opencode" ] && pass "KINGPIN_HARNESS=opencode recorded" || fail "env override: $("$KP_BIN/kingpin" lock harness)"
stop_holder
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "KINGPIN_HARNESS=opencode" --harness agy
[ "$("$KP_BIN/kingpin" lock harness)" = "agy" ] && pass "--harness beats KINGPIN_HARNESS" || fail "flag vs env: $("$KP_BIN/kingpin" lock harness)"
stop_holder

# Environment marker of the calling agent
"$KP_BIN/kingpin" lock release >/dev/null
start_holder "CLAUDECODE=1"
[ "$("$KP_BIN/kingpin" lock harness)" = "claude" ] && pass "CLAUDECODE=1 detected as claude" || fail "CLAUDECODE: $("$KP_BIN/kingpin" lock harness)"
stop_holder

# Invalid override is rejected and leaves the lock alone
"$KP_BIN/kingpin" lock release >/dev/null
bad_rc=0
bad_err=$(KINGPIN_HARNESS=bogus "$KP_BIN/kingpin" lock acquire 2>&1) || bad_rc=$?
[ "$bad_rc" -ne 0 ] && echo "$bad_err" | grep -q "unsupported harness: bogus" && [ ! -f "$lock_file" ] && pass "invalid KINGPIN_HARNESS rejected, no lock written" || fail "invalid override: rc=$bad_rc $bad_err"

# Process detection: the session process is named like the agent
mkdir -p "$T/agy-holder"
cat > "$T/agy-holder/agy" << F
#!/usr/bin/env bash
"$KP_BIN/kingpin" lock acquire >/dev/null 2>&1
sleep 30
F
chmod +x "$T/agy-holder/agy"
"$T/agy-holder/agy" &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(head -n 1 "$lock_file" 2>/dev/null)" = "$holder_pid" ] && break
  sleep 0.1
done
[ "$("$KP_BIN/kingpin" lock harness)" = "agy" ] && pass "session process named agy detected as agy" || fail "process detection: $("$KP_BIN/kingpin" lock harness)"

# release clears the record (release now has to run as the live holder)
KINGPIN_LOCK_PID=$holder_pid "$KP_BIN/kingpin" lock release >/dev/null
[ ! -f "$lock_file" ] && [ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "release clears the recorded harness" || fail "harness survived release"
stop_holder

# Test 7c: parallel acquire attempts race for the lock; exactly one wins
echo "=== Test 7c: parallel acquire race ==="
"$KP_BIN/kingpin" lock release >/dev/null
rm -rf "$T/race"
mkdir -p "$T/race"
race_n=20
race_sessions=()
race_jobs=()
for ((i = 1; i <= race_n; i++)); do
  sleep 30 &
  race_sessions+=("$!")
done
for ((i = 1; i <= race_n; i++)); do
  (
    while [ ! -f "$T/race/go" ]; do :; done
    race_code=0
    KINGPIN_LOCK_PID=${race_sessions[$((i - 1))]} "$KP_BIN/kingpin" lock acquire \
      >"$T/race/$i.out" 2>"$T/race/$i.err" || race_code=$?
    echo "$race_code" >"$T/race/$i.rc"
  ) &
  race_jobs+=("$!")
done
touch "$T/race/go"
for _ in $(seq 1 200); do
  [ "$(find "$T/race" -maxdepth 1 -name '*.rc' | wc -l)" -ge "$race_n" ] && break
  sleep 0.05
done
for race_job in "${race_jobs[@]}"; do
  wait "$race_job" 2>/dev/null || true
done

race_ok=0
race_refused=0
for ((i = 1; i <= race_n; i++)); do
  race_rc=$(cat "$T/race/$i.rc" 2>/dev/null || echo missing)
  if [ "$race_rc" = 0 ]; then
    race_ok=$((race_ok + 1))
    grep -q "lock: acquired" "$T/race/$i.out" || fail "winner printed no acquired line: $(cat "$T/race/$i.out")"
  else
    race_refused=$((race_refused + 1))
  fi
done
[ "$race_ok" -eq 1 ] && pass "exactly one parallel acquire won (of $race_n)" || fail "parallel acquire winners: $race_ok (of $race_n)"
[ "$race_refused" -eq $((race_n - 1)) ] && pass "every other parallel acquire refused" || fail "parallel acquire refusals: $race_refused (of $((race_n - 1)))"

race_winner=$(head -n 1 "$lock_file" 2>/dev/null || true)
race_winner_known=0
for race_pid in "${race_sessions[@]}"; do
  [ "$race_pid" = "$race_winner" ] && race_winner_known=1
done
[ "$race_winner_known" = 1 ] && pass "the lock names the winning session pid $race_winner" || fail "lock line 1 is not a racing pid: $race_winner"

race_unnamed=0
for ((i = 1; i <= race_n; i++)); do
  race_rc=$(cat "$T/race/$i.rc" 2>/dev/null || echo missing)
  if [ "$race_rc" != 0 ]; then
    { [ "$race_rc" = 1 ] && grep -q "another live kingpin orchestrator session holds the lock (pid $race_winner)" "$T/race/$i.err"; } \
      || race_unnamed=$((race_unnamed + 1))
  fi
done
[ "$race_unnamed" -eq 0 ] && pass "every refusal exits 1 and names the winner pid" || fail "$race_unnamed refusals did not name the winner"

for race_pid in "${race_sessions[@]}"; do
  kill "$race_pid" 2>/dev/null || true
  wait "$race_pid" 2>/dev/null || true
done

# Test 7d: release refuses to free a lock held by another live pid
echo "=== Test 7d: foreign release is refused ==="
"$KP_BIN/kingpin" lock release >/dev/null
sleep 30 &
owner_pid=$!
sleep 30 &
foreign_pid=$!
KINGPIN_LOCK_PID=$owner_pid "$KP_BIN/kingpin" lock acquire --harness agy >/dev/null
[ "$(head -n 1 "$lock_file" 2>/dev/null)" = "$owner_pid" ] && pass "the live owner pid is on line 1" || fail "lock line 1: $(head -n 1 "$lock_file" 2>/dev/null)"

foreign_rc=0
foreign_err=$(KINGPIN_LOCK_PID=$foreign_pid "$KP_BIN/kingpin" lock release 2>&1 >/dev/null) || foreign_rc=$?
[ "$foreign_rc" -ne 0 ] && echo "$foreign_err" | grep -q "another live kingpin orchestrator session holds the lock (pid $owner_pid)" \
  && pass "foreign release refused with the holder pid" || fail "foreign release: rc=$foreign_rc $foreign_err"
[ "$(head -n 1 "$lock_file" 2>/dev/null)" = "$owner_pid" ] && pass "the refused release left the lock with its owner" || fail "foreign release removed or rewrote the lock"

owner_rc=0
owner_out=$(KINGPIN_LOCK_PID=$owner_pid "$KP_BIN/kingpin" lock release 2>&1) || owner_rc=$?
[ "$owner_rc" -eq 0 ] && [ "$owner_out" = "lock: released" ] && [ ! -f "$lock_file" ] \
  && pass "the owner releases its own lock" || fail "owner release: rc=$owner_rc $owner_out"
kill "$owner_pid" "$foreign_pid" 2>/dev/null || true
wait "$owner_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true

# Test 7e: a reader never sees a half-written lock during re-acquire
echo "=== Test 7e: concurrent reader sees whole lock files ==="
sleep 30 &
reader_owner=$!
KINGPIN_LOCK_PID=$reader_owner "$KP_BIN/kingpin" lock acquire --harness agy >/dev/null
touch "$T/reader.go"
(
  reads=0
  empty_pid=0
  bad_harness=0
  while [ -f "$T/reader.go" ]; do
    [ -f "$lock_file" ] || continue
    line1=''
    line2=''
    { IFS= read -r line1 || true; IFS= read -r line2 || true; } < "$lock_file" 2>/dev/null || true
    reads=$((reads + 1))
    case "$line1" in ''|*[!0-9]*) empty_pid=$((empty_pid + 1)) ;; esac
    [ "$line2" = agy ] || bad_harness=$((bad_harness + 1))
  done
  printf '%s %s %s\n' "$reads" "$empty_pid" "$bad_harness" > "$T/reader.result"
) &
reader_pid=$!
for _ in $(seq 1 200); do
  KINGPIN_LOCK_PID=$reader_owner "$KP_BIN/kingpin" lock acquire --harness agy >/dev/null 2>&1
done
rm -f "$T/reader.go"
wait "$reader_pid"
read -r reader_reads reader_empty reader_bad < "$T/reader.result"
[ "$reader_reads" -gt 0 ] && pass "the reader sampled the lock $reader_reads times" || fail "the reader never saw the lock"
[ "$reader_empty" -eq 0 ] && pass "the reader never saw an empty or non-numeric pid" || fail "the reader saw $reader_empty empty pids"
[ "$reader_bad" -eq 0 ] && pass "the reader never saw an empty or invalid harness line" || fail "the reader saw $reader_bad bad harness lines"
KINGPIN_LOCK_PID=$reader_owner "$KP_BIN/kingpin" lock release >/dev/null
kill "$reader_owner" 2>/dev/null || true
wait "$reader_owner" 2>/dev/null || true

# Test 7f: normal runs leave no mutex, temp or stale files behind
echo "=== Test 7f: no lock siblings are left behind ==="
lock_leftovers=$(find "$KINGPIN_HOME" -maxdepth 1 \( -name 'orchestrator.lock.mutex*' -o -name 'orchestrator.lock.tmp.*' -o -name 'orchestrator.lock.stale.*' \) 2>/dev/null || true)
[ -z "$lock_leftovers" ] && pass "no mutex, temp or stale lock files remain" || fail "leftover lock files: $lock_leftovers"

# Test 7g: a live foreign mutex refuses acquire, names its owner, writes nothing.
# The helper waits its full budget (~9 s) before giving up, so this test is slow
# by design: the budget is what keeps a brief mutex section from refusing a real
# session, and shortening it to speed this test would undo that.
echo "=== Test 7g: a live foreign mutex blocks acquire ==="
rm -f "$lock_file" "$lock_file.mutex"
sleep 30 &
mutex_owner=$!
printf '%s\n' "$mutex_owner" > "$lock_file.mutex"
mutex_rc=0
mutex_err=$(KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire 2>&1 >/dev/null) || mutex_rc=$?
[ "$mutex_rc" -eq 1 ] && pass "acquire exits 1 while a live mutex is held" || fail "acquire rc with a live mutex: $mutex_rc"
echo "$mutex_err" | grep -q "could not take the orchestrator lock mutex (held by pid $mutex_owner for more than 8 s)" \
  && pass "the mutex refusal names the blocking pid" || fail "mutex refusal: $mutex_err"
[ ! -f "$lock_file" ] && pass "the blocked acquire wrote no lock file" || fail "the blocked acquire wrote $(head -n 1 "$lock_file" 2>/dev/null)"
[ "$(head -n 1 "$lock_file.mutex" 2>/dev/null)" = "$mutex_owner" ] && pass "the blocked acquire left the mutex with its owner" || fail "the blocked acquire rewrote the mutex"
mutex_leftovers=$(find "$KINGPIN_HOME" -maxdepth 1 \( -name 'orchestrator.lock.mutex.tmp.*' -o -name 'orchestrator.lock.mutex.stale.*' \) 2>/dev/null || true)
[ -z "$mutex_leftovers" ] && pass "the blocked acquire left no mutex temp or stale file" || fail "leftover mutex files: $mutex_leftovers"
rm -f "$lock_file.mutex"
kill "$mutex_owner" 2>/dev/null || true
wait "$mutex_owner" 2>/dev/null || true

# Test 7h: release frees a lock whose recorded holder is dead, from any session
echo "=== Test 7h: release clears a lock whose holder is dead ==="
sleep 0.01 &
dead_holder=$!
wait "$dead_holder" 2>/dev/null || true
printf '%s\n%s\n' "$dead_holder" agy > "$lock_file"
[ "$("$KP_BIN/kingpin" lock status)" = "lock: stale" ] && pass "a dead-pid lock reads as stale" || fail "dead-pid status: $("$KP_BIN/kingpin" lock status)"
stale_rc=0
stale_out=$(KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock release 2>&1) || stale_rc=$?
[ "$stale_rc" -eq 0 ] && [ "$stale_out" = "lock: released" ] && pass "a non-owner releases a dead-pid lock" || fail "dead-pid release: rc=$stale_rc $stale_out"
[ ! -f "$lock_file" ] && pass "the dead-pid lock, harness line and all, is gone after release" || fail "the dead-pid lock survived release"

# init without --harness leaves HARNESS unset so the lock holder's harness can apply
"$KP_BIN/kingpin" init demo-noharness "$T/proj" >/dev/null
! grep -q "^HARNESS=" "$KINGPIN_HOME/projects/demo-noharness.env" && pass "init without --harness writes no HARNESS line" || fail "init wrote HARNESS without --harness"

kp_test_finish LOCK
