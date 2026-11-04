#!/usr/bin/env bash
# Verification test for Kingpin: who owns the fleet's tmux server (issue #165).
#
# A tmux server that dies takes every worker window with it while the task records
# still name its socket. The suite covers the three readers that must say so
# (`kingpin list`, `kingpin wait`), the supervisor's restart-and-restore sweep, the
# spawn line that admits it started the server, and the rule that killing the fleet
# server never reaches the operator's default server. Every server here is a private
# one under the suite's own TMUX_TMPDIR: the operator's session `S1` is never touched.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "fleet-server"
kp_test_project

# The operator-server cases below start a private default server (`-L default`, inside
# the suite's own TMUX_TMPDIR). An early abort under `set -e` would otherwise leave it,
# and the fake harnesses on it, running after `kp_test_cleanup` removed the socket
# directory: nothing could reach them again. kp_test_cleanup only knows the fleet and
# TEST_SOCKET sockets, so this trap kills the private default server first.
kill_default_server() {
  "$REAL_TMUX" -L default kill-server 2>/dev/null || true
}
trap 'kill_default_server; kp_test_cleanup' EXIT

# A fake harness: it stays on stdin and reports nothing, so a restored window keeps
# the pane pid the record calls its harness. Node, not a shell, so a window that falls
# back to a recorded id does not read as a plain shell.
cat > "$T/fake-harness" << 'F'
#!/usr/bin/env node
const readline = require("readline");
readline.createInterface({ input: process.stdin }).on("line", () => {});
F
chmod +x "$T/fake-harness"
export KINGPIN_AGY=$T/fake-harness

env_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
window_exists() { # <socket> <session> <name>
  tmux -L "$1" list-windows -t "$2" -F '#{window_name}' 2>/dev/null | grep -qxF -- "$3"
}
server_pid() { # <socket> <session>
  tmux -L "$1" display-message -p -t "$2" '#{pid}' 2>/dev/null || true
}

# The one task the fleet cases share: a real spawn, so restore has a real lease and a
# real launch script to work with.
spawn_out=$("$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t-server --mode review)
echo "$spawn_out" | grep -q '^OK: spawned t-server ' \
  && pass "the fixture task spawned" || fail "the fixture task did not spawn: $spawn_out"
env_file="$KINGPIN_HOME/tasks/t-server/task.env"
grep -qx "TMUX_SOCKET=$KINGPIN_TMUX_SOCKET" "$env_file" \
  && pass "the fixture record names the fleet socket" || fail "the fixture record names another socket"
window_exists "$KINGPIN_TMUX_SOCKET" kingpin t-server \
  && pass "the fixture window is on the fleet server" || fail "the fixture window is missing"

# --- Test 1: `kingpin list` names the dead server and how to attach -----------------
echo "=== Test 1: list warns when a live record names a server that is gone ==="
tmux kill-server 2>/dev/null || true
sleep 0.2
list_out=$("$KP_BIN/kingpin" list 2>"$T/list.err" || true)
grep -q "the tmux server '$KINGPIN_TMUX_SOCKET' is not running" "$T/list.err" \
  && pass "list named the socket that is gone" || fail "list did not name the socket: $(cat "$T/list.err")"
grep -q "live tasks t-server" "$T/list.err" \
  && pass "list named the task whose window died with the server" || fail "list did not name the task: $(cat "$T/list.err")"
grep -q "tmux -L $KINGPIN_TMUX_SOCKET attach" "$T/list.err" \
  && pass "list said how to attach to that server" || fail "list gave no attach command: $(cat "$T/list.err")"
grep -q "kingpin restore" "$T/list.err" \
  && pass "list named the recovery command" || fail "list named no recovery: $(cat "$T/list.err")"
case "$list_out" in
  *DEAD*) pass "the dead row still reads DEAD" ;;
  *) fail "the dead row did not read DEAD: $list_out" ;;
esac
KINGPIN_SKIP_SOCKET_WARN=1 "$KP_BIN/kingpin" list 2>"$T/list-quiet.err" >/dev/null || true
[ -s "$T/list-quiet.err" ] \
  && fail "KINGPIN_SKIP_SOCKET_WARN=1 did not silence list: $(cat "$T/list-quiet.err")" \
  || pass "KINGPIN_SKIP_SOCKET_WARN=1 silences list"

# --- Test 2: `kingpin wait` names the same server -----------------------------------
echo "=== Test 2: wait warns when a live record names a server that is gone ==="
"$KP_BIN/kingpin-wait" --once >/dev/null 2>"$T/wait.err" || true
grep -q "the tmux server '$KINGPIN_TMUX_SOCKET' is not running" "$T/wait.err" \
  && pass "wait named the socket that is gone" || fail "wait did not name the socket: $(cat "$T/wait.err")"
KINGPIN_SKIP_SOCKET_WARN=1 "$KP_BIN/kingpin-wait" --once >/dev/null 2>"$T/wait-quiet.err" || true
[ -s "$T/wait-quiet.err" ] \
  && fail "KINGPIN_SKIP_SOCKET_WARN=1 did not silence wait: $(cat "$T/wait-quiet.err")" \
  || pass "KINGPIN_SKIP_SOCKET_WARN=1 silences wait"

# --- Test 3: the supervisor restarts the server and re-arms the window ---------------
echo "=== Test 3: watch restarts the fleet server and restores the window ==="
"$KP_BIN/kingpin-watch" --once >"$T/watch.out" 2>"$T/watch.err" || true
tmux has-session -t kingpin 2>/dev/null \
  && pass "watch started the fleet server again" || fail "the fleet server is still down"
window_exists "$KINGPIN_TMUX_SOCKET" kingpin t-server \
  && pass "watch restored the task's window by name" || fail "the task's window was not restored"
new_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="t-server"{print $1}')
[ -n "$new_wid" ] && grep -qx "TMUX_WINDOW_ID=$new_wid" "$env_file" \
  && pass "watch recorded the restored window id ($new_wid)" || fail "the restored window id was not recorded"
grep -q 'not running; restoring t-server' "$T/watch.out" \
  && pass "watch said which server it was bringing back" || fail "watch was silent: $(cat "$T/watch.out")"
[ -f "$KINGPIN_HOME/tasks/t-server/resume-prompt.txt" ] \
  && pass "the restored worker got a resume brief" || fail "no resume brief was written"
"$KP_BIN/kingpin" list >"$T/list-live.out" 2>&1 || true
case "$T/list-live.out" in
  *DEAD*) fail "list still reports a DEAD task after the restore: $(cat "$T/list-live.out")" ;;
  *) pass "no live row reads DEAD after the restore" ;;
esac

# --- Test 3b: the empty-fleet footer prints an attach command that works -------------
echo "=== Test 3b: the empty-fleet footer names a command that attaches ==="
# With no live task the footer names the socket a new spawn would use. On the operator's
# default server that must be a plain `tmux attach`: `tmux -L default attach -t kingpin`
# answers "can't find session: kingpin" on this fleet's own configuration (#165 review M1).
empty_home="$T/empty-home"
mkdir -p "$empty_home/tasks"
default_footer=$(KINGPIN_HOME="$empty_home" KINGPIN_TMUX_SOCKET=default "$KP_BIN/kingpin" list 2>/dev/null || true)
case "$default_footer" in
  *"Workers live on the tmux server 'default': tmux attach (kingpin peek <task-id> reads one pane)"*)
    pass "the empty fleet on the default socket gets a plain tmux attach" ;;
  *) fail "the empty-fleet footer on the default socket: $default_footer" ;;
esac
case "$default_footer" in
  *"attach -t kingpin"*) fail "the empty-fleet footer kept a hardcoded -t kingpin: $default_footer" ;;
  *) pass "the empty-fleet footer names no hardcoded session" ;;
esac
fleet_footer=$(KINGPIN_HOME="$empty_home" "$KP_BIN/kingpin" list 2>/dev/null || true)
case "$fleet_footer" in
  *"Workers live on the tmux server '$KINGPIN_TMUX_SOCKET': tmux -L $KINGPIN_TMUX_SOCKET attach (kingpin peek <task-id> reads one pane)"*)
    pass "the empty fleet on the fleet socket names its own attach command" ;;
  *) fail "the empty-fleet footer on the fleet socket: $fleet_footer" ;;
esac

# --- Test 3c: one dead server named two ways is one group of tasks -------------------
echo "=== Test 3c: no socket and TMUX_SOCKET=default are one server ==="
# A record written before the fleet moved to its own server names no socket, and one
# written after it names `default`: both mean the operator's default server. Its windows
# died with it, so both tasks belong to the one warning and the one restore (#165 M2).
mkdir -p "$KINGPIN_HOME/tasks/a-old" "$KINGPIN_HOME/tasks/z-new"
printf 'TASK_ID=a-old\nPROJECT=demo-auto\nHARNESS=agy\nMODE=review\nTMUX_TARGET=kingpin:a-old\n' \
  > "$KINGPIN_HOME/tasks/a-old/task.env"
printf 'TASK_ID=z-new\nPROJECT=demo-auto\nHARNESS=agy\nMODE=review\nTMUX_TARGET=kingpin:z-new\nTMUX_SOCKET=default\n' \
  > "$KINGPIN_HOME/tasks/z-new/task.env"
printf 'issue: #900\n' > "$KINGPIN_HOME/tasks/a-old/status"
printf 'issue: #901\n' > "$KINGPIN_HOME/tasks/z-new/status"
"$KP_BIN/kingpin" list >/dev/null 2>"$T/list-mixed.err" || true
grep -q "live tasks a-old, z-new name it" "$T/list-mixed.err" \
  && pass "list names both tasks on the one dead server" \
  || fail "list named one group only: $(cat "$T/list-mixed.err")"
"$KP_BIN/kingpin-wait" --once >/dev/null 2>"$T/wait-mixed.err" || true
grep -q "live tasks a-old, z-new name it" "$T/wait-mixed.err" \
  && pass "wait names both tasks on the one dead server" \
  || fail "wait named one group only: $(cat "$T/wait-mixed.err")"
"$KP_BIN/kingpin-watch" --once >"$T/watch-mixed.out" 2>&1 || true
grep -q "the tmux server 'default' is not running; restoring a-old z-new" "$T/watch-mixed.out" \
  && pass "watch hands both tasks on that server to restore" \
  || fail "watch restored one group only: $(cat "$T/watch-mixed.out")"
rm -rf "$KINGPIN_HOME/tasks/a-old" "$KINGPIN_HOME/tasks/z-new"
kill_default_server

# --- Test 4: killing the fleet server never touches the operator's default server ---
echo "=== Test 4: the operator's default server is untouched ==="
tmux -L default new-session -d -s S1 -n keep
default_pid=$(server_pid default S1)
tmux kill-server 2>/dev/null || true
sleep 0.2
"$KP_BIN/kingpin" list >/dev/null 2>&1 || true
"$KP_BIN/kingpin-watch" --once >/dev/null 2>&1 || true
[ "$(server_pid default S1)" = "$default_pid" ] \
  && pass "the operator's server is the same process it was" \
  || fail "the operator's server pid changed"
tmux -L default has-session -t S1 2>/dev/null \
  && pass "the operator's session S1 survived" || fail "the operator's session S1 is gone"
window_exists default S1 keep \
  && pass "the operator's window survived" || fail "the operator's window is gone"

# --- Test 5: a spawn that starts the server says so ---------------------------------
echo "=== Test 5: spawn admits it started the server ==="
tmux kill-server 2>/dev/null || true
sleep 0.2
fresh_out=$("$KP_BIN/kingpin" spawn demo-auto --issue 501 --id t-server-2 --mode review)
case "$fresh_out" in
  *"started the tmux server on socket '$KINGPIN_TMUX_SOCKET' (it was not running)"*)
    pass "a spawn on a dead server said it started one" ;;
  *) fail "the spawn hid that it started the server: $fresh_out" ;;
esac
live_out=$("$KP_BIN/kingpin" spawn demo-auto --issue 502 --id t-server-3 --mode review)
case "$live_out" in
  *"started the tmux server"*) fail "a spawn on a live server claimed to start it: $live_out" ;;
  *) pass "a spawn on a live server says nothing about starting it" ;;
esac

# --- Test 6: a fleet on the operator's default server is supervised the same way ----
echo "=== Test 6: the default-socket fleet is named and brought back ==="
default_out=$(KINGPIN_TMUX_SOCKET=default KINGPIN_TMUX_SESSION=S1 \
  "$KP_BIN/kingpin" spawn demo-auto --issue 503 --id t-default --mode review)
case "$default_out" in
  "OK: spawned t-default "*) pass "the default-socket task spawned" ;;
  *) fail "the default-socket task did not spawn: $default_out" ;;
esac
grep -qx "TMUX_SOCKET=default" "$KINGPIN_HOME/tasks/t-default/task.env" \
  && pass "the default-socket task records its socket" || fail "the default-socket task recorded another socket"
window_exists default S1 t-default \
  && pass "its window is on the default server" || fail "its window is not on the default server"
tmux -L default kill-server 2>/dev/null || true
sleep 0.2
"$KP_BIN/kingpin" list >/dev/null 2>"$T/list-default.err" || true
grep -q "the tmux server 'default' is not running" "$T/list-default.err" \
  && pass "list named the operator's default server" || fail "list did not name the default server: $(cat "$T/list-default.err")"
grep -q "tmux attach" "$T/list-default.err" \
  && pass "list gave the plain attach command for the default server" || fail "no plain attach command: $(cat "$T/list-default.err")"
"$KP_BIN/kingpin-watch" --once >/dev/null 2>"$T/watch-default.err" || true
tmux -L default has-session -t S1 2>/dev/null \
  && pass "watch brought the default server back" || fail "the default server is still down"
window_exists default S1 t-default \
  && pass "watch restored the default-socket task's window" || fail "the default-socket window was not restored"

tmux -L default kill-server 2>/dev/null || true
kp_test_finish FLEET-SERVER
