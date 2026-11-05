# shellcheck shell=bash
# Shared reader for the operator's issue-queue runner state, $KINGPIN_HOME/queue/.
# Sourced by `kingpin brief`; it only defines functions (no `set` options, no output
# beyond what each states, every function returns 0 unless stated).
#
# The runner is the operator's own script, not a Kingpin command: it walks an ordered
# issue list and spawns the next task while the fleet has a free slot. Its state sits
# beside it in one directory, and Kingpin only reads that directory:
#
#   queue    the issue numbers still to spawn, one per line, in arrival order
#   pause    while this file exists the runner idles. Its content is the runner's own
#            note; only its existence is a state Kingpin can report
#   started  the issues the runner has already spawned (never rerun)
#   skip     the issues the runner must never pick up
#   log      the runner's activity log
#
# A fleet with no runner has no such directory, and that is not an error: every
# function here answers for a missing directory and `kingpin brief` prints `Queue: none`.
# Nothing in this file writes, creates a directory or touches a running runner.

# kp_queue_dir <home>
# The runner's state directory for a fleet home.
kp_queue_dir() {
  printf '%s\n' "${1:?}/queue"
}

# kp_queue_waiting <home>
# How many issue numbers are waiting, always as a number: the non-empty lines of the
# runner's `queue` file, or 0 when the runner, the directory or the file is absent.
kp_queue_waiting() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} file n
  file="$(kp_queue_dir "$home")/queue"
  [ -f "$file" ] || {
    printf '0\n'
    return 0
  }
  n=$(grep -c . "$file" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# kp_queue_paused <home>
# Exit 0 while the runner is paused: the `pause` file exists in its state directory.
# The file's content is the runner's note, so only its presence is read.
kp_queue_paused() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}}
  [ -f "$(kp_queue_dir "$home")/pause" ]
}

# kp_queue_line <home>
# The one line `kingpin brief` prints for the queue: `Queue: none` when the runner
# keeps no state, else `Queue: <n> waiting, paused (queue/pause)` or
# `Queue: <n> waiting, not paused`. The paused form names the file that says so, so a
# reader who wants to resume the runner knows what to remove.
kp_queue_line() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} dir waiting
  dir=$(kp_queue_dir "$home")
  if [ ! -f "$dir/queue" ] && [ ! -f "$dir/pause" ]; then
    printf 'Queue: none\n'
    return 0
  fi
  waiting=$(kp_queue_waiting "$home")
  if kp_queue_paused "$home"; then
    printf 'Queue: %s waiting, paused (queue/pause)\n' "$waiting"
  else
    printf 'Queue: %s waiting, not paused\n' "$waiting"
  fi
}
