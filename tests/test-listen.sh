#!/usr/bin/env bash
# Verification test for Kingpin: kingpin listen: Lavish dossier opening, live listener, prompt routing.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "listen"
kp_test_project

# Test 11: Lavish review dossier auto-opening, live listener, and prompt routing
echo "=== Test 11: Lavish review dossier auto-opening, live listener, and prompt routing ==="
cat > "$T/mock-lavish" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/mock-lavish.log"
cmd="\${1:-}"
case "\$cmd" in
  poll)
    # Answer only the poll for the task the queued answer was written for: the
    # background listener for task-lavish-1 polls this same mock, and a shared
    # answer file let it steal the prompt meant for another session.
    task=\$(basename "\$(dirname "\${2:-}")")
    # A gate holds this poll open, so a case can change the task record while the
    # listener is inside a poll (issue #145: the task stops being live mid-flight).
    gate="$T/mock-lavish-gate-\$task"
    while [ -f "\$gate" ]; do sleep 0.05; done
    resp="$T/mock-lavish-response-\$task.txt"
    if [ -f "\$resp" ]; then
      cat "\$resp"
      # A queued NOT_FOUND answer is a failed poll, the way a session the server
      # lost answers: the listener answers that by opening the page again.
      lost=0
      grep -q 'NOT_FOUND' "\$resp" && lost=1
      rm -f "\$resp"
      [ "\$lost" -eq 0 ] || exit 1
    else
      sleep 0.2
    fi
    ;;
  reply)
    # A fail file makes the next N replies exit 1, so a case can prove a refused
    # reply is retried instead of recorded as delivered (review M1).
    task=\$(basename "\$(dirname "\${2:-}")")
    fail="$T/mock-lavish-fail-reply-\$task"
    if [ -f "\$fail" ]; then
      n=\$(cat "\$fail" 2>/dev/null || echo 0)
      if [ "\${n:-0}" -gt 0 ]; then
        printf '%s\n' "\$((n - 1))" > "\$fail"
        echo "refused: reply" >> "$T/mock-lavish.log"
        exit 1
      fi
      rm -f "\$fail"
    fi
    echo "OK: reply accepted"
    ;;
  end)
    echo "OK: session ended"
    ;;
  *)
    # An open answers the way lavish-axi does, with the session URL the listener
    # records for the handover (issue #146).
    task=\$(basename "\$(dirname "\${1:-}")")
    printf 'session:\n  file: %s\n  url: "http://127.0.0.1:4387/session/%s"\n  status: opened\n' "\${1:-}" "\$task"
    ;;
esac
EOF
chmod +x "$T/mock-lavish"
export KINGPIN_LAVISH="$T/mock-lavish"

# resp_file <task-dir>: where to queue this task's next poll answer.
resp_file() { printf '%s/mock-lavish-response-%s.txt\n' "$T" "$(basename "$1")"; }

# parked_file <task-dir>: the task's parked poll response, if one was written.
# Each event gets its own capture, so the name is not fixed.
parked_file() {
  local f
  for f in "$1"/unparsed-poll-*.txt; do
    if [ -e "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
}

# Parser fixtures, and the decoded prompt text of one parse. The parser falls back to
# its text scan whenever LAVISH_AXI_BIN names no decoder, which is what these use.
FIX="$KP_ROOT/tests/fixtures/lavish"
parsed_prompts() {
  LAVISH_AXI_BIN="${2:-}" node "$KP_ROOT/lib/lavish-prompts.mjs" kp-107 < "$1" \
    | awk -F'\t' '$1 == "feedback" || $1 == "approve" { print $2 }' \
    | while IFS= read -r b64; do printf '%s' "$b64" | base64 -d; printf '\n'; done
}

# 1. Setup task in review mode with report.html
t11_task="$KINGPIN_HOME/tasks/task-lavish-1"
mkdir -p "$t11_task"
echo "<html><body>Review Dossier 1</body></html>" > "$t11_task/report.html"
cat > "$t11_task/task.env" << EOF
TASK_ID=task-lavish-1
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/wt-lavish-1
ISSUE=401
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-1
EOF
tmux new-window -d -t kingpin: -n task-lavish-1 cat
echo "ready: branch=b review=APPROVE report=$t11_task/report.html" >> "$t11_task/status"

# 2. Run kingpin-watch --once to detect ready and auto-arm listener
"$KP_BIN/kingpin" watch --once >/dev/null

# Assert dossier was opened in lavish
sleep 0.3
grep -q "$t11_task/report.html" "$T/mock-lavish.log" 2>/dev/null && pass "mock-lavish opened review dossier" || fail "mock-lavish did not open review dossier"

# One open for one ready task, and the session URL it printed is recorded for the
# handover, so the orchestrator has no reason to run the command on the page again.
open_count=$(grep -cxF "$t11_task/report.html" "$T/mock-lavish.log" 2>/dev/null || true)
[ "$open_count" = "1" ] && pass "mock-lavish opened the review dossier exactly once" || fail "mock-lavish recorded $open_count opens of the review dossier"
t11_url="http://127.0.0.1:4387/session/task-lavish-1"
listed_url=$(cat "$t11_task/dossier.url" 2>/dev/null || true)
[ "$listed_url" = "$t11_url" ] && pass "listener recorded the session URL in dossier.url" || fail "dossier.url holds '$listed_url'"

# Assert listener.pid was created and process is running
[ -f "$t11_task/listener.pid" ] && pass "listener.pid created" || fail "listener.pid missing"
lpid=$(cat "$t11_task/listener.pid" 2>/dev/null || true)
[ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && pass "listener process is running (pid $lpid)" || fail "listener process not running"

# Assert kingpin list displays listener status
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "listening: pid $lpid" && pass "kingpin list displays listener pid" || fail "kingpin list missing listener pid: $list_out"

# kingpin list prints the recorded URL, not the command that would open the page again
if printf '%s\n' "$list_out" | grep -F '↳ Review:' | grep -Fq "$t11_url"; then
  pass "kingpin list prints the recorded dossier URL"
else
  fail "kingpin list missing the dossier URL: $list_out"
fi
! printf '%s\n' "$list_out" | grep -Fq "lavish-axi $t11_task/report.html" && pass "kingpin list does not print the opening command for a recorded URL" || fail "kingpin list still prints the opening command: $list_out"

# kingpin list shows the orchestrator lock holder and its harness
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire --harness agy >/dev/null
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "Orchestrator lock: held by pid $$ (agy)" && pass "kingpin list shows lock holder harness" || fail "kingpin list missing lock harness: $list_out"
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock release >/dev/null
list_out=$("$KP_BIN/kingpin" list)
! echo "$list_out" | grep -q "Orchestrator lock" && pass "kingpin list hides the lock line when free" || fail "kingpin list shows lock line when free"

# 3. Simulate Approve & Land feedback via Lavish
cat > "$(resp_file "$t11_task")" << 'RESP'
session:
  status: feedback
prompts[1]{prompt}:
  kingpin land task-lavish-1
RESP

for _ in $(seq 1 30); do
  if [ -f "$t11_task/landing_sent" ] && grep -q "approved:" "$t11_task/status" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

grep -q "approved: by user via lavish dossier" "$t11_task/status" && pass "approved status logged" || fail "approved status missing"
[ -f "$t11_task/landing_sent" ] && pass "landing triggered by listener" || fail "landing not triggered"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:task-lavish-1 -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 401" && pass "/issue-flow-done dispatched on approval" || fail "wrong done command: $pane_out"
grep -q "reply $t11_task/report.html --agent-reply Approval received" "$T/mock-lavish.log" && pass "approval confirmation reply sent to lavish" || fail "approval reply missing"

# 4. Simulate user feedback / Request Changes
t11_task2="$KINGPIN_HOME/tasks/task-lavish-2"
mkdir -p "$t11_task2"
echo "<html><body>Review Dossier 2</body></html>" > "$t11_task2/report.html"
cat > "$t11_task2/task.env" << EOF
TASK_ID=task-lavish-2
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=402
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-2
EOF
tmux new-window -d -t kingpin: -n task-lavish-2 cat
echo "ready: branch=b review=APPROVE report=$t11_task2/report.html" >> "$t11_task2/status"

# No listener has opened this dossier yet, so its list line keeps the command as the
# fallback (issue #146).
list_out=$("$KP_BIN/kingpin" list)
fallback_line=$(printf '%s\n' "$list_out" | grep -F '↳ Review:' | grep -F "$t11_task2/report.html" || true)
[ -n "$fallback_line" ] && printf '%s\n' "$fallback_line" | grep -Fq "lavish-axi $t11_task2/report.html" && pass "kingpin list keeps the opening command when no URL is recorded" || fail "kingpin list lost the fallback command: $list_out"

cat > "$(resp_file "$t11_task2")" << 'RESP'
session:
  status: feedback
prompts[1]:
  - prompt: "Request Changes: please fix line 42 in foo.sh"
    tag: action
RESP

listen_out=$("$KP_BIN/kingpin" listen task-lavish-2 --once)
t11_url2="http://127.0.0.1:4387/session/task-lavish-2"
printf '%s\n' "$listen_out" | grep -Fq "OK: listening on task-lavish-2; dossier $t11_url2" && pass "foreground listen prints the dossier URL" || fail "foreground listen status missing the URL: $listen_out"

[ -f "$t11_task2/feedback.md" ] && pass "feedback.md created" || fail "feedback.md missing"
grep -q "Request Changes: please fix line 42 in foo.sh" "$t11_task2/feedback.md" && pass "feedback text written correctly" || fail "feedback text incorrect"
grep -q "feedback: Request Changes: please fix line 42 in foo.sh" "$t11_task2/status" && pass "feedback status logged" || fail "feedback status missing"
grep -q "reply $t11_task2/report.html --agent-reply Feedback received" "$T/mock-lavish.log" && pass "feedback receipt reply sent to lavish" || fail "feedback reply missing"

# A listener restart keeps the recorded URL and opens nothing new: the marker and the
# URL file survive, and the page is not put back in the browser.
"$KP_BIN/kingpin" listen task-lavish-2 --once >/dev/null
restart_url=$(cat "$t11_task2/dossier.url" 2>/dev/null || true)
[ "$restart_url" = "$t11_url2" ] && pass "dossier.url survives a listener restart" || fail "dossier.url changed on restart: '$restart_url'"
restart_opens=$(grep -cxF "$t11_task2/report.html" "$T/mock-lavish.log" 2>/dev/null || true)
[ "$restart_opens" = "1" ] && pass "listener restart did not reopen the dossier" || fail "listener restart recorded $restart_opens opens"

# A session the server lost is reopened once: the dead URL is dropped, the page is
# opened again, and the URL that open printed replaces it, so `kingpin list` never
# hands over a session that is gone.
printf '%s\n' "http://127.0.0.1:4387/session/task-lavish-2-gone" > "$t11_task2/dossier.url"
printf '%s\n' "NOT_FOUND: no session for $t11_task2/report.html" > "$(resp_file "$t11_task2")"
"$KP_BIN/kingpin" listen task-lavish-2 --once >/dev/null
reopened_url=$(cat "$t11_task2/dossier.url" 2>/dev/null || true)
[ "$reopened_url" = "$t11_url2" ] && pass "listener replaced a lost session URL" || fail "dossier.url still holds '$reopened_url' after a lost session"
reopen_opens=$(grep -cxF "$t11_task2/report.html" "$T/mock-lavish.log" 2>/dev/null || true)
[ "$reopen_opens" = "2" ] && pass "listener reopened a lost session exactly once" || fail "listener recorded $reopen_opens opens after a lost session"
# Issue #145: the listener forwards a dossier message to the capo itself.
sleep 0.3
pane_out=$(tmux capture-pane -pJ -pt kingpin:task-lavish-2 -S -100)
printf '%s\n' "$pane_out" | grep -Fq "The boss wrote this in the review dossier" && pass "feedback forwarded to the worker pane" || fail "feedback was not forwarded: $pane_out"
printf '%s\n' "$pane_out" | grep -Fq "Request Changes: please fix line 42 in foo.sh" && pass "forward carries the reviewer's text" || fail "forward lost the feedback text"
printf '%s\n' "$pane_out" | grep -Fq "do not land in review mode" && pass "forward repeats the review rule" || fail "forward omits the review rule"
n1=$(printf '%s\n' "$pane_out" | grep -cF "The boss wrote this in the review dossier" || true)

# A listener restart with no new prompt must not replay the last one. The pane
# shows each sent line twice (tty echo plus `cat`), so compare the two counts.
"$KP_BIN/kingpin" listen task-lavish-2 --once >/dev/null
sleep 0.3
pane_out=$(tmux capture-pane -pJ -pt kingpin:task-lavish-2 -S -100)
n2=$(printf '%s\n' "$pane_out" | grep -cF "The boss wrote this in the review dossier" || true)
[ "$n1" -ge 1 ] && [ "$n2" = "$n1" ] && pass "listener restart did not forward the prompt twice" || fail "one prompt was forwarded again (before=$n1 after=$n2)"

# A recorded message whose window is gone is not forwarded, and the reason is stated.
t11_nowin="$KINGPIN_HOME/tasks/task-lavish-nowin"
mkdir -p "$t11_nowin"
echo "<html><body>Review Dossier NW</body></html>" > "$t11_nowin/report.html"
cat > "$t11_nowin/task.env" << EOFNW
TASK_ID=task-lavish-nowin
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-nowin
EOFNW
echo "ready: branch=b review=APPROVE report=none" > "$t11_nowin/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  Request Changes: the window is gone" > "$(resp_file "$t11_nowin")"
"$KP_BIN/kingpin" listen task-lavish-nowin --once >/dev/null
grep -Fq "the window is gone" "$t11_nowin/feedback.md" && pass "window gone: feedback recorded" || fail "window gone: feedback missing"
grep -Eq "^feedback: not forwarded: kingpin-send: tmux window .* is not alive" "$t11_nowin/status" && pass "window gone: reason recorded in status" || fail "window gone: no skip reason"
grep -Fq "reply $t11_nowin/report.html --agent-reply Feedback received. Recorded, not forwarded to the worker:" "$T/mock-lavish.log" && pass "window gone: receipt says it was not forwarded" || fail "window gone: receipt claims a forward"
[ ! -f "$t11_nowin/landing_sent" ] && pass "window gone: no landing" || fail "window gone: landing started"
rm -rf "$t11_nowin"

# A task archived while the listener polls is recorded, not forwarded.
t11_arch="$KINGPIN_HOME/tasks/task-lavish-arch"
t11_arch_archive="$KINGPIN_HOME/archive/task-lavish-arch"
mkdir -p "$t11_arch"
echo "<html><body>Review Dossier A</body></html>" > "$t11_arch/report.html"
cat > "$t11_arch/task.env" << EOFA
TASK_ID=task-lavish-arch
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-arch
EOFA
tmux new-window -d -t kingpin: -n task-lavish-arch cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_arch/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  Request Changes: archived feedback text" > "$(resp_file "$t11_arch")"
: > "$T/mock-lavish-gate-task-lavish-arch"
"$KP_BIN/kingpin" listen task-lavish-arch --background
for _ in $(seq 1 40); do
  [ -f "$t11_arch/listener.pid" ] && break
  sleep 0.05
done
arch_pid=$(cat "$t11_arch/listener.pid" 2>/dev/null || true)
# Wait until the listener is inside the gated poll, then archive the task out from under it.
for _ in $(seq 1 40); do
  grep -q "poll $t11_arch/report.html" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.05
done
mkdir -p "$KINGPIN_HOME/archive"
mv "$t11_arch" "$t11_arch_archive"
ln -s "$t11_arch_archive" "$t11_arch"
rm -f "$T/mock-lavish-gate-task-lavish-arch"
for _ in $(seq 1 60); do
  grep -q "^feedback: not forwarded: task is no longer live" "$t11_arch_archive/status" 2>/dev/null && break
  sleep 0.1
done
grep -q "^feedback: not forwarded: task is no longer live" "$t11_arch_archive/status" && pass "archived task: skip reason recorded" || fail "archived task: no skip reason"
grep -Fq "archived feedback text" "$t11_arch_archive/feedback.md" && pass "archived task: feedback kept" || fail "archived task: feedback lost"
pane_out=$(tmux capture-pane -pJ -t kingpin:task-lavish-arch -S -100)
! printf '%s\n' "$pane_out" | grep -Fq "The boss wrote this in the review dossier" && pass "archived task: nothing forwarded" || fail "archived task: feedback was forwarded"
if [ -n "$arch_pid" ]; then
  for _ in $(seq 1 40); do
    kill -0 "$arch_pid" 2>/dev/null || break
    sleep 0.05
  done
fi
rm -f "$t11_arch"
rm -rf "$t11_arch_archive"
tmux kill-window -t kingpin:task-lavish-arch 2>/dev/null || true

# A second listener on a live task prints one line, exits 0 and leaves the first alone.
t11_dup="$KINGPIN_HOME/tasks/task-lavish-dup"
mkdir -p "$t11_dup"
echo "<html><body>Review Dossier D</body></html>" > "$t11_dup/report.html"
cat > "$t11_dup/task.env" << EOFD
TASK_ID=task-lavish-dup
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-dup
EOFD
tmux new-window -d -t kingpin: -n task-lavish-dup cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_dup/status"
# Queue real work before either listener starts, then hold the first listener
# inside its poll. The pair races on a pending prompt, not on an empty dossier,
# and the duplicate's invocation has a clean window in which a poll would show.
dup_prompt="Request Changes: duplicate race prompt"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"$dup_prompt\"" "    tag: action" > "$(resp_file "$t11_dup")"
: > "$T/mock-lavish-gate-task-lavish-dup"
"$KP_BIN/kingpin" listen task-lavish-dup --background
for _ in $(seq 1 40); do
  [ -f "$t11_dup/listener.pid" ] && break
  sleep 0.05
done
dup_pid=$(cat "$t11_dup/listener.pid" 2>/dev/null || true)
# Wait until the first listener is inside the gated poll, so no other poll can
# change the counts below while the duplicate runs.
for _ in $(seq 1 40); do
  grep -qF "poll $t11_dup/report.html" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.05
done
dup_polls=$(grep -cF "poll $t11_dup/report.html" "$T/mock-lavish.log" || true)
dup_replies=$(grep -cF "reply $t11_dup/report.html --agent-reply " "$T/mock-lavish.log" || true)
sleep 0.2
dup_rc=0
# Bound the duplicate: a lost refusal polls into the held gate, and without a
# timeout that wedges the suite instead of reporting an assertion (review L1).
dup_out=$(timeout 10 "$KP_BIN/kingpin" listen task-lavish-dup --once 2>&1) || dup_rc=$?
if [ "$dup_rc" -eq 124 ]; then
  # Release the gate so the stuck poll and the first listener can finish, then fail.
  rm -f "$T/mock-lavish-gate-task-lavish-dup"
  fail "duplicate listener hung in a poll; timeout 10 killed it"
elif [ "$dup_rc" -eq 0 ]; then
  pass "duplicate listener exits 0"
else
  fail "duplicate listener exited $dup_rc: $dup_out"
fi
n=$(printf '%s\n' "$dup_out" | grep -c . || true)
[ "$n" = "1" ] && pass "duplicate listener prints one line" || fail "duplicate listener printed $n lines: $dup_out"
printf '%s\n' "$dup_out" | grep -q "already has a live listener (pid $dup_pid)" && pass "duplicate listener names the live pid" || fail "duplicate listener output: $dup_out"
[ "$(cat "$t11_dup/listener.pid" 2>/dev/null || true)" = "$dup_pid" ] && pass "duplicate left listener.pid with the first listener" || fail "duplicate overwrote listener.pid"
[ "$(head -n 1 "$t11_dup/listener.owner" 2>/dev/null || true)" = "$dup_pid" ] && pass "duplicate left the owner with the first listener" || fail "duplicate took the owner"
# L5: the --background launcher refuses a live task with the same one line.
dup_bg_rc=0
dup_bg_out=$(timeout 10 "$KP_BIN/kingpin" listen task-lavish-dup --background 2>&1) || dup_bg_rc=$?
[ "$dup_bg_rc" -eq 0 ] && pass "background duplicate exits 0" || fail "background duplicate exited $dup_bg_rc"
n=$(printf '%s\n' "$dup_bg_out" | grep -c . || true)
[ "$n" = "1" ] && pass "background duplicate prints one line" || fail "background duplicate printed $n lines: $dup_bg_out"
printf '%s\n' "$dup_bg_out" | grep -q "already has a live listener (pid $dup_pid)" && pass "background duplicate names the live pid" || fail "background duplicate output: $dup_bg_out"

# The duplicate neither polled nor replied, and the queued prompt is still pending.
n=$(grep -cF "poll $t11_dup/report.html" "$T/mock-lavish.log" || true)
[ "$n" = "$dup_polls" ] && pass "duplicate listener did not poll the dossier" || fail "duplicate added $((n - dup_polls)) poll(s)"
n=$(grep -cF "reply $t11_dup/report.html --agent-reply " "$T/mock-lavish.log" || true)
[ "$n" = "$dup_replies" ] && pass "duplicate listener did not reply to the dossier" || fail "duplicate added $((n - dup_replies)) reply(ies)"
[ -f "$(resp_file "$t11_dup")" ] && pass "duplicate left the queued prompt for the first listener" || fail "duplicate consumed the queued prompt"

# Release the first listener and let it handle the one queued prompt.
rm -f "$T/mock-lavish-gate-task-lavish-dup"
for _ in $(seq 1 60); do
  grep -Fq "$dup_prompt" "$t11_dup/feedback.md" 2>/dev/null \
    && [ "$(grep -cF "reply $t11_dup/report.html --agent-reply " "$T/mock-lavish.log" || true)" -ge 1 ] \
    && break
  sleep 0.1
done
n=$(grep -cF "$dup_prompt" "$t11_dup/feedback.md" || true)
[ "$n" = "1" ] && pass "queued prompt recorded once in feedback.md" || fail "queued prompt recorded $n times"
[ ! -f "$(resp_file "$t11_dup")" ] && pass "queued prompt consumed once" || fail "queued prompt left behind"
sleep 0.3
pane_out=$(tmux capture-pane -pJ -pt kingpin:task-lavish-dup -S -100)
# A `cat` window shows each sent line twice: once as the tty echo, once as cat output.
n=$(printf '%s\n' "$pane_out" | grep -cF "The boss wrote this in the review dossier" || true)
[ "$n" = "2" ] && pass "queued prompt forwarded to the pane once" || fail "queued prompt forwarded $((n / 2)) time(s)"
n=$(grep -cF "reply $t11_dup/report.html --agent-reply " "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "surviving listener replied to the dossier exactly once" || fail "dossier received $n replies"
sleep 0.3
n=$(grep -cF "reply $t11_dup/report.html --agent-reply " "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "no second reply after the duplicate exited" || fail "a later reply left the dossier in Working ($n replies)"

kill -- "-$dup_pid" 2>/dev/null || kill "$dup_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$dup_pid" 2>/dev/null || break
  sleep 0.05
done
[ ! -f "$t11_dup/listener.owner" ] && [ ! -f "$t11_dup/listener.pid" ] && pass "stopped listener cleared owner and pid" || fail "stopped listener left owner or pid"
# A listener killed before its trap ran leaves a dead pid: the next run reclaims it.
printf '999999\n' > "$t11_dup/listener.owner"
"$KP_BIN/kingpin" listen task-lavish-dup --once >/dev/null
[ ! -f "$t11_dup/listener.owner" ] && pass "stale owner reclaimed and released" || fail "stale owner left behind"
tmux kill-window -t kingpin:task-lavish-dup 2>/dev/null || true
rm -rf "$t11_dup"

# A listener started before this change records only listener.pid (issue #145): the
# next foreground listener refuses it, adopts its pid into the owner file, and leaves
# the running poll and listener.pid alone.
t11_old="$KINGPIN_HOME/tasks/task-lavish-legacy"
mkdir -p "$t11_old"
echo "<html><body>Review Dossier L</body></html>" > "$t11_old/report.html"
cat > "$t11_old/task.env" << EOFL
TASK_ID=task-lavish-legacy
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-legacy
EOFL
tmux new-window -d -t kingpin: -n task-lavish-legacy cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_old/status"
: > "$T/mock-lavish-gate-task-lavish-legacy"
"$KP_BIN/kingpin" listen task-lavish-legacy --background
for _ in $(seq 1 40); do
  [ -f "$t11_old/listener.poll" ] && break
  sleep 0.05
done
old_pid=$(cat "$t11_old/listener.pid" 2>/dev/null || true)
old_poll=$(cut -d' ' -f1 "$t11_old/listener.poll" 2>/dev/null || true)
polls_before=$(grep -cF "poll $t11_old/report.html" "$T/mock-lavish.log" || true)
replies_before=$(grep -cF "reply $t11_old/report.html --agent-reply " "$T/mock-lavish.log" || true)
# Drop the owner file: this is exactly the record an older listener leaves behind.
rm -f "$t11_old/listener.owner"
old_rc=0
old_out=$(timeout 10 "$KP_BIN/kingpin" listen task-lavish-legacy --once 2>&1) || old_rc=$?
if [ "$old_rc" -eq 124 ]; then
  rm -f "$T/mock-lavish-gate-task-lavish-legacy"
  fail "pid-only listener: duplicate hung in a poll; timeout 10 killed it"
elif [ "$old_rc" -eq 0 ]; then
  pass "pid-only listener: duplicate exits 0"
else
  fail "pid-only listener: duplicate exited $old_rc: $old_out"
fi
n=$(printf '%s\n' "$old_out" | grep -c . || true)
[ "$n" = "1" ] && pass "pid-only listener: duplicate prints one line" || fail "pid-only listener: duplicate printed $n lines: $old_out"
printf '%s\n' "$old_out" | grep -q "already has a live listener (pid $old_pid)" && pass "pid-only listener: duplicate names the live pid" || fail "pid-only listener output: $old_out"
[ "$(head -n 1 "$t11_old/listener.owner" 2>/dev/null || true)" = "$old_pid" ] && pass "pid-only listener: owner file adopted the live pid" || fail "pid-only listener: owner file not written"
[ "$(cat "$t11_old/listener.pid" 2>/dev/null || true)" = "$old_pid" ] && pass "pid-only listener: listener.pid left with the first listener" || fail "pid-only listener: duplicate overwrote listener.pid"
kill -0 "$old_poll" 2>/dev/null && pass "pid-only listener: duplicate left the first poll running" || fail "pid-only listener: duplicate stopped the first poll"
n=$(grep -cF "poll $t11_old/report.html" "$T/mock-lavish.log" || true)
[ "$n" = "$polls_before" ] && pass "pid-only listener: duplicate did not poll" || fail "pid-only listener: duplicate added $((n - polls_before)) poll(s)"
n=$(grep -cF "reply $t11_old/report.html --agent-reply " "$T/mock-lavish.log" || true)
[ "$n" = "$replies_before" ] && pass "pid-only listener: duplicate did not reply" || fail "pid-only listener: duplicate added $((n - replies_before)) reply(ies)"
rm -f "$T/mock-lavish-gate-task-lavish-legacy"
kill -- "-$old_pid" 2>/dev/null || kill "$old_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$old_pid" 2>/dev/null || break
  sleep 0.05
done
[ ! -f "$t11_old/listener.owner" ] && [ ! -f "$t11_old/listener.pid" ] && pass "pid-only listener: cleanup cleared owner and pid" || fail "pid-only listener: stopped listener left owner or pid"
tmux kill-window -t kingpin:task-lavish-legacy 2>/dev/null || true
rm -rf "$t11_old"

# Issue #147: a pointer reply clears the dossier's Working state when the capo reports.
t11_ans="$KINGPIN_HOME/tasks/task-lavish-answer"
mkdir -p "$t11_ans"
echo "<html><body>Review Dossier AN</body></html>" > "$t11_ans/report.html"
cat > "$t11_ans/task.env" << EOFAN
TASK_ID=task-lavish-answer
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-answer
EOFAN
tmux new-window -d -t kingpin: -n task-lavish-answer cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_ans/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"Request Changes: answer pointer prompt\"" "    tag: action" > "$(resp_file "$t11_ans")"
KINGPIN_LISTEN_ANSWER_TIMEOUT=5 "$KP_BIN/kingpin" listen task-lavish-answer --background
for _ in $(seq 1 60); do
  [ -s "$t11_ans/answer.pending" ] && break
  sleep 0.1
done
ans_pid=$(cat "$t11_ans/listener.pid" 2>/dev/null || true)
ans_pointer="reply $t11_ans/report.html --agent-reply The capo updated the page; open it to read the answer"
# The capo's next worker event is what clears Working.
printf 'waiting: needs-input %s\n' "$T/answer-question.md" >> "$t11_ans/status"
for _ in $(seq 1 60); do
  grep -Fq "$ans_pointer" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.1
done
n=$(grep -cF "$ans_pointer" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "answer watcher posts one pointer reply when the capo reports" || fail "pointer replies: $n"
grep -q "waiting: needs-input" "$t11_ans/answer.done" && pass "answer marker records the answered status line" || fail "answer marker missing the status line"
# A restart must not repeat the pointer for the same answer.
kill -- "-$ans_pid" 2>/dev/null || kill "$ans_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$ans_pid" 2>/dev/null || break
  sleep 0.05
done
KINGPIN_LISTEN_ANSWER_TIMEOUT=5 "$KP_BIN/kingpin" listen task-lavish-answer --background
for _ in $(seq 1 40); do
  ans_new=$(cat "$t11_ans/listener.pid" 2>/dev/null || true)
  [ -n "$ans_new" ] && [ "$ans_new" != "$ans_pid" ] && break
  sleep 0.05
done
sleep 0.5
n=$(grep -cF "$ans_pointer" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "listener restart does not post a second pointer" || fail "pointer replies after restart: $n"
# H3: the Stop hook writes the same `waiting:` line at the end of every turn, so a
# second round answered by an identical line must still post its own pointer.
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"Request Changes: second answer pointer prompt\"" "    tag: action" > "$(resp_file "$t11_ans")"
for _ in $(seq 1 80); do
  [ "$(grep -c . "$t11_ans/answer.pending" 2>/dev/null || true)" -ge 2 ] && break
  sleep 0.1
done
printf 'waiting: needs-input %s\n' "$T/answer-question.md" >> "$t11_ans/status"
for _ in $(seq 1 80); do
  [ "$(grep -cF "$ans_pointer" "$T/mock-lavish.log" || true)" -ge 2 ] && break
  sleep 0.1
done
n=$(grep -cF "$ans_pointer" "$T/mock-lavish.log" || true)
[ "$n" = "2" ] && pass "a repeated status line answers the next prompt with its own pointer" || fail "pointer replies after a repeated line: $n"
kill -- "-$ans_new" 2>/dev/null || kill "$ans_new" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$ans_new" 2>/dev/null || break
  sleep 0.05
done
tmux kill-window -t kingpin:task-lavish-answer 2>/dev/null || true
rm -rf "$t11_ans"

# Issue #147: with no status move, one "still working" reply follows the timeout.
t11_to="$KINGPIN_HOME/tasks/task-lavish-timeout"
mkdir -p "$t11_to"
echo "<html><body>Review Dossier TO</body></html>" > "$t11_to/report.html"
cat > "$t11_to/task.env" << EOFTO
TASK_ID=task-lavish-timeout
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-timeout
EOFTO
tmux new-window -d -t kingpin: -n task-lavish-timeout cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_to/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"Request Changes: timeout prompt\"" "    tag: action" > "$(resp_file "$t11_to")"
KINGPIN_LISTEN_ANSWER_TIMEOUT=1 "$KP_BIN/kingpin" listen task-lavish-timeout --background
for _ in $(seq 1 60); do
  grep -Fq "still working" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.1
done
to_pid=$(cat "$t11_to/listener.pid" 2>/dev/null || true)
to_reply="reply $t11_to/report.html --agent-reply The capo is still working; the answer will appear on the page."
n=$(grep -cF "$to_reply" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "timeout posts one still-working reply" || fail "still-working replies: $n"
sleep 1.2
n=$(grep -cF "$to_reply" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "timeout reply is not repeated for the same prompt" || fail "still-working replies after another interval: $n"
# H2: the timeout marker retires only the "still working" line, not the prompt, so
# a capo that answers after the timeout still gets its pointer.
printf 'ready: branch=b review=APPROVE report=none\n' >> "$t11_to/status"
to_pointer="reply $t11_to/report.html --agent-reply The capo updated the page; open it to read the answer"
for _ in $(seq 1 60); do
  grep -Fq "$to_pointer" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.1
done
n=$(grep -cF "$to_pointer" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "answer after the timeout still posts the pointer" || fail "pointer replies after the timeout: $n"
kill -- "-$to_pid" 2>/dev/null || kill "$to_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$to_pid" 2>/dev/null || break
  sleep 0.05
done
KINGPIN_LISTEN_ANSWER_TIMEOUT=1 "$KP_BIN/kingpin" listen task-lavish-timeout --background
for _ in $(seq 1 40); do
  to_new=$(cat "$t11_to/listener.pid" 2>/dev/null || true)
  [ -n "$to_new" ] && [ "$to_new" != "$to_pid" ] && break
  sleep 0.05
done
sleep 1.2
n=$(grep -cF "$to_reply" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "restart does not repeat the still-working reply" || fail "still-working replies after restart: $n"
kill -- "-$to_new" 2>/dev/null || kill "$to_new" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$to_new" 2>/dev/null || break
  sleep 0.05
done
tmux kill-window -t kingpin:task-lavish-timeout 2>/dev/null || true
rm -rf "$t11_to"

# M1: a reply Lavish refuses is not recorded as delivered, and the watcher retries.
t11_mfail="$KINGPIN_HOME/tasks/task-lavish-replyfail"
mkdir -p "$t11_mfail"
echo "<html><body>Review Dossier RF</body></html>" > "$t11_mfail/report.html"
cat > "$t11_mfail/task.env" << EOFRF
TASK_ID=task-lavish-replyfail
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-replyfail
EOFRF
tmux new-window -d -t kingpin: -n task-lavish-replyfail cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_mfail/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"Request Changes: reply failure prompt\"" "    tag: action" > "$(resp_file "$t11_mfail")"
KINGPIN_LISTEN_ANSWER_TIMEOUT=30 "$KP_BIN/kingpin" listen task-lavish-replyfail --background
for _ in $(seq 1 60); do
  grep -Fq "reply $t11_mfail/report.html --agent-reply Feedback received" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.1
done
mfail_pid=$(cat "$t11_mfail/listener.pid" 2>/dev/null || true)
mfail_pointer="reply $t11_mfail/report.html --agent-reply The capo updated the page; open it to read the answer"
# Refuse the next pointer reply once; the receipt above was already delivered.
printf '1\n' > "$T/mock-lavish-fail-reply-task-lavish-replyfail"
printf 'ready: branch=b review=APPROVE report=none\n' >> "$t11_mfail/status"
for _ in $(seq 1 60); do
  [ -f "$t11_mfail/answer.done" ] && grep -qE '^answered[[:space:]]' "$t11_mfail/answer.done" && break
  sleep 0.1
done
grep -qE '^answered[[:space:]]' "$t11_mfail/answer.done" 2>/dev/null && pass "refused pointer is marked answered only after a successful retry" || fail "refused pointer: no answered marker after the retry"
n=$(grep -cF "$mfail_pointer" "$T/mock-lavish.log" || true)
[ "$n" = "2" ] && pass "refused pointer is retried exactly once" || fail "pointer attempts after a refusal: $n"
n=$(grep -cF "refused: reply" "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "mock refused the first pointer reply" || fail "mock refusals: $n"
kill -- "-$mfail_pid" 2>/dev/null || kill "$mfail_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$mfail_pid" 2>/dev/null || break
  sleep 0.05
done
tmux kill-window -t kingpin:task-lavish-replyfail 2>/dev/null || true
rm -rf "$t11_mfail"

# M1: the timeout line follows the same rule; a refusal leaves it retryable.
t11_tfail="$KINGPIN_HOME/tasks/task-lavish-tmoutfail"
mkdir -p "$t11_tfail"
echo "<html><body>Review Dossier TF</body></html>" > "$t11_tfail/report.html"
cat > "$t11_tfail/task.env" << EOFTF
TASK_ID=task-lavish-tmoutfail
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-tmoutfail
EOFTF
tmux new-window -d -t kingpin: -n task-lavish-tmoutfail cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_tfail/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"Request Changes: timeout failure prompt\"" "    tag: action" > "$(resp_file "$t11_tfail")"
KINGPIN_LISTEN_ANSWER_TIMEOUT=1 "$KP_BIN/kingpin" listen task-lavish-tmoutfail --background
for _ in $(seq 1 60); do
  grep -Fq "reply $t11_tfail/report.html --agent-reply Feedback received" "$T/mock-lavish.log" 2>/dev/null && break
  sleep 0.1
done
tfail_pid=$(cat "$t11_tfail/listener.pid" 2>/dev/null || true)
tfail_reply="reply $t11_tfail/report.html --agent-reply The capo is still working; the answer will appear on the page."
printf '1\n' > "$T/mock-lavish-fail-reply-task-lavish-tmoutfail"
for _ in $(seq 1 80); do
  [ -f "$t11_tfail/answer.done" ] && grep -qE '^still-working[[:space:]]' "$t11_tfail/answer.done" && break
  sleep 0.1
done
grep -qE '^still-working[[:space:]]' "$t11_tfail/answer.done" 2>/dev/null && pass "refused timeout line is marked only after a successful retry" || fail "refused timeout line: no still-working marker after the retry"
n=$(grep -cF "$tfail_reply" "$T/mock-lavish.log" || true)
[ "$n" = "2" ] && pass "refused timeout line is retried exactly once" || fail "timeout attempts after a refusal: $n"
kill -- "-$tfail_pid" 2>/dev/null || kill "$tfail_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$tfail_pid" 2>/dev/null || break
  sleep 0.05
done
tmux kill-window -t kingpin:task-lavish-tmoutfail 2>/dev/null || true
rm -rf "$t11_tfail"

# kp-94: a killed listener's poll child must not own the session; the replacement does.
t11_orph="$KINGPIN_HOME/tasks/task-lavish-orphan"
mkdir -p "$t11_orph"
echo "<html><body>Review Dossier OR</body></html>" > "$t11_orph/report.html"
cat > "$t11_orph/task.env" << EOFO
TASK_ID=task-lavish-orphan
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-orphan
EOFO
tmux new-window -d -t kingpin: -n task-lavish-orphan cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_orph/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - prompt: \"Request Changes: orphan poll prompt\"" "    tag: action" > "$(resp_file "$t11_orph")"
: > "$T/mock-lavish-gate-task-lavish-orphan"
"$KP_BIN/kingpin" listen task-lavish-orphan --background
for _ in $(seq 1 40); do
  [ -f "$t11_orph/listener.poll" ] && break
  sleep 0.05
done
orph_old_pid=$(cat "$t11_orph/listener.pid" 2>/dev/null || true)
orph_poll=$(cut -d' ' -f1 "$t11_orph/listener.poll" 2>/dev/null || true)
polls_before=$(grep -cF "poll $t11_orph/report.html" "$T/mock-lavish.log" || true)
# Kill only the listener: its setsid'd poll child survives, still owning the session.
kill -KILL "$orph_old_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$orph_old_pid" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$orph_poll" 2>/dev/null && pass "killed listener left its poll child running" || fail "poll child died with the killed listener"
# The replacement stops that group before it starts polling.
"$KP_BIN/kingpin" listen task-lavish-orphan --background
for _ in $(seq 1 60); do
  orph_new_pid=$(cat "$t11_orph/listener.pid" 2>/dev/null || true)
  [ -n "$orph_new_pid" ] && [ "$orph_new_pid" != "$orph_old_pid" ] && break
  sleep 0.05
done
for _ in $(seq 1 40); do
  kill -0 "$orph_poll" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$orph_poll" 2>/dev/null && fail "replacement left the orphan poll running" || pass "replacement stopped the orphan poll group"
rm -f "$T/mock-lavish-gate-task-lavish-orphan"
for _ in $(seq 1 60); do
  grep -Fq "orphan poll prompt" "$t11_orph/feedback.md" 2>/dev/null && break
  sleep 0.1
done
grep -Fq "orphan poll prompt" "$t11_orph/feedback.md" && pass "replacement listener receives the queued prompt" || fail "prompt was swallowed by the orphan poll"
[ ! -f "$(resp_file "$t11_orph")" ] && pass "queued prompt consumed by the replacement" || fail "queued prompt left behind"
n=$(grep -cF "poll $t11_orph/report.html" "$T/mock-lavish.log" || true)
[ "$n" -gt "$polls_before" ] && pass "replacement started its own poll" || fail "replacement poll not recorded"
sleep 0.3
pane_out=$(tmux capture-pane -pJ -pt kingpin:task-lavish-orphan -S -100)
n=$(printf '%s\n' "$pane_out" | grep -cF "The boss wrote this in the review dossier" || true)
[ "$n" = "2" ] && pass "replacement forwarded the prompt once" || fail "replacement forwarded $((n / 2)) time(s)"
kill -- "-$orph_new_pid" 2>/dev/null || kill "$orph_new_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$orph_new_pid" 2>/dev/null || break
  sleep 0.05
done
tmux kill-window -t kingpin:task-lavish-orphan 2>/dev/null || true
rm -rf "$t11_orph"

# Negative feedback that mentions "approve" is feedback, not an approval
t11_task3="$KINGPIN_HOME/tasks/task-lavish-3"
mkdir -p "$t11_task3"
echo "<html><body>Review Dossier 3</body></html>" > "$t11_task3/report.html"
cat > "$t11_task3/task.env" << EOF3
TASK_ID=task-lavish-3
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=403
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-3
EOF3
echo "ready: branch=b review=APPROVE report=none" >> "$t11_task3/status"
cat > "$(resp_file "$t11_task3")" << 'RESP'
session:
  status: feedback
prompts[2]{prompt,tag}:
  "cannot approve until tests pass",action
  "Request Changes: do not approve yet",action
RESP
"$KP_BIN/kingpin" listen task-lavish-3 --once >/dev/null
[ ! -f "$t11_task3/landing_sent" ] && pass "negative feedback mentioning approve did not land" || fail "negative feedback triggered landing"
! grep -q "^approved:" "$t11_task3/status" && pass "negative feedback not logged as approval" || fail "negative feedback logged as approval"
grep -q "cannot approve until tests pass" "$t11_task3/feedback.md" && grep -q "do not approve yet" "$t11_task3/feedback.md" && pass "both negative prompts kept as feedback" || fail "negative prompts missing from feedback.md"
rm -rf "$t11_task3"

# Listener notes after the worker's ready: line must not bypass the review gate
t11_gate="$KINGPIN_HOME/tasks/task-lavish-gate"
mkdir -p "$t11_gate"
cat > "$t11_gate/task.env" << EOF4
TASK_ID=task-lavish-gate
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=404
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-gate
EOF4
tmux new-window -d -t kingpin: -n task-lavish-gate cat
printf '%s\n' "ready: branch=b review=NEEDS CHANGES report=.agents/reviews/r9.md" "feedback: Request Changes: please rename foo" "approved: by user via lavish dossier" > "$t11_gate/status"
"$KP_BIN/kingpin" land task-lavish-gate >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:task-lavish-gate -S -5)
echo "$pane_out" | grep -q "/fix-findings $T/proj/.agents/reviews/r9.md" && pass "feedback/approved notes do not bypass the fix-findings gate" || fail "gate bypassed after listener notes: $pane_out"
[ ! -f "$t11_gate/landing_sent" ] && pass "no landing dispatched for NEEDS CHANGES after listener notes" || fail "landing dispatched despite NEEDS CHANGES"
tmux kill-window -t kingpin:task-lavish-gate 2>/dev/null || true
rm -rf "$t11_gate"

# Approve & Land on a task that is not review-ready lands nothing and records no approval
t11_state="$KINGPIN_HOME/tasks/task-lavish-state"
mkdir -p "$t11_state"
rm -f "$KINGPIN_HOME/projects/demo-state.landing" "$KINGPIN_HOME/projects/demo-state.landing_queue"
echo "<html><body>Review Dossier S</body></html>" > "$t11_state/report.html"
cat > "$t11_state/task.env" << EOF8
TASK_ID=task-lavish-state
PROJECT=demo-state
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=406
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-state
EOF8
printf '%s\n' "ready: branch=b review=APPROVE report=none" "needs-input: which API shape?" > "$t11_state/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-state" > "$(resp_file "$t11_state")"
"$KP_BIN/kingpin" listen task-lavish-state --once >/dev/null
[ ! -f "$t11_state/landing_sent" ] && pass "approve on needs-input: did not land" || fail "approve on needs-input: landed"
! grep -q "^approved:" "$t11_state/status" && pass "approve on needs-input: recorded no approved: note" || fail "approve on needs-input: logged an approval"
grep -Fq "not ready to land (last event: needs-input: which API shape?)" "$T/mock-lavish.log" && pass "approve on needs-input: reply names the current state" || fail "approve on needs-input: reply does not name the state"
rm -f "$KINGPIN_HOME/projects/demo-state.landing" "$KINGPIN_HOME/projects/demo-state.landing_queue"
rm -rf "$t11_state"

# Approve & Land on a ready: line the gate cannot parse: refused, no approval note
t11_unknown="$KINGPIN_HOME/tasks/task-lavish-unknown"
mkdir -p "$t11_unknown"
rm -f "$KINGPIN_HOME/projects/demo-unknown.landing" "$KINGPIN_HOME/projects/demo-unknown.landing_queue"
echo "<html><body>Review Dossier U</body></html>" > "$t11_unknown/report.html"
cat > "$t11_unknown/task.env" << EOF9
TASK_ID=task-lavish-unknown
PROJECT=demo-unknown
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=407
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-unknown
EOF9
printf '%s\n' "ready: branch=b review=LGTM report=r.md" > "$t11_unknown/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-unknown" > "$(resp_file "$t11_unknown")"
"$KP_BIN/kingpin" listen task-lavish-unknown --once >/dev/null
[ ! -f "$t11_unknown/landing_sent" ] && pass "approve on an unreadable verdict: did not land" || fail "approve on an unreadable verdict: landed"
! grep -q "^approved:" "$t11_unknown/status" && pass "approve on an unreadable verdict: recorded no approved: note" || fail "approve on an unreadable verdict: logged an approval"
grep -Fq "Not landing. kingpin-land" "$T/mock-lavish.log" && grep -Fq "review=LGTM report=r.md" "$T/mock-lavish.log" && pass "approve on an unreadable verdict: reply carries the gate's refusal" || fail "approve on an unreadable verdict: refusal reply missing"
rm -f "$KINGPIN_HOME/projects/demo-unknown.landing" "$KINGPIN_HOME/projects/demo-unknown.landing_queue"
rm -rf "$t11_unknown"

# Repeat Approve while a fix pass is pending does not resend /fix-findings
t11_rep="$KINGPIN_HOME/tasks/task-lavish-repeat"
mkdir -p "$t11_rep"
echo "<html><body>Review Dossier R</body></html>" > "$t11_rep/report.html"
cat > "$t11_rep/task.env" << EOF5
TASK_ID=task-lavish-repeat
PROJECT=demo-repeat
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
ISSUE=405
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-repeat
EOF5
tmux new-window -d -t kingpin: -n task-lavish-repeat cat
echo "ready: branch=b review=NEEDS CHANGES report=.agents/reviews/r5.md" > "$t11_rep/status"
approve_resp() {
  printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-repeat" > "$(resp_file "$t11_rep")"
}
count_fix() { tmux capture-pane -pt kingpin:task-lavish-repeat -S -50 | grep -c "^/fix-findings "; }
approve_resp; "$KP_BIN/kingpin" listen task-lavish-repeat --once >/dev/null
sleep 0.1
n1=$(count_fix)
approve_resp; "$KP_BIN/kingpin" listen task-lavish-repeat --once >/dev/null
sleep 0.1
n2=$(count_fix)
[ "$n1" -ge 1 ] && [ "$n1" = "$n2" ] && pass "repeat Approve did not resend /fix-findings" || fail "/fix-findings lines: first=$n1 after repeat=$n2"
grep -q "Approval already received" "$T/mock-lavish.log" && pass "repeat Approve answered with a waiting reply" || fail "waiting reply missing"
echo "fixed: high=0 report=.agents/reviews/r5.md" >> "$t11_rep/status"
approve_resp; "$KP_BIN/kingpin" listen task-lavish-repeat --once >/dev/null
[ -f "$t11_rep/landing_sent" ] && pass "Approve after the worker's new event lands" || fail "landing not started after fixed:"
tmux kill-window -t kingpin:task-lavish-repeat 2>/dev/null || true
rm -rf "$t11_rep"
rm -f "$KINGPIN_HOME/projects/demo-repeat.landing" "$KINGPIN_HOME/projects/demo-repeat.landing_queue"

# Concurrent background launches start exactly one listener
t11_race="$KINGPIN_HOME/tasks/task-lavish-race"
mkdir -p "$t11_race"
echo "<html><body>Review Dossier Q</body></html>" > "$t11_race/report.html"
cat > "$t11_race/task.env" << EOF6
TASK_ID=task-lavish-race
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF6
echo "ready: branch=b review=APPROVE report=none" > "$t11_race/status"
for _ in 1 2 3 4; do "$KP_BIN/kingpin" listen task-lavish-race --background & done
wait
sleep 0.3
n=$(pgrep -f "^bash .*/kingpin-listen task-lavish-race$" | wc -l)
[ "$n" = "1" ] && pass "concurrent launches started one listener" || fail "$n listeners running"
rpid=$(cat "$t11_race/listener.pid" 2>/dev/null || true)
[ -n "$rpid" ] && { kill -- "-$rpid" 2>/dev/null || kill "$rpid" 2>/dev/null || true; }
sleep 0.2
[ ! -d "$t11_race/listener.lock" ] && pass "launch lock released" || fail "launch lock left behind"
rm -rf "$t11_race"

# The parser's fallback reads the compact table and both expanded prompt shapes.
# Output goes to a file: `grep -q` exits on the first match, and the resulting
# SIGPIPE in the decoder pipeline would trip `set -o pipefail`.
parsed_prompts "$FIX/compact-with-header.txt" > "$T/prompts.out"
n=$(wc -l < "$T/prompts.out")
[ "$n" = "2" ] && grep -Fxq "please widen the verdict table cell" "$T/prompts.out" && grep -Fxq "Request Changes: rename the helper" "$T/prompts.out" && pass "parser: compact table keeps its prompts" || fail "parser: compact table lost prompts ($n)"

parsed_prompts "$FIX/expanded-with-target.txt" > "$T/prompts.out"
n=$(wc -l < "$T/prompts.out")
[ "$n" = "1" ] && grep -Fxq "same issue here" "$T/prompts.out" && pass "parser: expanded prompt with target: is one prompt" || fail "parser: expanded prompt with target: yielded $n prompts"

parsed_prompts "$FIX/expanded-empty-uid.txt" > "$T/prompts.out"
n=$(wc -l < "$T/prompts.out")
[ "$n" = "1" ] && grep -Fxq "the freeform message that carries no element target" "$T/prompts.out" && pass "parser: expanded prompt with empty uid parses" || fail "parser: expanded prompt with empty uid yielded $n prompts"

# An expanded item with element text but no prompt: is not the reviewer's message
parsed_prompts "$FIX/expanded-text-no-prompt.txt" > "$T/prompts.out"
n=$(wc -l < "$T/prompts.out")
[ "$n" = "0" ] && pass "parser: expanded item with text: but no prompt: is not feedback" || fail "parser: expanded text leaked $n feedback line(s)"

# The exact response captured from kp-102, dom_snapshot: and all
parsed_prompts "$FIX/poll-kp-102-response.txt" > "$T/prompts.out"
n=$(wc -l < "$T/prompts.out")
[ "$n" = "2" ] && grep -Fxq "same issue here" "$T/prompts.out" && grep -Fxq "the text doesnt fit into the box make sure this doesnt happen anymore in future. tell the orchestrator to file an issue or do whatever it gets fixed okay?" "$T/prompts.out" && pass "parser: kp-102 capture keeps both prompts" || fail "parser: kp-102 capture yielded $n prompts"

# A decoder that throws still leaves the fallback in charge
mkdir -p "$T/lavish-stub/bin" "$T/lavish-stub/node_modules/@toon-format/toon/dist"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/lavish-stub/bin/lavish-axi"
chmod +x "$T/lavish-stub/bin/lavish-axi"
printf 'export function decode() { throw new Error("decoder exploded"); }\n' > "$T/lavish-stub/node_modules/@toon-format/toon/dist/index.mjs"
parsed_prompts "$FIX/poll-kp-102-response.txt" "$T/lavish-stub/bin/lavish-axi" > "$T/prompts.out"
n=$(wc -l < "$T/prompts.out")
[ "$n" = "2" ] && pass "parser: a decoder that throws still delivers both prompts" || fail "parser: throwing decoder yielded $n prompts"

# The listener delivers the kp-102 capture end to end, without asking for a resend
t11_kp102="$KINGPIN_HOME/tasks/task-lavish-kp102"
mkdir -p "$t11_kp102"
echo "<html><body>Review Dossier K</body></html>" > "$t11_kp102/report.html"
cat > "$t11_kp102/task.env" << EOF10
TASK_ID=task-lavish-kp102
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF10
echo "ready: branch=b review=APPROVE report=none" > "$t11_kp102/status"
cp "$FIX/poll-kp-102-response.txt" "$(resp_file "$t11_kp102")"
"$KP_BIN/kingpin" listen task-lavish-kp102 --once >/dev/null
grep -Fq "same issue here" "$t11_kp102/feedback.md" && grep -Fq "the text doesnt fit into the box" "$t11_kp102/feedback.md" && pass "listener: kp-102 capture delivered both prompts" || fail "listener: kp-102 capture lost prompts"
grep -q "^feedback: same issue here" "$t11_kp102/status" && pass "listener: kp-102 feedback note written" || fail "listener: kp-102 feedback note missing"
! grep -Fq "reply $t11_kp102/report.html --agent-reply I could not read" "$T/mock-lavish.log" && pass "listener: kp-102 reviewer not asked to resend" || fail "listener: kp-102 reviewer asked to resend"
[ -z "$(parked_file "$t11_kp102")" ] && pass "listener: kp-102 response needed no parking" || fail "listener: kp-102 response was parked"
rm -rf "$t11_kp102"

# L3: a multi-line prompt is forwarded as one operational line, while feedback.md
# keeps the text verbatim.
t11_ml="$KINGPIN_HOME/tasks/task-lavish-multiline"
mkdir -p "$t11_ml"
echo "<html><body>Review Dossier ML</body></html>" > "$t11_ml/report.html"
cat > "$t11_ml/task.env" << EOFML
TASK_ID=task-lavish-multiline
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-multiline
EOFML
tmux new-window -d -t kingpin: -n task-lavish-multiline cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_ml/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" '  - prompt: "Request Changes: first line\nsecond line"' "    tag: action" > "$(resp_file "$t11_ml")"
"$KP_BIN/kingpin" listen task-lavish-multiline --once >/dev/null
grep -Fxq "Request Changes: first line" "$t11_ml/feedback.md" && grep -Fxq "second line" "$t11_ml/feedback.md" && pass "multi-line prompt kept verbatim in feedback.md" || fail "multi-line prompt lost its line break in feedback.md"
sleep 0.3
pane_out=$(tmux capture-pane -pJ -pt kingpin:task-lavish-multiline -S -100)
n=$(printf '%s\n' "$pane_out" | grep -cF "The boss wrote this in the review dossier" || true)
[ "$n" = "2" ] && pass "multi-line prompt forwarded as one tty line" || fail "multi-line prompt forwarded in $((n / 2)) piece(s)"
printf '%s\n' "$pane_out" | grep -F "The boss wrote this in the review dossier" | grep -Fq "Request Changes: first line second line" && pass "multi-line prompt flattened onto one operational line" || fail "multi-line prompt was not flattened: $pane_out"
rm -rf "$t11_ml"
tmux kill-window -t kingpin:task-lavish-multiline 2>/dev/null || true

# An unknown prompt shape is recovered from its prompt: values instead of retyped
t11_rec="$KINGPIN_HOME/tasks/task-lavish-recover"
mkdir -p "$t11_rec"
echo "<html><body>Review Dossier V</body></html>" > "$t11_rec/report.html"
cat > "$t11_rec/task.env" << EOF11
TASK_ID=task-lavish-recover
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-recover
EOF11
tmux new-window -d -t kingpin: -n task-lavish-recover cat
echo "ready: branch=b review=APPROVE report=none" > "$t11_rec/status"
cp "$FIX/unknown-shape.txt" "$(resp_file "$t11_rec")"
"$KP_BIN/kingpin" listen task-lavish-recover --once >/dev/null
grep -Fq "recovered text from a shape the parser does not claim" "$t11_rec/feedback.md" && pass "listener: unknown shape recovered from prompt: value" || fail "listener: unknown shape lost its prompt text"
grep -q "^feedback: recovered text from a shape" "$t11_rec/status" && pass "listener: recovered feedback noted for the orchestrator" || fail "listener: recovered feedback not noted"
rec_parked=$(parked_file "$t11_rec")
[ -n "$rec_parked" ] && grep -Fq "prompt: recovered text from a shape the parser does not claim" "$rec_parked" && pass "listener: unparsed response parked in the task dir" || fail "listener: unparsed response not parked"
! grep -Fq "reply $t11_rec/report.html --agent-reply I could not read" "$T/mock-lavish.log" && pass "listener: recovered reviewer not asked to resend" || fail "listener: recovered reviewer asked to resend"
# One message gets one Conversation entry: the recovered prompt's own receipt is
# suppressed and the recovery receipt names the capture it kept.
n=$(grep -c "reply $t11_rec/report.html " "$T/mock-lavish.log" || true)
[ "$n" = "1" ] && pass "listener: recovered poll sends exactly one reply" || fail "listener: recovered poll sent $n replies"
grep -Fq "reply $t11_rec/report.html --agent-reply Feedback received and forwarded. Kingpin could not fully parse the poll response" "$T/mock-lavish.log" && pass "listener: recovery receipt reports the forward (window present)" || fail "listener: recovery receipt missing or changed"
grep -Fq "$rec_parked" "$T/mock-lavish.log" && pass "listener: recovery receipt names the parked file" || fail "listener: recovery receipt does not name the parked file"
sleep 0.3
pane_out=$(tmux capture-pane -pJ -pt kingpin:task-lavish-recover -S -100)
printf '%s\n' "$pane_out" | grep -Fq "recovered text from a shape the parser does not claim" && pass "listener: recovered text forwarded to the worker pane" || fail "listener: recovered text not forwarded: $pane_out"
rm -rf "$t11_rec"
tmux kill-window -t kingpin:task-lavish-recover 2>/dev/null || true

# The same recovery with no window keeps the recorded-not-forwarded receipt.
t11_recskip="$KINGPIN_HOME/tasks/task-lavish-recover-skip"
mkdir -p "$t11_recskip"
echo "<html><body>Review Dossier VS</body></html>" > "$t11_recskip/report.html"
cat > "$t11_recskip/task.env" << EOF11S
TASK_ID=task-lavish-recover-skip
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:task-lavish-recover-skip
EOF11S
echo "ready: branch=b review=APPROVE report=none" > "$t11_recskip/status"
cp "$FIX/unknown-shape.txt" "$(resp_file "$t11_recskip")"
"$KP_BIN/kingpin" listen task-lavish-recover-skip --once >/dev/null
recskip_parked=$(parked_file "$t11_recskip")
grep -Fq "recovered text from a shape the parser does not claim" "$t11_recskip/feedback.md" && pass "listener: windowless recovery still records the text" || fail "listener: windowless recovery lost its prompt text"
grep -Fq "reply $t11_recskip/report.html --agent-reply Feedback received and recorded. Not forwarded to the worker:" "$T/mock-lavish.log" && pass "listener: windowless recovery receipt records the skip" || fail "listener: windowless recovery receipt missing or changed"
grep -Fq "$recskip_parked" "$T/mock-lavish.log" && pass "listener: windowless recovery receipt names the parked file" || fail "listener: windowless recovery receipt does not name the parked file"
rm -rf "$t11_recskip"

# Prompts the parser cannot read are kept in listener.log, not dropped silently
t11_raw="$KINGPIN_HOME/tasks/task-lavish-raw"
mkdir -p "$t11_raw"
echo "<html><body>Review Dossier W</body></html>" > "$t11_raw/report.html"
cat > "$t11_raw/task.env" << EOF7
TASK_ID=task-lavish-raw
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF7
echo "ready: branch=b review=APPROVE report=none" > "$t11_raw/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - weird: shape" > "$(resp_file "$t11_raw")"
"$KP_BIN/kingpin" listen task-lavish-raw --once >/dev/null
grep -q "could not be parsed" "$t11_raw/listener.log" && grep -q "weird: shape" "$t11_raw/listener.log" && pass "unparsed prompts logged raw" || fail "unparsed prompts not logged"
raw_parked=$(parked_file "$t11_raw")
[ -n "$raw_parked" ] && grep -Fq "weird: shape" "$raw_parked" && pass "unparsed response parked in the task dir" || fail "unparsed response not parked"
grep -q "reply $t11_raw/report.html --agent-reply I could not read" "$T/mock-lavish.log" && pass "user told to resend unreadable feedback" || fail "no resend reply"
[ ! -f "$t11_raw/feedback.md" ] && pass "unreadable prompt did not produce a feedback entry" || fail "bogus feedback entry"
[ -n "$raw_parked" ] && grep -Fq "raw response parked at $raw_parked" "$t11_raw/status" && pass "orchestrator told where the raw response is parked" || fail "no parked-response note naming the capture"
rm -rf "$t11_raw"

# A prompts section nested under another key is parked and recovered, not dropped
t11_nested="$KINGPIN_HOME/tasks/task-lavish-nested"
mkdir -p "$t11_nested"
echo "<html><body>Review Dossier N</body></html>" > "$t11_nested/report.html"
cat > "$t11_nested/task.env" << EOF12
TASK_ID=task-lavish-nested
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF12
echo "ready: branch=b review=APPROVE report=none" > "$t11_nested/status"
cp "$FIX/nested-prompts.txt" "$(resp_file "$t11_nested")"
"$KP_BIN/kingpin" listen task-lavish-nested --once >/dev/null
nested_parked=$(parked_file "$t11_nested")
[ -n "$nested_parked" ] && pass "listener: nested prompts section parked in the task dir" || fail "listener: nested prompts section dropped with no park"
grep -Fq "nested prompts section is recovered" "$t11_nested/feedback.md" && pass "listener: nested prompts section recovered from prompt: value" || fail "listener: nested prompts section lost its text"
! grep -Fq "reply $t11_nested/report.html --agent-reply I could not read" "$T/mock-lavish.log" && pass "listener: nested reviewer not asked to resend" || fail "listener: nested reviewer asked to resend"
rm -rf "$t11_nested"

# Each unparseable poll gets its own capture, so a later one cannot overwrite the
# response an earlier feedback: note still points at.
t11_park="$KINGPIN_HOME/tasks/task-lavish-park"
mkdir -p "$t11_park"
echo "<html><body>Review Dossier P</body></html>" > "$t11_park/report.html"
cat > "$t11_park/task.env" << EOF13
TASK_ID=task-lavish-park
PROJECT=demo-auto
PROJECT_PATH=$T/proj
MODE=review
WORKTREE=$T/proj
EOF13
echo "ready: branch=b review=APPROVE report=none" > "$t11_park/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - weird: first response" > "$(resp_file "$t11_park")"
"$KP_BIN/kingpin" listen task-lavish-park --once >/dev/null
first_park=$(sed -n 's/^feedback: could not read the poll response; raw response parked at //p' "$t11_park/status" | tail -n 1)
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - weird: second response" > "$(resp_file "$t11_park")"
"$KP_BIN/kingpin" listen task-lavish-park --once >/dev/null
second_park=$(sed -n 's/^feedback: could not read the poll response; raw response parked at //p' "$t11_park/status" | tail -n 1)
[ -n "$first_park" ] && [ -n "$second_park" ] && [ "$first_park" != "$second_park" ] && pass "listener: each unparseable poll parks its own file" || fail "listener: parked file reused ($first_park / $second_park)"
grep -Fq "first response" "$first_park" 2>/dev/null && grep -Fq "second response" "$second_park" 2>/dev/null && pass "listener: earlier capture still holds its own response" || fail "listener: earlier parked response was overwritten"
rm -rf "$t11_park"

# Run kingpin-watch to verify feedback event handling
watch_fb=$("$KP_BIN/kingpin" watch --once 2>&1 || true)
echo "$watch_fb" | grep -q "received review feedback" && pass "kingpin-watch reported review feedback" || fail "kingpin-watch did not report feedback: $watch_fb"

# 5. Verify cleanup on kingpin-done
# task-lavish-1's WORKTREE is the project checkout, which no treehouse pool manages:
# stub the return so the cleanup is not refused as a lost lease (issue #75).
kp_test_stub_treehouse
[ -f "$t11_task/listener.pid" ] && pass "task-lavish-1 listener.pid present before done" || fail "listener.pid missing before done"
"$KP_BIN/kingpin" "done" task-lavish-1 --force >/dev/null

[ ! -f "$t11_task/listener.pid" ] && [ ! -f "$KINGPIN_HOME/archive/task-lavish-1/listener.pid" ] && pass "listener.pid removed by kingpin-done" || fail "listener.pid still present after done"
kill -0 "$lpid" 2>/dev/null && fail "listener was not killed" || pass "listener process killed by kingpin-done"
grep -q "end $t11_task/report.html" "$T/mock-lavish.log" && pass "mock-lavish end invoked by kingpin-done" || fail "mock-lavish end missing"

# Teardown test 10 resources
tmux kill-window -t kingpin:task-lavish-1 2>/dev/null || true
tmux kill-window -t kingpin:task-lavish-2 2>/dev/null || true
rm -rf "$t11_task" "$t11_task2"
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
# Put the default stub back rather than unsetting KINGPIN_LAVISH: an unset value
# resolves the real lavish-axi from PATH again (issue #129).
kp_test_stub_lavish

kp_test_finish LISTEN
