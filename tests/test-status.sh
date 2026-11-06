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
t62_ck=$t62_dir/checks-note
printf '%s\n' "merged: pr=u" "checks: pr=u checks=FAILED" > "$t62_ck"
[ "$(kp_status_last "$t62_ck")" = "merged: pr=u" ] && [ "$(kp_status_worker_events "$t62_ck")" = "1" ] && [ "$(kp_status_newest "$t62_ck")" = "checks: pr=u checks=FAILED" ] \
  && pass "t62: a checks: note is a note, not the worker's last event" || fail "t62: checks: note handling: last=$(kp_status_last "$t62_ck") events=$(kp_status_worker_events "$t62_ck")"
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
# codex-cli 0.166.0's bottom rows (issue #106, Phase 0 check 8): "• Working (3s • esc to
# interrupt)", sometimes with "· 1 background terminal running". The idle footer reads
# "Worked for 3s" above the input line "› Ask Codex to do anything".
t62_working codex $'• Working (4s • esc to interrupt) · 1 background terminal running · /ps to view · /stop to close' 0
t62_working codex $'• Working (3s • esc to interrupt)' 0
t62_working codex $'Worked for 3s • 10:54 PM\n\n› Ask Codex to do anything' 1
t62_working unknown 'Waiting for 1 background agent' 1

# The fleet's wire command per harness: pi exposes skills only as /skill:<name>, so a
# send that used the plain name would reach the model as ordinary text (spike.md,
# Check 3), and codex has no slash command for a skill at all, so a mention is
# $<name> (issue #106, Phase 0 check 5). An empty harness reads as claude; an unknown
# one keeps the plain form.
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
t62_skill codex "\$issue-flow 106" issue-flow 106
t62_skill codex "\$review --issue 7" review --issue 7
t62_skill codex "\$create-pr-merge" create-pr-merge
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
# The state token `kingpin list` and `kingpin brief` share (#188): one classifier, and
# a window that outlived its harness keeps the row `kingpin list` always printed.
t62_state_file=$t62_dir/state-status
t62_state() { # <liveness> <expected>
  local got
  got=$(kp_task_state "$t62_state_file" "$1")
  [ "$got" = "$2" ] && pass "t62: state on '$1' is $2" || fail "t62: state on '$1' = $got (want $2)"
}
printf '%s\n' 'failed: no status: stopped without reporting' > "$t62_state_file"
t62_state live SILENT
t62_state pane SILENT
t62_state dead none
t62_state skip none
printf '%s\n' 'needs-input: choose one' > "$t62_state_file"
t62_state live WAITING
t62_state pane DEAD
printf '%s\n' 'issue: #7' > "$t62_state_file"
t62_state live none
t62_state pane DEAD
printf '%s\n' 'ready: branch=b review=APPROVE report=r' > "$t62_state_file"
t62_state dead DEAD
printf '%s\n' 'merged: pr=u' > "$t62_state_file"
t62_state dead none
: > "$t62_state_file"
t62_state live none
t62_state pane DEAD
t62_state dead DEAD
rm -f "$t62_state_file"
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

# The archived-task readers (#115): kingpin done replaces a cleaned-up task's path
# with a symlink to its archive, and every fleet reader asks these two.
echo "=== Test t115: live-versus-archived task path readers ==="
t115_home=$T/t115-home; mkdir -p "$t115_home/tasks" "$t115_home/archive"
mkdir -p "$t115_home/tasks/live" "$t115_home/archive/gone" "$t115_home/archive/unlinked"
ln -s "$t115_home/archive/gone" "$t115_home/tasks/gone"
kp_task_is_live "$t115_home/tasks/live" && pass "t115: a real task directory is live" || fail "t115: a real task directory is not live"
kp_task_is_live "$t115_home/tasks/gone" && fail "t115: a dossier link counted as live" || pass "t115: a dossier link is not live"
kp_task_is_live "$t115_home/tasks/missing" && fail "t115: a missing task counted as live" || pass "t115: a missing task is not live"
[ "$(kp_task_archive_dir "$t115_home" gone)" = "$t115_home/archive/gone" ] && pass "t115: the link resolves to its archive" || fail "t115: archive dir = $(kp_task_archive_dir "$t115_home" gone)"
[ "$(kp_task_archive_dir "$t115_home" unlinked)" = "$t115_home/archive/unlinked" ] && pass "t115: a task archived before the link existed still resolves" || fail "t115: unlinked archive = $(kp_task_archive_dir "$t115_home" unlinked)"
kp_task_archive_dir "$t115_home" live >/dev/null && fail "t115: a live task reported as archived" || pass "t115: a live task is not archived"
kp_task_archive_dir "$t115_home" nope >/dev/null && fail "t115: an unknown id reported as archived" || pass "t115: an unknown id is not archived"
rm -rf "$t115_home"

# The finished-record reader (#198): a record whose work is over but whose cleanup
# never archived it must not keep the automatic curator gate busy.
echo "=== Test t198: finished task records ==="
t198_home=$T/t198-home
mkdir -p "$t198_home/tasks" "$t198_home/archive"
t198_mk() { # <id> <last-status-line>
  local id=$1 last=$2
  mkdir -p "$t198_home/tasks/$id"
  [ -n "$last" ] && printf '%s\n' "$last" > "$t198_home/tasks/$id/status"
  return 0
}
t198_finished() { # <id> <0 finished|1 not finished>
  local want=$2 got=1
  kp_task_is_finished "$t198_home/tasks/$1" && got=0
  [ "$got" = "$want" ] && pass "t198: $1 finished=$want" || fail "t198: $1 finished=$got (want $want)"
}
t198_mk merged 'merged: pr=https://example/pull/1'
t198_finished merged 0
t198_mk silent 'failed: no status: worker stopped without reporting'
t198_finished silent 0
t198_mk live 'ready: branch=b review=APPROVE report=r'
t198_finished live 1
t198_mk interrupted 'cleanup-refused: worktree is dirty'
t198_finished interrupted 1
t198_mk no-status ''
t198_finished no-status 1
t198_mk marker 'ready: branch=b review=APPROVE report=r'
touch "$t198_home/tasks/marker/done_cleaned"
t198_finished marker 0
t198_mk noted 'merged: pr=https://example/pull/2'
printf 'approved: by user via lavish dossier\n' >> "$t198_home/tasks/noted/status"
t198_finished noted 0
t198_finished missing 1
rm -rf "$t198_home"

# t206: kp_env_set is the one rewrite of a task.env key (lib/status.sh); the four copies it
# replaced shared the skip-unchanged, temp-file-beside-the-record and stderr behaviour.
echo "=== Test t206: kp_env_set rewrites one task.env key ==="
t206_dir=$T/t206; mkdir -p "$t206_dir"
t206_env=$t206_dir/task.env
t206_count() { find "$1" -mindepth 1 | wc -l; }
t206_reset() { printf '%s\n' "MODE=review" "KEY=old" "KEYX=keep" "PATH_X=a=b" > "$t206_env"; }

# An unchanged value touches nothing: same bytes, same inode (a hard link taken before
# still names the file), no temp file left beside it.
t206_reset
cp -p "$t206_env" "$T/t206.before"
rm -f "$T/t206.link"
ln "$t206_env" "$T/t206.link"
kp_env_set "$t206_env" KEY old
cmp -s "$t206_env" "$T/t206.before" && [ "$t206_env" -ef "$T/t206.link" ] \
  && pass "t206: an unchanged value leaves the file byte-identical and unreplaced" \
  || fail "t206: an unchanged value rewrote the file"
[ "$(t206_count "$t206_dir")" -eq 1 ] && pass "t206: no temp file is left beside the record" || fail "t206: $(find "$t206_dir" -mindepth 1 | tr '\n' ' ')"
kp_env_set "$t206_env" NEVER_SET ''
cmp -s "$t206_env" "$T/t206.before" && pass "t206: an absent key set to an empty value stays absent" || fail "t206: an empty value added a line"

# A changed value rewrites that key only; a key that is a prefix of another is not touched.
kp_env_set "$t206_env" KEY new
printf '%s\n' "MODE=review" "KEY=new" "KEYX=keep" "PATH_X=a=b" > "$T/t206.want"
cmp -s "$t206_env" "$T/t206.want" && pass "t206: a changed value rewrites that key only" || fail "t206: rewrote: $(tr '\n' ' ' < "$t206_env")"

# A missing key is appended as the last line.
t206_reset
kp_env_set "$t206_env" ADDED value
{ cat "$T/t206.before"; echo "ADDED=value"; } > "$T/t206.want"
cmp -s "$t206_env" "$T/t206.want" && pass "t206: a missing key is added as the last line" || fail "t206: add: $(tr '\n' ' ' < "$t206_env")"

# Every line of a duplicated key takes the value, so the last-wins reader sees it.
printf '%s\n' "KEY=one" "MODE=review" "KEY=two" > "$t206_env"
kp_env_set "$t206_env" KEY three
printf '%s\n' "KEY=three" "MODE=review" "KEY=three" > "$T/t206.want"
cmp -s "$t206_env" "$T/t206.want" && [ "$(kp_env_get "$t206_env" KEY)" = three ] \
  && pass "t206: a duplicated key is rewritten on every line" || fail "t206: duplicate: $(tr '\n' ' ' < "$t206_env")"

# A record whose last line has no newline does not glue the new key onto it.
printf 'MODE=review\nPATH_X=a=b' > "$t206_env"
kp_env_set "$t206_env" ADDED value
printf 'MODE=review\nPATH_X=a=b\nADDED=value\n' > "$T/t206.want"
cmp -s "$t206_env" "$T/t206.want" && pass "t206: an unterminated last line keeps its own line" || fail "t206: unterminated: $(od -c "$t206_env" | head -3 | tr '\n' ' ')"

# Values the sed form broke on, and quoting that must stay literal, read back unchanged.
# shellcheck disable=SC2016 # the literal $HOME is the value under test
t206_values=('a|b' 'x&y' 'back\slash' 'tab\tx' 'a/b' 'a b' '$HOME' '"q"' "it's" '-n' 'a=b' '*')
t206_bad=''
for t206_v in "${t206_values[@]}"; do
  t206_reset
  kp_env_set "$t206_env" KEY "$t206_v" || t206_bad="$t206_bad [$t206_v: exit]"
  [ "$(kp_env_get "$t206_env" KEY)" = "$t206_v" ] || t206_bad="$t206_bad [$t206_v: read back '$(kp_env_get "$t206_env" KEY)']"
  printf '%s\n' "MODE=review" "KEYX=keep" "PATH_X=a=b" > "$T/t206.want"
  grep -vx 'KEY=.*' "$t206_env" | cmp -s - "$T/t206.want" || t206_bad="$t206_bad [$t206_v: neighbours changed]"
  kp_env_set "$t206_env" NEWKEY "$t206_v" || t206_bad="$t206_bad [$t206_v: add exit]"
  [ "$(kp_env_get "$t206_env" NEWKEY)" = "$t206_v" ] || t206_bad="$t206_bad [$t206_v: added value read back wrong]"
done
[ -z "$t206_bad" ] && pass "t206: values with | & \\ / quotes and a leading dash land verbatim" || fail "t206:$t206_bad"

# A missing record is refused with the file named, and nothing is created.
rc=0
t206_err=$(kp_env_set "$t206_dir/absent.env" KEY v 2>&1) || rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$t206_dir/absent.env" ] && [[ $t206_err == *"$t206_dir/absent.env"* ]] \
  && pass "t206: a missing record exits 1, names the file and creates nothing" || fail "t206: missing: rc=$rc err='$t206_err'"

# A value that would split the line is refused and the record stays as it was.
t206_reset
cp -p "$t206_env" "$T/t206.before"
rc=0
t206_err=$(kp_env_set "$t206_env" KEY $'a\nb' 2>&1) || rc=$?
[ "$rc" -eq 1 ] && [[ $t206_err == *newline* ]] && cmp -s "$t206_env" "$T/t206.before" \
  && pass "t206: a value holding a newline exits 1 and leaves the record alone" || fail "t206: newline: rc=$rc err='$t206_err'"

# A failed write leaves the record intact and no temp file. Root ignores the modes.
if [ "$(id -u)" -eq 0 ]; then
  pass "t206: the read-only and unreadable cases are skipped (root ignores modes)"
else
  t206_reset
  cp -p "$t206_env" "$T/t206.before"
  chmod a-w "$t206_dir"
  rc=0
  t206_err=$(kp_env_set "$t206_env" KEY changed 2>&1) || rc=$?
  chmod u+w "$t206_dir"
  [ "$rc" -eq 1 ] && [[ $t206_err == *"cannot write"* ]] && cmp -s "$t206_env" "$T/t206.before" \
    && [ "$(t206_count "$t206_dir")" -eq 1 ] \
    && pass "t206: a folder that cannot take the temp file exits 1 with the record intact" \
    || fail "t206: read-only folder: rc=$rc err='$t206_err'"
  chmod 000 "$t206_env"
  rc=0
  t206_err=$(kp_env_set "$t206_env" KEY changed 2>&1) || rc=$?
  chmod 644 "$t206_env"
  [ "$rc" -eq 1 ] && cmp -s "$t206_env" "$T/t206.before" && [ "$(t206_count "$t206_dir")" -eq 1 ] \
    && pass "t206: an unreadable record exits 1 and is not replaced by a one-line file" \
    || fail "t206: unreadable record: rc=$rc err='$t206_err'"
fi

kp_test_finish STATUS
