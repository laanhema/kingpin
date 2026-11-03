#!/usr/bin/env bash
# Verification test for Kingpin: lib/status.sh: the shared status protocol and its callers.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "status"
kp_test_project

kp_test_stub_lavish

# t62: lib/status.sh owns the status protocol; one answer to "does a listener note count?"
echo "=== Test t62: shared status helper (lib/status.sh) ==="
# shellcheck source=../lib/status.sh
. "$KP_ROOT/lib/status.sh"
t62_dir=$T/t62; mkdir -p "$t62_dir"
t62_st=$t62_dir/status
printf '%s\n' "ready: branch=b review=APPROVE report=r" "feedback: Request Changes: x" "approved: by user via lavish dossier" > "$t62_st"
[ "$(kp_status_last "$t62_st")" = "ready: branch=b review=APPROVE report=r" ] && pass "t62: kp_status_last skips approved:/feedback: notes" || fail "t62: kp_status_last = $(kp_status_last "$t62_st")"
[ "$(kp_status_newest "$t62_st")" = "approved: by user via lavish dossier" ] && pass "t62: kp_status_newest keeps the newest note" || fail "t62: kp_status_newest = $(kp_status_newest "$t62_st")"
[ "$(kp_status_worker_events "$t62_st")" = "1" ] && pass "t62: notes are not worker events" || fail "t62: kp_status_worker_events = $(kp_status_worker_events "$t62_st")"
: > "$t62_dir/empty"
[ -z "$(kp_status_last "$t62_dir/empty")" ] && [ -z "$(kp_status_last "$t62_dir/missing")" ] && [ -z "$(kp_status_newest "$t62_dir/missing")" ] && pass "t62: empty and missing status files give no line" || fail "t62: empty/missing status gave a line"
printf '%s\n' "approved: x" > "$t62_dir/notes-only"
[ -z "$(kp_status_last "$t62_dir/notes-only")" ] && [ "$(kp_status_worker_events "$t62_dir/notes-only")" = "0" ] && pass "t62: a file of notes only has no worker event" || fail "t62: notes-only file reported an event"
for t62_l in "merged: pr=u" "failed: no status: x" "cleanup-refused: x"; do
  kp_status_is_terminal "$t62_l" && pass "t62: '${t62_l%%:*}:' is terminal" || fail "t62: '${t62_l%%:*}:' not terminal"
done
for t62_l in "ready: b" "needs-input: q" "fixed: high=0" "approved: x" "feedback: x" "issue: #1" ""; do
  kp_status_is_terminal "$t62_l" && fail "t62: '$t62_l' counted as terminal" || pass "t62: '${t62_l%%:*}' is not terminal"
done
# The Stop hook's outcome kinds (#102): waiting and silent are read here, not spelled out
# again by kingpin list, kingpin-wait and the suites.
for t62_l in "needs-input: q" "feedback: x" "waiting: needs-input q"; do
  kp_status_is_waiting "$t62_l" && pass "t62: '$t62_l' is waiting" || fail "t62: '$t62_l' not waiting"
done
for t62_l in "ready: b" "failed: x" ""; do
  kp_status_is_waiting "$t62_l" && fail "t62: '$t62_l' counted as waiting" || pass "t62: '$t62_l' is not waiting"
done
kp_status_is_silent "failed: no status: stopped without reporting" && pass "t62: the hook's no-status line is silent" || fail "t62: no-status line not silent"
for t62_l in "failed: something else" "waiting: x" "ready: b" ""; do
  kp_status_is_silent "$t62_l" && fail "t62: '$t62_l' counted as silent" || pass "t62: '$t62_l' is not silent"
done
printf '%s\n' "MODE=review" "HARNESS=agy" "HARNESS=claude" "EMPTY=" "PATH_X=a=b" > "$t62_dir/task.env"
[ "$(kp_env_get "$t62_dir/task.env" HARNESS)" = "claude" ] && pass "t62: kp_env_get returns the last assignment" || fail "t62: kp_env_get HARNESS = $(kp_env_get "$t62_dir/task.env" HARNESS)"
[ "$(kp_env_get "$t62_dir/task.env" PATH_X)" = "a=b" ] && [ -z "$(kp_env_get "$t62_dir/task.env" EMPTY)" ] && [ -z "$(kp_env_get "$t62_dir/task.env" NOPE)" ] && [ -z "$(kp_env_get "$t62_dir/nofile" MODE)" ] && pass "t62: kp_env_get handles = in values, empty, absent and missing file" || fail "t62: kp_env_get edge cases"
# The working-marker list is one function now (#102 review L2), so the three callers
# cannot disagree about it: every harness, plus the claude subagent line that
# kingpin-launch-check's own copy used to miss.
t62_working() { # <harness> <pane-tail> <0 working|1 idle>
  local got=1
  kp_pane_shows_working "$2" "$1" && got=0
  [ "$got" = "$3" ] && pass "t62: '$1' pane working=$3" || fail "t62: '$1' pane working=$got (want $3): $2"
}
t62_working claude $'tool output\nWaiting for 2 background agents' 0
t62_working claude '/tasks to see subagents' 0
t62_working claude $'$ make test\nok' 1
t62_working agy $'working\nesc to cancel' 0
t62_working agy 'Interrupt' 1
t62_working opencode $'working\nesc to cancel' 0
t62_working opencode $'working\nInterrupt' 0
t62_working opencode '$ ls -la' 1
# Pi 1.5.0's working rule (spike.md, Check 4): a box rule with a braille spinner and
# the word, directly above the model footer. The idle footer carries no "Working".
t62_working pi $'tool output\n── ⠏ Working ─────────────────────────\n…/project (main)\n↑10 ↓157 … anthropic/claude-sonnet-4.5 • medium' 0
t62_working pi $'$ make test\nok\n…/project (main)\n↑10 ↓157 … claude-sonnet-4.5 • medium' 1
t62_working unknown 'Waiting for 1 background agent' 1

# The fleet's wire command per harness: pi exposes skills only as /skill:<name>, so a
# send that used the plain name would reach the model as ordinary text (spike.md,
# Check 3). An empty harness reads as claude; an unknown one keeps the plain form.
t62_skill() { # <harness> <expected> [skill args...]
  local harness=$1 want=$2 got
  shift 2
  got=$(kp_skill_command "$harness" "$@")
  [ "$got" = "$want" ] && pass "t62: skill command on '$harness' is '$want'" || fail "t62: skill command on '$harness' = '$got' (want '$want')"
}
t62_skill claude "/review --issue 7" review --issue 7
t62_skill agy "/review --issue 7" review --issue 7
t62_skill opencode "/review --issue 7" review --issue 7
t62_skill pi "/skill:review --issue 7" review --issue 7
t62_skill "" "/review" review
t62_skill pi "/skill:create-pr-merge" create-pr-merge
t62_skill bogus "/review" review
# The claude marker literals have one owner (#80): a caller that copies an alternative
# into its own grep drifts out of step, which is how launch-check lost the footer. The
# alternatives are read from the claude arm itself, so one added there is covered without
# editing this guard.
t62_claude_markers() { # one claude-arm alternative per line, from the arm's grep pattern
  sed -n '/^[[:space:]]*claude)/,/^[[:space:]]*;;/p' "$KP_ROOT/lib/status.sh" |
    sed -n "s/.*grep -qE '\([^']*\)'.*/\1/p" | tr '|' '\n'
}
t62_marker_owners() { # <literal> -> the bin/ and lib/ files that carry it
  grep -lF -- "$1" "$KP_ROOT"/bin/* "$KP_ROOT"/lib/*.sh 2>/dev/null | sed "s|^$KP_ROOT/||" || true
}
t62_claude=$(t62_claude_markers)
[ -n "$t62_claude" ] && pass "t62: the claude alternatives are read from lib/status.sh" || fail "t62: no claude alternatives found in lib/status.sh"
while IFS= read -r t62_marker; do
  t62_files=$(t62_marker_owners "$t62_marker")
  [ "$t62_files" = "lib/status.sh" ] && pass "t62: '$t62_marker' is defined only in lib/status.sh" || fail "t62: '$t62_marker' appears in: $(printf '%s' "${t62_files:-nothing}" | tr '\n' ' ') (want lib/status.sh only)"
done <<< "$t62_claude"
# Callers share that answer: a listener note after merged: leaves the task finished for kingpin-wait
# (a raw last line would report the dead window as exited).
t62_task=$KINGPIN_HOME/tasks/t62-wait
mkdir -p "$t62_task"
printf 'PROJECT=demo-auto\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:t62-wait\n' > "$t62_task/task.env"
printf '%s\n' "merged: pr=u" "approved: by user via lavish dossier" > "$t62_task/status"
echo 2 > "$t62_task/seen"
set +e; t62_out=$("$KP_BIN/kingpin" wait --once 2>/dev/null); t62_rc=$?; set -e
[ "$t62_rc" -eq 1 ] && [ -z "$t62_out" ] && pass "t62: kingpin-wait treats merged: + approved: note as finished" || fail "t62: kingpin-wait rc=$t62_rc out=$t62_out"
# kingpin list shows the newest line, notes included
"$KP_BIN/kingpin" list 2>/dev/null | grep '^t62-wait ' | grep -q "approved: by user via lavish dossier" && pass "t62: kingpin list shows the newest status line" || fail "t62: kingpin list row: $("$KP_BIN/kingpin" list 2>/dev/null | grep '^t62-wait ')"
rm -rf "$t62_task" "$t62_dir"

# t71: the review-gate verdict parser (field order, separators, trailing prose)
echo "=== Test t71: verdict parser (lib/status.sh) ==="
t71_field() { # <status-line> <key> <expected>
  local got
  got=$(kp_status_field "$1" "$2")
  [ "$got" = "$3" ] && pass "t71: $2 of '$1' = '$3'" || fail "t71: $2 of '$1' = '$got' (want '$3')"
}
t71_verdict() { # <status-line> <expected>
  local got
  got=$(kp_status_verdict "$1")
  [ "$got" = "$2" ] && pass "t71: verdict of '$1' = '$2'" || fail "t71: verdict of '$1' = '$got' (want '$2')"
}
t71_kind() { # <verdict> <expected>
  local got
  got=$(kp_verdict_kind "$1")
  [ "$got" = "$2" ] && pass "t71: verdict '$1' is $2" || fail "t71: verdict '$1' is $got (want '$2')"
}
t71_count() { # <status-line> <key> <expected>
  local got
  got=$(kp_status_field_count "$1" "$2")
  [ "$got" = "$3" ] && pass "t71: $2 count of '$1' = $3" || fail "t71: $2 count of '$1' = $got (want '$3')"
}
t71_field "ready: branch=b review=APPROVE WITH NITS report=r.md" review "APPROVE WITH NITS"
t71_field "ready: branch=b review=APPROVE WITH NITS report=r.md" report "r.md"
t71_field "ready: branch=b report=r.md review=NEEDS CHANGES" review "NEEDS CHANGES"
t71_field "ready: branch=b report=r.md review=NEEDS CHANGES" report "r.md"
t71_field "ready: branch=b review=NEEDS CHANGES (2 high) report=r.md" review "NEEDS CHANGES (2 high)"
t71_field "ready: branch=b" review ""
t71_field "ready: branch=b" report ""
t71_field "" review ""
t71_field "ready: branch=b report=/abs/path.md review=APPROVE" report "/abs/path.md"
# A repeated field is ambiguous, so it has no value; the count tells the gate which
# refusal to print (absent, empty, or repeated).
t71_field "ready: branch=b review=APPROVE report=none review=NEEDS CHANGES" review ""
t71_field "ready: branch=b report=a.md report=b.md" report ""
t71_field "ready: branch=b review=" review ""
t71_count "ready: branch=b review=APPROVE report=none" review 1
t71_count "ready: branch=b review=" review 1
t71_count "ready: branch=b" review 0
t71_count "ready: branch=b review=APPROVE report=none review=NEEDS CHANGES" review 2
# high= is a field like any other: a report path or a different key is not a count
t71_field "fixed: high=0 report=r.md" high "0"
t71_field "fixed: high=2 report=r.md" high "2"
t71_field "fixed: report=high=0.md" high ""
t71_field "fixed: nothigh=3 report=r.md" high ""
t71_verdict "ready: branch=b review=needs changes (2 high) report=r.md" "NEEDS CHANGES"
t71_verdict "ready: branch=b review=NEEDS_CHANGES report=r.md" "NEEDS CHANGES"
t71_verdict "ready: branch=b review=NEEDS-CHANGES report=r.md" "NEEDS CHANGES"
t71_verdict "ready: branch=b review=needs  changes   (2 high)" "NEEDS CHANGES"
t71_verdict "ready: branch=b report=r.md review=APPROVE WITH NITS" "APPROVE WITH NITS"
t71_verdict "ready: branch=b review=lgtm report=r.md" "LGTM"
t71_verdict "ready: branch=b" ""
t71_kind APPROVE clean
t71_kind "APPROVE WITH NITS" findings
t71_kind "NEEDS CHANGES" findings
t71_kind LGTM unknown
t71_kind "" unknown

kp_test_finish STATUS
