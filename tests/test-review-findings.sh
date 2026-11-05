#!/usr/bin/env bash
# Verification test for Kingpin: the review-report reader and the landing gate
# that lands past Low-only findings (issue #187).
#
# Covers the reader's severity split (Critical, High and Medium block, Low is
# follow-up), the report shapes it must not count (a Medium mention in prose, an
# id under What's Good, a Fix Verification row, a CRLF file), the shapes it fails
# closed on (missing, empty, no Issues Found block, no recognized heading, an
# unknown heading inside the block), and the real kingpin land for an all-Low
# report, one Medium, High and Critical report, an all-Low NEEDS CHANGES line, a
# missing report, a report with no block, a report with an unknown section and a
# clean APPROVE. It ends on the preamble wording that makes the worker track the
# follow-ups.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "review-findings"
kp_test_project
kp_test_stub_lavish
# shellcheck source=../lib/review.sh
. "$KP_ROOT/lib/review.sh"

REVIEWS="$T/reviews"
mkdir -p "$REVIEWS" "$T/proj/.agents/reviews"

# write_report <path> <critical> <high> <medium> <low>: a report in the review
# skill's own section order, followed by sections that must never count.
write_report() {
  {
    printf '# Code Review: demo\n\n'
    printf '**Recommendation**: APPROVE WITH NITS\n\n'
    printf '## Summary\n\nShort. A Medium mention in prose is not a finding.\n\n'
    printf '## Issues Found\n\n'
    printf '### Critical\n\n%s\n\n' "$2"
    printf '### High Priority\n\n%s\n\n' "$3"
    printf '### Medium Priority\n\n%s\n\n' "$4"
    printf '### Suggestions (Low)\n\n%s\n\n' "$5"
    printf "## What's Good\n\n- **L3** \`x.sh:9\`: this line is praise, not a finding.\n\n"
    printf '## Validation Results\n\n| Check | Status |\n|---|---|\n| Fix Verification | L1 | fixed |\n'
  } > "$1"
}

# shellcheck disable=SC2016 # the backticks are markdown code-span literals in the fixture
low1='- **L1** `a.sh:1`: a stale comment. **Why:** it misleads. **Fix:** reword it.'
# shellcheck disable=SC2016 # the backticks are markdown code-span literals in the fixture
low2='- **L2** `b.sh:2`: a long line. **Why:** it wraps. **Fix:** split it.'
# shellcheck disable=SC2016 # the backticks are markdown code-span literals in the fixture
med1='- **M1** `a.sh:2`: an edge case. **Why:** it breaks. **Fix:** handle it.'
# shellcheck disable=SC2016 # the backticks are markdown code-span literals in the fixture
high1='- **H1** `a.sh:3`: a lost write. **Why:** data is lost. **Fix:** fsync it.'
# shellcheck disable=SC2016 # the backticks are markdown code-span literals in the fixture
crit1='- **C1** `a.sh:4`: a leak. **Why:** it never closes. **Fix:** close it.'

echo "=== Reader: the split comes from the report sections ==="

write_report "$REVIEWS/all-low.md" 'None' 'None' 'None' "$low1
$low2"
write_report "$REVIEWS/medium.md" 'None' 'None' "$med1" 'None'
write_report "$REVIEWS/high.md" 'None' "$high1" 'None' 'None'
write_report "$REVIEWS/critical.md" "$crit1" 'None' 'None' 'None'
write_report "$REVIEWS/none.md" 'None' 'None' 'None' 'None'
write_report "$REVIEWS/mixed.md" "$crit1" 'None' 'None' "$low1"

cat > "$REVIEWS/unknown-section.md" <<'EOF'
# Code Review: demo

## Issues Found

### Critical

None

### High Priority

None

### Medium Priority

None

### Suggestions (Low)

None

### Notes

- **L9** `z.sh:9`: a note, not an open finding.

## Next Steps

- **L8** `y.sh:8`: outside the Issues Found block.
EOF

sed 's/$/\r/' "$REVIEWS/all-low.md" > "$REVIEWS/all-low-crlf.md"
: > "$REVIEWS/empty.md"
# shellcheck disable=SC2016 # the backticks are markdown literals in the fixture
printf '# Code Review: demo\n\n## Summary\n\n- **M1** `a.sh:1`: a finding with no block.\n' > "$REVIEWS/no-block.md"
# shellcheck disable=SC2016 # the backticks are markdown literals in the fixture
printf '# Code Review: demo\n\n## Issues Found\n\n- **L1** `a.sh:1`: a finding with no heading.\n' > "$REVIEWS/no-heading.md"

expect_counts() { # <label> <report> <blocking> <followup>
  local label=$1 report=$2 want_blocking=$3 want_followup=$4 got='' rc=0 found='' got_followup
  kp_run got rc kp_review_blocking_count "$report"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want_blocking" ]; then
    pass "$label: blocking count is $want_blocking"
  else
    fail "$label: blocking count is '$got' (exit $rc), want $want_blocking"
  fi
  kp_run found rc kp_review_followups "$report"
  if [ "$rc" -ne 0 ]; then
    got_followup="cannot derive"
  else
    got_followup=$(printf '%s\n' "$found" | awk 'NF { n++ } END { print n + 0 }')
  fi
  if [ "$got_followup" = "$want_followup" ]; then
    pass "$label: follow-up count is $want_followup"
  else
    fail "$label: follow-up count is $got_followup, want $want_followup"
  fi
}

expect_unreadable() { # <label> <report>
  local label=$1 report=$2 out='' rc=0
  kp_run out rc kp_review_blocking_count "$report"
  [ "$rc" -eq 1 ] && [ -z "$out" ] \
    && pass "$label: the blocking count refuses (exit 1, no number)" \
    || fail "$label: the blocking count answered (exit $rc): $out"
  kp_run out rc kp_review_followups "$report"
  [ "$rc" -eq 1 ] && [ -z "$out" ] \
    && pass "$label: follow-ups refuse too" \
    || fail "$label: follow-ups answered (exit $rc): $out"
}

expect_counts "all Low" "$REVIEWS/all-low.md" 0 2
expect_counts "one Medium" "$REVIEWS/medium.md" 1 0
expect_counts "one High" "$REVIEWS/high.md" 1 0
expect_counts "one Critical" "$REVIEWS/critical.md" 1 0
expect_counts "all None" "$REVIEWS/none.md" 0 0
expect_counts "one Critical and one Low" "$REVIEWS/mixed.md" 1 1
expect_counts "CRLF line endings" "$REVIEWS/all-low-crlf.md" 0 2

# The follow-up lines come back verbatim, in report order.
follows=$(kp_review_followups "$REVIEWS/all-low.md")
printf '%s\n' "$follows" | grep -qF -- "$low1" \
  && pass "follow-ups: the first Low bullet is verbatim" \
  || fail "follow-ups: the first Low bullet is missing: $follows"
printf '%s\n' "$follows" | grep -qF -- "$low2" \
  && pass "follow-ups: the second Low bullet is verbatim" \
  || fail "follow-ups: the second Low bullet is missing: $follows"
first=$(printf '%s\n' "$follows" | head -n 1)
[ "$first" = "$low1" ] && pass "follow-ups: report order is kept" || fail "follow-ups: order changed: $first"

expect_unreadable "a missing report" "$REVIEWS/absent.md"
expect_unreadable "an empty report" "$REVIEWS/empty.md"
expect_unreadable "a report with no Issues Found block" "$REVIEWS/no-block.md"
expect_unreadable "a report with no severity heading" "$REVIEWS/no-heading.md"
expect_unreadable "a report with an unknown section" "$REVIEWS/unknown-section.md"

# ---- The real landing gate ---------------------------------------------------

# Write the reports the land cases point at, under the worktree, where kingpin
# land resolves a relative report= path.
write_report "$T/proj/.agents/reviews/all-low.md" 'None' 'None' 'None' "$low1
$low2"
write_report "$T/proj/.agents/reviews/medium.md" 'None' 'None' "$med1" 'None'
write_report "$T/proj/.agents/reviews/high.md" 'None' "$high1" 'None' 'None'
write_report "$T/proj/.agents/reviews/critical.md" "$crit1" 'None' 'None' 'None'
cp "$REVIEWS/no-block.md" "$T/proj/.agents/reviews/no-block.md"
cp "$REVIEWS/unknown-section.md" "$T/proj/.agents/reviews/unknown-section.md"

# rf_task <name> <verdict> <report-rel-path>: a review-mode task whose worker
# window is a fresh cat pane, so the suite asserts on what the real kingpin land
# dispatched.
rf_task() {
  local name=$1 verdict=$2 report=$3
  local d="$KINGPIN_HOME/tasks/$name"
  mkdir -p "$d"
  tmux new-window -d -t kingpin: -n "$name" cat
  cat > "$d/task.env" << EOF
TASK_ID=$name
PROJECT=demo-rf
MODE=review
WORKTREE=$T/proj
ISSUE=187
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$name
EOF
  printf 'ready: branch=b review=%s report=%s\n' "$verdict" "$report" > "$d/status"
}

rf_pane_has() { # <name> <text>
  tmux capture-pane -pt "kingpin:$1" -S -8 2>/dev/null | grep -qF -- "$2"
}

rf_cleanup() { # <name>
  tmux kill-window -t "kingpin:$1" 2>/dev/null || true
  rm -rf "${KINGPIN_HOME:?}/tasks/$1"
  rm -f "$KINGPIN_HOME/projects/demo-rf.landing" "$KINGPIN_HOME/projects/demo-rf.landing_queue"
}

echo "=== Land: an all-Low report lands without a fix pass ==="
rf_task rf-low 'APPROVE WITH NITS' .agents/reviews/all-low.md
rf_out='' rf_rc=0
kp_run rf_out rf_rc "$KP_BIN/kingpin" land rf-low
rf_low="$KINGPIN_HOME/tasks/rf-low"
[ "$rf_rc" -eq 0 ] && pass "all Low: land exited 0" || fail "all Low: exit $rf_rc: $rf_out"
[ -f "$rf_low/landing_sent" ] && pass "all Low: landing_sent was written" || fail "all Low: landing_sent missing"
[ ! -f "$rf_low/landing_in_progress" ] && pass "all Low: no fix pass started" || fail "all Low: landing_in_progress was written"
[ -f "$rf_low/followups.md" ] && pass "all Low: followups.md was written" || fail "all Low: followups.md missing"
grep -qF -- "$low1" "$rf_low/followups.md" 2>/dev/null && pass "all Low: followups.md holds L1" || fail "all Low: L1 is missing from followups.md"
grep -qF -- "$low2" "$rf_low/followups.md" 2>/dev/null && pass "all Low: followups.md holds L2" || fail "all Low: L2 is missing from followups.md"
grep -q '^# Follow-up findings' "$rf_low/followups.md" 2>/dev/null && pass "all Low: followups.md opens with its heading" || fail "all Low: followups.md has no heading"
echo "$rf_out" | grep -qE '2 Low finding' && pass "all Low: the output names the follow-up count" || fail "all Low: the output does not name the count: $rf_out"
kp_wait_until 2 rf_pane_has rf-low "/issue-flow-done 187" \
  && pass "all Low: /issue-flow-done was sent" \
  || fail "all Low: /issue-flow-done was not sent: $(tmux capture-pane -pt kingpin:rf-low -S -8)"
! rf_pane_has rf-low "/fix-findings" \
  && pass "all Low: no /fix-findings was sent" \
  || fail "all Low: /fix-findings was sent: $(tmux capture-pane -pt kingpin:rf-low -S -8)"
rf_cleanup rf-low

echo "=== Land: a blocking finding runs the fix pass ==="
rf_blocked() { # <name> <verdict> <report-rel-path> <label> [expected-output]
  local name=$1 verdict=$2 report=$3 label=$4 want=${5:-}
  local d="$KINGPIN_HOME/tasks/$name" out='' rc=0
  rf_task "$name" "$verdict" "$report"
  kp_run out rc "$KP_BIN/kingpin" land "$name"
  [ "$rc" -eq 0 ] && pass "$label: land exited 0" || fail "$label: exit $rc: $out"
  [ -f "$d/landing_in_progress" ] && pass "$label: landing_in_progress was written" || fail "$label: landing_in_progress missing"
  [ ! -f "$d/landing_sent" ] && pass "$label: no landing was sent" || fail "$label: landing_sent appeared"
  [ ! -f "$d/followups.md" ] && pass "$label: no followups.md was written" || fail "$label: followups.md appeared on a blocked report"
  if [ -n "$want" ]; then
    case "$out" in
      *"$want"*) pass "$label: the output says why it blocked" ;;
      *) fail "$label: the output does not say why it blocked: $out" ;;
    esac
  fi
  kp_wait_until 2 rf_pane_has "$name" "/fix-findings" \
    && pass "$label: /fix-findings was sent" \
    || fail "$label: /fix-findings was not sent: $(tmux capture-pane -pt "kingpin:$name" -S -8)"
  ! rf_pane_has "$name" "/issue-flow-done" \
    && pass "$label: no landing command was sent" \
    || fail "$label: a landing command was sent: $(tmux capture-pane -pt "kingpin:$name" -S -8)"
  rf_cleanup "$name"
}

rf_blocked rf-medium 'APPROVE WITH NITS' .agents/reviews/medium.md "one Medium"
rf_blocked rf-high 'APPROVE WITH NITS' .agents/reviews/high.md "one High"
rf_blocked rf-critical 'APPROVE WITH NITS' .agents/reviews/critical.md "one Critical"
rf_blocked rf-unknown 'APPROVE WITH NITS' .agents/reviews/unknown-section.md "an unknown section"
rf_blocked rf-changes 'NEEDS CHANGES' .agents/reviews/all-low.md "an all-Low NEEDS CHANGES" \
  "the verdict blocks the merge on its own"
rf_blocked rf-missing 'APPROVE WITH NITS' .agents/reviews/absent.md "a missing report"
rf_blocked rf-noblock 'APPROVE WITH NITS' .agents/reviews/no-block.md "a report with no block"

echo "=== Land: a clean APPROVE still lands ==="
rf_task rf-clean 'APPROVE' none
rf_out='' rf_rc=0
kp_run rf_out rf_rc "$KP_BIN/kingpin" land rf-clean
rf_clean="$KINGPIN_HOME/tasks/rf-clean"
[ "$rf_rc" -eq 0 ] && pass "clean: land exited 0" || fail "clean: exit $rf_rc: $rf_out"
[ -f "$rf_clean/landing_sent" ] && pass "clean: landing_sent was written" || fail "clean: landing_sent missing"
[ ! -f "$rf_clean/followups.md" ] && pass "clean: no followups.md was written" || fail "clean: followups.md appeared"
kp_wait_until 2 rf_pane_has rf-clean "/issue-flow-done 187" \
  && pass "clean: /issue-flow-done was sent" \
  || fail "clean: /issue-flow-done was not sent"
rf_cleanup rf-clean

echo "=== Preamble: the worker tracks the follow-up findings ==="
preamble="$KP_ROOT/worker/preamble.md"
landing_block=$(sed -n '/^## Landing$/,/^## /p' "$preamble")
[ -n "$landing_block" ] && pass "preamble has a Landing section" || fail "preamble has no Landing section"
grep -q 'followups.md' <<< "$landing_block" \
  && pass "preamble names followups.md" \
  || fail "preamble does not name followups.md"
grep -qF '## Follow-up' <<< "$landing_block" \
  && pass "preamble asks for a follow-up checklist in the PR body" \
  || fail "preamble asks for no follow-up checklist"
grep -qi 'open one GitHub issue' <<< "$landing_block" \
  && pass "preamble allows one issue instead of the checklist" \
  || fail "preamble does not allow one issue"
grep -q 'before you report' <<< "$landing_block" && grep -q 'merged:' <<< "$landing_block" \
  && pass "preamble puts the follow-up tracking before merged:" \
  || fail "preamble does not order the follow-up tracking before merged:"

kp_test_finish REVIEW-FINDINGS
