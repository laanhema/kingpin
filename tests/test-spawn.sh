#!/usr/bin/env bash
# Verification test for Kingpin: kingpin spawn: window ID tracking, descriptive slugs, pinned window names.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "spawn"
kp_test_bsd_shims
kp_test_project

kp_test_stub_lavish

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
for _ in $(seq 1 50); do
  [ -f "$KINGPIN_HOME/tasks/t18-pinned/emitted" ] && break
  sleep 0.1
done
sleep 0.3
[ -f "$KINGPIN_HOME/tasks/t18-pinned/emitted" ] && pass "t18: worker emitted the rename escape sequence" || fail "t18: worker never emitted the escape sequence"
[ "$(tmux display-message -p -t "$t18_wid" '#{window_name}')" = "t18-pinned" ] && pass "t18: escape-sequence rename did not change the window name" || fail "t18: window renamed to $(tmux display-message -p -t "$t18_wid" '#{window_name}')"
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

kp_test_finish SPAWN
