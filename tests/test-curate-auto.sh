#!/usr/bin/env bash
# Verification test for Kingpin: the automatic curator trigger (issue #88).
#
# The trigger rides kingpin-watch --once. Every case runs against a temp skills
# clone, a stubbed `gh` and a fake curator, so nothing here touches the real
# ~/.claude/skills or GitHub.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "curate-auto"
kp_test_project

# A real skills checkout: a bare origin, a clone, and one commit on main.
git init -q --bare "$T/skills-origin.git"
git clone -q "$T/skills-origin.git" "$T/skills" 2>/dev/null
(
  cd "$T/skills" || exit 1
  git checkout -q -b main
  echo "# Skills" > SKILL.md
  git add SKILL.md
  git commit -qm "init"
  git push -q -u origin main
)
# The curator's target check compares gh's base repository with the origin URL, so
# the origin has to name a GitHub repository. The push above is already done; an
# insteadOf rewrite keeps every later `git fetch`/`push` on the local bare repo so
# no test reaches the network.
git -C "$T/skills" remote set-url origin https://github.com/laanhema/skills.git
git -C "$T/skills" config "url.$T/skills-origin.git.insteadOf" https://github.com/laanhema/skills.git

# A gh stub that records argv and answers the calls the curator flow makes. The
# target answers come from the REST pull request the check reads. gh 2.97.0 has no
# `baseRepository` field for `pr view --json`, so the stub refuses that field the
# way the real gh does: a regression to it fails here instead of passing quietly.
# The curator's own `--mark-applied` runs inside the tmux window, which does not
# inherit the suite's KP_TEST_* variables, so the stub reads the exported
# KINGPIN_SKILLS_DIR and logs to /dev/null when the log variable is not there.
cat > "$T/bin/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KP_TEST_GH_LOG:-/dev/null}"
case "$*" in
  "pr create"*) echo "https://github.com/laanhema/skills/pull/7" ;;
  "pr merge"*) exit 0 ;;
esac
case "$*" in
  # gh 2.97.0 has no baseRepository field for `gh pr view --json`.
  *"--json"*baseRepository*)
    echo 'gh: Unknown JSON field: "baseRepository"' >&2
    exit 1
    ;;
  "api repos/someone-else/other-repo/pulls/"*)
    printf 'someone-else/other-repo curator/2026-01-01\n'
    ;;
  "api repos/laanhema/skills/pulls/9 --jq"*)
    printf 'laanhema/skills curator/1999-12-31\n'
    ;;
  "api repos/laanhema/skills/pulls/500 --jq"*)
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  "api repos/laanhema/skills/pulls/"*)
    printf 'laanhema/skills %s\n' "$(git -C "${KINGPIN_SKILLS_DIR:?}" symbolic-ref --short HEAD)"
    ;;
  "pr view "*"--json state"*) echo MERGED ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$T/bin/gh"

# The fake curator opens a PR and marks the batch applied, the way the preamble
# tells the real curator to: it checks out the branch the record names first, so
# the applied marker's head check sees the branch the PR really came from.
cat > "$T/fake-curator" << EOF_CURATOR
#!/usr/bin/env bash
printf 'call\n' >> "$T/curator-calls.log"
branch=\$(sed -n 's/^BRANCH=//p' "\$KINGPIN_HOME/tasks/curator/task.env" 2>/dev/null | tail -n 1)
[ -z "\$branch" ] || git -C "$T/skills" checkout -q -B "\$branch" main
url="https://github.com/laanhema/skills/pull/7"
printf '%s\n' "\$url" > "\$KINGPIN_HOME/curator/pr"
$KP_BIN/kingpin-curate --mark-applied "\$url" >/dev/null 2>&1
exit 0
EOF_CURATOR
chmod +x "$T/fake-curator"

export KINGPIN_SKILLS_DIR=$T/skills
export KINGPIN_CURATOR_AUTO=1
export KINGPIN_GH=$T/bin/gh
export KINGPIN_CURATOR_CMD=$T/fake-curator
export KP_TEST_GH_LOG=$T/gh-calls.log
: > "$KP_TEST_GH_LOG"
: > "$T/curator-calls.log"

curator_calls() {
  if [ -f "$T/curator-calls.log" ]; then
    wc -l < "$T/curator-calls.log" | tr -d ' '
  else
    echo 0
  fi
}

calls_eq() { [ "$(curator_calls)" = "$1" ]; }

# curator_pane_dead: the staged curator window's pane has exited. remain-on-exit
# keeps the window, which is what lets the guard see a dead pane at all.
curator_pane_dead() {
  [ "$(tmux list-panes -t kingpin:curator -F '#{pane_dead}' 2>/dev/null || echo 0)" = "1" ]
}

# reset_state: forget every curator and task record but keep the project config.
reset_state() {
  tmux kill-window -t kingpin:curator 2>/dev/null || true
  sleep 0.2
  rm -rf "$KINGPIN_HOME"/tasks/* "$KINGPIN_HOME"/archive/* "$KINGPIN_HOME"/curator
  rm -f "$KINGPIN_HOME"/projects/*.landing "$KINGPIN_HOME"/projects/*.landing_queue \
    "$KINGPIN_HOME"/projects/*.landing.mutex
  : > "$T/curator-calls.log"
}

seed_critiques() { # <n>: archive-task critiques, the shape kingpin done leaves behind
  local n=$1 i
  for i in $(seq 1 "$n"); do
    mkdir -p "$KINGPIN_HOME/archive/c$i"
    echo "critique c$i" > "$KINGPIN_HOME/archive/c$i/critique"
  done
}

mk_live_task() { # <id>
  local id=$1
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF
TASK_ID=$id
PROJECT=demo-auto
PROJECT_PATH=$T/proj
HARNESS=claude
MODE=review
TMUX_TARGET=kingpin:$id
EOF
}

# mk_task <id> <last-status-line> [done_cleaned]: a real task record whose last
# worker line is the given one; `done_cleaned` adds the marker kingpin-done writes
# after a successful cleanup. Unlike mk_live_task, this writes a status file.
mk_task() { # <id> <last-status-line> [done_cleaned]
  local id=$1 last=$2 marker=${3:-}
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF
TASK_ID=$id
PROJECT=demo-auto
PROJECT_PATH=$T/proj
HARNESS=claude
MODE=review
TMUX_TARGET=kingpin:$id
EOF
  printf '%s\n' "$last" > "$KINGPIN_HOME/tasks/$id/status"
  if [ "$marker" = done_cleaned ]; then touch "$KINGPIN_HOME/tasks/$id/done_cleaned"; fi
  return 0
}

# mk_curator_record <branch> <pr>: a live curator task waiting for review, with
# no report.html, so a sweep reports it without arming a dossier listener.
mk_curator_record() {
  local branch=$1 pr=$2
  mkdir -p "$KINGPIN_HOME/tasks/curator" "$KINGPIN_HOME/curator"
  cat > "$KINGPIN_HOME/tasks/curator/task.env" << EOF
TASK_ID=curator
PROJECT=curator
PROJECT_PATH=$T/skills
HARNESS=claude
MODE=review
BRANCH=$branch
WORKTREE=$T/skills
TMUX_TARGET=kingpin:curator
CREATED=$(date +%Y-%m-%dT%H:%M:%S%z)
NO_LEASE=1
CURATOR=1
EOF
  printf 'ready: branch=%s review=PENDING report=%s pr=%s\n' "$branch" \
    "$KINGPIN_HOME/tasks/curator/report.html" "$pr" > "$KINGPIN_HOME/tasks/curator/status"
  printf '%s\n' "$pr" > "$KINGPIN_HOME/curator/pr"
}

run_watch() {
  "$KP_BIN/kingpin-watch" --once >"$T/watch.out" 2>&1
}

watch_out() { cat "$T/watch.out"; }

last_run_day() { sed -n 2p "$KINGPIN_HOME/curator/last-run" 2>/dev/null || true; }

# Test 1: below the three-critique threshold, nothing starts and the day is unclaimed
echo "=== Test 1: threshold ==="
reset_state
seed_critiques 2
run_watch
kp_holds_for 0.5 calls_eq 0 && pass "two pending critiques start no curator" || fail "a curator started below the threshold"
[ ! -f "$KINGPIN_HOME/curator/last-run" ] && pass "a below-threshold tick claims no day" || fail "a below-threshold tick claimed the day"

# Test 1b: a tick that launches nothing starts no tmux server (issue #191 review M3).
# The trigger reads local files only, so a stamped day on a dead server must stay dead.
echo "=== Test 1b: a skipped tick starts no server ==="
reset_state
seed_critiques 3
mkdir -p "$KINGPIN_HOME/curator"
printf '1\n%s\n' "$(date +%F)" > "$KINGPIN_HOME/curator/last-run"
tmux kill-server 2>/dev/null || true
tmux list-sessions >/dev/null 2>&1 \
  && fail "the fleet server survived the reset" \
  || pass "the fleet server is down before a skipped tick"
"$KP_BIN/kingpin-curate" --auto >/dev/null 2>&1 || true
tmux list-sessions >/dev/null 2>&1 \
  && fail "a skipped --auto tick started the tmux server" \
  || pass "a skipped --auto tick starts no tmux server"
calls_eq 0 && pass "the skipped tick launched no curator" || fail "the skipped tick launched a curator"
# The rest of the suite expects the suite's fleet server.
tmux new-session -d -s kingpin -n home

# Test 2: a live fleet task holds the trigger back
echo "=== Test 2: live fleet ==="
reset_state
seed_critiques 3
mk_live_task busy
printf 'needs-input: confirm the API shape\n' > "$KINGPIN_HOME/tasks/busy/status"
run_watch
kp_holds_for 0.5 calls_eq 0 && pass "a live task keeps the curator from starting" || fail "a curator started with a live task in the fleet"
! watch_out | grep -q "task curator is still live" && pass "an ordinary busy fleet adds no curator diagnostic" || fail "the busy gate printed a curator diagnostic: $(watch_out)"
watch_out | grep -qF "task busy is still in flight (last status: needs-input: confirm the API shape)" \
  && pass "the in-flight task is named in the tick output" \
  || fail "the tick did not name the in-flight task: $(watch_out)"

# Test 2b: a record whose work is over does not hold the gate, even when its
# cleanup never archived it (#198).
echo "=== Test 2b: finished records are idle ==="
reset_state
seed_critiques 3
mk_task merged 'merged: pr=https://github.com/laanhema/skills/pull/3'
auto_out=$("$KP_BIN/kingpin-curate" --auto 2>&1)
kp_wait_until 10 calls_eq 1 \
  && pass "a merged record with no cleanup starts the curator" \
  || fail "a curator did not start with a merged record (calls=$(curator_calls)): $auto_out"
! printf '%s\n' "$auto_out" | grep -q "is still in flight" \
  && pass "a merged record is not named as in flight" \
  || fail "a merged record was named as in flight: $auto_out"

reset_state
seed_critiques 3
mk_task silent 'failed: no status: worker stopped without reporting'
auto_out=$("$KP_BIN/kingpin-curate" --auto 2>&1)
kp_wait_until 10 calls_eq 1 \
  && pass "a silent record starts the curator" \
  || fail "a curator did not start with a failed: no status: record (calls=$(curator_calls)): $auto_out"
! printf '%s\n' "$auto_out" | grep -q "is still in flight" \
  && pass "a silent record is not named as in flight" \
  || fail "a silent record was named as in flight: $auto_out"

reset_state
seed_critiques 3
mk_task marker 'ready: branch=b review=APPROVE report=r' done_cleaned
auto_out=$("$KP_BIN/kingpin-curate" --auto 2>&1)
kp_wait_until 10 calls_eq 1 \
  && pass "a done_cleaned record starts the curator" \
  || fail "a curator did not start with a done_cleaned record (calls=$(curator_calls)): $auto_out"
! printf '%s\n' "$auto_out" | grep -q "is still in flight" \
  && pass "a done_cleaned record is not named as in flight" \
  || fail "a done_cleaned record was named as in flight: $auto_out"

reset_state
seed_critiques 3
mk_task landed 'merged: pr=https://github.com/laanhema/skills/pull/4'
touch "$KINGPIN_HOME/tasks/landed/landing_in_progress"
auto_out=$("$KP_BIN/kingpin-curate" --auto 2>&1)
kp_wait_until 10 calls_eq 1 \
  && pass "a terminal record still carrying landing_in_progress starts the curator" \
  || fail "a curator did not start with a terminal landing_in_progress record (calls=$(curator_calls)): $auto_out"
! printf '%s\n' "$auto_out" | grep -q "is still in flight" \
  && pass "a terminal landing_in_progress record is not named as in flight" \
  || fail "a terminal landing_in_progress record was named as in flight: $auto_out"

# Test 2c: cleanup-refused: is not finished, because kingpin-watch retries it.
echo "=== Test 2c: an interrupted cleanup holds the gate ==="
reset_state
seed_critiques 3
mk_task stubborn 'cleanup-refused: worktree has uncommitted changes'
auto_out=$("$KP_BIN/kingpin-curate" --auto 2>&1)
kp_holds_for 0.5 calls_eq 0 \
  && pass "a cleanup-refused record keeps the curator from starting" \
  || fail "a curator started with a cleanup-refused record in the fleet"
stubborn_holds=$(printf '%s\n' "$auto_out" | grep -cF 'task stubborn is still in flight (last status: cleanup-refused:' || true)
[ "$stubborn_holds" = "1" ] \
  && pass "the cleanup-refused record is named once in the output" \
  || fail "the cleanup-refused record was named $stubborn_holds times: $auto_out"
[ ! -f "$KINGPIN_HOME/curator/last-run" ] \
  && pass "a cleanup-refused record claims no day" \
  || fail "a cleanup-refused record claimed the day"

# Test 3: an empty landing lane is required too
echo "=== Test 3: landing gates ==="
reset_state
seed_critiques 3
mk_live_task busy
touch "$KINGPIN_HOME/tasks/busy/landing_in_progress"
run_watch
kp_holds_for 0.5 calls_eq 0 && pass "landing_in_progress keeps the curator from starting" || fail "a curator started during a landing"

reset_state
seed_critiques 3
printf 'ghost\n' > "$KINGPIN_HOME/projects/demo.landing_queue"
"$KP_BIN/kingpin-curate" --auto >/dev/null 2>&1 || true
kp_holds_for 0.5 calls_eq 0 && pass "a pending project landing keeps the curator from starting" || fail "a curator started with a queued landing"

reset_state
seed_critiques 3
mk_live_task holder
printf 'holder\n' > "$KINGPIN_HOME/projects/demo.landing"
run_watch
kp_holds_for 0.5 calls_eq 0 && pass "a live landing holder keeps the curator from starting" || fail "a curator started while a landing holder was live"

# Test 4: at most one launch per calendar day
echo "=== Test 4: once a day ==="
reset_state
seed_critiques 3
run_watch
kp_wait_until 10 calls_eq 1 && pass "an idle fleet with three critiques starts one curator" || fail "the curator did not start (calls=$(curator_calls))"
[ "$(last_run_day)" = "$(date +%F)" ] && pass "the run claims today's day stamp" || fail "the day stamp is wrong: $(last_run_day)"
sleep 1
run_watch
kp_holds_for 0.5 calls_eq 1 && pass "a second idle moment the same day starts nothing" || fail "a second curator started the same day"
# The operator landed the first PR: archive the finished curator record and free
# the fleet, then pretend the day has rolled over.
"$KP_BIN/kingpin" "done" curator >/dev/null 2>&1 || true
reset_state
seed_critiques 3
mkdir -p "$KINGPIN_HOME/curator"
printf '1\n2000-01-01\n' > "$KINGPIN_HOME/curator/last-run"
run_watch
kp_wait_until 10 calls_eq 1 && pass "a fresh day starts exactly one more curator" || fail "a fresh day did not start a curator (calls=$(curator_calls))"
[ "$(last_run_day)" = "$(date +%F)" ] && pass "the fresh-day run claims the new day" || fail "the fresh-day run did not claim the day"

# Test 5: an existing window is a reported no-op, a dead pane is reaped
echo "=== Test 5: existing window ==="
reset_state
seed_critiques 3
tmux new-window -d -t kingpin: -n curator "sleep 300"
run_watch
sleep 0.5
watch_out | grep -q "curator window kingpin:curator is already active; the automatic run skipped" \
  && pass "an existing curator window is reported, not duplicated" \
  || fail "no existing-window line: $(watch_out)"
[ "$(curator_calls)" = "0" ] && pass "an existing curator window launches nothing" || fail "a second curator launched over a live window"
[ "$(last_run_day)" = "$(date +%F)" ] && pass "an existing window claims the day" || fail "an existing window did not claim the day: $(last_run_day)"
tmux kill-window -t kingpin:curator 2>/dev/null || true

reset_state
seed_critiques 3
tmux set-option -g remain-on-exit on
tmux new-window -d -t kingpin: -n curator "bash -c 'exit 3'"
kp_wait_until 4 curator_pane_dead \
  && pass "dead curator pane staged" || fail "could not stage a dead curator pane"
run_watch
kp_wait_until 10 calls_eq 1 && pass "a dead curator pane is reaped and replaced" || fail "no curator after the dead pane (calls=$(curator_calls))"
watch_out | grep -q "reaped dead curator window" && pass "the dead-window reap is reported" || fail "reap not reported: $(watch_out)"
tmux set-option -g remain-on-exit off

# Test 5a: a refused reap is reported, not called done (issue #182)
reset_state
seed_critiques 3
tmux set-option -g remain-on-exit on
tmux new-window -d -t kingpin: -n curator "bash -c 'exit 3'"
kp_wait_until 4 curator_pane_dead \
  && pass "a dead curator pane is staged for the refused reap" \
  || fail "could not stage a dead pane for the refused reap"
mkdir -p "$T/failbin"
cat > "$T/failbin/tmux" << FAILTMUX
#!/usr/bin/env bash
case " \$* " in
  *" kill-window "*curator*) echo "tmux: refusing kill-window from the suite" >&2; exit 1 ;;
esac
exec "$T/bin/tmux" "\$@"
FAILTMUX
chmod +x "$T/failbin/tmux"
PATH="$T/failbin:$PATH" run_watch
watch_out | grep -q "could not reap dead curator window" \
  && pass "an automatic run reports a refused reap" \
  || fail "the automatic refused reap is silent: $(watch_out)"
watch_out | grep -q "reaped dead curator window" \
  && fail "the automatic run reported a refused reap as done: $(watch_out)" \
  || pass "the automatic run does not report a refused reap as done"
[ "$(last_run_day)" = "$(date +%F)" ] \
  && pass "a refused reap still claims the day" \
  || fail "a refused reap left the day unclaimed: $(last_run_day)"
tmux list-windows -t kingpin -F '#{window_id} #{window_name}' \
  | awk '$2 == "curator" { print $1 }' \
  | while read -r w; do tmux kill-window -t "$w" 2>/dev/null || true; done
tmux set-option -g remain-on-exit off
reset_state

# Test 5b: a record without TMUX_SOCKET is probed where its window really lives
# ---------------------------------------------------------------------------
# A curator record written before the fleet had its own server (issue #142) names
# no socket, so its window is on the default server. The liveness probe must read
# the record's socket, not the current environment's, or it misses a live curator
# and launches a second one beside it.
reset_state
seed_critiques 3
mk_curator_record "curator/$(date +%F)" "none"
tmux -L default new-session -d -s kingpin -n curator "sleep 300"
run_watch
sleep 0.5
watch_out | grep -q "curator window kingpin:curator is already active; the automatic run skipped" \
  && pass "a record without TMUX_SOCKET sees its default-server window as live" \
  || fail "the record's default-server window was missed: $(watch_out)"
[ "$(curator_calls)" = "0" ] && pass "an old record's live window launches nothing" || fail "a second curator launched over the default-server window"
tmux -L default kill-server 2>/dev/null || true

# Test 5c: the reap never kills a window it did not probe (issue #191 review M4).
# An archived record (the symlink `kingpin done` leaves) names a dead pane in S1 while
# the configured session is S2, where a live curator window sits. The resolved window
# decides: the trigger skips, claims the day, and the live window stays.
echo "=== Test 5c: the reap follows the resolved window ==="
reset_state
seed_critiques 3
printf 'TMUX_SOCKET=kingpin\nTMUX_SESSION=S2\n' > "$KINGPIN_HOME/config.env"
tmux new-session -d -s S1 -n home
tmux new-session -d -s S2 -n home
tmux set-option -g remain-on-exit on
tmux new-window -d -t S1: -n curator "bash -c 'exit 3'"
t5c_s1_dead() { [ "$(tmux list-panes -t S1:curator -F '#{pane_dead}' 2>/dev/null)" = 1 ]; }
kp_wait_until 4 t5c_s1_dead && pass "a dead pane is staged in the record's session" || fail "could not stage a dead pane in S1:curator"
tmux new-window -d -t S2: -n curator "sleep 300"
live_pid=$(tmux list-panes -t S2:curator -F '#{pane_pid}')
mkdir -p "$KINGPIN_HOME/archive/curator"
cat > "$KINGPIN_HOME/archive/curator/task.env" << EOF_T5C
TASK_ID=curator
PROJECT=curator
PROJECT_PATH=$T/skills
HARNESS=claude
MODE=review
BRANCH=curator/2026-01-01
WORKTREE=$T/skills
MUX=tmux
NO_LEASE=1
CURATOR=1
TMUX_SOCKET=kingpin
TMUX_TARGET=S1:curator
MUX_TARGET=S1:curator
EOF_T5C
printf 'failed: the curator stopped\n' > "$KINGPIN_HOME/archive/curator/status"
ln -s "$KINGPIN_HOME/archive/curator" "$KINGPIN_HOME/tasks/curator"
run_watch
watch_out | grep -q "curator window .*S2:curator is already active; the automatic run skipped" \
  && pass "the trigger skips the live window under the resolved session" \
  || fail "no skip line for the resolved session's window: $(watch_out)"
tmux list-panes -t S2:curator -F '#{pane_pid}' 2>/dev/null | grep -qxF -- "$live_pid" \
  && pass "the live window under the resolved session survived the sweep" \
  || fail "the sweep killed the live window under the resolved session: $(watch_out)"
kp_holds_for 0.5 calls_eq 0 && pass "the skipped sweep launched no curator" || fail "the skipped sweep launched a curator"
[ "$(last_run_day)" = "$(date +%F)" ] && pass "the skipped sweep claims the day" || fail "the skipped sweep claimed no day: $(last_run_day)"
tmux set-option -g remain-on-exit off
tmux kill-session -t S1 2>/dev/null || true
tmux kill-session -t S2 2>/dev/null || true
rm -f "$KINGPIN_HOME/config.env"

# Test 6: two triggers in parallel still start one curator
echo "=== Test 6: concurrency ==="
reset_state
seed_critiques 3
"$KP_BIN/kingpin-curate" --auto >/dev/null 2>&1 &
auto_a=$!
"$KP_BIN/kingpin-curate" --auto >/dev/null 2>&1 &
auto_b=$!
wait "$auto_a" 2>/dev/null || true
wait "$auto_b" 2>/dev/null || true
kp_wait_until 10 calls_eq 1 && pass "two parallel triggers start exactly one curator" || fail "parallel triggers started $(curator_calls) curators"

# Test 7: the marker at PR-open records the URL and is idempotent
echo "=== Test 7: marker at PR open ==="
reset_state
seed_critiques 3
run_watch
kp_wait_until 10 calls_eq 1 || fail "the seed run did not start a curator"
kp_wait_until 10 test -f "$KINGPIN_HOME/tasks/c1/critique.consumed" || test -f "$KINGPIN_HOME/archive/c1/critique.consumed" \
  && pass "a real run consumes the batch" \
  || fail "the batch was not consumed"
pr_marker=""
for f in "$KINGPIN_HOME"/archive/c1/critique.applied.*.pr "$KINGPIN_HOME"/tasks/c1/critique.applied.*.pr; do
  [ -f "$f" ] && pr_marker=$f && break
done
[ -n "$pr_marker" ] && grep -qxF "https://github.com/laanhema/skills/pull/7" "$pr_marker" \
  && pass "the applied marker records the PR URL" \
  || fail "critique.applied.*.pr missing or wrong: ${pr_marker:-none}"
: > "$KP_TEST_GH_LOG"
mark_out=$("$KP_BIN/kingpin-curate" --mark-applied "https://github.com/laanhema/skills/pull/7" 2>&1)
echo "$mark_out" | grep -q "OK: marked 0 critique(s)" \
  && pass "marking an already-applied batch prints 0" \
  || fail "second mark-applied output: $mark_out"
grep -qE "^api repos/laanhema/skills/pulls/7( |$)" "$KP_TEST_GH_LOG" \
  && pass "the target check reads the PR through the REST call" \
  || fail "no REST pull request read in the gh log: $(cat "$KP_TEST_GH_LOG")"
! grep -q baseRepository "$KP_TEST_GH_LOG" \
  && pass "the target check does not ask for the gh 2.97.0 field" \
  || fail "the target check still asks for baseRepository: $(cat "$KP_TEST_GH_LOG")"
grep -qE "^api repos/laanhema/skills/pulls/7 .*--hostname github\.com$" "$KP_TEST_GH_LOG" \
  && pass "the target check addresses the host the PR URL names" \
  || fail "no --hostname from the PR URL in the gh log: $(cat "$KP_TEST_GH_LOG")"
dry_out=$("$KP_BIN/kingpin-curate" --dry-run 2>&1)
echo "$dry_out" | grep -q "no pending skill critiques" \
  && pass "the dry run reports no pending critique after the marker" \
  || fail "the dry run still lists pending critiques: $dry_out"

# Test 8: kingpin land curator merges the PR and archives the record
echo "=== Test 8: land ==="
reset_state
cur_branch="curator/$(date +%F)"
git -C "$T/skills" checkout -q -B "$cur_branch" main
pr_url="https://github.com/laanhema/skills/pull/8"
mkdir -p "$KINGPIN_HOME/tasks/curator" "$KINGPIN_HOME/curator"
cat > "$KINGPIN_HOME/tasks/curator/task.env" << EOF
TASK_ID=curator
PROJECT=curator
PROJECT_PATH=$T/skills
HARNESS=claude
MODE=review
BRANCH=$cur_branch
WORKTREE=$T/skills
TMUX_TARGET=kingpin:curator
CREATED=$(date +%Y-%m-%dT%H:%M:%S%z)
NO_LEASE=1
CURATOR=1
EOF
printf 'ready: branch=%s review=PENDING report=%s pr=%s\n' "$cur_branch" \
  "$KINGPIN_HOME/tasks/curator/report.html" "$pr_url" > "$KINGPIN_HOME/tasks/curator/status"
printf '%s\n' "$pr_url" > "$KINGPIN_HOME/curator/pr"
land_rc=0
land_out=$("$KP_BIN/kingpin" land curator 2>&1) || land_rc=$?
[ "$land_rc" -eq 0 ] && pass "kingpin land curator exits 0" || fail "kingpin land curator exit=$land_rc: $land_out"
grep -qE "^pr merge $pr_url( |$)" "$KP_TEST_GH_LOG" \
  && pass "the PR was merged through gh" \
  || fail "gh log has no merge of $pr_url: $(cat "$KP_TEST_GH_LOG")"
archived_status=$(cat "$KINGPIN_HOME/archive/curator/status" 2>/dev/null || true)
echo "$archived_status" | grep -qxF "merged: pr=$pr_url" \
  && pass "the archived curator status records the merge" \
  || fail "no merged: line in the archive: $archived_status"
[ -L "$KINGPIN_HOME/tasks/curator" ] \
  && pass "tasks/curator is a link to the archive after landing" \
  || fail "tasks/curator is not the archive link after landing"
git -C "$T/skills" checkout -q main 2>/dev/null || true

# Test 9: a due curator never delays a landing (or the supervisor tick)
echo "=== Test 9: no delay for a landing ==="
reset_state
seed_critiques 3
tmux new-window -t kingpin -n kp88-probe 'exec bash'
probe_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="kp88-probe"{print $1}')
[ -n "$probe_wid" ] && pass "probe window created" || fail "could not create the probe window"
mkdir -p "$KINGPIN_HOME/tasks/t-auto"
cat > "$KINGPIN_HOME/tasks/t-auto/task.env" << EOF
TASK_ID=t-auto
PROJECT=demo-auto
PROJECT_PATH=$T/proj
HARNESS=claude
MODE=auto
ISSUE=88
TMUX_TARGET=kingpin:t-auto
TMUX_WINDOW_ID=$probe_wid
EOF
printf 'ready: branch=kingpin/x review=APPROVE report=none\n' > "$KINGPIN_HOME/tasks/t-auto/status"
tick_start=$(date +%s)
run_watch
tick_elapsed=$(( $(date +%s) - tick_start ))
[ "$tick_elapsed" -le 5 ] \
  && pass "the supervisor tick finished in ${tick_elapsed}s with a due curator" \
  || fail "the supervisor tick took ${tick_elapsed}s with a due curator"
watch_out | grep -q "t-auto is ready (auto mode); initiating landing" \
  && pass "the landing still started in the same tick" \
  || fail "the landing was skipped: $(watch_out)"
tmux kill-window -t "$probe_wid" 2>/dev/null || true

# Test 10: a live curator record that nobody landed says why the day is skipped
echo "=== Test 10: a stuck curator record ==="
reset_state
seed_critiques 3
cur_branch="curator/$(date +%F)"
stuck_pr="https://github.com/laanhema/skills/pull/55"
mk_curator_record "$cur_branch" "$stuck_pr"
run_watch
kp_holds_for 0.5 calls_eq 0 && pass "a live curator record starts no curator" || fail "a curator started over a live record"
watch_out | grep -q "task curator is still live" \
  && pass "the live curator record is named in the tick output" \
  || fail "the tick said nothing about the live record: $(watch_out)"
watch_out | grep -q "last status: ready: branch=$cur_branch" \
  && pass "the diagnostic carries the record's last status line" \
  || fail "the diagnostic lost the status line: $(watch_out)"
watch_out | grep -q "pr=$stuck_pr" \
  && pass "the diagnostic names the recorded PR" \
  || fail "the diagnostic lost the PR: $(watch_out)"
[ ! -f "$KINGPIN_HOME/curator/last-run" ] && pass "the held-back tick claims no day" || fail "the held-back tick claimed the day"

# Test 11: a manual run leaves a live curator record alone
echo "=== Test 11: a manual run over a live record ==="
cp "$KINGPIN_HOME/tasks/curator/status" "$T/stuck-status.before"
cp "$KINGPIN_HOME/tasks/curator/task.env" "$T/stuck-env.before"
manual_rc=0
manual_out=$("$KP_BIN/kingpin-curate" 2>&1) || manual_rc=$?
[ "$manual_rc" -eq 1 ] && pass "a manual run over a live curator record exits 1" || fail "manual run exit=$manual_rc: $manual_out"
echo "$manual_out" | grep -q "land or close its PR first" \
  && pass "the refusal says what to do with the PR" \
  || fail "refusal text: $manual_out"
cmp -s "$T/stuck-status.before" "$KINGPIN_HOME/tasks/curator/status" \
  && pass "the live record's status file survives the refused run" \
  || fail "the refused manual run rewrote the status file"
cmp -s "$T/stuck-env.before" "$KINGPIN_HOME/tasks/curator/task.env" \
  && pass "the live record's task.env survives the refused run" \
  || fail "the refused manual run rewrote task.env"
grep -qxF "$stuck_pr" "$KINGPIN_HOME/curator/pr" \
  && pass "the recorded PR survives the refused run" \
  || fail "the refused run replaced the recorded PR"
[ "$(curator_calls)" = "0" ] && pass "the refused run launched no curator" || fail "the refused run launched a curator"

# Test 12: a launch that fails before the window is retried on the next tick
echo "=== Test 12: a failed tmux launch ==="
reset_state
seed_critiques 3
mkdir -p "$T/failbin"
cat > "$T/failbin/tmux" << EOF_TMUX
#!/usr/bin/env bash
prev=''
for a in "\$@"; do
  if [ "\$prev" = "-n" ] && [ "\$a" = "curator" ]; then
    echo "tmux: simulated window failure" >&2
    exit 1
  fi
  prev=\$a
done
exec "$T/bin/tmux" "\$@"
EOF_TMUX
chmod +x "$T/failbin/tmux"
launch_rc=0
PATH="$T/failbin:$PATH" "$KP_BIN/kingpin-curate" --auto >"$T/launch.out" 2>&1 || launch_rc=$?
[ "$launch_rc" -eq 0 ] && pass "a failed launch still exits 0 in the automatic path" || fail "failed launch exit=$launch_rc: $(cat "$T/launch.out")"
grep -q "could not launch the curator" "$T/launch.out" \
  && pass "the failed launch is reported" \
  || fail "no launch-failure line: $(cat "$T/launch.out")"
[ ! -f "$KINGPIN_HOME/curator/last-run" ] && pass "a failed launch does not claim the day" || fail "a failed launch claimed the day"
[ ! -d "$KINGPIN_HOME/tasks/curator" ] && pass "a failed launch leaves no half-written curator record" || fail "tasks/curator survived a failed launch"
run_watch
kp_wait_until 10 calls_eq 1 && pass "the next tick retries the launch" || fail "the next tick did not retry (calls=$(curator_calls))"

# Test 13: land refuses a PR that is not in the skills repository
echo "=== Test 13: land target repository ==="
reset_state
cur_branch="curator/$(date +%F)"
git -C "$T/skills" checkout -q -B "$cur_branch" main
mk_curator_record "$cur_branch" "https://github.com/someone-else/other-repo/pull/1234"
: > "$KP_TEST_GH_LOG"
land_rc=0
land_out=$("$KP_BIN/kingpin" land curator 2>&1) || land_rc=$?
[ "$land_rc" -eq 1 ] && pass "a PR in another repository is refused" || fail "foreign land exit=$land_rc: $land_out"
echo "$land_out" | grep -q "not the skills origin (laanhema/skills)" \
  && pass "the refusal names both repositories" \
  || fail "refusal text: $land_out"
! grep -qE "^pr merge " "$KP_TEST_GH_LOG" \
  && pass "no merge was attempted on the foreign PR" \
  || fail "the foreign PR was merged: $(cat "$KP_TEST_GH_LOG")"
[ ! -f "$KINGPIN_HOME/tasks/curator/landing_sent" ] \
  && pass "the refused target leaves no landing marker" \
  || fail "landing_sent was written for a refused target"
! grep -q '^merged:' "$KINGPIN_HOME/tasks/curator/status" \
  && pass "the refused target records no merge" \
  || fail "status records a merge of a refused target"

# Test 14: land refuses a PR from a branch the record did not open
echo "=== Test 14: land target branch ==="
reset_state
cur_branch="curator/$(date +%F)"
git -C "$T/skills" checkout -q -B "$cur_branch" main
mk_curator_record "$cur_branch" "https://github.com/laanhema/skills/pull/9"
: > "$KP_TEST_GH_LOG"
land_rc=0
land_out=$("$KP_BIN/kingpin" land curator 2>&1) || land_rc=$?
[ "$land_rc" -eq 1 ] && pass "a PR from another branch is refused" || fail "wrong-head land exit=$land_rc: $land_out"
echo "$land_out" | grep -q "not the recorded '$cur_branch'" \
  && pass "the refusal names the recorded branch" \
  || fail "refusal text: $land_out"
! grep -qE "^pr merge " "$KP_TEST_GH_LOG" \
  && pass "no merge was attempted for the wrong head branch" \
  || fail "the wrong-head PR was merged: $(cat "$KP_TEST_GH_LOG")"

# Test 15: --mark-applied refuses a PR in another repository too
echo "=== Test 15: mark-applied target ==="
reset_state
mkdir -p "$KINGPIN_HOME/tasks/c1" "$KINGPIN_HOME/curator/collected"
printf 'critique c1\n' > "$KINGPIN_HOME/tasks/c1/critique"
cp "$KINGPIN_HOME/tasks/c1/critique" "$KINGPIN_HOME/curator/collected/c1"
printf '%s\n' "$KINGPIN_HOME/tasks/c1/critique" > "$KINGPIN_HOME/curator/batch-critiques.txt"
mark_rc=0
mark_out=$("$KP_BIN/kingpin-curate" --mark-applied "https://github.com/someone-else/other-repo/pull/7" 2>&1) || mark_rc=$?
[ "$mark_rc" -eq 1 ] && pass "mark-applied refuses a PR in another repository" || fail "foreign mark-applied exit=$mark_rc: $mark_out"
echo "$mark_out" | grep -q "not the skills origin" \
  && pass "the mark-applied refusal names the origin" \
  || fail "refusal text: $mark_out"
[ -f "$KINGPIN_HOME/tasks/c1/critique" ] \
  && pass "the refused marker leaves the critique pending" \
  || fail "a foreign URL consumed the critique"

# Test 15b: --mark-applied refuses a PR gh cannot read, and a URL that is not a PR
echo "=== Test 15b: mark-applied unreadable PR ==="
reset_state
mkdir -p "$KINGPIN_HOME/tasks/c1" "$KINGPIN_HOME/curator/collected"
printf 'critique c1\n' > "$KINGPIN_HOME/tasks/c1/critique"
cp "$KINGPIN_HOME/tasks/c1/critique" "$KINGPIN_HOME/curator/collected/c1"
printf '%s\n' "$KINGPIN_HOME/tasks/c1/critique" > "$KINGPIN_HOME/curator/batch-critiques.txt"
mark_rc=0
mark_out=$("$KP_BIN/kingpin-curate" --mark-applied "https://github.com/laanhema/skills/pull/500" 2>&1) || mark_rc=$?
[ "$mark_rc" -eq 1 ] && pass "mark-applied refuses a PR gh cannot read" || fail "unreadable mark-applied exit=$mark_rc: $mark_out"
echo "$mark_out" | grep -q "Not Found (HTTP 404)" \
  && pass "the refusal names the gh error" \
  || fail "refusal text: $mark_out"
[ -f "$KINGPIN_HOME/tasks/c1/critique" ] \
  && pass "the unreadable PR leaves the critique pending" \
  || fail "an unreadable PR consumed the critique"
mark_rc=0
mark_out=$("$KP_BIN/kingpin-curate" --mark-applied "https://github.com/laanhema/skills/issues/7" 2>&1) || mark_rc=$?
[ "$mark_rc" -eq 1 ] && pass "mark-applied refuses a URL that is not a pull request" || fail "non-PR mark-applied exit=$mark_rc: $mark_out"
echo "$mark_out" | grep -q "is not a pull request URL" \
  && pass "the non-PR refusal names the URL shape" \
  || fail "refusal text: $mark_out"
[ -f "$KINGPIN_HOME/tasks/c1/critique" ] \
  && pass "the non-PR URL leaves the critique pending" \
  || fail "a non-PR URL consumed the critique"

# Test 16: a terminal curator record is archived without the merge verification
echo "=== Test 16: terminal record reconcile ==="
reset_state
cur_branch="curator/$(date +%F)"
git -C "$T/skills" checkout -q -B "$cur_branch" main
printf 'an unmerged curator edit\n' >> "$T/skills/SKILL.md"
git -C "$T/skills" commit -qam "curator: unmerged edit"
mk_curator_record "$cur_branch" "https://github.com/laanhema/skills/pull/55"
printf 'failed: the curator stopped\n' >> "$KINGPIN_HOME/tasks/curator/status"
run_watch
sleep 0.5
[ -L "$KINGPIN_HOME/tasks/curator" ] \
  && pass "the terminal record is archived without the merge verification" \
  || fail "the terminal record still holds tasks/curator: $(watch_out)"
[ -d "$KINGPIN_HOME/archive/curator" ] && pass "the archive holds the record" || fail "no archive/curator after the reconcile"
git -C "$T/skills" checkout -q main 2>/dev/null || true
git -C "$T/skills" branch -D "$cur_branch" >/dev/null 2>&1 || true

# Test 16b: a finished curator record the reconcile cannot archive is left intact
# (#198 review M1). `kingpin done` dies on the record's missing WORKTREE before it
# writes a cleanup-refused: line, so the record is still a real directory when the
# launch would overwrite it. Both paths must stop and keep its evidence.
echo "=== Test 16b: an unarchivable curator record ==="
reset_state
seed_critiques 3
cur_branch="curator/$(date +%F)"
unarchived_pr="https://github.com/laanhema/skills/pull/56"
mk_curator_record "$cur_branch" "$unarchived_pr"
printf 'merged: pr=%s\n' "$unarchived_pr" >> "$KINGPIN_HOME/tasks/curator/status"
grep -v '^WORKTREE=' "$KINGPIN_HOME/tasks/curator/task.env" > "$T/curator-env.noworktree"
cp "$T/curator-env.noworktree" "$KINGPIN_HOME/tasks/curator/task.env"
cp "$KINGPIN_HOME/tasks/curator/status" "$T/unarchived-status.before"
auto_out='' auto_rc=0
kp_run auto_out auto_rc "$KP_BIN/kingpin-curate" --auto
[ "$auto_rc" -eq 0 ] \
  && pass "an unarchivable curator record exits 0 in the automatic path" \
  || fail "the automatic path exited $auto_rc: $auto_out"
kp_holds_for 0.5 calls_eq 0 \
  && pass "an unarchivable curator record launches no curator" \
  || fail "a curator launched over the unarchived record"
printf '%s\n' "$auto_out" | grep -qF "the finished curator record could not be archived (last status: merged: pr=$unarchived_pr)" \
  && pass "the automatic path names the unarchived record" \
  || fail "no unarchived-record line on the automatic path: $auto_out"
auto_notes=$(printf '%s\n' "$auto_out" | grep -cF 'could not be archived' || true)
[ "$auto_notes" = "1" ] \
  && pass "the automatic path reports the unarchived record once" \
  || fail "the unarchived record was reported $auto_notes times: $auto_out"
cmp -s "$T/unarchived-status.before" "$KINGPIN_HOME/tasks/curator/status" \
  && pass "the unarchived record's status survives the automatic path" \
  || fail "the automatic path rewrote the unarchived record's status"
cmp -s "$T/curator-env.noworktree" "$KINGPIN_HOME/tasks/curator/task.env" \
  && pass "the unarchived record's task.env survives the automatic path" \
  || fail "the automatic path rewrote the unarchived record's task.env"
[ ! -f "$KINGPIN_HOME/curator/last-run" ] \
  && pass "an unarchivable record claims no day" \
  || fail "an unarchivable record claimed the day"

manual_out='' manual_rc=0
kp_run manual_out manual_rc "$KP_BIN/kingpin-curate"
[ "$manual_rc" -eq 1 ] \
  && pass "a manual run over an unarchivable curator record exits 1" \
  || fail "the manual run exited $manual_rc: $manual_out"
printf '%s\n' "$manual_out" | grep -qF "could not be archived" \
  && pass "the manual refusal names the unarchived record" \
  || fail "no unarchived-record line on the manual path: $manual_out"
printf '%s\n' "$manual_out" | grep -qF "run kingpin done curator to see why" \
  && pass "the manual refusal names the recovery step" \
  || fail "the manual refusal lost the recovery step: $manual_out"
cmp -s "$T/unarchived-status.before" "$KINGPIN_HOME/tasks/curator/status" \
  && pass "the unarchived record's status survives the manual path" \
  || fail "the manual path rewrote the unarchived record's status"
cmp -s "$T/curator-env.noworktree" "$KINGPIN_HOME/tasks/curator/task.env" \
  && pass "the unarchived record's task.env survives the manual path" \
  || fail "the manual path rewrote the unarchived record's task.env"

tmux kill-window -t kingpin:curator 2>/dev/null || true
kp_test_finish CURATE-AUTO
