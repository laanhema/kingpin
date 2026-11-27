#!/usr/bin/env bash
# Verification suite for Kingpin issue #256: `kingpin wake`, the orchestrator's
# read-only wake-up call.
#
# The wake blocks until a live task's status file gains a needs-input:, ready:,
# fixed:, failed:, waiting:, merged: or cleanup-refused: line, prints each such line
# as `<task-id> <status line>`, prints `resume: <token>` last and exits 0. A timeout
# prints only the resume line and exits 3. It writes nothing under KINGPIN_HOME, so
# `kingpin watch --once` dispatches the same line on its own: the suite runs both
# beside each other and asserts that both happen, that the wake leaves every `seen`
# cursor alone, and that a merged: line the supervisor archived is still reported
# through the archive link, or from the newest archive when no link exists.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "wake"
# Section 8 fakes kingpin-done; the fake lives in the private copy of bin/.
kp_test_private_bin

# One live tmux window stands in for the workers' panes, so the wait pass inside
# `kingpin-watch --once` never reports a fixture task as exited (and launch-check never
# appends a `failed: no status:` line of its own) while the suite drives its status file.
tmux new-window -t kingpin -n kp256-probe 'exec bash'
probe_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="kp256-probe"{print $1}')
[ -n "$probe_wid" ] && pass "probe window created ($probe_wid)" || fail "could not create the probe window"

TASKS="$KINGPIN_HOME/tasks"

# mk_task <id> [first status line]: a live record whose status file starts with an
# informational line, so the task starts with nothing pending.
mk_task() {
  local id=$1 first=${2:-'issue: #256'}
  mkdir -p "$TASKS/$id"
  printf 'PROJECT=demo\nHARNESS=claude\nMODE=review\nTMUX_TARGET=kingpin:%s\nTMUX_WINDOW_ID=%s\n' \
    "$id" "$probe_wid" > "$TASKS/$id/task.env"
  printf '%s\n' "$first" > "$TASKS/$id/status"
}

reset_fleet() { rm -rf "$TASKS" "$KINGPIN_HOME/archive"; mkdir -p "$TASKS"; }

# token_of <output>: the token from the last `resume:` line.
token_of() { printf '%s\n' "$1" | sed -n 's/^resume: //p' | tail -n 1; }

# count_in <token> <id>: the count the token holds for <id>, or `none`.
count_in() {
  local pair
  for pair in $(printf '%s' "$1" | tr ',' ' '); do
    [ "${pair%%:*}" = "$2" ] && { printf '%s\n' "${pair##*:}"; return 0; }
  done
  printf 'none\n'
}

# A background wake. It is bounded twice: by its own --timeout and by `timeout 60`, so
# the `wait` that reaps it can never hang.
BG_PID=''
bg_wake() {
  local name=$1
  shift
  timeout 60 "$KP_BIN/kingpin" wake "$@" > "$T/$name.out" 2> "$T/$name.err" &
  BG_PID=$!
}
# bg_ended <name>: the wake printed its resume line, which is always its last write.
bg_ended() { grep -q '^resume: ' "$T/$1.out" 2>/dev/null; }
bg_running() { kill -0 "$2" 2>/dev/null && ! bg_ended "$1"; }
# bg_reap <pid>: sets BG_RC.
bg_reap() { BG_RC=0; wait "$1" || BG_RC=$?; }
# wake_idle <timeout-pid>: the wake finished a pass and is waiting for the next one
# (its inotifywait or sleep child is running). Only after that is a task it never saw
# guaranteed to be new to it.
wake_idle() {
  local w c
  for w in $(pgrep -P "$1" 2>/dev/null || true); do
    for c in $(pgrep -P "$w" 2>/dev/null || true); do
      case $(ps -o comm= -p "$c" 2>/dev/null) in
        inotifywait|sleep) return 0 ;;
      esac
    done
  done
  return 1
}

# fine_mtime <path>: modification time with sub-second precision where the host has it,
# so a rewrite with identical content inside the same second still shows.
fine_mtime() { stat -c %y "$1" 2>/dev/null || stat -f %Fm "$1" 2>/dev/null || echo unknown; }

# home_snapshot <dir>: every entry under <dir> as type, mtime, checksum (files) or
# target (links), and path, so a run that wrote, created, moved or removed anything
# changes the listing.
home_snapshot() {
  local p
  find "$1" 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf 'l\t%s\t%s\n' "$(readlink "$p")" "$p"
    elif [ -d "$p" ]; then
      printf 'd\t%s\t%s\n' "$(fine_mtime "$p")" "$p"
    else
      printf 'f\t%s\t%s\t%s\n' "$(fine_mtime "$p")" "$(cksum < "$p" | awk '{print $1}')" "$p"
    fi
  done
}

# cursor_snapshot <id>: the supervisor's cursor files of one task (seen, seen_line and
# every seen_* file), with their bytes and mtimes.
cursor_snapshot() {
  local f
  for f in "$TASKS/$1"/seen "$TASKS/$1"/seen_*; do
    [ -e "$f" ] || continue
    printf '%s\t%s\t%s\n' "$f" "$(fine_mtime "$f")" "$(cksum < "$f" | awk '{print $1}')"
  done
}

seen_count() {
  local file="$TASKS/$1/seen"
  [ -f "$file" ] || { echo 0; return 0; }
  tr -d ' \n' < "$file"
}

out='' rc=0

echo "=== Section 1: help and refusals ==="
kp_run out rc "$KP_BIN/kingpin" wake --help
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi usage \
  && pass "wake --help exits 0 with usage" || fail "wake --help: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin" wake -h
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi usage \
  && pass "wake -h exits 0 with usage" || fail "wake -h: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin" wake --timeout x
[ "$rc" -eq 2 ] && pass "--timeout x exits 2" || fail "--timeout x exited $rc: $out"
kp_run out rc "$KP_BIN/kingpin" wake --from 'bogus;x'
[ "$rc" -eq 2 ] && pass "a malformed --from token exits 2" || fail "--from 'bogus;x' exited $rc: $out"
kp_run out rc "$KP_BIN/kingpin" wake --from
[ "$rc" -eq 2 ] && pass "--from with no value exits 2" || fail "--from with no value exited $rc: $out"
kp_run out rc "$KP_BIN/kingpin" wake --bogus
[ "$rc" -eq 2 ] && pass "an unknown flag exits 2" || fail "--bogus exited $rc: $out"

echo "=== Section 2: the timeout ==="
reset_fleet
mk_task t2-quiet
kp_run out rc "$KP_BIN/kingpin" wake --timeout 1
[ "$rc" -eq 3 ] && pass "a quiet fleet times out with exit 3" || fail "a quiet fleet exited $rc: $out"
[ "$out" = "resume: w1,t2-quiet:1" ] \
  && pass "a timeout prints only the resume line" || fail "timeout output was: $out"
bare_home="$T/bare-home"
mkdir -p "$bare_home"
kp_run out rc env KINGPIN_HOME="$bare_home" "$KP_BIN/kingpin" wake --timeout 0
[ "$rc" -eq 3 ] && [ "$out" = "resume: w1" ] \
  && pass "a home with no tasks/ times out with 'resume: w1'" || fail "no tasks/: rc=$rc out=$out"
[ ! -e "$bare_home/tasks" ] \
  && pass "the wake did not create tasks/" || fail "the wake created $bare_home/tasks"
# A leading zero is base 10, not octal: `09` once died in the wait arithmetic at once.
bg_wake s2 --timeout 09
s2_pid=$BG_PID
kp_wait_until 10 wake_idle "$s2_pid" || fail "the --timeout 09 wake never reached its wait step"
kp_holds_for 1 bg_running s2 "$s2_pid" \
  && pass "--timeout 09 waits instead of failing" || fail "--timeout 09 ended: $(cat "$T/s2.out" "$T/s2.err")"
printf 'ready: review=APPROVE\n' >> "$TASKS/t2-quiet/status"
kp_wait_until 10 bg_ended s2 || fail "the --timeout 09 wake did not end on a ready: line"
bg_reap "$s2_pid"
[ "$BG_RC" -eq 0 ] && grep -qx 't2-quiet ready: review=APPROVE' "$T/s2.out" \
  && pass "--timeout 09 reports the line and exits 0" || fail "--timeout 09: rc=$BG_RC out=$(cat "$T/s2.out" "$T/s2.err")"

echo "=== Section 3: blocks, then wakes ==="
reset_fleet
mk_task t3-block
bg_wake s3 --timeout 30
s3_pid=$BG_PID
kp_wait_until 10 wake_idle "$s3_pid" || fail "the wake never reached its wait step"
kp_holds_for 0.5 bg_running s3 "$s3_pid" \
  && pass "the wake blocks on a quiet fleet" || fail "the wake ended on a quiet fleet: $(cat "$T/s3.out")"
printf 'needs-input: q\n' >> "$TASKS/t3-block/status"
kp_wait_until 10 bg_ended s3 \
  && pass "an appended needs-input: line ends the wake" || fail "the wake did not end within 10 s"
bg_reap "$s3_pid"
[ "$BG_RC" -eq 0 ] && pass "the wake exits 0 after printing a line" || fail "the wake exited $BG_RC"
[ "$(cat "$T/s3.out")" = "$(printf 't3-block needs-input: q\nresume: w1,t3-block:2')" ] \
  && pass "the wake printed the line and the resume token" || fail "wake output: $(cat "$T/s3.out")"

echo "=== Section 4: the kinds that wake it and the notes that do not ==="
reset_fleet
mk_task t4
kp_run out rc "$KP_BIN/kingpin" wake --timeout 0
tok=$(token_of "$out")
[ "$rc" -eq 3 ] && [ "$tok" = "w1,t4:1" ] && pass "baseline token taken" || fail "baseline: rc=$rc out=$out"
for line in 'needs-input: which way?' 'ready: review=APPROVE' 'fixed: high=0' 'failed: tests red' \
  'failed: no status: the turn ended without a status line' 'waiting: needs-input question.md' \
  'merged: pr=https://example.test/pr/256' 'cleanup-refused: dirty worktree'; do
  printf '%s\n' "$line" >> "$TASKS/t4/status"
  kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
  want_count=$(wc -l < "$TASKS/t4/status" | tr -d ' ')
  [ "$rc" -eq 0 ] && [ "$out" = "$(printf 't4 %s\nresume: w1,t4:%s' "$line" "$want_count")" ] \
    && pass "'${line%%:*}:' wakes (${line})" || fail "'$line': rc=$rc out=$out"
  tok=$(token_of "$out")
done
for line in 'issue: #256' 'approved: dossier' 'feedback: try again' \
  'checks: pr=https://example.test/pr/256 checks=FAILED' 'progress: 50%' 'report: report.html' ''; do
  printf '%s\n' "$line" >> "$TASKS/t4/status"
  before=$(count_in "$tok" t4)
  kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
  tok=$(token_of "$out")
  label=${line%%:*}
  [ -n "$label" ] || label='a blank line'
  [ "$rc" -eq 3 ] && [ "$out" = "resume: $tok" ] && [ "$(count_in "$tok" t4)" -eq $((before + 1)) ] \
    && pass "'$label' does not wake, and the baseline moved past it" \
    || fail "'$line': rc=$rc out=$out (count before $before)"
done

echo "=== Section 5: several lines in one pass ==="
reset_fleet
mk_task t5-a
mk_task t5-b
kp_run out rc "$KP_BIN/kingpin" wake --timeout 0
tok=$(token_of "$out")
printf 'ready: review=APPROVE\nissue: #256\nfailed: oops\n' >> "$TASKS/t5-a/status"
printf 'needs-input: which?\n' >> "$TASKS/t5-b/status"
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
want=$(printf 't5-a ready: review=APPROVE\nt5-a failed: oops\nt5-b needs-input: which?\nresume: w1,t5-a:4,t5-b:2')
[ "$rc" -eq 0 ] && [ "$out" = "$want" ] \
  && pass "three lines in two tasks print in task then file order, resume last" \
  || fail "several lines: rc=$rc out=$out"

echo "=== Section 6: the resume token across a re-arm ==="
reset_fleet
mk_task t6
kp_run out rc "$KP_BIN/kingpin" wake --timeout 1
tok=$(token_of "$out")
[ "$rc" -eq 3 ] && [ "$tok" = "w1,t6:1" ] && pass "arm A timed out with token $tok" || fail "arm A: rc=$rc out=$out"
printf 'needs-input: between arms\n' >> "$TASKS/t6/status"
kp_run out rc "$KP_BIN/kingpin" wake --timeout 0
[ "$rc" -eq 3 ] && [ "$out" = "resume: w1,t6:2" ] \
  && pass "control: a wake without --from does not see a line appended before it started" \
  || fail "control: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
[ "$rc" -eq 0 ] && [ "$out" = "$(printf 't6 needs-input: between arms\nresume: w1,t6:2')" ] \
  && pass "--from the token reports the line appended between arms" || fail "--from: rc=$rc out=$out"
# A count with a leading zero is base 10: `08` is line 8, so line 9 is new.
reset_fleet
mk_task t6-zero
for n in 2 3 4 5 6 7 8; do printf 'issue: #%s\n' "$n" >> "$TASKS/t6-zero/status"; done
printf 'ready: review=APPROVE\n' >> "$TASKS/t6-zero/status"
kp_run out rc "$KP_BIN/kingpin" wake --from 'w1,t6-zero:08' --timeout 0
[ "$rc" -eq 0 ] && [ "$out" = "$(printf 't6-zero ready: review=APPROVE\nresume: w1,t6-zero:9')" ] \
  && pass "--from with a count of 08 reports line 9 and prints the count in base 10" \
  || fail "--from w1,t6-zero:08: rc=$rc out=$out"

echo "=== Section 7: no race with kingpin watch --once ==="
reset_fleet
mk_task t7
kp_run out rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$rc" -eq 0 ] && [ "$(seen_count t7)" = 1 ] \
  && pass "a first sweep set the supervisor's cursor" || fail "first sweep: rc=$rc seen=$(seen_count t7) out=$out"
kp_run out rc "$KP_BIN/kingpin" wake --timeout 0
tok=$(token_of "$out")
printf 'needs-input: first\n' >> "$TASKS/t7/status"
kp_run out rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$rc" -eq 0 ] && [ "$(seen_count t7)" = 2 ] \
  && pass "watch --once dispatched and acked the line" || fail "watch: rc=$rc seen=$(seen_count t7) out=$out"
cur_before=$(cursor_snapshot t7)
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
cur_after=$(cursor_snapshot t7)
[ "$rc" -eq 0 ] && [ "$out" = "$(printf 't7 needs-input: first\nresume: w1,t7:2')" ] \
  && pass "the wake still reports a line the supervisor already acked" || fail "wake after watch: rc=$rc out=$out"
[ -n "$cur_before" ] && [ "$cur_before" = "$cur_after" ] \
  && pass "the wake left seen, seen_line and every seen_* file untouched" \
  || fail "the cursor changed: before=[$cur_before] after=[$cur_after]"
tok=$(token_of "$out")
cur_before=$(cursor_snapshot t7)
bg_wake s7 --from "$tok" --timeout 30
s7_pid=$BG_PID
kp_wait_until 10 wake_idle "$s7_pid" || fail "the second wake never reached its wait step"
cur_mid=$(cursor_snapshot t7)
[ "$cur_before" = "$cur_mid" ] \
  && pass "an armed wake leaves the cursor untouched" || fail "the armed wake changed the cursor: [$cur_before] -> [$cur_mid]"
printf 'needs-input: second\n' >> "$TASKS/t7/status"
kp_run out rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$rc" -eq 0 ] && [ "$(seen_count t7)" = 3 ] \
  && pass "watch --once beside an armed wake dispatched and acked the line" \
  || fail "watch beside the wake: rc=$rc seen=$(seen_count t7) out=$out"
kp_wait_until 10 bg_ended s7 || fail "the wake beside watch --once did not end"
bg_reap "$s7_pid"
[ "$BG_RC" -eq 0 ] && [ "$(cat "$T/s7.out")" = "$(printf 't7 needs-input: second\nresume: w1,t7:3')" ] \
  && pass "the wake beside watch --once reported the same line" \
  || fail "wake beside watch: rc=$BG_RC out=$(cat "$T/s7.out")"

echo "=== Section 8: a task archived by the supervisor ==="
reset_fleet
# The fake archives exactly as kingpin-done does (move, marker, absolute link) for a
# record whose last line is merged:, and refuses anything else, the way a retried
# cleanup that still cannot run refuses, so a cleanup-refused: task stays live.
cat > "$KP_BIN/kingpin-done" <<'DONE'
#!/usr/bin/env bash
set -euo pipefail
id=$1
home=${KINGPIN_HOME:?}
case $(tail -n 1 "$home/tasks/$id/status") in merged:*) ;; *) exit 1 ;; esac
mkdir -p "$home/archive"
dest="$home/archive/$id"
n=1
while [ -e "$dest" ]; do n=$((n + 1)); dest="$home/archive/$id.$n"; done
mv "$home/tasks/$id" "$dest"
touch "$dest/done_cleaned"
ln -s "$(cd "$dest" && pwd -P)" "$home/tasks/$id"
DONE
chmod +x "$KP_BIN/kingpin-done"
mk_task t8-merge
mk_task t8-refused
kp_run out rc "$KP_BIN/kingpin" wake --timeout 0
tok=$(token_of "$out")
printf 'merged: done\n' >> "$TASKS/t8-merge/status"
printf 'cleanup-refused: x\n' >> "$TASKS/t8-refused/status"
kp_run out rc timeout 60 "$KP_BIN/kingpin-watch" --once
[ "$rc" -eq 0 ] && [ -L "$TASKS/t8-merge" ] \
  && pass "the supervisor archived the merged task behind a link" || fail "watch: rc=$rc out=$out"
[ -d "$TASKS/t8-refused" ] && [ ! -L "$TASKS/t8-refused" ] \
  && pass "the cleanup-refused task stayed live" || fail "t8-refused is no longer live"
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 't8-merge merged: done' \
  && pass "the merged: line is reported through the archive link" || fail "archived merged: rc=$rc out=$out"
printf '%s\n' "$out" | grep -qx 't8-refused cleanup-refused: x' \
  && pass "the cleanup-refused: line is reported on the live task" || fail "cleanup-refused: out=$out"
tok=$(token_of "$out")
[ "$(count_in "$tok" t8-merge)" = none ] && [ "$(count_in "$tok" t8-refused)" = 2 ] \
  && pass "the resume token drops the archived task and keeps the live one" || fail "token after archive: $tok"
# The gap inside kingpin done, or a link it never wrote: the record is moved whole and
# no link is at tasks/<id>. The wake reads the newest archive directly. Older records
# of the same id sit at archive/t8-gap and .2 to .9, so the newest is .10, which a
# glob's lexical order would place before .2.
mk_task t8-gap
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
tok=$(token_of "$out")
[ "$(count_in "$tok" t8-gap)" = 1 ] && pass "the gap task is in the baseline" || fail "gap baseline: $out"
mkdir -p "$KINGPIN_HOME/archive/t8-gap"
printf 'issue: old\nmerged: older record\n' > "$KINGPIN_HOME/archive/t8-gap/status"
for n in 2 3 4 5 6 7 8 9; do
  mkdir -p "$KINGPIN_HOME/archive/t8-gap.$n"
  printf 'issue: old\nmerged: older record %s\n' "$n" > "$KINGPIN_HOME/archive/t8-gap.$n/status"
done
printf 'merged: gap\n' >> "$TASKS/t8-gap/status"
mv "$TASKS/t8-gap" "$KINGPIN_HOME/archive/t8-gap.10"
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
[ "$rc" -eq 0 ] && [ "$out" = "$(printf 't8-gap merged: gap\nresume: %s' "${tok/,t8-gap:1/}")" ] \
  && pass "a moved record with no link reports its merged: line from the newest archive" \
  || fail "gap: rc=$rc out=$out"
[ ! -e "$TASKS/t8-gap" ] && pass "the wake wrote no link of its own" || fail "tasks/t8-gap appeared"

echo "=== Section 9: a task spawned after the start ==="
reset_fleet
mk_task t9-old
bg_wake s9 --timeout 30
s9_pid=$BG_PID
kp_wait_until 10 wake_idle "$s9_pid" || fail "the wake never reached its wait step"
mk_task t9-new 'ready: review=APPROVE'
kp_wait_until 10 bg_ended s9 || fail "the wake did not end on the new task"
bg_reap "$s9_pid"
[ "$BG_RC" -eq 0 ] && [ "$(cat "$T/s9.out")" = "$(printf 't9-new ready: review=APPROVE\nresume: w1,t9-old:1,t9-new:1')" ] \
  && pass "a task spawned after the start is watched from its first line" \
  || fail "late spawn: rc=$BG_RC out=$(cat "$T/s9.out")"

echo "=== Section 10: a rewritten file ==="
reset_fleet
mk_task t10
printf 'ready: review=APPROVE\n' >> "$TASKS/t10/status"
kp_run out rc "$KP_BIN/kingpin" wake --from 'w1,t10:9' --timeout 0
[ "$rc" -eq 3 ] && [ "$out" = "resume: w1,t10:2" ] \
  && pass "a file shorter than its baseline resets it and replays nothing" || fail "rewritten: rc=$rc out=$out"

echo "=== Section 11: the wake writes nothing ==="
reset_fleet
mk_task t11
kp_run out rc "$KP_BIN/kingpin" wake --timeout 0
tok=$(token_of "$out")
printf 'needs-input: snap\n' >> "$TASKS/t11/status"
snap_before=$(home_snapshot "$KINGPIN_HOME")
kp_run out rc "$KP_BIN/kingpin" wake --from "$tok" --timeout 0
snap_after=$(home_snapshot "$KINGPIN_HOME")
[ "$rc" -eq 0 ] && pass "the reporting run printed its line" || fail "reporting run: rc=$rc out=$out"
[ "$snap_before" = "$snap_after" ] \
  && pass "a run that reported lines wrote nothing under KINGPIN_HOME" \
  || fail "the reporting run changed KINGPIN_HOME: $(diff <(printf '%s\n' "$snap_before") <(printf '%s\n' "$snap_after") | tr '\n' '|')"
snap_before=$(home_snapshot "$KINGPIN_HOME")
kp_run out rc "$KP_BIN/kingpin" wake --timeout 1
snap_after=$(home_snapshot "$KINGPIN_HOME")
[ "$rc" -eq 3 ] && pass "the quiet run timed out" || fail "quiet run: rc=$rc out=$out"
[ "$snap_before" = "$snap_after" ] \
  && pass "a run that timed out wrote nothing under KINGPIN_HOME" \
  || fail "the quiet run changed KINGPIN_HOME: $(diff <(printf '%s\n' "$snap_before") <(printf '%s\n' "$snap_after") | tr '\n' '|')"

echo "=== Section 12: static, the wake calls no writer ==="
wake_code=$(grep -v '^[[:space:]]*#' "$KP_ROOT/bin/kingpin-wake")
for pattern in kingpin-wait kingpin-ack kingpin-launch-check kingpin-rename kingpin-guard lib/mux.sh mkdir touch; do
  printf '%s\n' "$wake_code" | grep -qF -- "$pattern" \
    && fail "bin/kingpin-wake names $pattern outside a comment" \
    || pass "bin/kingpin-wake does not name $pattern"
done
printf '%s\n' "$wake_code" | grep -qE '>>?[[:space:]]*"?\$\{?(KP_HOME|KINGPIN_HOME|tasks_dir)' \
  && fail "bin/kingpin-wake redirects into a path under KINGPIN_HOME" \
  || pass "bin/kingpin-wake redirects into no path under KINGPIN_HOME"

echo "=== Section 13: the contract rule in the installed copies ==="
git init -q -b main "$T/kp-checkout"
mkdir -p "$T/kp-checkout/orchestrator"
cp "$KP_ROOT/orchestrator/contract.md" "$T/kp-checkout/orchestrator/contract.md"
git -C "$T/kp-checkout" add orchestrator/contract.md
git -C "$T/kp-checkout" -c user.email=t@t -c user.name=t commit -q -m init
kp_run out rc "$KP_BIN/kingpin-guard" install --dir "$T/kp-checkout"
[ "$rc" -eq 0 ] && pass "guard install exits 0" || fail "guard install: rc=$rc out=$out"
for copy in "$KINGPIN_HOME/orchestrator.md" "$T/kp-checkout/.claude/rules/kingpin-orchestrator.md" \
  "$T/kp-checkout/.agents/rules/kingpin.md"; do
  for phrase in 'kingpin wake --from' 'never use it as the supervisor' "never \`bin/kingpin ack\` a line it printed"; do
    grep -qF -- "$phrase" "$copy" \
      && pass "${copy#"$T"/} carries '$phrase'" || fail "${copy#"$T"/} lacks '$phrase'"
  done
done
kp_run out rc "$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout"
[ "$rc" -eq 0 ] && pass "guard check passes over the installed copies" || fail "guard check: rc=$rc out=$out"

kp_test_finish WAKE
