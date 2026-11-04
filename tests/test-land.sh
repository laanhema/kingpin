#!/usr/bin/env bash
# Verification test for Kingpin: kingpin land: review-gate verdicts, fix-findings, re-review, output wording.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "land"
kp_test_project

# Test 9: Landing review gate verdict parsing, fix-findings, and re-review
echo "=== Test 9: Landing review gate verdict parsing, fix-findings, and re-review ==="

# 1. The review gate: every verdict spelling through the real kingpin land
echo "=== Test 9a: review gate verdicts through kingpin land ==="

# gate_case <name> <status-line>: a review-mode task whose worker window is a
# fresh cat pane, so the test asserts on what the real kingpin land dispatched.
gate_case() {
  local name=$1
  local d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  tmux new-window -d -t kingpin: -n "$name" cat
  cat > "$d/task.env" << EOF
TASK_ID=$name
PROJECT=demo-gate
MODE=review
WORKTREE=$T/proj
ISSUE=310
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
EOF
  printf '%s\n' "$2" > "$d/status"
  set +e
  gate_out=$("$KP_BIN/kingpin" land "$name" 2>&1)
  gate_rc=$?
  set -e
  sleep 0.1
  gate_pane=$(tmux capture-pane -pt "kingpin:$name" -S -5)
  gate_landing=no
  if [ -f "$d/landing_sent" ]; then gate_landing=yes; fi
  gate_lock=no
  if [ -f "$KINGPIN_HOME/projects/demo-gate.landing" ]; then gate_lock=yes; fi
}
gate_done() {
  tmux kill-window -t "kingpin:$1" 2>/dev/null || true
  rm -rf "$KINGPIN_HOME/tasks/$1"
  rm -f "$KINGPIN_HOME/projects/demo-gate.landing" "$KINGPIN_HOME/projects/demo-gate.landing_queue"
}
gate_findings() { # <name> <status-line> <report path as sent to /fix-findings>
  gate_case "$1" "$2"
  [ "$gate_rc" -eq 0 ] && pass "$1: findings verdict accepted (exit 0)" || fail "$1: exit $gate_rc, want 0: $gate_out"
  [ "$gate_landing" = "no" ] && [ "$gate_lock" = "no" ] && pass "$1: no landing dispatched" || fail "$1: landed despite a findings verdict"
  echo "$gate_pane" | grep -Fq "/fix-findings $T/proj/$3" && pass "$1: sent /fix-findings with the report path" || fail "$1: wrong fix-findings command: $gate_pane"
  gate_done "$1"
}
gate_clean() { # <name> <status-line>
  gate_case "$1" "$2"
  [ "$gate_rc" -eq 0 ] && pass "$1: clean verdict accepted (exit 0)" || fail "$1: exit $gate_rc, want 0: $gate_out"
  [ "$gate_landing" = "yes" ] && pass "$1: landing dispatched" || fail "$1: landing_sent missing"
  echo "$gate_pane" | grep -q "/issue-flow-done 310" && pass "$1: sent /issue-flow-done" || fail "$1: wrong done command: $gate_pane"
  # Issue #170: the dispatch stays the bare command, because /issue-flow-done takes
  # exactly one issue number and a trailing reminder reads as a malformed argument.
  # The landing order lives in the worker's preamble instead (Test 16).
  echo "$gate_pane" | grep -qE "/issue-flow-done 310[[:space:]]*$" \
    && pass "$1: the dispatch is the bare command" || fail "$1: the dispatch carries a trailing note: $gate_pane"
  ! echo "$gate_pane" | grep -q "Closes #" \
    && pass "$1: the dispatch carries no closing keyword" || fail "$1: the dispatch repeats the preamble: $gate_pane"
  gate_done "$1"
}
gate_refused() { # <name> <status-line> <text the message must name>
  gate_case "$1" "$2"
  [ "$gate_rc" -ne 0 ] && pass "$1: refused with exit $gate_rc" || fail "$1: landed an unreadable verdict (exit 0)"
  [ "$gate_landing" = "no" ] && [ "$gate_lock" = "no" ] && pass "$1: no landing dispatched" || fail "$1: landed an unreadable verdict"
  echo "$gate_out" | grep -Fq "$3" && pass "$1: message names the line it could not parse" || fail "$1: message does not name '$3': $gate_out"
  ! echo "$gate_pane" | grep -qE "/fix-findings|/issue-flow-done" && pass "$1: nothing dispatched to the worker" || fail "$1: dispatched despite refusing: $gate_pane"
  gate_done "$1"
}

# The four supported findings spellings, then case, separators, trailing prose
# and field order: all of them must still run the fix pass.
gate_findings gate-nits "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r1.md" ".agents/reviews/r1.md"
gate_findings gate-space "ready: branch=b review=NEEDS CHANGES report=r2.md" "r2.md"
gate_findings gate-under "ready: branch=b review=NEEDS_CHANGES report=r3.md" "r3.md"
gate_findings gate-dash "ready: branch=b review=NEEDS-CHANGES report=r4.md" "r4.md"
gate_findings gate-prose "ready: branch=b review=NEEDS CHANGES (2 high) report=r5.md" "r5.md"
gate_findings gate-lower "ready: branch=b review=needs changes report=r6.md" "r6.md"
gate_findings gate-reorder "ready: branch=b report=r7.md review=NEEDS CHANGES" "r7.md"
gate_findings gate-reorder-prose "ready: branch=b report=r8.md review=NEEDS CHANGES (2 high)" "r8.md"

# A clean approval lands, in either case
gate_clean gate-approve "ready: branch=b review=APPROVE report=none"
gate_clean gate-approve-lower "ready: branch=b review=approve report=none"

# Verdicts the gate does not recognize fail closed, naming the line
gate_refused gate-lgtm "ready: branch=b review=LGTM report=r.md" "review=LGTM report=r.md"
gate_refused gate-unknown "ready: branch=b review=SHIP IT report=r.md" "review=SHIP IT report=r.md"
gate_refused gate-noverdict "ready: branch=b" "no review= field"
gate_refused gate-needs-input "needs-input: which API shape?" "needs-input: which API shape?"
gate_refused gate-fixed-nohigh "fixed: report=r.md" "fixed: report=r.md"
gate_refused gate-fixed-badhigh "fixed: high=two report=r.md" "fixed: high=two report=r.md"
# high= is a parsed field: a report path or a lookalike key does not supply a count
gate_refused gate-fixed-report-high "fixed: report=high=0.md" "fixed: report=high=0.md"
gate_refused gate-fixed-nothigh "fixed: nothigh=3 report=r.md" "fixed: nothigh=3 report=r.md"
# A fixed: line that also reports findings contradicts itself: refuse, do not land
gate_refused gate-fixed-review "fixed: high=0 review=NEEDS CHANGES report=r.md" "review=NEEDS CHANGES"
gate_refused gate-fixed-review-reorder "fixed: review=NEEDS CHANGES high=0 report=r.md" "review=NEEDS CHANGES"
gate_refused gate-fixed-nits "fixed: high=0 review=APPROVE WITH NITS report=r.md" "review=APPROVE WITH NITS"
# A fixed: line may carry the verdict when it is clean
gate_clean gate-fixed-approve "fixed: high=0 review=APPROVE report=none"
# A repeated review= field is ambiguous: the gate refuses instead of trusting one
gate_refused gate-dup-review "ready: branch=b review=APPROVE report=none review=NEEDS CHANGES" "repeats the review= field"
# An empty review= field is a different mistake from a missing one, and says so
gate_refused gate-empty-review "ready: branch=b review= report=r.md" "empty review= field"

# 2. APPROVE WITH NITS and NEEDS CHANGES report path resolution & /fix-findings dispatch
t7_dir="$KINGPIN_HOME/tasks/t7-nits"
mkdir -p "$t7_dir"
tmux new-window -d -t kingpin: -n t7-nits cat
cat > "$t7_dir/task.env" << EOF
TASK_ID=t7-nits
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
ISSUE=301
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t7-nits
EOF
echo "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r1.md" > "$t7_dir/status"

"$KP_BIN/kingpin" land t7-nits >/dev/null
[ -f "$t7_dir/landing_in_progress" ] && pass "landing_in_progress set on APPROVE WITH NITS" || fail "landing_in_progress missing"
[ ! -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "landing lock not acquired during fix pass" || fail "landing lock prematurely acquired"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-nits -S -5)
echo "$pane_out" | grep -q "/fix-findings $T/proj/.agents/reviews/r1.md" && pass "resolved report path sent to /fix-findings" || fail "wrong fix-findings command: $pane_out"

# 3. fixed: high > 0 triggers /review dispatch
echo "fixed: high=1 report=.agents/reviews/r1.md" >> "$t7_dir/status"
"$KP_BIN/kingpin" land t7-nits >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-nits -S -5)
echo "$pane_out" | grep -q "/review --issue 301" && pass "/review --issue dispatched on high > 0" || fail "wrong review command: $pane_out"
[ ! -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "landing lock not acquired during re-review" || fail "landing lock prematurely acquired on re-review"

# Re-review without issue
t7_noissue="$KINGPIN_HOME/tasks/t7-noissue"
mkdir -p "$t7_noissue"
tmux new-window -d -t kingpin: -n t7-noissue cat
cat > "$t7_noissue/task.env" << EOF
TASK_ID=t7-noissue
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t7-noissue
EOF
echo "fixed: high=2 report=r.md" > "$t7_noissue/status"
"$KP_BIN/kingpin" land t7-noissue >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-noissue -S -5)
echo "$pane_out" | grep -qx "/review" && pass "/review dispatched when issue not set" || fail "wrong review command without issue: $pane_out"
tmux kill-window -t kingpin:t7-noissue 2>/dev/null || true
rm -rf "$t7_noissue"

# 4. fixed: high == 0 auto-advances to project landing lock & /issue-flow-done in review mode
echo "fixed: high=0 report=.agents/reviews/r1.md" >> "$t7_dir/status"
"$KP_BIN/kingpin" watch --once >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "project landing lock acquired on clean fix pass" || fail "landing lock not acquired"
[ -f "$t7_dir/landing_sent" ] && pass "landing_sent marker created on landing dispatch" || fail "landing_sent missing"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-nits -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 301" && pass "/issue-flow-done dispatched after clean fix" || fail "wrong done command: $pane_out"

tmux kill-window -t kingpin:t7-nits 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
rm -rf "$t7_dir"

# Auto mode continuation on fixed: high=0
t7_auto="$KINGPIN_HOME/tasks/t7-auto"
mkdir -p "$t7_auto"
tmux new-window -d -t kingpin: -n t7-auto cat
cat > "$t7_auto/task.env" << EOF
TASK_ID=t7-auto
PROJECT=demo-auto
MODE=auto
WORKTREE=$T/proj
ISSUE=303
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t7-auto
EOF
echo "fixed: high=0 report=r.md" > "$t7_auto/status"
"$KP_BIN/kingpin" watch --once >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "auto-mode acquired landing lock on clean fix pass" || fail "auto-mode landing lock not acquired"
[ -f "$t7_auto/landing_sent" ] && pass "auto-mode landing_sent created" || fail "auto-mode landing_sent missing"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-auto -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 303" && pass "auto-mode /issue-flow-done dispatched" || fail "wrong auto done command: $pane_out"

tmux kill-window -t kingpin:t7-auto 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
rm -rf "$t7_auto"

# 5. APPROVE with no findings goes straight to landing queue
t7_app="$KINGPIN_HOME/tasks/t7-app"
mkdir -p "$t7_app"
tmux new-window -d -t kingpin: -n t7-app cat
cat > "$t7_app/task.env" << EOF
TASK_ID=t7-app
PROJECT=demo-auto
MODE=review
WORKTREE=$T/proj
ISSUE=302
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t7-app
EOF
echo "ready: branch=b review=APPROVE report=none" > "$t7_app/status"

"$KP_BIN/kingpin" land t7-app >/dev/null
[ -f "$KINGPIN_HOME/projects/demo-auto.landing" ] && pass "landing lock acquired directly for APPROVE" || fail "landing lock not acquired for APPROVE"
[ -f "$t7_app/landing_sent" ] && pass "landing_sent created for APPROVE" || fail "landing_sent missing for APPROVE"
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t7-app -S -5)
echo "$pane_out" | grep -q "/issue-flow-done 302" && pass "/issue-flow-done dispatched for APPROVE" || fail "wrong done command for APPROVE: $pane_out"

tmux kill-window -t kingpin:t7-app 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-auto.landing" "$KINGPIN_HOME/projects/demo-auto.landing_queue"
rm -rf "$t7_app"

kp_test_stub_lavish

# Test 14: kingpin land states whether it lands or runs the fix pass first
echo "=== Test 14: kingpin land output (fix pass vs landing) and approve alias ==="
mk_t14() {
  local name=$1 status=$2
  local d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  tmux new-window -d -t kingpin: -n "$name" cat
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t14
MODE=review
WORKTREE=$T/proj
ISSUE=314
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
ENVEOF
  echo "$status" > "$d/status"
}
rm -f "$KINGPIN_HOME/projects/demo-t14.landing" "$KINGPIN_HOME/projects/demo-t14.landing_queue"

# Fix-findings path: says a fix pass runs first and that landing continues after fixed:
mk_t14 t14-nits "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r.md"
out=$("$KP_BIN/kingpin" land t14-nits)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "fix pass" && echo "$last" | grep -q "fixed:" && pass "fix path: last line says the fix pass runs first and landing continues after fixed:" || fail "fix path output unclear: $out"
echo "$last" | grep -q "not landing yet" && pass "fix path: output says it is not landing yet" || fail "fix path does not say it is not landing: $last"
[ ! -f "$KINGPIN_HOME/projects/demo-t14.landing" ] && pass "fix path: no landing lock taken" || fail "fix path took the landing lock"

# Fix pass left High findings: re-review, not landing
echo "fixed: high=1 report=r.md" >> "$KINGPIN_HOME/tasks/t14-nits/status"
out=$("$KP_BIN/kingpin" land t14-nits)
echo "$out" | tail -n 1 | grep -q "re-review" && pass "re-review path: output says a re-review comes first" || fail "re-review path output unclear: $out"

# Clean fix pass: says landing is starting, and the last line is the outcome (not kingpin-send's OK line)
echo "fixed: high=0 report=r.md" >> "$KINGPIN_HOME/tasks/t14-nits/status"
out=$("$KP_BIN/kingpin" land t14-nits)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "starting landing" && pass "clean fix pass: output says landing is starting" || fail "clean fix pass output unclear: $out"
echo "$last" | grep -q "^OK: sent" && fail "kingpin-send's OK line hides the outcome line" || pass "outcome line is the last line"
sleep 0.1
tmux capture-pane -pt kingpin:t14-nits -S -8 | grep -q "/issue-flow-done 314" && pass "clean fix pass dispatched /issue-flow-done" || fail "no /issue-flow-done after clean fix pass"
tmux kill-window -t kingpin:t14-nits 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"

# Clean review, via both names
mk_t14 t14-clean "ready: branch=b review=APPROVE report=none"
out=$("$KP_BIN/kingpin" land t14-clean)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "starting landing" && echo "$last" | grep -q "review is clean" && pass "clean path: output says the review is clean and landing is starting" || fail "clean path output unclear: $out"
tmux kill-window -t kingpin:t14-clean 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"
# No verdict at all: the gate fails closed instead of landing on trust
mk_t14 t14-nover "ready: branch=b"
if out=$("$KP_BIN/kingpin" land t14-nover 2>&1); then
  fail "no verdict: landed a task with no review verdict: $out"
else
  pass "no verdict: refused to land"
fi
echo "$out" | grep -Fq "ready: branch=b" && pass "no verdict: message names the status line" || fail "no verdict: message does not name the line: $out"
[ ! -f "$KINGPIN_HOME/tasks/t14-nover/landing_sent" ] && [ ! -f "$KINGPIN_HOME/projects/demo-t14.landing" ] && pass "no verdict: no landing_sent and no landing lock" || fail "no verdict: landing was recorded"
tmux kill-window -t kingpin:t14-nover 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"
mk_t14 t14-alias "ready: branch=b review=APPROVE report=none"
out=$("$KP_BIN/kingpin" approve t14-alias)
echo "$out" | tail -n 1 | grep -q "starting landing" && [ -f "$KINGPIN_HOME/tasks/t14-alias/landing_sent" ] && pass "kingpin approve behaves like kingpin land" || fail "kingpin approve failed: $out"
tmux kill-window -t kingpin:t14-alias 2>/dev/null || true
"$KP_BIN/kingpin" --help | grep -q "approve" && pass "kingpin --help mentions the approve alias" || fail "--help does not mention approve"
rm -f "$KINGPIN_HOME/projects/demo-t14.landing" "$KINGPIN_HOME/projects/demo-t14.landing_queue"
rm -rf "$KINGPIN_HOME/tasks/t14-nits" "$KINGPIN_HOME/tasks/t14-clean" "$KINGPIN_HOME/tasks/t14-nover" "$KINGPIN_HOME/tasks/t14-alias"

# Test 15: fleet sends follow the worker's harness (issue #93). Pi exposes a skill
# only as /skill:<name>, so a plain /review would reach the model as ordinary text.
echo "=== Test 15: pi sends use /skill:<name> ==="
mk_t15() { # <name> <status-line> [issue]
  local name=$1 status=$2 issue=${3-315}
  local d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  tmux new-window -d -t kingpin: -n "$name" cat
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
PROJECT=demo-t15
HARNESS=pi
MODE=review
WORKTREE=$T/proj
ISSUE=$issue
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
ENVEOF
  printf '%s\n' "$status" > "$d/status"
}
t15_done() {
  tmux kill-window -t "kingpin:$1" 2>/dev/null || true
  rm -f "$KINGPIN_HOME/projects/demo-t15.landing" "$KINGPIN_HOME/projects/demo-t15.landing_queue"
}
rm -f "$KINGPIN_HOME/projects/demo-t15.landing" "$KINGPIN_HOME/projects/demo-t15.landing_queue"

mk_t15 t15-pi-nits "ready: branch=b review=APPROVE WITH NITS report=r.md"
"$KP_BIN/kingpin" land t15-pi-nits >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t15-pi-nits -S -5)
echo "$pane_out" | grep -q "/skill:fix-findings $T/proj/r.md" && pass "pi: APPROVE WITH NITS sends /skill:fix-findings" || fail "pi fix-findings: $pane_out"
t15_done t15-pi-nits

mk_t15 t15-pi-done "ready: branch=b review=APPROVE report=none"
"$KP_BIN/kingpin" land t15-pi-done >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t15-pi-done -S -5)
echo "$pane_out" | grep -q "/skill:issue-flow-done 315" && pass "pi: a clean review sends /skill:issue-flow-done" || fail "pi done: $pane_out"
t15_done t15-pi-done

mk_t15 t15-pi-pr "ready: branch=b review=APPROVE report=none" ""
"$KP_BIN/kingpin" land t15-pi-pr >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t15-pi-pr -S -5)
echo "$pane_out" | grep -q "/skill:create-pr-merge" && pass "pi: no issue sends /skill:create-pr-merge" || fail "pi pr: $pane_out"
! echo "$pane_out" | grep -q "Closes #" && pass "pi: a landing with no issue asks for no closing keyword" || fail "pi: a landing with no issue asked for a closing keyword: $pane_out"
t15_done t15-pi-pr

# The other harnesses keep the plain command.
mk_t15 t15-claude "ready: branch=b review=APPROVE WITH NITS report=r.md"
kp_test_sub "$KINGPIN_HOME/tasks/t15-claude/task.env" 's/^HARNESS=pi$/HARNESS=claude/'
"$KP_BIN/kingpin" land t15-claude >/dev/null
sleep 0.1
pane_out=$(tmux capture-pane -pt kingpin:t15-claude -S -5)
echo "$pane_out" | grep -q "/fix-findings $T/proj/r.md" && ! echo "$pane_out" | grep -q "/skill:fix-findings" \
  && pass "claude still sends the plain /fix-findings" || fail "claude fix-findings: $pane_out"
t15_done t15-claude

rm -rf "$KINGPIN_HOME/tasks/t15-pi-nits" "$KINGPIN_HOME/tasks/t15-pi-done" "$KINGPIN_HOME/tasks/t15-pi-pr" "$KINGPIN_HOME/tasks/t15-claude"

# Test 16: the worker's landing contract closes the issue before it reports (issue #170).
# This asserts the preamble's wording, not a merge path, and that is the whole reachable
# surface: the order lives in a document the worker reads, and no code path in this repo
# can enforce what a worker's prose makes it do. A fake merge path here would exercise the
# fake worker, not kingpin. The one code path that does act on the order, `done`'s issue
# readout, is covered by Test 24 in tests/test-done.sh.
echo "=== Test 16: the worker preamble states the landing order ==="
preamble="$KP_ROOT/worker/preamble.md"
landing_block=$(sed -n '/^## Landing$/,/^## /p' "$preamble")
[ -n "$landing_block" ] && pass "preamble has a Landing section" || fail "preamble has no Landing section"
grep -q 'Closes #' <<< "$landing_block" && pass "preamble asks for the closing keyword in the PR body" || fail "preamble asks for no closing keyword"
grep -q 'Refs #' <<< "$landing_block" && fail "preamble still asks for a bare reference" || pass "preamble does not ask for a bare reference"
grep -qi 'close the issue' <<< "$landing_block" && pass "preamble tells the worker to close the issue" || fail "preamble does not tell the worker to close the issue"
grep -qi 'board item' <<< "$landing_block" && pass "preamble tells the worker to move the board item" || fail "preamble does not tell the worker to move the board item"
grep -q 'before you append' <<< "$landing_block" && grep -q 'merged:' <<< "$landing_block" \
  && pass "preamble puts the close before merged:" || fail "preamble does not order the close before merged:"

kp_test_finish LAND

