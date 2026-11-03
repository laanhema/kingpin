#!/usr/bin/env bash
# Verification test for Kingpin: kingpin land: review-gate verdicts, fix-findings, re-review, output wording.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "land"
kp_test_project

# Test 9: Landing review gate verdict parsing, fix-findings, and re-review
echo "=== Test 9: Landing review gate verdict parsing, fix-findings, and re-review ==="

# 1. Regex parsing unit tests
check_parse() {
  local last_status="$1"
  local exp_v="$2"
  local exp_r="$3"
  local verdict="" report=""
  if [[ $last_status =~ review=(.*)[[:space:]]+report=([^[:space:]]*) ]]; then
    verdict="${BASH_REMATCH[1]}"
    report="${BASH_REMATCH[2]}"
  elif [[ $last_status =~ review=([^ ]+( [^ ]+)*) ]]; then
    verdict="${BASH_REMATCH[1]}"
  fi
  if [ -z "$report" ] && [[ $last_status =~ report=([^[:space:]]+) ]]; then
    report="${BASH_REMATCH[1]}"
  fi
  verdict=$(echo "$verdict" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
  report=$(echo "$report" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
  [ "$verdict" = "$exp_v" ] && [ "$report" = "$exp_r" ]
}

check_parse "ready: branch=b review=APPROVE report=none" "APPROVE" "none" && pass "parsed APPROVE report=none" || fail "failed parse APPROVE"
check_parse "ready: branch=b review=APPROVE WITH NITS report=.agents/reviews/r1.md" "APPROVE WITH NITS" ".agents/reviews/r1.md" && pass "parsed APPROVE WITH NITS" || fail "failed parse APPROVE WITH NITS"
check_parse "ready: branch=b review=NEEDS CHANGES report=r2.md" "NEEDS CHANGES" "r2.md" && pass "parsed NEEDS CHANGES" || fail "failed parse NEEDS CHANGES"

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
# No parsable verdict: lands as before, but does not claim the review is clean
mk_t14 t14-nover "ready: branch=b"
out=$("$KP_BIN/kingpin" land t14-nover)
last=$(printf '%s\n' "$out" | tail -n 1)
echo "$last" | grep -q "no review verdict recorded" && ! echo "$last" | grep -q "review is clean" && pass "no verdict: output does not claim the review is clean" || fail "no-verdict output unclear: $out"
tmux kill-window -t kingpin:t14-nover 2>/dev/null || true
rm -f "$KINGPIN_HOME/projects/demo-t14.landing"
mk_t14 t14-alias "ready: branch=b review=APPROVE report=none"
out=$("$KP_BIN/kingpin" approve t14-alias)
echo "$out" | tail -n 1 | grep -q "starting landing" && [ -f "$KINGPIN_HOME/tasks/t14-alias/landing_sent" ] && pass "kingpin approve behaves like kingpin land" || fail "kingpin approve failed: $out"
tmux kill-window -t kingpin:t14-alias 2>/dev/null || true
"$KP_BIN/kingpin" --help | grep -q "approve" && pass "kingpin --help mentions the approve alias" || fail "--help does not mention approve"
rm -f "$KINGPIN_HOME/projects/demo-t14.landing" "$KINGPIN_HOME/projects/demo-t14.landing_queue"
rm -rf "$KINGPIN_HOME/tasks/t14-nits" "$KINGPIN_HOME/tasks/t14-clean" "$KINGPIN_HOME/tasks/t14-nover" "$KINGPIN_HOME/tasks/t14-alias"

kp_test_finish LAND
