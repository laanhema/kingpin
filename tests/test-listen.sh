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
    resp="$T/mock-lavish-response-\$task.txt"
    if [ -f "\$resp" ]; then
      cat "\$resp"
      rm -f "\$resp"
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
TMUX_TARGET=kingpin:task-lavish-2
EOF
tmux new-window -d -t kingpin: -n task-lavish-2 cat
echo "ready: branch=b review=APPROVE report=$t11_task2/report.html" >> "$t11_task2/status"

cat > "$(resp_file "$t11_task2")" << 'RESP'
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
EOF11
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
grep -Fq "reply $t11_rec/report.html --agent-reply Feedback received and forwarded." "$T/mock-lavish.log" && pass "listener: recovery receipt says the message was forwarded" || fail "listener: recovery receipt missing or changed"
grep -Fq "$rec_parked" "$T/mock-lavish.log" && pass "listener: recovery receipt names the parked file" || fail "listener: recovery receipt does not name the parked file"
rm -rf "$t11_rec"

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
