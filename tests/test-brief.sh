#!/usr/bin/env bash
# Verification test for Kingpin: `kingpin brief`, the one-screen fleet digest (issue #188).
#
# Covers the digest on an empty fleet and on a fixture of every shape it reports: a live
# task waiting on a review, a task blocked on a human, a review whose landing already
# started, a task whose window is gone, a cleaned-up record and an archived dossier link.
# It checks that the board and the digest read the same state for every task, that the
# output is one line per task with no pane dump, that the action sections appear and
# disappear as their markers change, a queued review and a fix pass with High findings
# left outside the approval count, a window that outlived its harness, the queue pause
# state, the AFK and supervisor lines, the landing lanes, a record naming a server that
# is not running, the read-only guarantee, and the two refusals of the command's own
# argument parsing.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "brief"
# shellcheck source=../lib/portable.sh
. "$KP_ROOT/lib/portable.sh"
# shellcheck source=../lib/afk.sh
. "$KP_ROOT/lib/afk.sh"

# brief_task <home> <id> <project> <status line>...
# One live record: task.env naming the suite's tmux server and a window called <id>,
# and the given status lines. The window itself is brief_window's job, because a case
# about a dead record must not create one.
brief_task() {
  local home=$1 id=$2 project=$3 d
  shift 3
  d="$home/tasks/$id"
  mkdir -p "$d"
  {
    printf 'TASK_ID=%s\nPROJECT=%s\nHARNESS=agy\nMODE=review\n' "$id" "$project"
    printf 'TMUX_SOCKET=%s\nTMUX_TARGET=kingpin:%s\n' "$KINGPIN_TMUX_SOCKET" "$id"
  } > "$d/task.env"
  printf '%s\n' "$@" > "$d/status"
}

# brief_pane_runs <window-id> <expected-command>: 0 while the pane runs that command,
# which is how a window stops reading as a plain shell and the shared resolver reads
# the recorded harness as live.
brief_pane_runs() {
  [ "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" = "$2" ]
}

# brief_window <id>: a window named <id> running a non-shell command, waited for so the
# row that reads it cannot race the window's start.
brief_window() {
  local id=$1 win
  win=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "$id" 'exec sleep 300')
  if kp_wait_until 5 brief_pane_runs "$win" sleep; then
    pass "window $id is up and runs a command"
  else
    fail "window $id never settled on a non-shell command"
  fi
  printf '%s\n' "$win"
}

# brief_has <output> <label> <line>: the digest carries exactly this line.
brief_has() {
  local out=$1 label=$2 want=$3
  if printf '%s\n' "$out" | grep -qxF -- "$want"; then
    pass "$label: '$want'"
  else
    fail "$label: missing '$want' in: $(printf '%s' "$out" | tr '\n' '|')"
  fi
}

# brief_matches <output> <label> <ERE>: at least one line of the digest matches.
brief_matches() {
  local out=$1 label=$2 want=$3
  if printf '%s\n' "$out" | grep -qE -- "$want"; then
    pass "$label: a line matches /$want/"
  else
    fail "$label: no line matches /$want/ in: $(printf '%s' "$out" | tr '\n' '|')"
  fi
}

# brief_lacks <output> <label> <ERE>: no line of the digest matches.
brief_lacks() {
  local out=$1 label=$2 want=$3
  if printf '%s\n' "$out" | grep -qE -- "$want"; then
    fail "$label: an unexpected line matches /$want/ in: $(printf '%s' "$out" | tr '\n' '|')"
  else
    pass "$label: no line matches /$want/"
  fi
}

# brief_state <output> <task-id> <column-start> <column-width>: the STATE column of that
# task's row, trimmed. The columns before it are the same width in both tables (id 22,
# project 10, harness 8, mode 12), and `brief` then prints the state where `list` first
# prints its SESSION column (10) and then the state, so the two starts differ.
brief_state() {
  local out=$1 id=$2 start=$3 width=$4 row
  row=$(printf '%s\n' "$out" | grep -E "^$id " || true)
  [ -n "$row" ] || return 0
  printf '%s\n' "$row" | awk -v s0="$start" -v w="$width" '{ s = substr($0, s0, w); sub(/[ \t]+$/, "", s); print s }'
}

# brief_snapshot: every file under $KINGPIN_HOME as <mtime>\t<crc>\t<path>, so a run
# that wrote anything, however small, changes the listing.
brief_snapshot() {
  local f
  find "$KINGPIN_HOME" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' \
      "$(kp_mtime "$f" 2>/dev/null || echo missing)" \
      "$(cksum < "$f" | awk '{print $1}')" \
      "$f"
  done
}

echo "=== Test 1: an empty fleet and a missing home ==="
brief_out='' brief_rc=0
t1_home="$T/t1-home"
kp_run brief_out brief_rc env KINGPIN_HOME="$t1_home" "$KP_BIN/kingpin" brief
[ "$brief_rc" -eq 0 ] && pass "an empty fleet exits 0" || fail "an empty fleet exited $brief_rc: $brief_out"
for want in \
  'Fleet: no live tasks' \
  'Supervisor: none - run kingpin watch' \
  'AFK: off' \
  'Queue: none'
do
  brief_has "$brief_out" "empty fleet" "$want"
done
[ ! -e "$t1_home" ] \
  && pass "a missing home is still absent after the run" \
  || fail "the run created $t1_home"
brief_lacks "$brief_out" "empty fleet" '^TASK ID '

echo "=== Test 2: the fleet fixture ==="
brief_window kp-live >/dev/null
brief_window kp-waiting >/dev/null
brief_window kp-nits >/dev/null
brief_window kp-fixed >/dev/null
brief_task "$KINGPIN_HOME" kp-live demo \
  'issue: #188 https://example/188' \
  'ready: branch=b review=APPROVE report=.agents/reviews/188-review.md'
echo '<html></html>' > "$KINGPIN_HOME/tasks/kp-live/report.html"
brief_task "$KINGPIN_HOME" kp-waiting demo 'needs-input: which option?'
brief_task "$KINGPIN_HOME" kp-nits demo 'ready: branch=b review=NEEDS CHANGES report=r.md'
brief_task "$KINGPIN_HOME" kp-fixed demo 'fixed: high=0 report=.agents/reviews/188-review.md'
touch "$KINGPIN_HOME/tasks/kp-fixed/landing_in_progress"
# A record whose window is gone: nothing ever created one.
brief_task "$KINGPIN_HOME" kp-dead demo 'ready: branch=b review=APPROVE report=r.md'
# A cleaned-up record and the dossier link kingpin done leaves: neither is a live task.
brief_task "$KINGPIN_HOME" kp-done demo 'merged: pr=https://example/pull/2'
touch "$KINGPIN_HOME/tasks/kp-done/done_cleaned"
mkdir -p "$KINGPIN_HOME/archive/kp-archived"
printf 'merged: pr=https://example/pull/3\n' > "$KINGPIN_HOME/archive/kp-archived/status"
ln -s "$KINGPIN_HOME/archive/kp-archived" "$KINGPIN_HOME/tasks/kp-archived"

kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
[ "$brief_rc" -eq 0 ] && pass "the fixture exits 0" || fail "the fixture exited $brief_rc: $brief_out"
for want in \
  'Fleet: 5 live task(s), 2 waiting for approval, 1 dead - run kingpin restore' \
  'Queue: none'
do
  brief_has "$brief_out" "fixture header" "$want"
done
brief_matches "$brief_out" "fixture" '^kp-waiting .*WAITING'
brief_matches "$brief_out" "fixture" '^kp-dead .*DEAD'
brief_lacks "$brief_out" "fixture" '^kp-done'
brief_lacks "$brief_out" "fixture" '^kp-archived'
# Bounded output: one row per task and no pane dump, which `list` adds below a row.
for id in kp-live kp-waiting kp-nits kp-fixed kp-dead; do
  rows=$(printf '%s\n' "$brief_out" | grep -cE "^$id " || true)
  [ "$rows" -eq 1 ] && pass "$id: exactly one line" || fail "$id: $rows lines"
done
brief_lacks "$brief_out" "fixture" '↳'
# The approval section names the review waiting on a decision, with its verdict and the
# report the worker handed over, and leaves out the one whose landing already started.
brief_matches "$brief_out" "approvals" '^  kp-live +APPROVE +report: \.agents/reviews/188-review\.md$'
brief_matches "$brief_out" "approvals" '^  kp-nits +NEEDS CHANGES \(fix pass first\) +report: r\.md$'
brief_lacks "$brief_out" "approvals" '^  kp-fixed '
brief_lacks "$brief_out" "approvals" '^  kp-waiting '
# The dossier section names the page and the one command that opens it: no listener
# recorded a URL yet.
brief_matches "$brief_out" "dossiers" "^  kp-live +lavish-axi .*/tasks/kp-live/report\\.html$"

echo "=== Test 3: the board and the digest read the same state ==="
list_out='' list_rc=0
kp_run list_out list_rc "$KP_BIN/kingpin" list
[ "$list_rc" -eq 0 ] && pass "list exits 0 beside the digest" || fail "list exited $list_rc: $list_out"
for id in kp-live kp-waiting kp-nits kp-fixed kp-dead; do
  brief_s=$(brief_state "$brief_out" "$id" 57 12)
  list_s=$(brief_state "$list_out" "$id" 68 18)
  [ "$brief_s" = "running" ] && brief_s='-'
  [ "$brief_s" = "$list_s" ] \
    && pass "$id: both read '$list_s'" \
    || fail "$id: brief '$brief_s' vs list '$list_s'"
done

echo "=== Test 4: a dossier listener that runs, and a recorded URL ==="
printf 'http://lavish.example:4387/session/abc\n' > "$KINGPIN_HOME/tasks/kp-live/dossier.url"
printf '%s\n' "$$" > "$KINGPIN_HOME/tasks/kp-live/listener.pid"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
[ "$brief_rc" -eq 0 ] && pass "a listened-to dossier exits 0" || fail "brief exited $brief_rc: $brief_out"
brief_lacks "$brief_out" "listened dossier" '^  kp-live +lavish-axi|http://lavish\.example'
rm -f "$KINGPIN_HOME/tasks/kp-live/listener.pid"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_matches "$brief_out" "recorded URL" '^  kp-live +http://lavish\.example:4387/session/abc$'
sh -c 'exit 0' &
dead_listener=$!
wait "$dead_listener" 2>/dev/null || true
printf '%s\n' "$dead_listener" > "$KINGPIN_HOME/tasks/kp-live/listener.pid"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_matches "$brief_out" "dead listener" '^  kp-live +http://lavish\.example:4387/session/abc$'
rm -f "$KINGPIN_HOME/tasks/kp-live/listener.pid"

echo "=== Test 5: an approval already in flight is not waiting ==="
touch "$KINGPIN_HOME/tasks/kp-live/landing_sent"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_has "$brief_out" "landing sent" 'Fleet: 5 live task(s), 1 waiting for approval, 1 dead - run kingpin restore'
brief_lacks "$brief_out" "landing sent" '^  kp-live +APPROVE'
rm -f "$KINGPIN_HOME/tasks/kp-live/landing_sent"

echo "=== Test 6: the issue-queue pause state ==="
mkdir -p "$KINGPIN_HOME/queue"
printf '189\n190\n191\n' > "$KINGPIN_HOME/queue/queue"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_has "$brief_out" "queue running" 'Queue: 3 waiting, not paused'
printf 'parked by the boss\n' > "$KINGPIN_HOME/queue/pause"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_has "$brief_out" "queue paused" 'Queue: 3 waiting, paused (queue/pause)'
rm -f "$KINGPIN_HOME/queue/pause" "$KINGPIN_HOME/queue/queue"

echo "=== Test 7: the AFK switch ==="
kp_afk_write "$KINGPIN_HOME" "$$" 3600 || fail "the AFK fixture could not be armed"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_matches "$brief_out" "afk armed" "^AFK: on until [0-9:]+ \(pid $$\\)$"
kp_run brief_out brief_rc "$KP_BIN/kingpin" afk off
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_has "$brief_out" "afk off" 'AFK: off'

echo "=== Test 8: the supervisor line ==="
# A stand-in whose argv carries `kingpin-watch`, which is the process check lib/supervisor.sh
# makes; it needs no fleet work, only to stay alive while the digest reads the pidfile.
cat > "$T/bin/kingpin-watch" << 'WATCHEOF'
#!/usr/bin/env bash
sleep 60
WATCHEOF
chmod +x "$T/bin/kingpin-watch"
"$T/bin/kingpin-watch" &
watch_pid=$!
printf '%s\n%s\n' "$watch_pid" "$(date +%s)" > "$KINGPIN_HOME/supervisor.pid"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_matches "$brief_out" "supervisor running" "^Supervisor: running \\(pid $watch_pid, since ([0-9:]+|unknown)\\)$"
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_has "$brief_out" "supervisor gone" 'Supervisor: none - run kingpin watch'
rm -f "$KINGPIN_HOME/supervisor.pid"

echo "=== Test 9: the landing lanes ==="
mkdir -p "$KINGPIN_HOME/projects"
printf 'kp-live\n' > "$KINGPIN_HOME/projects/demo.landing"
printf 'kp-waiting\nkp-dead\n' > "$KINGPIN_HOME/projects/demo.landing_queue"
printf 'kp-fixed\n' > "$KINGPIN_HOME/projects/other.landing_queue"
: > "$KINGPIN_HOME/projects/idle.landing"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
brief_matches "$brief_out" "held lane" '^  demo +holder kp-live, 2 queued$'
brief_matches "$brief_out" "free lane" '^  other +holder free, 1 queued$'
brief_lacks "$brief_out" "empty lane" '^  idle '
rm -f "$KINGPIN_HOME/projects/demo.landing" "$KINGPIN_HOME/projects/demo.landing_queue" \
  "$KINGPIN_HOME/projects/other.landing_queue" "$KINGPIN_HOME/projects/idle.landing"

echo "=== Test 10: a record naming a server that is not running ==="
t10_home="$T/t10-home"
brief_task "$t10_home" kp-away demo 'issue: #188'
kp_test_sub "$t10_home/tasks/kp-away/task.env" "s|^TMUX_SOCKET=.*|TMUX_SOCKET=kingpin-brief-missing|"
kp_run brief_out brief_rc env KINGPIN_HOME="$t10_home" "$KP_BIN/kingpin" brief
[ "$brief_rc" -eq 0 ] && pass "a dead server still exits 0" || fail "a dead server exited $brief_rc: $brief_out"
brief_matches "$brief_out" "dead server" '^kp-away .*DEAD'
brief_has "$brief_out" "dead server" 'Fleet: 1 live task(s), 0 waiting for approval, 1 dead - run kingpin restore'

echo "=== Test 11: the command writes nothing ==="
before=$(brief_snapshot)
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
after=$(brief_snapshot)
[ "$brief_rc" -eq 0 ] && pass "the digest exits 0" || fail "the digest exited $brief_rc: $brief_out"
[ "$before" = "$after" ] \
  && pass "the run wrote nothing under KINGPIN_HOME" \
  || fail "the run changed KINGPIN_HOME: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' '|')"

echo "=== Test 12: help and refusals ==="
brief_help='' brief_help_rc=0
kp_run brief_help brief_help_rc "$KP_BIN/kingpin" brief --help
[ "$brief_help_rc" -eq 0 ] && printf '%s' "$brief_help" | grep -qi 'usage' \
  && pass "brief --help exits 0 with usage" \
  || fail "brief --help rc=$brief_help_rc out=$(printf '%s' "$brief_help" | head -n 1)"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief --bogus
[ "$brief_rc" -eq 2 ] && pass "an unknown argument exits 2" || fail "an unknown argument exited $brief_rc"

echo "=== Test 13: a queued review waits for the lane, not for approval ==="
# The fixture's two approvals are kp-live and kp-nits; a row the project's landing queue
# already holds belongs to the lane line and must not be counted here.
brief_window kp-queued >/dev/null
brief_task "$KINGPIN_HOME" kp-queued demo 'ready: branch=b review=APPROVE report=q.md'
mkdir -p "$KINGPIN_HOME/projects"
printf 'kp-queued\n' > "$KINGPIN_HOME/projects/demo.landing_queue"
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
[ "$brief_rc" -eq 0 ] && pass "a queued review exits 0" || fail "a queued review exited $brief_rc: $brief_out"
brief_has "$brief_out" "queued review" 'Fleet: 6 live task(s), 2 waiting for approval, 1 dead - run kingpin restore'
brief_lacks "$brief_out" "queued review" '^  kp-queued '
brief_matches "$brief_out" "queued review" '^  demo +holder free, 1 queued$'
rm -f "$KINGPIN_HOME/projects/demo.landing_queue"
rm -rf "$KINGPIN_HOME/tasks/kp-queued"

echo "=== Test 14: a fix pass with High findings left needs a re-review ==="
# kingpin land sends /review for a fixed: row whose high= is not zero, so the row is
# labelled and counted apart instead of joining the approvals it cannot land from.
brief_window kp-refix >/dev/null
brief_task "$KINGPIN_HOME" kp-refix demo 'fixed: high=3 report=.agents/reviews/188-review.md'
brief_window kp-fixclean >/dev/null
brief_task "$KINGPIN_HOME" kp-fixclean demo 'fixed: high=0 report=.agents/reviews/188-review.md'
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
[ "$brief_rc" -eq 0 ] && pass "the fixed rows exit 0" || fail "the fixed rows exited $brief_rc: $brief_out"
brief_has "$brief_out" "fixed rows" 'Fleet: 7 live task(s), 3 waiting for approval, 1 need(s) re-review, 1 dead - run kingpin restore'
brief_matches "$brief_out" "fixed rows" '^  kp-refix +fixed: high=3 \(needs re-review\) +report: \.agents/reviews/188-review\.md$'
brief_matches "$brief_out" "fixed rows" '^  kp-fixclean +fixed: high=0 +report: \.agents/reviews/188-review\.md$'
brief_lacks "$brief_out" "fixed rows" '^  kp-refix +fixed: high=3 +report:'

echo "=== Test 15: a window that outlived its harness keeps the SILENT row ==="
# A pane running a plain shell is what a window holds after its harness exits. The
# finished silent stop is terminal, so it is not DEAD, and the row stays SILENT on both
# the digest and the board instead of reading Unseen: N.
kp_gone_win=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n kp-harness-gone 'exec sh')
if kp_wait_until 5 brief_pane_runs "$kp_gone_win" sh; then
  pass "window kp-harness-gone is up and runs a shell"
else
  fail "window kp-harness-gone never settled on a shell"
fi
brief_task "$KINGPIN_HOME" kp-harness-gone demo 'failed: no status: stopped without reporting'
kp_run brief_out brief_rc "$KP_BIN/kingpin" brief
kp_run list_out list_rc "$KP_BIN/kingpin" list
brief_matches "$brief_out" "harness gone (brief)" '^kp-harness-gone .*SILENT'
brief_matches "$list_out" "harness gone (list)" '^kp-harness-gone .*SILENT'

kp_test_finish BRIEF
