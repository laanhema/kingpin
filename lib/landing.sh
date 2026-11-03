# shellcheck shell=bash
# Shared landing-lane state machine for kingpin-land, kingpin-done and kingpin-watch.
# Source it; it only defines functions (no `set` options, no output unless stated,
# every function returns 0 unless stated).
#
#   # shellcheck source=../lib/landing.sh
#   . "$KP_BIN/../lib/landing.sh"
#
# A project's landing lane is two files under $KP_HOME/projects:
#   <project>.landing        the id of the task that owns the lane (the holder)
#   <project>.landing_queue  one task id per line, in arrival order
# plus a short-lived <project>.landing.mutex directory that makes every
# check-and-claim atomic. flock is not used: it is not available on macOS by
# default. The holder file keeps its one-line format, so a live fleet and the
# existing suites keep working; the mutex is a sibling directory.
#
# The lane is free when it has no holder, or when the holder can no longer land:
# its task dir is gone, or its last worker event is terminal (merged:, failed:,
# cleanup-refused:). A queued id is landable only when its task dir and task.env
# still exist, it was not already cleaned up or dispatched, and its last worker
# event is not terminal; anything else is dropped from the queue and named on
# stderr, because a silent swallow is what made the lane wedge.
#
# Every function takes <kp-home> first, so a caller can point it at a scratch
# fleet. The mutex is per project, and no function calls another that takes it:
# there is no lock ordering to get wrong.

# shellcheck source=status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"

# kp_landing_lock <kp-home> <project>
# Prints the project's landing lock path (the holder file).
kp_landing_lock() {
  printf '%s\n' "${1:?}/projects/${2:?}.landing"
}

# kp_landing_queue <kp-home> <project>
# Prints the project's landing queue path.
kp_landing_queue() {
  printf '%s\n' "${1:?}/projects/${2:?}.landing_queue"
}

# kp_landing_holder <kp-home> <project>
# Prints the holder id; empty when the lane is free.
kp_landing_holder() {
  local lock
  lock=$(kp_landing_lock "$1" "$2")
  [ -f "$lock" ] || return 0
  head -n 1 "$lock" 2>/dev/null || true
}

# kp_landing_holder_live <kp-home> <holder>
# Exit 0 only when the holder's task dir still exists and its last worker event
# is not terminal. An empty holder, a missing task dir and a finished task all
# mean the lane is free: exit 1.
kp_landing_holder_live() {
  local home=${1:-} holder=${2:-}
  [ -n "$home" ] && [ -n "$holder" ] || return 1
  [ -d "$home/tasks/$holder" ] || return 1
  ! kp_status_is_terminal "$(kp_status_last "$home/tasks/$holder/status")"
}

# kp_landing_task_landable <kp-home> <task>
# Exit 0 only when <task> can still land: its task dir and task.env exist, it has
# no done_cleaned and no landing_sent marker, and its last worker event is not
# terminal. Exit 1 otherwise (the id is dead and belongs out of the queue).
kp_landing_task_landable() {
  local home=${1:-} task=${2:-} dir
  [ -n "$home" ] && [ -n "$task" ] || return 1
  dir="$home/tasks/$task"
  [ -d "$dir" ] || return 1
  [ -f "$dir/task.env" ] || return 1
  [ ! -f "$dir/done_cleaned" ] || return 1
  [ ! -f "$dir/landing_sent" ] || return 1
  ! kp_status_is_terminal "$(kp_status_last "$dir/status")"
}

# _kp_landing_unlandable_reason <kp-home> <task>
# Prints why <task> cannot land, for the drop line a caller reports on stderr.
_kp_landing_unlandable_reason() {
  local home=${1:-} task=${2:-} dir last
  dir="$home/tasks/$task"
  [ -d "$dir" ] || { printf 'no task dir\n'; return 0; }
  [ -f "$dir/task.env" ] || { printf 'no task.env\n'; return 0; }
  [ ! -f "$dir/done_cleaned" ] || { printf 'already cleaned up\n'; return 0; }
  [ ! -f "$dir/landing_sent" ] || { printf 'already dispatched\n'; return 0; }
  last=$(kp_status_last "$dir/status")
  printf 'finished (%s)\n' "$last"
}

# _kp_landing_mutex_acquire <kp-home> <project>
# Takes the project's mkdir mutex. Exit 0 = taken (the caller must release it),
# 1 = could not be taken within ~5 s. A mutex whose pid file names a dead
# process, or whose directory is older than a minute, is reclaimed: a process
# killed between the mkdir and the pid write must not wedge the lane forever.
_kp_landing_mutex_acquire() {
  local home=${1:?} project=${2:?} mutex pid n=0
  mutex="$(kp_landing_lock "$home" "$project").mutex"
  mkdir -p "$home/projects" || return 1
  while [ "$n" -lt 250 ]; do
    if mkdir "$mutex" 2>/dev/null; then
      printf '%s\n' "$$" > "$mutex/pid" 2>/dev/null || true
      return 0
    fi
    pid=""
    [ -f "$mutex/pid" ] && pid=$(head -n 1 "$mutex/pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$mutex"
        continue
      fi
    fi
    if [ -n "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$mutex"
      continue
    fi
    sleep 0.02
    n=$((n + 1))
  done
  return 1
}

# _kp_landing_mutex_release <kp-home> <project>
# Releases the project's mutex. Always 0: a missing mutex is already released.
_kp_landing_mutex_release() {
  rm -rf "$(kp_landing_lock "${1:?}" "${2:?}").mutex" 2>/dev/null || true
}

# _kp_landing_queue_remove <queue-file> <task>
# Drops every line equal to <task>, rewriting the queue through a temp file in
# the same directory (never `sed -i`, which is not portable and not atomic).
# The caller holds the project mutex.
_kp_landing_queue_remove() {
  local queue=${1:?} task=${2:?} tmp
  [ -f "$queue" ] || return 0
  tmp=$(mktemp "${queue}.XXXXXX") || return 1
  grep -vxF -e "$task" "$queue" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$queue"
}

# kp_landing_acquire <kp-home> <project> <task>
# Claims the lane for <task> atomically: writes the holder file and removes the
# task from the queue under the project mutex. Re-acquiring as the current
# holder also succeeds. Exit 0 = claimed, 1 = a live holder owns the lane,
# 2 = the mutex could not be taken (nothing changed).
kp_landing_acquire() {
  local home=${1:?} project=${2:?} task=${3:?} lock queue holder
  lock=$(kp_landing_lock "$home" "$project")
  queue=$(kp_landing_queue "$home" "$project")
  _kp_landing_mutex_acquire "$home" "$project" || return 2
  holder=$(kp_landing_holder "$home" "$project")
  if [ -n "$holder" ] && [ "$holder" != "$task" ] && kp_landing_holder_live "$home" "$holder"; then
    _kp_landing_mutex_release "$home" "$project"
    return 1
  fi
  printf '%s\n' "$task" > "$lock"
  _kp_landing_queue_remove "$queue" "$task"
  _kp_landing_mutex_release "$home" "$project"
  return 0
}

# kp_landing_enqueue <kp-home> <project> <task>
# Appends <task> to the project's landing queue once, under the mutex. Exit 0 =
# queued (or already queued), 2 = the mutex could not be taken.
kp_landing_enqueue() {
  local home=${1:?} project=${2:?} task=${3:?} queue
  queue=$(kp_landing_queue "$home" "$project")
  _kp_landing_mutex_acquire "$home" "$project" || return 2
  if [ -f "$queue" ] && grep -qxF -e "$task" "$queue" 2>/dev/null; then
    _kp_landing_mutex_release "$home" "$project"
    return 0
  fi
  printf '%s\n' "$task" >> "$queue"
  _kp_landing_mutex_release "$home" "$project"
  return 0
}

# kp_landing_release <kp-home> <project> <task>
# Removes the holder file only when <task> is the holder. Exit 0 = released,
# 1 = not the holder (nothing touched), 2 = the mutex could not be taken
# (nothing touched either).
kp_landing_release() {
  local home=${1:?} project=${2:?} task=${3:?} lock holder
  lock=$(kp_landing_lock "$home" "$project")
  _kp_landing_mutex_acquire "$home" "$project" || return 2
  holder=$(kp_landing_holder "$home" "$project")
  if [ "$holder" != "$task" ]; then
    _kp_landing_mutex_release "$home" "$project"
    return 1
  fi
  rm -f "$lock"
  _kp_landing_mutex_release "$home" "$project"
  return 0
}

# kp_landing_pop <kp-home> <project>
# Under the mutex, drops every id that can no longer land (naming each on stderr
# as `kingpin-landing: dropping <id> from the <project> queue: <reason>`), then
# prints the next landable id and removes it from the queue. Prints nothing when
# no id can land. Exit 0, or 2 when the mutex could not be taken.
kp_landing_pop() {
  local home=${1:?} project=${2:?} queue tmp id next=""
  queue=$(kp_landing_queue "$home" "$project")
  [ -f "$queue" ] || return 0
  _kp_landing_mutex_acquire "$home" "$project" || return 2
  tmp=$(mktemp "${queue}.XXXXXX") || {
    _kp_landing_mutex_release "$home" "$project"
    return 2
  }
  : > "$tmp"
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    if [ -n "$next" ]; then
      printf '%s\n' "$id" >> "$tmp"
      continue
    fi
    if kp_landing_task_landable "$home" "$id"; then
      next=$id
    else
      printf 'kingpin-landing: dropping %s from the %s queue: %s\n' \
        "$id" "$project" "$(_kp_landing_unlandable_reason "$home" "$id")" >&2
    fi
  done < "$queue"
  mv "$tmp" "$queue"
  _kp_landing_mutex_release "$home" "$project"
  [ -z "$next" ] || printf '%s\n' "$next"
  return 0
}

# kp_landing_drain <kp-home> <project> <kp-bin>
# While the lane has no live holder: pop the next landable id and run
# `"<kp-bin>/kingpin-land" <id>`; a land that fails is reported and dropped (it
# was already popped, and requeueing would spin on the same entry forever).
# Returns when the lane is held or the queue has no landable id. Always 0.
kp_landing_drain() {
  local home=${1:?} project=${2:?} kp_bin=${3:?} holder id
  while true; do
    holder=$(kp_landing_holder "$home" "$project")
    if [ -n "$holder" ] && kp_landing_holder_live "$home" "$holder"; then
      return 0
    fi
    id=$(kp_landing_pop "$home" "$project") || return 0
    [ -n "$id" ] || return 0
    if ! "$kp_bin/kingpin-land" "$id"; then
      printf 'kingpin-landing: queued task %s could not land; dropped from the %s queue\n' \
        "$id" "$project" >&2
    fi
  done
}
