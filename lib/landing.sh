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
# plus a short-lived <project>.landing.mutex file that makes every
# check-and-claim atomic. The mutex sequence itself is lib/mutex.sh, shared with
# the orchestrator lock so both callers get the same reclaim rules. flock is not
# used: it is not available on macOS by default. The holder file keeps its
# one-line format, so a live fleet and the existing suites keep working; the
# mutex is a sibling file.
#
# Two races this file closes, because both dispatch a task twice:
#   * The claim itself is atomic on its own (`_kp_landing_claim` hard-links a
#     prepared file into place), so even two processes that both believe the
#     lane is free cannot both become the holder.
#   * The mutex is created by an atomic hard link, released only by its owner,
#     and reclaimed by renaming it away after checking that the file moved is
#     the one inspected. A plain `rm` reclaim let two reclaimers delete each
#     other's fresh mutex, which put two processes in the critical section at
#     once; `mv` onto a directory would nest instead of failing, so the mutex is
#     a file, not a directory. The sequence lives in lib/mutex.sh.
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
# shellcheck source=mutex.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mutex.sh"

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
# Exit 0 only when the holder's task dir is a live record and its last worker
# event is not terminal. An empty holder, a missing task dir, the link
# kingpin-done leaves for an archived task, and a finished task all mean the
# lane is free: exit 1.
kp_landing_holder_live() {
  local home=${1:-} holder=${2:-}
  [ -n "$home" ] && [ -n "$holder" ] || return 1
  kp_task_is_live "$home/tasks/$holder" || return 1
  ! kp_status_is_terminal "$(kp_status_last "$home/tasks/$holder/status")"
}

# kp_landing_task_landable <kp-home> <task>
# Exit 0 only when <task> can still land: its task dir is a live record with a
# task.env, it has no done_cleaned and no landing_sent marker, and its last worker
# event is not terminal. Exit 1 otherwise (the id is dead and belongs out of the
# queue).
kp_landing_task_landable() {
  local home=${1:-} task=${2:-} dir
  [ -n "$home" ] && [ -n "$task" ] || return 1
  dir="$home/tasks/$task"
  kp_task_is_live "$dir" || return 1
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
  if [ -L "$dir" ]; then printf 'archived\n'; return 0; fi
  [ -d "$dir" ] || { printf 'no task dir\n'; return 0; }
  [ -f "$dir/task.env" ] || { printf 'no task.env\n'; return 0; }
  [ ! -f "$dir/done_cleaned" ] || { printf 'already cleaned up\n'; return 0; }
  [ ! -f "$dir/landing_sent" ] || { printf 'already dispatched\n'; return 0; }
  last=$(kp_status_last "$dir/status")
  printf 'finished (%s)\n' "$last"
}

# _kp_landing_mutex_acquire <kp-home> <project>
# Takes the project's mutex through the shared helper (lib/mutex.sh), which owns
# the acquire sequence: the path is the holder file's path plus `.mutex`. Exit 0 =
# taken (the caller must release it), 1 = could not be taken within the helper's
# budget.
_kp_landing_mutex_acquire() {
  local home=${1:?} project=${2:?} mutex
  mutex="$(kp_landing_lock "$home" "$project").mutex"
  kp_mutex_acquire "$mutex"
}

# _kp_landing_mutex_release <kp-home> <project>
# Releases the project's mutex through the shared helper, which releases only
# when this shell owns it: a release can never delete a mutex that another
# process has just taken. Always 0.
_kp_landing_mutex_release() {
  local home=${1:?} project=${2:?} mutex
  mutex="$(kp_landing_lock "$home" "$project").mutex"
  kp_mutex_release "$mutex"
}

# _kp_landing_claim <lock> <task>
# Creates <lock> naming <task> atomically: a private file with the id is
# hard-linked into place, and link(2) fails when the lock already exists. Two
# processes that both believe the lane is free therefore cannot both claim it;
# the loser gets 1. The caller holds the project mutex.
_kp_landing_claim() {
  local lock=${1:?} task=${2:?} tmp
  tmp=$(mktemp "${lock}.claim.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$task" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ln "$tmp" "$lock" 2>/dev/null; then
    rm -f "$tmp"
    # The holder file is fleet-visible and used to be written 0644; keep that.
    chmod 0644 "$lock" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp"
  return 1
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
# task from the queue under the project mutex. The holder file itself is created
# by an atomic link, so a second claimant can never also win. Re-acquiring as the
# current holder also succeeds. Exit 0 = claimed, 1 = a live holder owns the lane,
# 2 = the mutex could not be taken (nothing changed).
kp_landing_acquire() {
  local home=${1:?} project=${2:?} task=${3:?} lock queue holder stale moved
  lock=$(kp_landing_lock "$home" "$project")
  queue=$(kp_landing_queue "$home" "$project")
  _kp_landing_mutex_acquire "$home" "$project" || return 2
  holder=$(kp_landing_holder "$home" "$project")
  if [ -n "$holder" ] && [ "$holder" = "$task" ]; then
    _kp_landing_mutex_release "$home" "$project"
    return 0
  fi
  if [ -n "$holder" ] && kp_landing_holder_live "$home" "$holder"; then
    _kp_landing_mutex_release "$home" "$project"
    return 1
  fi
  if [ -f "$lock" ]; then
    # The lane is free but its file names a task that can no longer land (or is
    # empty). Clear it by renaming it away and checking that it was the file we
    # inspected: a holder written in between is put back instead of removed.
    stale="$lock.stale.$$"
    rm -f "$stale"
    if mv "$lock" "$stale" 2>/dev/null; then
      moved=$(head -n 1 "$stale" 2>/dev/null || true)
      if [ "$moved" != "$holder" ]; then
        mv "$stale" "$lock" 2>/dev/null || rm -f "$stale"
        _kp_landing_mutex_release "$home" "$project"
        return 1
      fi
      rm -f "$stale"
    fi
  fi
  if ! _kp_landing_claim "$lock" "$task"; then
    _kp_landing_mutex_release "$home" "$project"
    return 1
  fi
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
