#!/usr/bin/env bash
# Verification test for Kingpin: kingpin lock: lifecycle, collisions, stale locks, recorded harness.
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

# release clears the record
"$KP_BIN/kingpin" lock release >/dev/null
[ ! -f "$lock_file" ] && [ -z "$("$KP_BIN/kingpin" lock harness)" ] && pass "release clears the recorded harness" || fail "harness survived release"
stop_holder

# init without --harness leaves HARNESS unset so the lock holder's harness can apply
"$KP_BIN/kingpin" init demo-noharness "$T/proj" >/dev/null
! grep -q "^HARNESS=" "$KINGPIN_HOME/projects/demo-noharness.env" && pass "init without --harness writes no HARNESS line" || fail "init wrote HARNESS without --harness"

kp_test_finish LOCK
