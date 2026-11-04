#!/usr/bin/env bash
# Verification test for Kingpin: kingpin send and kingpin peek.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "send-peek"
kp_test_project

kp_test_stub_lavish

# Test 13: kingpin-send types text literally and submits it with a separate Enter
echo "=== Test 13: kingpin-send literal text ==="
t13_dir="$KINGPIN_HOME/tasks/t13-send"
mkdir -p "$t13_dir"
tmux new-window -d -t kingpin: -n t13-send cat
cat > "$t13_dir/task.env" << EOF
TASK_ID=t13-send
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t13-send
EOF

# Poll the pane (wrapped lines joined) until a line equal to $1 shows up
pane_has_line() {
  local want=$1
  for _ in $(seq 1 50); do
    tmux capture-pane -pJt kingpin:t13-send -S -200 2>/dev/null | grep -qxF -- "$want" && return 0
    sleep 0.1
  done
  return 1
}

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "Escape" >/dev/null
pane_has_line "Escape" && pass "kingpin-send delivers 'Escape' as text, not the key" || fail "Escape did not arrive as text"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "C-c" >/dev/null
pane_has_line "C-c" && pass "kingpin-send delivers 'C-c' as text, not Ctrl-C" || fail "C-c did not arrive as text"
tmux list-panes -t kingpin:t13-send >/dev/null 2>&1 && pass "cat pane survived 'C-c' text" || fail "pane died after C-c"

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "-n literal dash" >/dev/null
pane_has_line "-n literal dash" && pass "kingpin-send delivers text starting with a dash" || fail "dash-leading text did not arrive"

long_msg=$(printf '%04d' $(seq 1 500))
[ "${#long_msg}" -eq 2000 ] || fail "test message is ${#long_msg} chars, not 2000"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send "$long_msg" >/dev/null
pane_has_line "$long_msg" && pass "2,000-character message arrived intact" || fail "2,000-character message was truncated or altered"

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t13-send $'multi-a\nmulti-b' >/dev/null
if pane_has_line "multi-a" && pane_has_line "multi-b"; then pass "multi-line message: both lines reached the pane"; else fail "multi-line message lost a line"; fi

tmux kill-window -t kingpin:t13-send 2>/dev/null || true
rm -rf "$t13_dir"

# Test 20: kingpin peek prints the tail of a worker pane, read-only
echo "=== Test 20: kingpin peek ==="
t20_dir="$KINGPIN_HOME/tasks/t20-peek"
mkdir -p "$t20_dir"
# shellcheck disable=SC2016 # single quotes are intentional: $i expands in the inner bash -c
tmux new-window -d -t kingpin: -n t20-peek bash -c 'for i in $(seq 1 40); do echo "line-$i"; echo; done; echo "   "; exec cat'
t20_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="t20-peek"{print $1}')
[ -n "$t20_wid" ] || fail "t20: fake pane window was not created"
cat > "$t20_dir/task.env" << EOF
TASK_ID=t20-peek
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t20-peek
TMUX_WINDOW_ID=$t20_wid
EOF
t20_ready=0
for _ in $(seq 1 50); do
  if tmux capture-pane -pJt "$t20_wid" -S -200 2>/dev/null | grep -qx "line-40"; then t20_ready=1; break; fi
  sleep 0.1
done
[ "$t20_ready" -eq 1 ] || fail "t20: fake pane never showed line-40"

# default: last 20 non-empty lines
t20_out=$("$KP_BIN/kingpin" peek t20-peek)
[ "$(echo "$t20_out" | wc -l)" -eq 20 ] && [ "$(echo "$t20_out" | head -n 1)" = "line-21" ] && [ "$(echo "$t20_out" | tail -n 1)" = "line-40" ] && pass "t20: peek prints the last 20 lines by default" || fail "t20: default peek output wrong: $t20_out"
if echo "$t20_out" | grep -qv '[^[:space:]]'; then fail "t20: peek output has a blank line"; else pass "t20: peek output has no blank lines"; fi

# --lines N
t20_out=$("$KP_BIN/kingpin" peek t20-peek --lines 5)
[ "$(echo "$t20_out" | wc -l)" -eq 5 ] && [ "$(echo "$t20_out" | tail -n 1)" = "line-40" ] && pass "t20: --lines 5 prints 5 lines" || fail "t20: --lines 5 output wrong: $t20_out"
t20_out=$("$KP_BIN/kingpin" peek --lines=3 t20-peek)
[ "$(echo "$t20_out" | wc -l)" -eq 3 ] && pass "t20: --lines=3 prints 3 lines" || fail "t20: --lines=3 output wrong: $t20_out"
for bad in 0 abc -2; do
  t20_rc=0
  "$KP_BIN/kingpin" peek t20-peek --lines "$bad" >/dev/null 2>&1 || t20_rc=$?
  [ "$t20_rc" -eq 2 ] && pass "t20: --lines $bad is rejected" || fail "t20: --lines $bad exited $t20_rc"
done

# no keys sent, no state changed: only list-panes and capture-pane reach tmux
mkdir -p "$T/t20-shim"
cat > "$T/t20-shim/tmux" << EOF
#!/usr/bin/env bash
echo "\$1" >> "$T/t20-tmux.log"
exec "$T/bin/tmux" "\$@"
EOF
chmod +x "$T/t20-shim/tmux"
: > "$T/t20-tmux.log"
t20_sum() { (cd "$t20_dir" && find . -type f | sort | xargs sha256sum; find . | sort); }
t20_before=$(t20_sum)
t20_pane_before=$(tmux capture-pane -pJt "$t20_wid" -S -200)
PATH="$T/t20-shim:$PATH" "$KP_BIN/kingpin" peek t20-peek >/dev/null
t20_after=$(t20_sum)
t20_pane_after=$(tmux capture-pane -pJt "$t20_wid" -S -200)
if [ -s "$T/t20-tmux.log" ] && ! grep -qv -e '^list-panes$' -e '^capture-pane$' "$T/t20-tmux.log"; then pass "t20: peek only runs list-panes and capture-pane"; else fail "t20: peek ran other tmux commands: $(sort -u "$T/t20-tmux.log" | tr '\n' ' ')"; fi
[ "$t20_before" = "$t20_after" ] && pass "t20: peek leaves the task folder unchanged" || fail "t20: task folder changed"
[ "$t20_pane_before" = "$t20_pane_after" ] && pass "t20: peek leaves the pane unchanged" || fail "t20: pane changed"

# window renamed: the stale TMUX_TARGET name no longer exists, the window ID still does
tmux rename-window -t "$t20_wid" t20-renamed
t20_out=$("$KP_BIN/kingpin" peek t20-peek --lines 1 2>&1) && [ "$t20_out" = "line-40" ] && pass "t20: peek reaches the pane after a window rename" || fail "t20: peek after rename failed: $t20_out"

# legacy task.env without TMUX_WINDOW_ID falls back to TMUX_TARGET
tmux rename-window -t "$t20_wid" t20-peek
sed -i '/^TMUX_WINDOW_ID=/d' "$t20_dir/task.env"
t20_out=$("$KP_BIN/kingpin" peek t20-peek --lines 1 2>&1) && [ "$t20_out" = "line-40" ] && pass "t20: legacy task.env falls back to TMUX_TARGET" || fail "t20: legacy peek failed: $t20_out"

# unknown task and missing window
t20_rc=0
t20_err=$("$KP_BIN/kingpin" peek t20-no-such-task 2>&1 >/dev/null) || t20_rc=$?
[ "$t20_rc" -eq 1 ] && echo "$t20_err" | grep -q "not found" && pass "t20: unknown task exits 1 with a clear message" || fail "t20: unknown task rc=$t20_rc: $t20_err"
[ -z "$t20_wid" ] || tmux kill-window -t "$t20_wid" 2>/dev/null || true
t20_rc=0
t20_err=$("$KP_BIN/kingpin" peek t20-peek 2>&1 >/dev/null) || t20_rc=$?
[ "$t20_rc" -eq 1 ] && echo "$t20_err" | grep -q "not alive" && pass "t20: missing window exits 1 with a clear message" || fail "t20: missing window rc=$t20_rc: $t20_err"

rm -rf "$t20_dir" "$T/t20-shim" "$T/t20-tmux.log"

# Test 21: a stale window ID that now names another window is not followed (issue #149)
echo "=== Test 21: a stale window ID that names another window ==="
t21_other=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n t21-other bash -c 'echo other-window; exec cat')
tmux new-window -d -t kingpin: -n t21-mine bash -c 'echo mine-window; exec cat' >/dev/null
t21_dir="$KINGPIN_HOME/tasks/t21-moved"
mkdir -p "$t21_dir"
cat > "$t21_dir/task.env" << EOF
TASK_ID=t21-moved
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t21-mine
TMUX_WINDOW_ID=$t21_other
EOF
t21_ready=0
for _ in $(seq 1 50); do
  tmux capture-pane -pJt kingpin:t21-mine -S -50 2>/dev/null | grep -qx "mine-window" \
    && tmux capture-pane -pJt "$t21_other" -S -50 2>/dev/null | grep -qx "other-window" && { t21_ready=1; break; }
  sleep 0.1
done
[ "$t21_ready" -eq 1 ] || fail "t21: the fixture panes never drew"
t21_other_before=$(tmux capture-pane -pJt "$t21_other" -S -50)
t21_out=$("$KP_BIN/kingpin" peek t21-moved --lines 1 2>&1) && [ "$t21_out" = "mine-window" ] \
  && pass "t21: peek reaches the task's own window, not the stale id's" \
  || fail "t21: peek followed the stale id: $t21_out"
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin" send t21-moved "hello-mine" >/dev/null
for _ in $(seq 1 50); do
  tmux capture-pane -pJt kingpin:t21-mine -S -50 2>/dev/null | grep -qxF "hello-mine" && break
  sleep 0.1
done
t21_other_after=$(tmux capture-pane -pJt "$t21_other" -S -50)
[ "$t21_other_before" = "$t21_other_after" ] \
  && pass "t21: the window the stale id names was left untouched" \
  || fail "t21: the stale id's window received the text"

# The healthy path still runs only list-panes and capture-pane, on the same read-only contract.
mkdir -p "$T/t21-shim"
cat > "$T/t21-shim/tmux" << EOF
#!/usr/bin/env bash
echo "\$1" >> "$T/t21-tmux.log"
exec "$T/bin/tmux" "\$@"
EOF
chmod +x "$T/t21-shim/tmux"
: > "$T/t21-tmux.log"
PATH="$T/t21-shim:$PATH" "$KP_BIN/kingpin" peek t21-moved >/dev/null
if [ -s "$T/t21-tmux.log" ] && ! grep -qv -e '^list-panes$' -e '^capture-pane$' "$T/t21-tmux.log"; then
  pass "t21: peek still runs only list-panes and capture-pane"
else
  fail "t21: peek ran other tmux commands: $(sort -u "$T/t21-tmux.log" | tr '\n' ' ')"
fi
tmux kill-window -t "$t21_other" 2>/dev/null || true
tmux kill-window -t kingpin:t21-mine 2>/dev/null || true
rm -rf "$t21_dir" "$T/t21-shim" "$T/t21-tmux.log"

# Test 22: a recorded ID alive under another name, unclaimed by any task, still resolves
echo "=== Test 22: the ID fallback still reaches a hand-renamed window ==="
t22_wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n t22-renamed bash -c 'echo handnamed; exec cat')
t22_dir="$KINGPIN_HOME/tasks/t22-handnamed"
mkdir -p "$t22_dir"
cat > "$t22_dir/task.env" << EOF
TASK_ID=t22-handnamed
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_TARGET=kingpin:t22-handnamed
TMUX_WINDOW_ID=$t22_wid
EOF
for _ in $(seq 1 50); do
  tmux capture-pane -pJt "$t22_wid" -S -50 2>/dev/null | grep -qx "handnamed" && break
  sleep 0.1
done
t22_out=$("$KP_BIN/kingpin" peek t22-handnamed --lines 1 2>&1) && [ "$t22_out" = "handnamed" ] \
  && pass "t22: the recorded id still reaches a hand-renamed window" \
  || fail "t22: id fallback failed: $t22_out"
tmux kill-window -t "$t22_wid" 2>/dev/null || true
rm -rf "$t22_dir"

# ---------------------------------------------------------------------------

kp_test_finish SEND-PEEK
