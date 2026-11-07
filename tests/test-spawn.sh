#!/usr/bin/env bash
# Verification test for Kingpin: kingpin spawn: window ID tracking, descriptive slugs, pinned window names.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "spawn"
kp_test_bsd_shims
kp_test_project

kp_test_stub_lavish

# window_name_is <window-id> <name>: the window still carries the name Kingpin gave it.
window_name_is() {
  [ "$(tmux display-message -p -t "$1" '#{window_name}')" = "$2" ]
}

# Test 15: workers are tracked by tmux window ID, so renames and moves keep working
echo "=== Test 15: window ID tracking (rename, move, gone, legacy) ==="
mk_t15() {
  local name=$1 cmd=${2:-cat} d wid
  d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "$name" "$cmd")
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t15
HARNESS=claude
MODE=review
PROJECT_PATH=$T/proj
WORKTREE=$T/t15-missing-worktree-$name
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
TMUX_WINDOW_ID=$wid
ENVEOF
  : > "$d/status"
  echo 0 > "$d/seen"
  printf '%s\n' "$wid"
}

# Rename + move to another session; the old name target must be dead
t15_wid=$(mk_t15 t15-move)
tmux new-session -d -s kp-t15-other -n home
tmux rename-window -t "$t15_wid" renamed-t15
tmux move-window -d -s "$t15_wid" -t kp-t15-other:
! tmux list-panes -t kingpin:t15-move >/dev/null 2>&1 && pass "t15: old name target no longer resolves after rename+move" || fail "t15: old name target still resolves"
tmux list-windows -t kp-t15-other -F '#{window_id}' | grep -qx "$t15_wid" && pass "t15: window now lives in the other session" || fail "t15: window did not move"

KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t15-move "moved-ok" > "$T/t15-send.out" 2>&1 && pass "t15: kingpin-send reached the renamed+moved window" || fail "t15: kingpin-send failed: $(cat "$T/t15-send.out")"
t15_seen=0
for _ in $(seq 1 50); do
  tmux capture-pane -pJt "$t15_wid" -S -50 2>/dev/null | grep -qxF "moved-ok" && { t15_seen=1; break; }
  sleep 0.1
done
[ "$t15_seen" -eq 1 ] && pass "t15: text arrived in the moved window's pane" || fail "t15: text did not arrive in the moved window"

t15_wait=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t15_wait" | grep -q "^t15-move exited" && fail "t15: kingpin-wait reported a live renamed+moved window as exited" || pass "t15: kingpin-wait still sees the renamed+moved window as alive"
"$KP_BIN/kingpin" ack t15-move
[ ! -f "$KINGPIN_HOME/tasks/t15-move/seen_exited" ] && pass "t15: kingpin ack did not mark the live window exited" || fail "t15: kingpin ack marked the live window exited"

"$KP_BIN/kingpin-done" t15-move --force >/dev/null 2>&1 || true
! tmux list-windows -a -F '#{window_id}' | grep -qx "$t15_wid" && pass "t15: kingpin-done closed the renamed+moved window" || fail "t15: kingpin-done left the renamed+moved window alive"
tmux kill-session -t kp-t15-other 2>/dev/null || true

# A window that comes back under the task's name is the task's window (resolution is
# name-first), so it is not `exited`; that is the DEAD state kingpin list reports.
t15g_wid=$(mk_t15 t15-gone)
tmux kill-window -t "$t15g_wid"
tmux new-window -d -t kingpin: -n t15-gone cat
t15g_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t15g_out" | grep -q "^t15-gone exited" && fail "t15: a resurrected window with the task's name was reported exited" || pass "t15: a resurrected window with the task's name is not exited"
tmux kill-window -t kingpin:t15-gone 2>/dev/null || true
# With no window under the name, the task reads as exited.
t15g_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null || true)
echo "$t15g_out" | grep -q "^t15-gone exited" && pass "t15: task whose window is gone reads as exited" || fail "t15: gone window not reported as exited (got: $t15g_out)"
"$KP_BIN/kingpin" ack t15-gone
[ -f "$KINGPIN_HOME/tasks/t15-gone/seen_exited" ] && pass "t15: kingpin ack marks the gone window exited" || fail "t15: seen_exited missing for gone window"

# Legacy task.env with only TMUX_TARGET still works through the name
t15l_wid=$(mk_t15 t15-legacy)
kp_test_sub "$KINGPIN_HOME/tasks/t15-legacy/task.env" '/^TMUX_WINDOW_ID=/d'
KINGPIN_SEND_DELAY=0.1 "$KP_BIN/kingpin-send" t15-legacy "legacy-ok" >/dev/null 2>&1 && pass "t15: legacy task.env (TMUX_TARGET only) still reaches the window" || fail "t15: legacy task.env send failed"
"$KP_BIN/kingpin-done" t15-legacy --force >/dev/null 2>&1 || true
! tmux list-windows -a -F '#{window_id}' | grep -qx "$t15l_wid" && pass "t15: kingpin-done closed the legacy window" || fail "t15: kingpin-done left the legacy window alive"
rm -rf "$KINGPIN_HOME/tasks/t15-move" "$KINGPIN_HOME/tasks/t15-gone" "$KINGPIN_HOME/tasks/t15-legacy"

# Test 17: descriptive slugs for task ID, branch and window (kp-<n>-<slug> / kp-<slug>)
echo "=== Test 17: descriptive title slugs ==="
t17_title='Unify Task ID, git branch, and window name with descriptive title slugs'
[ "$(node "$KP_ROOT/lib/slug.mjs" "$t17_title")" = "unify-task-id" ] && pass "t17: slug of a long title is 3 words" || fail "t17: wrong slug for the long title"
[ -z "$(node "$KP_ROOT/lib/slug.mjs" '!!!')" ] && pass "t17: punctuation-only text gives an empty slug" || fail "t17: punctuation-only slug not empty"
[ "$(node "$KP_ROOT/lib/slug.mjs" 'Überprüfung der API')" = "uberprufung-der-api" ] && pass "t17: accents are folded" || fail "t17: accents not folded"
t17_long=$(node "$KP_ROOT/lib/slug.mjs" 'Internationalization infrastructure modernization')
[[ $t17_long =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#t17_long}" -le 24 ] && pass "t17: slug is lowercase dashes and at most 24 chars ($t17_long)" || fail "t17: bad slug shape: $t17_long"
[ "$(node "$KP_ROOT/lib/slug.mjs" 'the supercalifragilisticexpialidocious thing')" = "supercalifragilisticexpi" ] && pass "t17: an over-long first word falls back to a non-stop word" || fail "t17: over-long first word fell back to a stop word"

# gh stub: prints a fixed title, logs every call, fails when t17-gh-fail exists
cat > "$T/t17-gh" << 'EOF17'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/t17-gh-calls"
[ ! -e "$(dirname "$0")/t17-gh-fail" ] || exit 1
echo "Wait for worker wakeup events"
EOF17
chmod +x "$T/t17-gh"
export KINGPIN_GH=$T/t17-gh
export KINGPIN_AGY=$T/fake-worker

# Issue mode: ID, branch, window and TMUX_TARGET carry the same slug
t17_id=kp-301-wait-worker-wakeup
t17_out=$("$KP_BIN/kingpin" spawn demo-auto --issue 301 --mode review)
echo "$t17_out" | grep -q "spawned $t17_id " && pass "t17: issue spawn named $t17_id" || fail "t17: issue spawn ID wrong: $t17_out"
t17_env=$KINGPIN_HOME/tasks/$t17_id/task.env
grep -qx "BRANCH=kingpin/$t17_id" "$t17_env" && pass "t17: BRANCH is kingpin/$t17_id" || fail "t17: wrong BRANCH"
grep -qx "TMUX_TARGET=kingpin:$t17_id" "$t17_env" && pass "t17: TMUX_TARGET is kingpin:$t17_id" || fail "t17: wrong TMUX_TARGET"
grep -qE '^CREATED=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$' "$t17_env" && pass "t17: CREATED is written in a form both date(1)s write" || fail "t17: CREATED is missing or GNU-only: $(grep '^CREATED=' "$t17_env")"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "$t17_id" && pass "t17: tmux window is named $t17_id" || fail "t17: window name wrong"
t17_wt=$(sed -n 's/^WORKTREE=//p' "$t17_env")
[ "$(git -C "$t17_wt" branch --show-current)" = "kingpin/$t17_id" ] && pass "t17: worktree is on kingpin/$t17_id" || fail "t17: worktree branch wrong"
grep -qE '^BASE_SHA=[0-9a-f]{40}$' "$t17_env" \
  && [ "$(sed -n 's/^BASE_SHA=//p' "$t17_env")" = "$(git -C "$t17_wt" rev-parse HEAD)" ] \
  && pass "t17: BASE_SHA is the commit the branch was leased at" || fail "t17: BASE_SHA missing or not the lease commit: $(grep '^BASE_SHA=' "$t17_env")"
[ ! -e "$KINGPIN_HOME/tasks/$t17_id/launching" ] && grep -q '^TMUX_WINDOW_ID=' "$t17_env" && pass "t45: spawn removes the launching marker" || fail "t45: launching marker left behind"
"$KP_BIN/kingpin" send "$t17_id" "echo t17-ok" | grep -q "OK: sent to kingpin:$t17_id" && pass "t17: kingpin send reaches the slugged window" || fail "t17: kingpin send failed"
"$KP_BIN/kingpin" "done" "$t17_id" --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "$t17_id" && [ -L "$KINGPIN_HOME/tasks/$t17_id" ] && pass "t17: kingpin done closed and archived the slugged task" || fail "t17: kingpin done left the task behind"

# gh failing: the spawn degrades to kp-<n>
touch "$T/t17-gh-fail"
"$KP_BIN/kingpin" spawn demo-auto --issue 302 --mode review | grep -q "spawned kp-302 " && pass "t17: gh failure falls back to kp-302" || fail "t17: gh failure did not fall back to kp-302"
"$KP_BIN/kingpin" "done" kp-302 --force >/dev/null
rm -f "$T/t17-gh-fail"

# Text mode: kp-<slug>, second identical request gets -2
"$KP_BIN/kingpin" spawn demo-auto --text "refactor authentication service" --mode review | grep -q "spawned kp-refactor-authentication " && pass "t17: text spawn named kp-refactor-authentication" || fail "t17: text spawn ID wrong"
"$KP_BIN/kingpin" spawn demo-auto --text "refactor authentication service" --mode review | grep -q "spawned kp-refactor-authentication-2 " && pass "t17: second identical text spawn gets -2" || fail "t17: text spawn collided"
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "kp-refactor-authentication" && pass "t17: text window is named kp-refactor-authentication" || fail "t17: text window name wrong"

# Rename: once the worker reports its issue, the window and TMUX_TARGET follow
t17_text=kp-refactor-authentication
t17_tenv=$KINGPIN_HOME/tasks/$t17_text/task.env
t17_twid=$(sed -n 's/^TMUX_WINDOW_ID=//p' "$t17_tenv")
t17_tbranch=$(sed -n 's/^BRANCH=//p' "$t17_tenv")
echo "issue: #303 https://example/303" >> "$KINGPIN_HOME/tasks/$t17_text/status"
"$KP_BIN/kingpin-wait" --once >/dev/null || true
t17_new=kp-303-wait-worker-wakeup
[ "$(tmux display-message -p -t "$t17_twid" '#{window_name}')" = "$t17_new" ] && pass "t17: window renamed to $t17_new after the issue line" || fail "t17: window not renamed"
grep -qx "TMUX_TARGET=kingpin:$t17_new" "$t17_tenv" && pass "t17: TMUX_TARGET rewritten to kingpin:$t17_new" || fail "t17: TMUX_TARGET not rewritten"
grep -qx "TMUX_WINDOW_ID=$t17_twid" "$t17_tenv" && grep -qx "BRANCH=$t17_tbranch" "$t17_tenv" && [ -d "$KINGPIN_HOME/tasks/$t17_text" ] && pass "t17: window ID, branch and task folder unchanged" || fail "t17: rename touched the window ID, branch or task folder"
[ -f "$KINGPIN_HOME/tasks/$t17_text/renamed" ] && pass "t17: renamed marker written" || fail "t17: no renamed marker"
"$KP_BIN/kingpin" send "$t17_text" "echo t17-renamed" | grep -q "OK: sent to kingpin:$t17_new" && pass "t17: kingpin send reaches the renamed window" || fail "t17: kingpin send after rename failed"
t17_calls=$(wc -l < "$T/t17-gh-calls")
"$KP_BIN/kingpin-wait" --once >/dev/null || true
"$KP_BIN/kingpin-rename" "$t17_text" >/dev/null
[ "$(wc -l < "$T/t17-gh-calls")" = "$t17_calls" ] && [ "$(tmux display-message -p -t "$t17_twid" '#{window_name}')" = "$t17_new" ] && pass "t17: a second rename is a no-op" || fail "t17: second rename was not a no-op"
# A retry after a lost marker finds TMUX_TARGET already at the new name: kp_env_set
# writes nothing, so the record keeps its bytes and its inode.
cp -p "$t17_tenv" "$T/t17-env.before"
rm -f "$T/t17-env.link"
ln "$t17_tenv" "$T/t17-env.link"
rm -f "$KINGPIN_HOME/tasks/$t17_text/renamed"
"$KP_BIN/kingpin-rename" "$t17_text" >/dev/null
cmp -s "$t17_tenv" "$T/t17-env.before" && [ "$t17_tenv" -ef "$T/t17-env.link" ] && [ -f "$KINGPIN_HOME/tasks/$t17_text/renamed" ] \
  && pass "t17: a rename retried after a lost marker leaves task.env untouched" || fail "t17: the retried rename rewrote task.env or left no marker"
"$KP_BIN/kingpin" "done" "$t17_text" --force >/dev/null
"$KP_BIN/kingpin" "done" kp-refactor-authentication-2 --force >/dev/null
! tmux list-windows -t kingpin -F '#{window_name}' | grep -qE "^kp-(303|refactor)" && pass "t17: kingpin done closed the renamed windows" || fail "t17: windows left behind"

# An explicit --id wins and never calls gh
rm -f "$T/t17-gh-calls"
"$KP_BIN/kingpin" spawn demo-auto --issue 304 --id t17-explicit --mode review | grep -q "spawned t17-explicit " && pass "t17: --id overrides the generated ID" || fail "t17: --id ignored"
[ ! -e "$T/t17-gh-calls" ] && pass "t17: --id spawn made no gh call" || fail "t17: --id spawn called gh"
"$KP_BIN/kingpin" "done" t17-explicit --force >/dev/null
unset KINGPIN_GH

# Test 18: spawned windows keep the name Kingpin gave them
echo "=== Test 18: spawned windows are pinned against renames ==="
# Simulate a user config that renames windows; the private server dies in cleanup.
tmux set-option -g automatic-rename on
tmux set-option -g allow-rename on
cat > "$T/fake-renamer" << 'FRN'
#!/usr/bin/env bash
# Wait for the test's go marker, then emit a rename escape sequence like a child command would
until [ -f "$KINGPIN_TASK_DIR/go" ]; do sleep 0.1; done
printf '\033kevil\033\\'
: > "$KINGPIN_TASK_DIR/emitted"
exec bash
FRN
chmod +x "$T/fake-renamer"
export KINGPIN_AGY=$T/fake-renamer
"$KP_BIN/kingpin" spawn demo-auto --issue 306 --id t18-pinned --mode review >/dev/null
t18_wid=$(sed -n 's/^TMUX_WINDOW_ID=//p' "$KINGPIN_HOME/tasks/t18-pinned/task.env")
[ "$(tmux display-message -p -t "$t18_wid" '#{automatic-rename} #{allow-rename}')" = "0 0" ] && pass "t18: automatic-rename and allow-rename are off on the task window" || fail "t18: window options not pinned: $(tmux display-message -p -t "$t18_wid" '#{automatic-rename} #{allow-rename}')"
touch "$KINGPIN_HOME/tasks/t18-pinned/go"
kp_wait_until 5 test -f "$KINGPIN_HOME/tasks/t18-pinned/emitted" && pass "t18: worker emitted the rename escape sequence" || fail "t18: worker never emitted the escape sequence"
kp_holds_for 0.3 window_name_is "$t18_wid" t18-pinned && pass "t18: escape-sequence rename did not change the window name" || fail "t18: window renamed to $(tmux display-message -p -t "$t18_wid" '#{window_name}')"
"$KP_BIN/kingpin" "done" t18-pinned --force >/dev/null
export KINGPIN_AGY=$T/fake-worker
tmux set-option -gu automatic-rename
tmux set-option -gu allow-rename

# Test 19: the dependency setup command runs inside the leased worktree, before launch
echo "=== Test 19: SETUP_CMD runs in the worktree ==="
# The project env carries the setup command the way `kingpin init --setup` writes it.
setup_project() { # <command>: rewrite demo-auto's SETUP_CMD, keeping the project path
  printf 'PROJECT_PATH=%q\nHARNESS=agy\nSETUP_CMD=%q\n' "$T/proj" "$1" > "$KINGPIN_HOME/projects/demo-auto.env"
}

setup_project 'touch setup-ran && echo ok'
"$KP_BIN/kingpin" spawn demo-auto --issue 401 --id t19-setup-ok --mode review >/dev/null && pass "t19: spawn with a setup command exits 0" || fail "t19: spawn with a setup command failed"
t19_wt=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/t19-setup-ok/task.env")
[ -f "$t19_wt/setup-ran" ] && pass "t19: the setup command ran in the worktree" || fail "t19: setup-ran missing from the worktree"
grep -qx 'ok' "$KINGPIN_HOME/tasks/t19-setup-ok/setup.log" && pass "t19: setup.log holds the command's output" || fail "t19: setup.log missing 'ok': $(cat "$KINGPIN_HOME/tasks/t19-setup-ok/setup.log" 2>/dev/null)"
"$KP_BIN/kingpin" "done" t19-setup-ok --force >/dev/null

# A failed setup aborts the spawn and leaves nothing behind for the next lease. The command
# prints its own words, so the failure output must carry them: the cleanup trap deletes
# $task_dir, and with it setup.log, before the operator can read it (issue #81).
setup_project 'echo setup-broke >&2; false'
t19_rc=0
t19_err=$("$KP_BIN/kingpin" spawn demo-auto --issue 402 --id t19-setup-fail --mode review 2>&1 >/dev/null) || t19_rc=$?
if [ "$t19_rc" -ne 0 ] && [ ! -d "$KINGPIN_HOME/tasks/t19-setup-fail" ] && grep -q 'setup failed' <<< "$t19_err" && grep -q 'setup-broke' <<< "$t19_err"; then
  pass "t19: a failed setup command aborts the spawn, leaves no task dir, and streams its output"
else
  fail "t19: a failed setup command did not abort cleanly (rc=$t19_rc): $t19_err"
fi
if grep -q 'setup\.log' <<< "$t19_err"; then
  fail "t19: the failure message names a setup.log path that the cleanup deletes: $t19_err"
else
  pass "t19: the failure message names no deleted setup.log path"
fi
t19_pool_rc=0
t19_pool=$(cd "$T/proj" && treehouse status 2>&1) || t19_pool_rc=$?
t19_leased=$(grep -c leased <<< "$t19_pool" || true)
if [ "$t19_pool_rc" -eq 0 ] && [ "$t19_leased" -eq 0 ]; then
  pass "t19: the failed spawn returned its worktree to the pool"
else
  fail "t19: pool unreadable (rc=$t19_pool_rc) or $t19_leased worktree(s) still leased after a failed setup"
fi
# Restore the setup command the rest of the suite expects.
setup_project 'echo setup'

# Test 20: the tmux session is resolved, never created behind the operator's back
# (issue #152). A queue runner with no $TMUX used to get a second `kingpin` session
# while the operator watched another one.
echo "=== Test 20: spawn resolves its tmux session without a client ==="
t20_target() { # <task-id>: the session the task recorded
  sed -n 's/^TMUX_TARGET=//p' "$KINGPIN_HOME/tasks/$1/task.env" 2>/dev/null | cut -d: -f1 || true
}
t20_window_in() { # <session> <window name>
  local names
  names=$(tmux list-windows -t "$1" -F '#{window_name}' 2>/dev/null || true)
  printf '%s\n' "$names" | grep -qx "$2"
}

# Branch 1: no session at all. The named fallback is created and the output says so.
tmux kill-session -t kingpin 2>/dev/null || true
[ -z "$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)" ] && pass "t20: the private server starts with no session" || fail "t20: a session was left on the server before the fallback case"
t20_fallback=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-fallback --mode review 2>&1 || true)
tmux has-session -t kingpin 2>/dev/null && pass "t20: the named fallback session was created" || fail "t20: no fallback session after the spawn"
[ "$(t20_target t20-fallback)" = "kingpin" ] && t20_window_in kingpin t20-fallback && pass "t20: the fallback spawn landed in kingpin" || fail "t20: fallback target is $(t20_target t20-fallback)"
grep -qF 'session the named fallback' <<< "$t20_fallback" && pass "t20: the spawn output reports the named fallback" || fail "t20: spawn output does not report the fallback: $t20_fallback"
"$KP_BIN/kingpin" "done" t20-fallback --force >/dev/null || true

# Branch 2: one session on the server. It is the target, and no second one appears.
t20_only=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-only --mode review 2>&1 || true)
[ "$(t20_target t20-only)" = "kingpin" ] && t20_window_in kingpin t20-only && pass "t20: the only session on the server is used" || fail "t20: single-session spawn target is $(t20_target t20-only)"
[ "$(tmux list-sessions -F '#{session_name}' | wc -l | tr -d ' ')" = "1" ] && pass "t20: the single-session spawn created no second session" || fail "t20: sessions after the single-session spawn: $(tmux list-sessions -F '#{session_name}' | tr '\n' ' ')"
grep -qF 'session the only session on the server' <<< "$t20_only" && pass "t20: the spawn output names the single session" || fail "t20: spawn output does not name the single session: $t20_only"
"$KP_BIN/kingpin" "done" t20-only --force >/dev/null || true

# Branch 3: an env target wins over the single session, and the spawn says which.
tmux new-session -d -s S1 -n home
t20_env=$(TMUX='' KINGPIN_TMUX_SESSION=S1 "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-env --mode review 2>&1 || true)
[ "$(t20_target t20-env)" = "S1" ] && t20_window_in S1 t20-env && pass "t20: KINGPIN_TMUX_SESSION wins without a client" || fail "t20: env target is $(t20_target t20-env)"
grep -qF 'session from KINGPIN_TMUX_SESSION' <<< "$t20_env" && pass "t20: the spawn output names the env target" || fail "t20: spawn output does not name the env target: $t20_env"
# kingpin list names the session a live worker's window is in.
t20_list=$("$KP_BIN/kingpin" list 2>/dev/null || true)
grep -q 'SESSION' <<< "$t20_list" && pass "t20: kingpin list has a SESSION column" || fail "t20: kingpin list header has no SESSION column: $t20_list"
[ "$(printf '%s\n' "$t20_list" | awk '$1=="t20-env"{print $5}')" = "S1" ] && pass "t20: kingpin list names the worker's session" || fail "t20: list row for t20-env: $(printf '%s\n' "$t20_list" | awk '$1=="t20-env"')"
"$KP_BIN/kingpin" "done" t20-env --force >/dev/null || true

# Branch 4: --tmux-session beats the env target.
t20_flag=$(TMUX='' KINGPIN_TMUX_SESSION=kingpin "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-flag --mode review --tmux-session S1 2>&1 || true)
[ "$(t20_target t20-flag)" = "S1" ] && t20_window_in S1 t20-flag && pass "t20: --tmux-session beats KINGPIN_TMUX_SESSION" || fail "t20: flag target is $(t20_target t20-flag)"
grep -qF 'session from --tmux-session' <<< "$t20_flag" && pass "t20: the spawn output names the flag target" || fail "t20: spawn output does not name the flag target: $t20_flag"
"$KP_BIN/kingpin" "done" t20-flag --force >/dev/null || true

# Branch 4b: tmux accepts an unambiguous session-name prefix, so the recorded target has
# to be the name tmux resolved it to, not the prefix that was typed.
t20_prefix=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-prefix --mode review --tmux-session S 2>&1 || true)
[ "$(t20_target t20-prefix)" = "S1" ] && t20_window_in S1 t20-prefix && pass "t20: a session-name prefix records the real session name" || fail "t20: prefix target is $(t20_target t20-prefix)"
grep -qF "tmux -L $KINGPIN_TMUX_SOCKET S1:t20-prefix" <<< "$t20_prefix" && pass "t20: the OK line names the resolved session" || fail "t20: OK line does not name the resolved session: $t20_prefix"
"$KP_BIN/kingpin" "done" t20-prefix --force >/dev/null || true

# Branch 5: the one attached session wins, even with two other sessions on the server.
tmux new-session -d -s S2 -n home
( sleep 60 | tmux -C attach-session -t S2 >/dev/null 2>&1 ) &
t20_attach_pid=$!
for _ in $(seq 1 50); do
  [ "$(tmux display-message -p -t S2 '#{session_attached}' 2>/dev/null || true)" = "1" ] && break
  sleep 0.1
done
[ "$(tmux display-message -p -t S2 '#{session_attached}' 2>/dev/null || true)" = "1" ] && pass "t20: a client is attached to S2" || fail "t20: could not attach a client to S2"
t20_attached=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-attached --mode review 2>&1 || true)
[ "$(t20_target t20-attached)" = "S2" ] && t20_window_in S2 t20-attached && pass "t20: the attached session wins over the other two" || fail "t20: attached-session target is $(t20_target t20-attached)"
grep -qF 'session the only attached session' <<< "$t20_attached" && pass "t20: the spawn output names the attached session" || fail "t20: spawn output does not name the attached session: $t20_attached"
tmux detach-client -s S2 2>/dev/null || true
kill "$t20_attach_pid" 2>/dev/null || true
wait "$t20_attach_pid" 2>/dev/null || true
"$KP_BIN/kingpin" "done" t20-attached --force >/dev/null || true

# Branch 6: several sessions and no attached client is a guess, so the spawn refuses
# and names every candidate. Nothing is leased and no task record survives.
t20_amb_rc=0
t20_amb=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-ambiguous --mode review 2>&1 >/dev/null) || t20_amb_rc=$?
if [ "$t20_amb_rc" -ne 0 ] && grep -q 'S1' <<< "$t20_amb" && grep -q 'S2' <<< "$t20_amb" && grep -q 'kingpin' <<< "$t20_amb"; then
  pass "t20: several unattached sessions refuse and name the candidates"
else
  fail "t20: ambiguous server did not refuse with candidates (rc=$t20_amb_rc): $t20_amb"
fi
[ ! -e "$KINGPIN_HOME/tasks/t20-ambiguous" ] && pass "t20: the refused spawn left no task folder" || fail "t20: the refused spawn left $KINGPIN_HOME/tasks/t20-ambiguous"
grep -qF 'none has a client attached' <<< "$t20_amb" && pass "t20: the refusal reports that no client is attached" || fail "t20: the refusal does not report the measured state: $t20_amb"
t20_windows=$(tmux list-windows -a -F '#{window_name}' 2>/dev/null || true)
! grep -qx t20-ambiguous <<< "$t20_windows" && pass "t20: the refused spawn opened no window" || fail "t20: the refused spawn opened a window"

# Branch 7: an explicit target that does not exist is refused, not created.
t20_missing_rc=0
t20_missing=$(TMUX='' KINGPIN_TMUX_SESSION=t20-nope "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-missing --mode review 2>&1 >/dev/null) || t20_missing_rc=$?
[ "$t20_missing_rc" -ne 0 ] && grep -q 't20-nope' <<< "$t20_missing" && pass "t20: an unknown explicit target is refused by name" || fail "t20: unknown target was not refused (rc=$t20_missing_rc): $t20_missing"
[ ! -e "$KINGPIN_HOME/tasks/t20-missing" ] && pass "t20: the refused explicit target left no task folder" || fail "t20: unknown target left a task folder"

# Branch 8: more than one attached session is a guess too, and the refusal reports what
# it measured instead of claiming that no client is attached.
( sleep 60 | tmux -C attach-session -t S1 >/dev/null 2>&1 ) &
t20_att1_pid=$!
( sleep 60 | tmux -C attach-session -t S2 >/dev/null 2>&1 ) &
t20_att2_pid=$!
for _ in $(seq 1 50); do
  [ "$(tmux display-message -p -t S1 '#{session_attached}' 2>/dev/null || true)" = "1" ] \
    && [ "$(tmux display-message -p -t S2 '#{session_attached}' 2>/dev/null || true)" = "1" ] && break
  sleep 0.1
done
t20_multi_rc=0
t20_multi=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 500 --id t20-multi-attached --mode review 2>&1 >/dev/null) || t20_multi_rc=$?
if [ "$t20_multi_rc" -ne 0 ] && grep -qF '2 of them have a client attached' <<< "$t20_multi" && grep -q 'S1' <<< "$t20_multi" && grep -q 'S2' <<< "$t20_multi"; then
  pass "t20: two attached sessions refuse and report the measured attachment"
else
  fail "t20: two attached sessions did not refuse with the measured state (rc=$t20_multi_rc): $t20_multi"
fi
! grep -qF 'with no client attached' <<< "$t20_multi" && pass "t20: the refusal does not claim no client is attached" || fail "t20: the refusal claims no client is attached: $t20_multi"
[ ! -e "$KINGPIN_HOME/tasks/t20-multi-attached" ] && pass "t20: the two-attached refusal left no task folder" || fail "t20: the two-attached refusal left a task folder"
tmux detach-client -s S1 2>/dev/null || true
tmux detach-client -s S2 2>/dev/null || true
kill "$t20_att1_pid" "$t20_att2_pid" 2>/dev/null || true
wait "$t20_att1_pid" "$t20_att2_pid" 2>/dev/null || true

tmux kill-session -t S1 2>/dev/null || true
tmux kill-session -t S2 2>/dev/null || true
tmux has-session -t kingpin 2>/dev/null && pass "t20: the suite's kingpin session is left in place" || fail "t20: the suite lost its kingpin session"

# Test 21: the fleet-wide tmux target (issue #191). TMUX_SOCKET and TMUX_SESSION in
# config.env are the fleet default, the env and --tmux-session still win, and with no
# name at all a spawn run inside tmux follows the caller's own session and socket.
echo "=== Test 21: spawn resolves the fleet-wide tmux target ==="
t21_target() { # <task-id>: the session the task recorded
  sed -n 's/^TMUX_TARGET=//p' "$KINGPIN_HOME/tasks/$1/task.env" 2>/dev/null | cut -d: -f1 || true
}
t21_socket() { # <task-id>: the socket the task recorded
  sed -n 's/^TMUX_SOCKET=//p' "$KINGPIN_HOME/tasks/$1/task.env" 2>/dev/null || true
}
t21_window_in() { # <socket name or path> <session> <window name>
  if [ "${1#*/}" != "$1" ]; then
    "$REAL_TMUX" -S "$1" list-windows -t "$2" -F '#{window_name}' 2>/dev/null | grep -qx "$3"
  else
    "$REAL_TMUX" -L "$1" list-windows -t "$2" -F '#{window_name}' 2>/dev/null | grep -qx "$3"
  fi
}
t21_write_config() { # <socket value> <session value>
  printf 'TMUX_SOCKET=%s\nTMUX_SESSION=%s\n' "$1" "$2" > "$KINGPIN_HOME/config.env"
}

# Case 1: the config pair names the target, and the OK line names the config file.
t21_write_config kingpin S1
tmux new-session -d -s S1 -n home
t21_config=$(TMUX='' env -u KINGPIN_TMUX_SOCKET "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-config --mode review 2>&1 || true)
[ "$(t21_socket t21-config)" = "kingpin" ] && [ "$(t21_target t21-config)" = "S1" ] && t21_window_in kingpin S1 t21-config \
  && pass "t21: config.env TMUX_SOCKET/TMUX_SESSION place the window" \
  || fail "t21: config target is socket $(t21_socket t21-config) session $(t21_target t21-config): $t21_config"
grep -qF "session from TMUX_SESSION in $KINGPIN_HOME/config.env" <<< "$t21_config" \
  && pass "t21: the spawn output names TMUX_SESSION in config.env" \
  || fail "t21: spawn output does not name the config session: $t21_config"

# Case 2: KINGPIN_TMUX_SOCKET wins over TMUX_SOCKET in the config.
t21_write_config no-such-socket S1
t21_env_spawn=$(TMUX='' KINGPIN_TMUX_SOCKET=kingpin "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-env-socket --mode review --tmux-session S1 2>&1 || true)
[ "$(t21_socket t21-env-socket)" = "kingpin" ] && [ "$(t21_target t21-env-socket)" = "S1" ] \
  && pass "t21: KINGPIN_TMUX_SOCKET wins over the configured socket" \
  || fail "t21: env socket lost to the config: socket $(t21_socket t21-env-socket): $t21_env_spawn"

# Case 3: --tmux-session wins over a configured session.
t21_write_config kingpin nope
t21_flag_spawn=$(TMUX='' env -u KINGPIN_TMUX_SOCKET "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-flag-wins --mode review --tmux-session S1 2>&1 || true)
[ "$(t21_socket t21-flag-wins)" = "kingpin" ] && [ "$(t21_target t21-flag-wins)" = "S1" ] \
  && pass "t21: --tmux-session wins over the configured session" \
  || fail "t21: flag lost to the config session: $(t21_target t21-flag-wins): $t21_flag_spawn"
grep -qF 'session from --tmux-session' <<< "$t21_flag_spawn" \
  && pass "t21: the spawn output names the flag as the source" \
  || fail "t21: spawn output does not name the flag: $t21_flag_spawn"

# Case 4: a configured session that does not exist is refused by name, before a lease.
t21_missing='' t21_missing_rc=0
kp_run t21_missing t21_missing_rc env -u KINGPIN_TMUX_SOCKET -u TMUX \
  "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-missing --mode review
if [ "$t21_missing_rc" -ne 0 ] && grep -qF 'nope' <<< "$t21_missing" \
  && grep -qF "$KINGPIN_HOME/config.env" <<< "$t21_missing"; then
  pass "t21: a missing configured session is refused with the session and the config path"
else
  fail "t21: missing configured session not refused as expected (rc=$t21_missing_rc): $t21_missing"
fi
[ ! -e "$KINGPIN_HOME/tasks/t21-missing" ] \
  && pass "t21: the refused config target left no task folder" \
  || fail "t21: the refused config target left $KINGPIN_HOME/tasks/t21-missing"

for t21_id in t21-config t21-env-socket t21-flag-wins; do
  "$KP_BIN/kingpin" "done" "$t21_id" --force >/dev/null 2>&1 || true
done

# Case 5: with no config and no env, the caller's own tmux client decides both the
# socket and the session.
rm -f "$KINGPIN_HOME/config.env"
"$REAL_TMUX" -L caller new-session -d -s orch -n home
t21_caller_socket=$("$REAL_TMUX" -L caller display-message -p '#{socket_path}')
t21_caller=$(TMUX="$t21_caller_socket,$$,0" env -u KINGPIN_TMUX_SOCKET "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-caller --mode review 2>&1 || true)
[ "$(t21_socket t21-caller)" = "$t21_caller_socket" ] && [ "$(t21_target t21-caller)" = "orch" ] \
  && t21_window_in "$t21_caller_socket" orch t21-caller \
  && pass "t21: a spawn inside tmux lands in the caller's session on the caller's socket" \
  || fail "t21: caller target is socket $(t21_socket t21-caller) session $(t21_target t21-caller): $t21_caller"
grep -qF "session the caller's tmux session (\$TMUX)" <<< "$t21_caller" \
  && pass "t21: the spawn output names the caller's session" \
  || fail "t21: spawn output does not name the caller's session: $t21_caller"
grep -qF "tmux -S $t21_caller_socket orch:t21-caller" <<< "$t21_caller" \
  && pass "t21: the OK line names the caller's socket path" \
  || fail "t21: OK line does not name the socket path: $t21_caller"
t21_list=$("$KP_BIN/kingpin" list 2>/dev/null || true)
[ "$(printf '%s\n' "$t21_list" | awk '$1=="t21-caller"{print $5}')" = "orch" ] \
  && pass "t21: kingpin list names the caller's session" \
  || fail "t21: list row for t21-caller: $(printf '%s\n' "$t21_list" | awk '$1=="t21-caller"')"
t21_send=$("$KP_BIN/kingpin" send t21-caller "echo t21-ok" 2>&1 || true)
grep -qF 'OK: sent to orch:t21-caller' <<< "$t21_send" \
  && pass "t21: kingpin send reaches the caller-socket window" \
  || fail "t21: kingpin send to the caller-socket window failed: $t21_send"
"$KP_BIN/kingpin" "done" t21-caller --force >/dev/null 2>&1 || true
! t21_window_in "$t21_caller_socket" orch t21-caller \
  && pass "t21: kingpin done closed the caller-socket window" \
  || fail "t21: kingpin done left the caller-socket window alive"

# S1 was only needed by the named-target cases above; the fallback cases below want
# the fleet server's one remaining session to be the suite's `kingpin`.
tmux kill-session -t S1 2>/dev/null || true

# Case 6: a stale $TMUX is not an error. The spawn falls back to the fleet server and
# says once why it ignored the caller.
t21_stale_rc=0
t21_stale=$(TMUX="$T/nope,$$,0" env -u KINGPIN_TMUX_SOCKET "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-stale --mode review 2>"$T/t21-stale.err") || t21_stale_rc=$?
[ "$t21_stale_rc" -eq 0 ] && [ "$(t21_socket t21-stale)" = "kingpin" ] && [ "$(t21_target t21-stale)" = "kingpin" ] \
  && pass "t21: a stale \$TMUX falls back to the fleet server" \
  || fail "t21: stale \$TMUX broke the spawn (rc=$t21_stale_rc, socket $(t21_socket t21-stale)): $t21_stale"
[ "$(grep -c 'names no reachable session' "$T/t21-stale.err" || true)" = "1" ] \
  && pass "t21: the stale-\$TMUX fallback prints one stderr line" \
  || fail "t21: stale-\$TMUX stderr: $(cat "$T/t21-stale.err")"
"$KP_BIN/kingpin" "done" t21-stale --force >/dev/null 2>&1 || true

# Case 7: outside tmux with no config, the only remaining session is used, and the
# normal out-of-tmux path prints no fallback note (only a set-but-stale $TMUX does).
t21_plain_rc=0
t21_plain=$(env -u KINGPIN_TMUX_SOCKET -u TMUX "$KP_BIN/kingpin" spawn demo-auto --issue 600 --id t21-outside --mode review 2>"$T/t21-plain.err") || t21_plain_rc=$?
[ "$t21_plain_rc" -eq 0 ] && [ "$(t21_target t21-outside)" = "kingpin" ] && t21_window_in kingpin kingpin t21-outside \
  && pass "t21: outside tmux the only session on the fleet server is used" \
  || fail "t21: out-of-tmux target is $(t21_target t21-outside) (rc=$t21_plain_rc): $t21_plain"
grep -qF 'session the only session on the server' <<< "$t21_plain" \
  && pass "t21: the spawn output names the single fleet session" \
  || fail "t21: spawn output does not name the single session: $t21_plain"
! grep -q 'names no reachable session' "$T/t21-plain.err" \
  && pass "t21: the out-of-tmux fallback prints no stale-\$TMUX note" \
  || fail "t21: out-of-tmux stderr: $(cat "$T/t21-plain.err")"
"$KP_BIN/kingpin" "done" t21-outside --force >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Test 22: Herdr spawns, the down-session refusal, --tmux-session and the tmux override
echo "=== Test 22: Herdr spawn and its refusals ==="
kp_test_fake_herdr_state
t22_session="kp-spawn-test-$$"
t22_record() { sed -n "s/^$2=//p" "$KINGPIN_HOME/tasks/$1/task.env" 2>/dev/null || true; }

# Case 1: a Herdr spawn creates a labelled pane and records the Herdr keys.
t22_out='' t22_rc=0
kp_run t22_out t22_rc env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$t22_session" \
  "$KP_BIN/kingpin" spawn demo-auto --text "herdr spawn" --id t22-herdr
[ "$t22_rc" -eq 0 ] \
  && pass "t22: a Herdr spawn succeeds" \
  || fail "t22: Herdr spawn exited $t22_rc: $t22_out $(cat "$KP_TEST_HERDR_CALLS" 2>/dev/null || true)"
[ "$(t22_record t22-herdr MUX)" = herdr ] \
  && pass "t22: the record names MUX=herdr" \
  || fail "t22: record: $(cat "$KINGPIN_HOME/tasks/t22-herdr/task.env" 2>/dev/null || true)"
[ "$(t22_record t22-herdr MUX_SESSION)" = "$t22_session" ] \
  && pass "t22: the record names the Herdr session" \
  || fail "t22: MUX_SESSION is '$(t22_record t22-herdr MUX_SESSION)'"
grep -qx 'MUX_LABEL=t22-herdr' "$KINGPIN_HOME/tasks/t22-herdr/task.env" \
  && pass "t22: the record names the pane label" \
  || fail "t22: MUX_LABEL is missing: $(cat "$KINGPIN_HOME/tasks/t22-herdr/task.env" 2>/dev/null || true)"
t22_target=$(t22_record t22-herdr MUX_TARGET)
[ -n "$t22_target" ] \
  && pass "t22: the record names the created pane" \
  || fail "t22: MUX_TARGET is empty"
grep -q '^TMUX_TARGET=' "$KINGPIN_HOME/tasks/t22-herdr/task.env" \
  && fail "t22: a Herdr record carries a TMUX_TARGET" \
  || pass "t22: a Herdr record carries no TMUX_TARGET"
awk -F '\t' -v id="$t22_target" '$1 == id && $2 == "t22-herdr" { found = 1 } END { exit !found }' \
  "$KP_TEST_HERDR_STATE/panes.tsv" \
  && pass "t22: the created pane carries the task label" \
  || fail "t22: panes: $(cat "$KP_TEST_HERDR_STATE/panes.tsv")"
t22_off=$(awk -v s="--session $t22_session " 'index($0, s) != 1 { print }' "$KP_TEST_HERDR_CALLS" || true)
[ -z "$t22_off" ] \
  && pass "t22: every herdr call names the private session" \
  || fail "t22: calls outside $t22_session: $t22_off"
grep -qF "herdr --session $t22_session $t22_target" <<< "$t22_out" \
  && pass "t22: the OK line names the herdr session and the pane" \
  || fail "t22: OK line: $t22_out"

t22_done_out='' t22_done_rc=0
kp_run t22_done_out t22_done_rc env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$t22_session" \
  "$KP_BIN/kingpin" "done" t22-herdr --force
[ "$t22_done_rc" -eq 0 ] \
  && pass "t22: kingpin done cleans a Herdr task" \
  || fail "t22: done exited $t22_done_rc: $t22_done_out"
[ -d "$KINGPIN_HOME/archive/t22-herdr" ] \
  && { [ -L "$KINGPIN_HOME/tasks/t22-herdr" ] || [ ! -e "$KINGPIN_HOME/tasks/t22-herdr" ]; } \
  && pass "t22: done archived the Herdr record" \
  || fail "t22: archive: $(ls -ld "$KINGPIN_HOME/tasks/t22-herdr" "$KINGPIN_HOME/archive/t22-herdr" 2>&1 || true)"
awk -F '\t' -v id="$t22_target" '$1 == id { found = 1 } END { exit !found }' \
  "$KP_TEST_HERDR_STATE/panes.tsv" \
  && fail "t22: done left the Herdr pane open" \
  || pass "t22: done closed the Herdr pane"
t22_off=$(awk -v s="--session $t22_session " 'index($0, s) != 1 { print }' "$KP_TEST_HERDR_CALLS" || true)
[ -z "$t22_off" ] \
  && pass "t22: every call through done names the private session" \
  || fail "t22: calls outside $t22_session: $t22_off"

# Case 2: a session that is not running refuses the spawn before the lease, and names
# the command that starts it.
kp_test_herdr_down
t22_down='' t22_down_rc=0
kp_run t22_down t22_down_rc env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$t22_session" \
  "$KP_BIN/kingpin" spawn demo-auto --text "herdr down" --id t22-down
[ "$t22_down_rc" -eq 1 ] \
  && pass "t22: a down Herdr session refuses the spawn" \
  || fail "t22: spawn exited $t22_down_rc: $t22_down"
grep -qF "herdr --session $t22_session server" <<< "$t22_down" \
  && pass "t22: the refusal names how to start the session" \
  || fail "t22: refusal: $t22_down"
[ ! -e "$KINGPIN_HOME/tasks/t22-down" ] && [ ! -L "$KINGPIN_HOME/tasks/t22-down" ] \
  && pass "t22: the refused spawn left no task folder" \
  || fail "t22: the refused spawn left a task folder"
git -C "$T/proj" rev-parse --verify --quiet refs/heads/kingpin/t22-down >/dev/null \
  && fail "t22: the refused spawn created its branch" \
  || pass "t22: the refused spawn created no branch"
kp_test_herdr_up

# Case 3: --tmux-session is tmux-only and is refused by name on a Herdr fleet.
t22_flag='' t22_flag_rc=0
kp_run t22_flag t22_flag_rc env KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION="$t22_session" \
  "$KP_BIN/kingpin" spawn demo-auto --text "herdr flag" --id t22-flag --tmux-session tmuxy
[ "$t22_flag_rc" -eq 1 ] \
  && pass "t22: --tmux-session is refused on a Herdr fleet" \
  || fail "t22: spawn exited $t22_flag_rc: $t22_flag"
grep -qF -- "--tmux-session names a tmux session; the fleet's mux is herdr" <<< "$t22_flag" \
  && pass "t22: the refusal names the flag and the backend" \
  || fail "t22: refusal: $t22_flag"
[ ! -e "$KINGPIN_HOME/tasks/t22-flag" ] \
  && pass "t22: the flag refusal left no task folder" \
  || fail "t22: the flag refusal left a task folder"

# Case 4: KINGPIN_MUX=tmux inside a Herdr pane still spawns a tmux worker.
t22_tmux='' t22_tmux_rc=0
kp_run t22_tmux t22_tmux_rc env HERDR_ENV=1 HERDR_SESSION=inside KINGPIN_MUX=tmux \
  "$KP_BIN/kingpin" spawn demo-auto --text "tmux inside herdr" --id t22-tmux
[ "$t22_tmux_rc" -eq 0 ] \
  && pass "t22: KINGPIN_MUX=tmux inside Herdr still spawns" \
  || fail "t22: spawn exited $t22_tmux_rc: $t22_tmux"
[ -n "$(t21_target t22-tmux)" ] && [ "$(t21_socket t22-tmux)" = kingpin ] \
  && t21_window_in kingpin "$(t21_target t22-tmux)" t22-tmux \
  && pass "t22: the override lands a tmux window on the fleet server" \
  || fail "t22: target is socket $(t21_socket t22-tmux) session $(t21_target t22-tmux): $t22_tmux"
grep -q '^MUX=herdr' "$KINGPIN_HOME/tasks/t22-tmux/task.env" \
  && fail "t22: the tmux override recorded MUX=herdr" \
  || pass "t22: the tmux override records no Herdr mux"
grep -qx "TMUX_TARGET=kingpin:t22-tmux" "$KINGPIN_HOME/tasks/t22-tmux/task.env" \
  && pass "t22: the tmux override records TMUX_TARGET" \
  || fail "t22: record: $(cat "$KINGPIN_HOME/tasks/t22-tmux/task.env" 2>/dev/null || true)"
"$KP_BIN/kingpin" "done" t22-tmux --force >/dev/null 2>&1 || true

# The caller server is not kp_test_cleanup's, so this suite kills it itself.
"$REAL_TMUX" -L caller kill-server 2>/dev/null || true

kp_test_finish SPAWN
