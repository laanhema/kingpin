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
    if [ -f "$T/mock-lavish-response.txt" ]; then
      cat "$T/mock-lavish-response.txt"
      rm -f "$T/mock-lavish-response.txt"
    else
      sleep 0.2
    fi
    ;;
  reply)
    echo "OK: reply accepted"
    ;;
  end)
    echo "OK: session ended"
    ;;
  *)
    echo "OK: opened"
    ;;
esac
EOF
chmod +x "$T/mock-lavish"
export KINGPIN_LAVISH="$T/mock-lavish"

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
TMUX_TARGET=kingpin:task-lavish-1
EOF
tmux new-window -d -t kingpin: -n task-lavish-1 cat
echo "ready: branch=b review=APPROVE report=$t11_task/report.html" >> "$t11_task/status"

# 2. Run kingpin-watch --once to detect ready and auto-arm listener
"$KP_BIN/kingpin" watch --once >/dev/null

# Assert dossier was opened in lavish
sleep 0.3
grep -q "$t11_task/report.html" "$T/mock-lavish.log" 2>/dev/null && pass "mock-lavish opened review dossier" || fail "mock-lavish did not open review dossier"

# Assert listener.pid was created and process is running
[ -f "$t11_task/listener.pid" ] && pass "listener.pid created" || fail "listener.pid missing"
lpid=$(cat "$t11_task/listener.pid" 2>/dev/null || true)
[ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && pass "listener process is running (pid $lpid)" || fail "listener process not running"

# Assert kingpin list displays listener status
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "listening: pid $lpid" && pass "kingpin list displays listener pid" || fail "kingpin list missing listener pid: $list_out"

# kingpin list shows the orchestrator lock holder and its harness
KINGPIN_LOCK_PID=$$ "$KP_BIN/kingpin" lock acquire --harness agy >/dev/null
list_out=$("$KP_BIN/kingpin" list)
echo "$list_out" | grep -q "Orchestrator lock: held by pid $$ (agy)" && pass "kingpin list shows lock holder harness" || fail "kingpin list missing lock harness: $list_out"
"$KP_BIN/kingpin" lock release >/dev/null
list_out=$("$KP_BIN/kingpin" list)
! echo "$list_out" | grep -q "Orchestrator lock" && pass "kingpin list hides the lock line when free" || fail "kingpin list shows lock line when free"

# 3. Simulate Approve & Land feedback via Lavish
cat > "$T/mock-lavish-response.txt" << 'RESP'
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
TMUX_TARGET=kingpin:task-lavish-2
EOF
tmux new-window -d -t kingpin: -n task-lavish-2 cat
echo "ready: branch=b review=APPROVE report=$t11_task2/report.html" >> "$t11_task2/status"

cat > "$T/mock-lavish-response.txt" << 'RESP'
session:
  status: feedback
prompts[1]:
  - prompt: "Request Changes: please fix line 42 in foo.sh"
    tag: action
RESP

"$KP_BIN/kingpin" listen task-lavish-2 --once >/dev/null

[ -f "$t11_task2/feedback.md" ] && pass "feedback.md created" || fail "feedback.md missing"
grep -q "Request Changes: please fix line 42 in foo.sh" "$t11_task2/feedback.md" && pass "feedback text written correctly" || fail "feedback text incorrect"
grep -q "feedback: Request Changes: please fix line 42 in foo.sh" "$t11_task2/status" && pass "feedback status logged" || fail "feedback status missing"
grep -q "reply $t11_task2/report.html --agent-reply Feedback received" "$T/mock-lavish.log" && pass "feedback receipt reply sent to lavish" || fail "feedback reply missing"

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
TMUX_TARGET=kingpin:task-lavish-3
EOF3
echo "ready: branch=b review=APPROVE report=none" >> "$t11_task3/status"
cat > "$T/mock-lavish-response.txt" << 'RESP'
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
TMUX_TARGET=kingpin:task-lavish-state
EOF8
printf '%s\n' "ready: branch=b review=APPROVE report=none" "needs-input: which API shape?" > "$t11_state/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-state" > "$T/mock-lavish-response.txt"
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
TMUX_TARGET=kingpin:task-lavish-unknown
EOF9
printf '%s\n' "ready: branch=b review=LGTM report=r.md" > "$t11_unknown/status"
printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-unknown" > "$T/mock-lavish-response.txt"
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
TMUX_TARGET=kingpin:task-lavish-repeat
EOF5
tmux new-window -d -t kingpin: -n task-lavish-repeat cat
echo "ready: branch=b review=NEEDS CHANGES report=.agents/reviews/r5.md" > "$t11_rep/status"
approve_resp() {
  printf '%s\n' "session:" "  status: feedback" "prompts[1]{prompt}:" "  kingpin land task-lavish-repeat" > "$T/mock-lavish-response.txt"
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
printf '%s\n' "session:" "  status: feedback" "prompts[1]:" "  - weird: shape" > "$T/mock-lavish-response.txt"
"$KP_BIN/kingpin" listen task-lavish-raw --once >/dev/null
grep -q "could not be parsed" "$t11_raw/listener.log" && grep -q "weird: shape" "$t11_raw/listener.log" && pass "unparsed prompts logged raw" || fail "unparsed prompts not logged"
grep -q "reply $t11_raw/report.html --agent-reply I could not read" "$T/mock-lavish.log" && pass "user told to resend unreadable feedback" || fail "no resend reply"
! grep -q "^feedback:" "$t11_raw/status" && pass "unreadable prompt did not produce a feedback note" || fail "bogus feedback note"
rm -rf "$t11_raw"

# Run kingpin-watch to verify feedback event handling
watch_fb=$("$KP_BIN/kingpin" watch --once 2>&1 || true)
echo "$watch_fb" | grep -q "received review feedback" && pass "kingpin-watch reported review feedback" || fail "kingpin-watch did not report feedback: $watch_fb"

# 5. Verify cleanup on kingpin-done
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
unset KINGPIN_LAVISH

kp_test_finish LISTEN
