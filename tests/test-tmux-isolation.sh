#!/usr/bin/env bash
# Workers live on the fleet's own tmux server (issue #142): an operator session
# kill, or a `tmux kill-server` on the operator's server, must not reach a worker,
# and every fleet command must still find its window afterwards.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "tmux-isolation"
kp_test_project

# shellcheck source=../lib/tmux.sh
. "$KP_ROOT/lib/tmux.sh"

OPS_SOCKET="$TEST_SOCKET-ops"

# Test 1: no command runs tmux behind the fleet's back
# ---------------------------------------------------------------------------
# A resolver that runs raw tmux reads the default server, where no worker lives.
# The suites cannot catch that by observation, because a bare tmux call in a suite
# lands on the fleet socket; this static check covers it instead.
#
# The pattern matches `tmux` in command position, whatever comes after it: the
# start of a line, the start of a `$(...)`, or right after `;`, `&&`, `||`, `|`
# or `!`. That catches `tmux -L <sock> ...`, `tmux -S <path> ...` and every
# subcommand, not a fixed list of them. A string or a comment that merely
# contains the word is not a call and does not match; a whole-line comment is
# filtered out as well. The directories are absolute, so the check cannot pass
# from another working directory with an empty result.
echo "--- Test 1: every tmux call goes through kp_tmux ---"
raw=$(grep -rnE '(^|[;&|!]|\$\()[[:space:]]*tmux([[:space:]]|$)' \
  "$KP_ROOT/bin" "$KP_ROOT/lib" \
  | grep -v "^$KP_ROOT/lib/tmux.sh:" \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -z "$raw" ]; then
  pass "t1: no command calls tmux outside lib/tmux.sh"
else
  fail "t1: these call tmux without kp_tmux (they would read the default server): $raw"
fi

# Test 1b: no command checks a session by a bare name (issues #149, #181)
# ---------------------------------------------------------------------------
# `has-session -t name` accepts a unique prefix, so a server holding only
# `kingpin-workers` answers for `kingpin` and the caller creates nothing. The one
# exact check is kp_tmux_has_session; the one deliberate prefix resolver is
# kp_tmux_resolve_session, and both live in lib/tmux.sh. The scan is written so a
# raw call anywhere in bin/ or lib/ fails it, and a fixture proves it cannot pass
# vacuously.
echo "--- Test 1b: every session check goes through kp_tmux_has_session ---"
has_session_scan() {
  local root=${1:?} dir dirs=()
  for dir in "$root/bin" "$root/lib"; do
    [ -d "$dir" ] && dirs+=("$dir")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  grep -rnF 'has-session' "${dirs[@]}" 2>/dev/null \
    | grep -vF -- "$root/lib/tmux.sh:" \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true
}
raw_sessions=$(has_session_scan "$KP_ROOT")
if [ -z "$raw_sessions" ]; then
  pass "t1b: no command calls has-session outside lib/tmux.sh (use kp_tmux_has_session)"
else
  fail "t1b: these check a session without kp_tmux_has_session (a prefix answers for another session): $raw_sessions"
fi
mkdir -p "$T/fixture/bin"
# shellcheck disable=SC2016 # the fixture writes a literal tmux call, not a shell expansion
printf '%s\n' 'kp_tmux "$sock" has-session -t x' > "$T/fixture/bin/raw"
fixture_hit=$(has_session_scan "$T/fixture")
if [ -n "$fixture_hit" ]; then
  pass "t1b: the check catches a raw has-session"
else
  fail "t1b: the check missed a raw has-session"
fi

# Test 1c: the helper matches a session exactly, on a prefix-only server
# ---------------------------------------------------------------------------
# The fleet server this suite uses already holds `kingpin`, so the case the issue
# names is measured on a second private server holding only `kingpin-workers`.
echo "--- Test 1c: a session is matched exactly ---"
pfx_socket="$TEST_SOCKET-prefix"
tmux -L "$pfx_socket" new-session -d -s kingpin-workers -n home
kp_tmux_has_session "$pfx_socket" kingpin && fail "t1c: a prefix-only server answered for kingpin" || pass "t1c: a prefix-only server does not answer for kingpin"
kp_tmux_has_session "$pfx_socket" kingpin-workers && pass "t1c: the exact session matches" || fail "t1c: the exact session did not match"
kp_tmux_has_session "$pfx_socket" kingpin-worker && fail "t1c: a shorter prefix matched" || pass "t1c: a shorter prefix matches nothing"
kp_tmux_has_session "$pfx_socket" '' && fail "t1c: an empty name matched" || pass "t1c: an empty name matches nothing"
kp_tmux_ensure_session "$pfx_socket" kingpin
kp_tmux_has_session "$pfx_socket" kingpin && pass "t1c: ensure created the exact session" || fail "t1c: ensure did not create the exact session"
tmux -L "$pfx_socket" kill-server 2>/dev/null || true

# Test 2: a spawn from inside the operator's tmux session lands on the fleet server
# ---------------------------------------------------------------------------
echo "--- Test 2: spawn from inside the operator's session ---"
tmux -L "$OPS_SOCKET" new-session -d -s opswin -n home
ops_sid=$(tmux -L "$OPS_SOCKET" display-message -p -t opswin '#{session_id}' | tr -d '$')
ops_path=$(tmux -L "$OPS_SOCKET" display-message -p '#{socket_path}')
export KINGPIN_AGY=$T/fake-worker

spawn_out=$(TMUX="$ops_path,$$,$ops_sid" "$KP_BIN/kingpin" spawn demo-auto --issue 300 --id t100-fleet --mode review)
env_file=$KINGPIN_HOME/tasks/t100-fleet/task.env
grep -qx "TMUX_SOCKET=$KINGPIN_TMUX_SOCKET" "$env_file" && pass "t2: the record names the fleet socket" || fail "t2: TMUX_SOCKET not recorded: $(grep TMUX_SOCKET "$env_file" || true)"
grep -qx "TMUX_TARGET=kingpin:t100-fleet" "$env_file" && pass "t2: the target is the kingpin session" || fail "t2: wrong TMUX_TARGET"
echo "$spawn_out" | grep -q "tmux -L $KINGPIN_TMUX_SOCKET kingpin:t100-fleet" && pass "t2: spawn names the fleet server" || fail "t2: spawn output: $spawn_out"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "t100-fleet" && pass "t2: the window is on the fleet server" || fail "t2: window missing on the fleet server"
! tmux -L "$OPS_SOCKET" list-windows -t opswin -F '#{window_name}' 2>/dev/null | grep -qx "t100-fleet" && pass "t2: the window is not in the operator's session" || fail "t2: the window landed in the operator's session"
t100_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="t100-fleet"{print $1}')

# Test 3: killing the operator's session, then its server, leaves the worker alone
# ---------------------------------------------------------------------------
echo "--- Test 3: the operator's server dies, the worker does not ---"
tmux -L "$OPS_SOCKET" kill-session -t opswin 2>/dev/null || true
! tmux -L "$OPS_SOCKET" has-session -t opswin 2>/dev/null && pass "t3: the operator's session is gone" || fail "t3: the operator's session survived"
tmux -L "$OPS_SOCKET" kill-server 2>/dev/null || true
kp_holds_for 0.3 tmux list-panes -t "$t100_wid" && pass "t3: the worker window survived the operator's kill-server" || fail "t3: the worker window is gone"

t100_peek=$("$KP_BIN/kingpin" peek t100-fleet --lines 5 2>&1) && pass "t3: kingpin peek reads the surviving pane" || fail "t3: peek failed: $t100_peek"
# shellcheck disable=SC2016 # the pane's shell expands the task dir at run time
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin" send t100-fleet 'printf "%s\n" "ready: branch=t100 review=APPROVE report=none" >> "$KINGPIN_TASK_DIR/status"' >/dev/null \
  && pass "t3: kingpin send reaches the surviving pane" || fail "t3: send failed"
t100_status=0
for _ in $(seq 1 40); do
  grep -qx "ready: branch=t100 review=APPROVE report=none" "$KINGPIN_HOME/tasks/t100-fleet/status" 2>/dev/null && { t100_status=1; break; }
  sleep 0.1
done
[ "$t100_status" = 1 ] && pass "t3: the status protocol still works after the kill" || fail "t3: no status line after the send"
wait_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$wait_out" | grep -q "^t100-fleet " && pass "t3: kingpin wait reports the surviving worker" || fail "t3: wait output: $wait_out"

# Test 4: kingpin list names the server and session
# ---------------------------------------------------------------------------
echo "--- Test 4: kingpin list names where a worker lives ---"
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "tmux -L $KINGPIN_TMUX_SOCKET kingpin" && pass "t4: the row names the socket and session" || fail "t4: no socket/session line: $list_out"
echo "$list_out" | grep -q "Workers live on the tmux server '$KINGPIN_TMUX_SOCKET'" && pass "t4: the footer names the fleet server" || fail "t4: no footer line"

# Test 5: kingpin done closes a window on the fleet server
# ---------------------------------------------------------------------------
echo "--- Test 5: kingpin done closes the fleet window ---"
"$KP_BIN/kingpin" "done" t100-fleet --force >/dev/null 2>&1 || true
! tmux list-panes -t "$t100_wid" >/dev/null 2>&1 && pass "t5: kingpin done closed the fleet window" || fail "t5: the window is still open"

# Test 6: nothing ever reached the default server
# ---------------------------------------------------------------------------
echo "--- Test 6: the default server stayed untouched ---"
! tmux -L default list-sessions >/dev/null 2>&1 && pass "t6: no tmux server on the default socket" || fail "t6: something started a default tmux server"

# Test 7: a record written before the split resolves on the default server
# ---------------------------------------------------------------------------
# The empty-socket branch of kp_tmux must name the default server explicitly
# (issue #142 review, M1): a bare `tmux` follows $TMUX, so a peek run from a
# fleet pane reads the fleet server, where an old record's window is not. The
# window here is created with an explicit `-L default`, and TMUX points at a
# second server, so only an explicit `-L default` finds it.
echo "--- Test 7: an old record resolves on the default server ---"
tmux -L default new-session -d -s kingpin -n oldwin
old_dir=$KINGPIN_HOME/tasks/t101-old
mkdir -p "$old_dir"
cat > "$old_dir/task.env" <<'EOF_ENV'
TASK_ID=t101-old
PROJECT=demo-auto
HARNESS=agy
MODE=review
TMUX_TARGET=kingpin:oldwin
EOF_ENV
: > "$old_dir/status"

tmux -L "$OPS_SOCKET" new-session -d -s opswin -n home
ops_path=$(tmux -L "$OPS_SOCKET" display-message -p '#{socket_path}')
ops_sid=$(tmux -L "$OPS_SOCKET" display-message -p -t opswin '#{session_id}' | tr -d '$')
# The pane is a shell on the default server, so the marker it prints is what a
# peek of the old record must find.
old_marker="old-record-pane-$$"
if TMUX="$ops_path,$$,$ops_sid" "$KP_BIN/kingpin" send t101-old "printf '%s\n' '$old_marker'" >/dev/null 2>&1; then
  pass "t7: send reaches the old record's window on the default server"
else
  fail "t7: send could not reach the old record's window"
fi
old_peek=""
for _ in $(seq 1 40); do
  old_peek=$(TMUX="$ops_path,$$,$ops_sid" "$KP_BIN/kingpin" peek t101-old --lines 20 2>&1 || true)
  case "$old_peek" in *"$old_marker"*) break ;; esac
  sleep 0.1
done
case "$old_peek" in
  *"$old_marker"*) pass "t7: peek reads the old record's window on the default server" ;;
  *) fail "t7: peek did not reach the default server window: $old_peek" ;;
esac
rm -rf "$old_dir"

tmux -L "$OPS_SOCKET" kill-server 2>/dev/null || true
tmux -L default kill-server 2>/dev/null || true
kp_test_finish TMUX-ISOLATION
