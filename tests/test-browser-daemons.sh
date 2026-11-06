#!/usr/bin/env bash
# Verification test for Kingpin: browser daemons do not outlive the task that started them.
# A fake `chrome-devtools-axi-bridge.js` stand-in is started with its working directory inside
# a fixture, so the suite exercises the real ownership rule (the daemon's cwd) without a
# browser; the name mirrors the argv word the real bridge is started with.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "browser-daemons"
kp_test_bsd_shims
kp_test_project
# shellcheck source=../lib/browser.sh
. "$KP_ROOT/lib/browser.sh"

# The fixture daemons are direct children of this shell. A pid that has exited but is not
# reaped yet (a zombie) answers `kill -0`, so every assertion reads the process state.
alive() {
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' || true)
  [ -n "$st" ] || return 1
  case "$st" in Z*) return 1 ;; esac
  return 0
}

fake_daemon=$T/chrome-devtools-axi-bridge.js
cat > "$fake_daemon" << 'DAEMON'
#!/usr/bin/env bash
# Stand-in for the chrome-devtools-axi bridge: it keeps the marker in its own argv, leaves
# a child process, and records that child so the suite can assert the whole tree is gone.
sleep 600 &
echo "$!" > "$1"
wait
DAEMON
chmod +x "$fake_daemon"

# A bridge that forks a child while it shuts down: the child starts after the stop took its
# tree snapshot and inherits the bridge's process group, so only a group kill reaches it.
fake_shutdown_daemon=$T/fork/chrome-devtools-axi-bridge.js
mkdir -p "$T/fork"
cat > "$fake_shutdown_daemon" << 'SHUTDOWN'
#!/usr/bin/env bash
trap 'sleep 600 & echo "$!" > "$1"; exit 0' TERM
while :; do sleep 0.05; done
SHUTDOWN
chmod +x "$fake_shutdown_daemon"

fixture_pids=()
started_pid=''
started_child_file=''
fake_children=$T/daemon-children
mkdir -p "$fake_children"
fake_seq=0
start_fake_daemon() { # <dir>: the pid file stays outside <dir>, so the fixture tree stays clean
  local dir=$1
  fake_seq=$((fake_seq + 1))
  started_child_file=$fake_children/child-$fake_seq.pid
  ( cd "$dir" && exec "$fake_daemon" "$started_child_file" ) >/dev/null 2>&1 &
  started_pid=$!
  fixture_pids+=("$started_pid")
}

start_plain_process() { # <dir>: a process with the same cwd that is not a browser daemon
  local dir=$1
  ( cd "$dir" && exec sleep 600 ) >/dev/null 2>&1 &
  started_pid=$!
  fixture_pids+=("$started_pid")
}

# <dir>: a process whose argv only mentions the bridge name, a log tail. It is not the
# daemon, so the reader must never list it and cleanup must never stop it.
start_marker_mention() {
  local dir=$1 log
  log=$dir/chrome-devtools-axi-bridge.log
  : > "$log"
  ( cd "$dir" && exec tail -f "$log" ) >/dev/null 2>&1 &
  started_pid=$!
  fixture_pids+=("$started_pid")
}

# <dir>: a bridge that leads its own process group and forks a child while it shuts down.
# Job control is on for the launch, which is what puts the job in its own group: without
# that, the fixture would share this shell's group and the group kill could never run.
start_shutdown_daemon() {
  local dir=$1
  fake_seq=$((fake_seq + 1))
  started_child_file=$fake_children/shutdown-$fake_seq.pid
  set -m
  ( cd "$dir" && exec "$fake_shutdown_daemon" "$started_child_file" ) >/dev/null 2>&1 &
  started_pid=$!
  set +m
  fixture_pids+=("$started_pid")
}

argv_has() { # <pid> <fixed string>: the process is visible in ps with that argv
  ps -o args= -p "$1" 2>/dev/null | grep -qF -- "$2"
}

daemon_seen() { # <dir> <pid>: the ps table sees the daemon once it has started
  kp_browser_daemons_under "$1" | cut -f1 | grep -qx "$2"
}

child_pid() { # <pid-file>: the pid the fake daemon recorded for its child
  local file=$1
  kp_wait_until 5 test -s "$file" || return 1
  head -n 1 "$file"
}

stop_fixtures() {
  local p
  for p in ${fixture_pids[@]+"${fixture_pids[@]}"}; do
    kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
  done
  kp_test_cleanup
}
trap stop_fixtures EXIT

# --- t1: the shared reader, its ownership boundary and the size formatter -----------------
echo "=== Test t1: shared browser-daemon reader (lib/browser.sh) ==="
t1_dir=$T/t1-task
t1_dir_other=$T/t1-task-other
t1_wt=$T/t1-worktree
mkdir -p "$t1_dir" "$t1_dir_other" "$t1_wt/sub"
start_fake_daemon "$t1_dir"; t1_pid=$started_pid
start_fake_daemon "$t1_wt/sub"; t1_wt_pid=$started_pid
start_fake_daemon "$t1_dir_other"; t1_other_pid=$started_pid
start_marker_mention "$t1_dir"; t1_mention_pid=$started_pid
kp_wait_until 5 daemon_seen "$t1_dir" "$t1_pid" && pass "t1: the daemon in the task folder is in the table" || fail "t1: daemon $t1_pid never appeared in the table"
kp_wait_until 5 daemon_seen "$t1_wt/sub" "$t1_wt_pid" && pass "t1: the daemon below the worktree is in the table" || fail "t1: daemon $t1_wt_pid never appeared in the table"
kp_wait_until 5 argv_has "$t1_mention_pid" "chrome-devtools-axi-bridge.log" || fail "t1: the log-tail process never started"
t1_rows=$(kp_browser_daemons_under "$t1_dir")
printf '%s\n' "$t1_rows" | cut -f1 | grep -qx "$t1_pid" && pass "t1: a task folder matches its own daemon" || fail "t1: task folder did not match its daemon: $t1_rows"
printf '%s\n' "$t1_rows" | cut -f1 | grep -qx "$t1_mention_pid" && fail "t1: a process that only mentions the bridge name was listed as a daemon" || pass "t1: a process that only mentions the bridge name is not a daemon"
kp_browser_pid_is_daemon "$t1_mention_pid" && fail "t1: a process that only mentions the bridge name passes the kill re-check" || pass "t1: a process that only mentions the bridge name fails the kill re-check"
kp_browser_pid_is_daemon "$t1_pid" && pass "t1: the bridge script itself passes the kill re-check" || fail "t1: the daemon $t1_pid failed the kill re-check"
printf '%s\n' "$t1_rows" | cut -f1 | grep -qx "$t1_other_pid" && fail "t1: a sibling path with a shared prefix matched" || pass "t1: 't1-task' does not match 't1-task-other'"
printf '%s\n' "$t1_rows" | cut -f1 | grep -qx "$t1_wt_pid" && fail "t1: a task folder matched a daemon under another worktree" || pass "t1: a task folder does not match an unrelated worktree"
t1_wt_rows=$(kp_browser_daemons_under "$t1_wt")
printf '%s\n' "$t1_wt_rows" | cut -f1 | grep -qx "$t1_wt_pid" && pass "t1: a worktree matches a daemon in one of its subdirectories" || fail "t1: worktree did not match its subdirectory daemon: $t1_wt_rows"
t1_memory=$(printf '%s\n' "$t1_rows" | cut -f2)
case "$t1_memory" in ''|*[!0-9]*) fail "t1: RSS total is not a number: $t1_memory" ;; *) pass "t1: RSS total is a number of kilobytes ($t1_memory)" ;; esac
[ "$(kp_browser_size 1048576)" = "1.0 GB" ] && pass "t1: one GiB formats as 1.0 GB" || fail "t1: 1048576 kB formatted as $(kp_browser_size 1048576)"
[ "$(kp_browser_size 512000)" = "500 MB" ] && pass "t1: 512000 kB formats as 500 MB" || fail "t1: 512000 kB formatted as $(kp_browser_size 512000)"

# --- t2: kingpin done stops the task's daemons and leaves everyone else alone -------------
echo "=== Test t2: kingpin done stops the task's browser daemons ==="
t2_spawn=$("$KP_BIN/kingpin" spawn demo-auto --text "browser fixture zero" --id t2-browser)
t2_dir=$KINGPIN_HOME/tasks/t2-browser
t2_wt=$(sed -n 's/^WORKTREE=//p' "$t2_dir/task.env")
[ -n "$t2_wt" ] && [ -d "$t2_wt" ] && pass "t2: the fixture task leased a worktree" || fail "t2: no fixture task: $t2_spawn"

# One live task that never runs this cleanup, holding a daemon of its own: it must survive.
t2_bystander_dir=$KINGPIN_HOME/tasks/t2-bystander
t2_bystander_wt=$T/t2-bystander-worktree
mkdir -p "$t2_bystander_dir" "$t2_bystander_wt"
cat > "$t2_bystander_dir/task.env" << EOF
TASK_ID=t2-bystander
PROJECT=demo-browser
PROJECT_PATH=$T/proj
WORKTREE=$t2_bystander_wt
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:t2-bystander
EOF
printf '%s\n' "ready: branch=b review=APPROVE report=none" > "$t2_bystander_dir/status"

start_fake_daemon "$t2_dir"; t2_dir_pid=$started_pid; t2_dir_child_file=$started_child_file
start_fake_daemon "$t2_wt"; t2_wt_pid=$started_pid; t2_wt_child_file=$started_child_file
start_fake_daemon "$t2_bystander_dir"; t2_other_daemon_pid=$started_pid
start_plain_process "$t2_dir"; t2_plain_pid=$started_pid
start_marker_mention "$t2_dir"; t2_mention_pid=$started_pid
start_shutdown_daemon "$t2_dir"; t2_shutdown_pid=$started_pid; t2_shutdown_child_file=$started_child_file
kp_wait_until 5 daemon_seen "$t2_dir" "$t2_dir_pid" || fail "t2: the task-folder daemon never started"
kp_wait_until 5 daemon_seen "$t2_wt" "$t2_wt_pid" || fail "t2: the worktree daemon never started"
kp_wait_until 5 daemon_seen "$t2_bystander_dir" "$t2_other_daemon_pid" || fail "t2: the bystander daemon never started"
kp_wait_until 5 argv_has "$t2_mention_pid" "chrome-devtools-axi-bridge.log" || fail "t2: the log-tail process never started"
t2_shutdown_pgid=$(ps -o pgid= -p "$t2_shutdown_pid" 2>/dev/null | tr -d ' ' || true)
[ "$t2_shutdown_pgid" = "$t2_shutdown_pid" ] && pass "t2: the shutdown-forking daemon leads its own process group" || fail "t2: daemon $t2_shutdown_pid is in group $t2_shutdown_pgid, so the group-kill case cannot be exercised"
t2_child=$(child_pid "$t2_dir_child_file" || true)
t2_wt_child=$(child_pid "$t2_wt_child_file" || true)

if t2_out=$("$KP_BIN/kingpin-done" t2-browser --force 2>/dev/null); then t2_rc=0; else t2_rc=$?; fi
[ "$t2_rc" -eq 0 ] && pass "t2: kingpin done exited 0" || fail "t2: kingpin done exited $t2_rc: $t2_out"
alive "$t2_dir_pid" && fail "t2: the task-folder daemon survived cleanup (pid $t2_dir_pid)" || pass "t2: the task-folder daemon is gone"
alive "$t2_wt_pid" && fail "t2: the worktree daemon survived cleanup (pid $t2_wt_pid)" || pass "t2: the worktree daemon is gone"
[ -z "$t2_child" ] || { alive "$t2_child" && fail "t2: the task-folder daemon's child survived (pid $t2_child)" || pass "t2: the task-folder daemon's child is gone"; }
[ -z "$t2_wt_child" ] || { alive "$t2_wt_child" && fail "t2: the worktree daemon's child survived (pid $t2_wt_child)" || pass "t2: the worktree daemon's child is gone"; }
t2_shutdown_child=$(child_pid "$t2_shutdown_child_file" || true)
[ -z "$t2_shutdown_child" ] || { alive "$t2_shutdown_child" && fail "t2: a child the bridge forked while shutting down survived (pid $t2_shutdown_child)" || pass "t2: a child the bridge forked while shutting down is gone"; }
alive "$t2_other_daemon_pid" && pass "t2: a daemon belonging to another task was left alone" || fail "t2: the other task's daemon was killed"
alive "$t2_plain_pid" && pass "t2: a non-daemon process in the task folder was left alone" || fail "t2: a non-daemon process in the task folder was killed"
alive "$t2_mention_pid" && pass "t2: a process that only mentions the bridge name was left alone" || fail "t2: a process that only mentions the bridge name was killed (pid $t2_mention_pid)"
printf '%s\n' "$t2_out" | grep -q "; stopped 3 browser daemons" && pass "t2: the OK line names the three stopped daemons" || fail "t2: OK line missing the stop note: $t2_out"
[ -L "$KINGPIN_HOME/tasks/t2-browser" ] && [ -d "$KINGPIN_HOME/archive/t2-browser" ] && pass "t2: the task was archived after the stop" || fail "t2: the task was not archived"
# The bystander's record goes, so a later list call sees only the task it asks about.
# Its daemon stays alive until the suite's trap, which also proves it was never touched.
rm -rf "$t2_bystander_dir" "$t2_bystander_wt"

# --- t3: kingpin spawn stops a daemon left in a pooled slot -------------------------------
echo "=== Test t3: kingpin spawn clears a browser daemon from a pooled slot ==="
# The slot is prepared by hand and leased through a `treehouse` stand-in, because the real
# pool skips a slot while a process holds its cwd (measured on treehouse v3.1.1): the spawn's
# job is to clear the slot it was handed, and the stand-in hands it the one with the leftover.
t3_slot=$T/t3-slot
git -C "$T/proj" worktree add -q -b kingpin/t3-second "$t3_slot" main
mkdir -p "$T/t3-bin"
cat > "$T/t3-bin/treehouse" << TREEEOF
#!/usr/bin/env bash
case "\${1:-}" in
  get) printf '%s\n' "$t3_slot" ;;
  return) printf 'return %s\n' "\$*" >> "$T/t3-treehouse.log" ;;
esac
exit 0
TREEEOF
chmod +x "$T/t3-bin/treehouse"
start_fake_daemon "$t3_slot"; t3_leftover_pid=$started_pid
kp_wait_until 5 daemon_seen "$t3_slot" "$t3_leftover_pid" && pass "t3: a daemon was left in the slot before the spawn" || fail "t3: the leftover daemon never started"
t3_err=$T/t3-spawn.err
t3_spawn=$(PATH="$T/t3-bin:$PATH" "$KP_BIN/kingpin" spawn demo-auto --text "browser fixture two" --id t3-second 2>"$t3_err")
t3_wt=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/t3-second/task.env" 2>/dev/null || true)
[ "$t3_wt" = "$t3_slot" ] && pass "t3: the spawn leased the prepared slot" || fail "t3: spawn leased $t3_wt, not $t3_slot ($t3_spawn)"
alive "$t3_leftover_pid" && fail "t3: the leftover daemon survived the spawn (pid $t3_leftover_pid)" || pass "t3: the leftover daemon is gone"
grep -q "kingpin-spawn: stopped 1 browser daemon left in $t3_slot" "$t3_err" && pass "t3: the spawn named the stopped daemon and the slot" || fail "t3: spawn stderr missing the note: $(cat "$t3_err")"
PATH="$T/t3-bin:$PATH" "$KP_BIN/kingpin" "done" t3-second --force >/dev/null 2>&1 || true

# --- t4: kingpin list shows per-task browser memory --------------------------------------
echo "=== Test t4: kingpin list shows the browser processes a task holds ==="
t4_wt=$T/t4-worktree
mkdir -p "$KINGPIN_HOME/tasks/t4-with-browser" "$KINGPIN_HOME/tasks/t4-clean" "$t4_wt"
git -C "$t4_wt" init -q
make_idle_task() { # <id> <worktree> <last-status>
  local id=$1 wt=$2 st=$3
  mkdir -p "$KINGPIN_HOME/tasks/$id"
  cat > "$KINGPIN_HOME/tasks/$id/task.env" << EOF
TASK_ID=$id
PROJECT=demo-browser
PROJECT_PATH=$T/proj
WORKTREE=$wt
TMUX_SOCKET=$KINGPIN_TMUX_SOCKET
TMUX_TARGET=kingpin:$id
EOF
  printf '%s\n' "$st" > "$KINGPIN_HOME/tasks/$id/status"
}
make_idle_task t4-with-browser "$t4_wt" "ready: branch=b review=APPROVE report=none"
make_idle_task t4-clean "$t4_wt" "issue: #4 fixture"
start_fake_daemon "$KINGPIN_HOME/tasks/t4-with-browser"; t4_pid=$started_pid
kp_wait_until 5 daemon_seen "$KINGPIN_HOME/tasks/t4-with-browser" "$t4_pid" || fail "t4: the list fixture daemon never started"
t4_list=$("$KP_BIN/kingpin" list)
printf '%s\n' "$t4_list" | grep -qE "↳ Browser: +1 daemon, [0-9][0-9]* MB \(pid $t4_pid\)" && pass "t4: list names one daemon, its memory and its pid" || fail "t4: list browser line wrong: $(printf '%s\n' "$t4_list" | grep '↳ Browser:' || echo none)"
t4_lines=$(printf '%s\n' "$t4_list" | grep -c "↳ Browser:" || true)
[ "$t4_lines" -eq 1 ] && pass "t4: only the task that holds a daemon gets the line" || fail "t4: $t4_lines browser lines for one daemon"
t4_help=$("$KP_BIN/kingpin" list --help)
printf '%s\n' "$t4_help" | grep -qi "browser" && pass "t4: list --help names the browser line" || fail "t4: list --help does not mention the browser line"

# --- t5: the daemon scan runs ps once per call, whatever the daemon count -----------------
echo "=== Test t5: the daemon scan costs one ps per call ==="
t5_dir_one=$T/t5-task-one
t5_dir_two=$T/t5-task-two
mkdir -p "$t5_dir_one" "$t5_dir_two"
start_fake_daemon "$t5_dir_one"; t5_pid_one=$started_pid
start_fake_daemon "$t5_dir_two"; t5_pid_two=$started_pid
kp_wait_until 5 daemon_seen "$t5_dir_one" "$t5_pid_one" || fail "t5: the first scan fixture daemon never started"
kp_wait_until 5 daemon_seen "$t5_dir_two" "$t5_pid_two" || fail "t5: the second scan fixture daemon never started"

# A ps shim in the tests/lib.sh shim shape: it counts every invocation and execs the real
# ps captured before the shim went in front of PATH. The counter is read just before and
# just after one kp_browser_daemons call, so the delta holds for whatever the scan finds.
mkdir -p "$T/bin"
t5_real_ps=$(command -v ps)
cat > "$T/bin/ps" << PSHEOF
#!/usr/bin/env bash
printf 'call\n' >> $T/ps-count
exec $t5_real_ps "\$@"
PSHEOF
chmod +x "$T/bin/ps"
: > "$T/ps-count"
t5_saved_path=$PATH
PATH="$T/bin:$PATH"
hash -r
t5_rows=$(kp_browser_daemons)
t5_calls=$(wc -l < "$T/ps-count")
PATH=$t5_saved_path
hash -r
[ "$t5_calls" = 1 ] && pass "t5: one kp_browser_daemons call cost exactly one ps" || fail "t5: one call cost $t5_calls ps invocations, not 1"
printf '%s\n' "$t5_rows" | cut -f1 | grep -qx "$t5_pid_one" && pass "t5: the first fixture daemon is still in the returned table" || fail "t5: the shim broke the scan: daemon $t5_pid_one missing from $t5_rows"
printf '%s\n' "$t5_rows" | cut -f1 | grep -qx "$t5_pid_two" && pass "t5: the second fixture daemon is still in the returned table" || fail "t5: the shim broke the scan: daemon $t5_pid_two missing from $t5_rows"

# --- tidy: tasks this suite created, so the archive does not leak into later checks ------
rm -rf "$KINGPIN_HOME/tasks/t4-with-browser" "$KINGPIN_HOME/tasks/t4-clean" "$KINGPIN_HOME/tasks/t2-bystander" "$t4_wt"

kp_test_finish "BROWSER-DAEMON"
