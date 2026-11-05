#!/usr/bin/env bash
# Verification test for Kingpin: `kingpin stats`, the fleet summary (issue #189).
#
# Covers the summary counts and layout on a three-task fixture, the `--since` window
# and its two refusals, archived records and the dossier link a cleanup leaves behind,
# the curator and undated records that are counted and skipped, an empty fleet, the
# guarantee that the command writes nothing, and the two precedence rules that decide a
# `merged:` before a `cleanup-refused:` and a `failed:` before a `needs-input:`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "stats"
# shellcheck source=../lib/portable.sh
. "$KP_ROOT/lib/portable.sh"

# stats_task <home> <id> <age-seconds> <status line>...
# One record the summary reads: task.env with CREATED <age> seconds ago, the given
# status lines, and a status mtime of now, which is the finish time the summary uses.
# <home> is the fleet home the record belongs to, so a case can build its own fixture.
stats_task() {
  local home=$1 id=$2 age=$3 d
  shift 3
  d="$home/tasks/$id"
  mkdir -p "$d"
  printf 'TASK_ID=%s\nPROJECT=demo\nMODE=review\nCREATED=%s\n' "$id" "$(kp_test_iso_ago "$age")" \
    > "$d/task.env"
  printf '%s\n' "$@" > "$d/status"
  kp_test_touch_ago "$d/status" 0
}

# stats_has <output> <label> <line>: the summary carries exactly this line.
stats_has() {
  local out=$1 label=$2 want=$3
  if printf '%s\n' "$out" | grep -qxF -- "$want"; then
    pass "$label: '$want'"
  else
    fail "$label: missing '$want' in: $(printf '%s' "$out" | tr '\n' '|')"
  fi
}

# stats_snapshot: every file under $KINGPIN_HOME as <mtime>\t<crc>\t<path>, so a run that
# wrote anything, however small, changes the listing.
stats_snapshot() {
  local f
  find "$KINGPIN_HOME" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' \
      "$(kp_mtime "$f" 2>/dev/null || echo missing)" \
      "$(cksum < "$f" | awk '{print $1}')" \
      "$f"
  done
}

echo "=== Test 1: the three-task fixture ==="
stats_out='' stats_rc=0
stats_task "$KINGPIN_HOME" t-stats-approve 10800 \
  'issue: #1 u' \
  'ready: branch=b review=APPROVE report=r.md' \
  'merged: pr=u'
stats_task "$KINGPIN_HOME" t-stats-fixed 3600 \
  'ready: branch=b review=NEEDS CHANGES report=r.md' \
  'fixed: high=0 report=r.md' \
  'ready: branch=b review=APPROVE report=r.md' \
  'merged: pr=u'
stats_task "$KINGPIN_HOME" t-stats-failed 7200 \
  'ready: branch=b review=NEEDS CHANGES report=r.md' \
  'failed: tests red'

stats_before=$(stats_snapshot)
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats
stats_after=$(stats_snapshot)
[ "$stats_rc" -eq 0 ] && pass "stats exits 0" || fail "stats exited $stats_rc: $stats_out"
for want in \
  'Window: all records' \
  'Records: 3 (finished 3, in flight 0, without a report 0)' \
  'Finished: 2 merged, 1 failed' \
  'Verdicts: APPROVE 2, APPROVE WITH NITS 0, NEEDS CHANGES 1, other 0' \
  'Fix passes: 1 of 3 reviewed tasks (33%)' \
  'Cleanup refused: 0' \
  'Failed:' \
  '  t-stats-failed  failed: tests red' \
  'Time to merged: median 2h, p90 3h (n=2)'
do
  stats_has "$stats_out" "three-task fixture" "$want"
done
[ "$stats_before" = "$stats_after" ] \
  && pass "the run wrote nothing under KINGPIN_HOME" \
  || fail "the run changed KINGPIN_HOME: $(diff <(printf '%s\n' "$stats_before") <(printf '%s\n' "$stats_after") | tr '\n' '|')"

echo "=== Test 2: --since limits the window ==="
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats --since 90m
[ "$stats_rc" -eq 0 ] && pass "--since 90m exits 0" || fail "--since 90m exited $stats_rc: $stats_out"
for want in \
  'Records: 1 (finished 1, in flight 0, without a report 0)' \
  'Finished: 1 merged, 0 failed' \
  'Verdicts: APPROVE 1, APPROVE WITH NITS 0, NEEDS CHANGES 0, other 0' \
  'Fix passes: 1 of 1 reviewed tasks (100%)' \
  'Time to merged: median 1h, p90 1h (n=1)'
do
  stats_has "$stats_out" "--since 90m" "$want"
done
printf '%s\n' "$stats_out" | grep -qF 'Window: last 90m (since ' \
  && pass "--since 90m names the window and its start" \
  || fail "--since 90m lost the window line: $(printf '%s' "$stats_out" | head -n 1)"

kp_run stats_out stats_rc "$KP_BIN/kingpin" stats --since 4x
[ "$stats_rc" -eq 2 ] && pass "--since 4x exits 2" || fail "--since 4x exited $stats_rc, want 2"
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats --since
[ "$stats_rc" -eq 2 ] && pass "--since with no value exits 2" || fail "--since with no value exited $stats_rc, want 2"

echo "=== Test 3: archived records and the dossier link ==="
mkdir -p "$KINGPIN_HOME/archive"
mv "$KINGPIN_HOME/tasks/t-stats-approve" "$KINGPIN_HOME/archive/t-stats-approve"
ln -s "$KINGPIN_HOME/archive/t-stats-approve" "$KINGPIN_HOME/tasks/t-stats-approve"
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats
[ "$stats_rc" -eq 0 ] && pass "an archived record is read" || fail "stats exited $stats_rc: $stats_out"
stats_has "$stats_out" "archived record" 'Records: 3 (finished 3, in flight 0, without a report 0)'

stats_task "$KINGPIN_HOME" t-stats-live 1800 'issue: #9 u'
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats
stats_has "$stats_out" "live in-flight record" 'Records: 4 (finished 3, in flight 1, without a report 0)'

echo "=== Test 4: curator and undated records are counted and skipped ==="
stats_task "$KINGPIN_HOME" curator 1200 'ready: branch=curator review=PENDING report=r.md'
printf 'CURATOR=1\n' >> "$KINGPIN_HOME/tasks/curator/task.env"
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats
stats_has "$stats_out" "curator skipped" \
  'Records: 4 (finished 3, in flight 1, without a report 0); 1 curator skipped'
stats_has "$stats_out" "curator verdict kept out" \
  'Verdicts: APPROVE 2, APPROVE WITH NITS 0, NEEDS CHANGES 1, other 0'

stats_task "$KINGPIN_HOME" t-stats-undated 600 'issue: #10 u'
kp_test_sub "$KINGPIN_HOME/tasks/t-stats-undated/task.env" '/^CREATED=/d'
kp_run stats_out stats_rc "$KP_BIN/kingpin" stats --since 100m
[ "$stats_rc" -eq 0 ] && pass "a windowed run still exits 0" || fail "stats --since exited $stats_rc: $stats_out"
stats_has "$stats_out" "undated skipped" \
  'Records: 2 (finished 1, in flight 1, without a report 0); 1 curator skipped; 1 skipped: no CREATED'

echo "=== Test 5: an empty fleet and a missing KINGPIN_HOME ==="
stats_nohome="$T/no-home"
kp_run stats_out stats_rc env KINGPIN_HOME="$stats_nohome" "$KP_BIN/kingpin" stats
[ "$stats_rc" -eq 0 ] && pass "a missing KINGPIN_HOME exits 0" || fail "a missing home exited $stats_rc: $stats_out"
stats_has "$stats_out" "empty fleet" 'Records: 0 (finished 0, in flight 0, without a report 0)'
stats_has "$stats_out" "empty fleet" 'Time to merged: none (no merged record)'
[ ! -e "$stats_nohome" ] \
  && pass "a missing KINGPIN_HOME is still absent after the run" \
  || fail "the run created $stats_nohome"

echo "=== Test 6: a merge after a cleanup refusal, and a question after a failure ==="
# These two records own a fleet home of their own, so the counts above stay fixed. The
# first ends `cleanup-refused:` after its merge and must still count as merged, with the
# refusal visible on its own line; the second ends `needs-input:` after a `failed:` and
# must count as in flight rather than failed.
stats_home="$T/precedence"
stats_task "$stats_home" t-stats-merged-refused 5400 \
  'ready: branch=b review=APPROVE report=r.md' \
  'merged: pr=u' \
  'cleanup-refused: worktree busy'
stats_task "$stats_home" t-stats-asked-after-failure 3600 \
  'ready: branch=b review=NEEDS CHANGES report=r.md' \
  'failed: tests red' \
  'needs-input: which branch?'
kp_run stats_out stats_rc env KINGPIN_HOME="$stats_home" "$KP_BIN/kingpin" stats
[ "$stats_rc" -eq 0 ] && pass "the precedence fixture exits 0" || fail "stats exited $stats_rc: $stats_out"
for want in \
  'Records: 2 (finished 1, in flight 1, without a report 0)' \
  'Finished: 1 merged, 0 failed' \
  'Cleanup refused: 1'
do
  stats_has "$stats_out" "precedence fixture" "$want"
done
printf '%s\n' "$stats_out" | grep -qxF -- '  t-stats-asked-after-failure  needs-input: which branch?' \
  && fail "a failed: line followed by needs-input: was reported as failed" \
  || pass "a failed: line followed by needs-input: is in flight, not failed"

kp_test_finish STATS
