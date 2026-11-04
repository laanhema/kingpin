# shellcheck shell=bash
# Shared mutex file for the kingpin state files. Sourced by lib/landing.sh (the
# per-project landing lane), bin/kingpin-lock (the orchestrator lock) and
# lib/curator.sh (the non-blocking auto-curate gate); it only defines functions
# (no `set` options, no output, every function returns 0 unless stated).
#
#   # shellcheck source=../lib/mutex.sh
#   . "$KP_BIN/../lib/mutex.sh"
#
# A mutex is a one-line file holding the owner's pid, created by hard-linking a
# prepared file into place: link(2) is atomic and fails when the mutex exists, so
# a contender never sees a mutex without its pid and only one contender can win.
# flock is not used because it is not available on macOS by default.
#
# The mutex is a file, not a directory: `mv` onto a directory would nest instead
# of failing, so a directory-based mutex could not be reclaimed safely.

# kp_mutex_owner
# The pid read from the mutex on the last iteration of a failed
# `kp_mutex_acquire`: who held it when the wait gave up. Empty when no owner
# could be read (no mutex, or one with an empty first line). It is a variable
# rather than a local so the caller can name the blocker in its refusal.
kp_mutex_owner=''

# kp_mutex_acquire <mutex>
# Takes <mutex>. Exit 0 = taken (the caller must release it), 1 = not taken
# within about 9 s; kp_mutex_owner then names the pid that was read last.
#
# A mutex is reclaimed when its pid names a dead process, or when the file is
# older than a minute (a process killed inside the section, or one that never
# released). The reclaim renames the mutex away and then checks that it moved the
# mutex it inspected: two reclaimers therefore cannot delete each other's fresh
# mutex, and a mutex that appeared after the read is put back.
kp_mutex_acquire() {
  local mutex=${1:?} tmp stolen seen moved old n=0
  kp_mutex_owner=''
  mkdir -p "$(dirname "$mutex")" 2>/dev/null || return 1
  while [ "$n" -lt 250 ]; do
    tmp=$(mktemp "${mutex}.tmp.XXXXXX" 2>/dev/null) || return 1
    if printf '%s\n' "$$" > "$tmp" 2>/dev/null && ln "$tmp" "$mutex" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    seen=""
    [ -f "$mutex" ] && seen=$(head -n 1 "$mutex" 2>/dev/null || true)
    # shellcheck disable=SC2034 # read by the caller after this returns 1
    kp_mutex_owner=$seen
    old=""
    [ -n "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null)" ] && old=1
    if [ -z "$old" ] && { [ -z "$seen" ] || kill -0 "$seen" 2>/dev/null; }; then
      # A live owner, or a mutex created just now: wait for it.
      sleep 0.02
      n=$((n + 1))
      continue
    fi
    stolen="${mutex}.stale.$$"
    rm -f "$stolen"
    if ! mv "$mutex" "$stolen" 2>/dev/null; then
      # Another contender reclaimed it first.
      sleep 0.02
      n=$((n + 1))
      continue
    fi
    moved=""
    [ -f "$stolen" ] && moved=$(head -n 1 "$stolen" 2>/dev/null || true)
    if [ -n "$seen" ] && [ "$moved" != "$seen" ]; then
      # We moved a mutex that appeared after our read: hand it back untouched,
      # and never overwrite a mutex that is already back in place.
      if [ -e "$mutex" ]; then
        rm -f "$stolen"
      else
        mv "$stolen" "$mutex" 2>/dev/null || rm -f "$stolen"
      fi
      sleep 0.02
      n=$((n + 1))
      continue
    fi
    rm -f "$stolen"
    n=$((n + 1))
  done
  return 1
}

# kp_mutex_try <mutex>
# One non-blocking claim attempt, for a caller that must never wait (the
# auto-curate gate in lib/curator.sh). Exit 0 = taken (the caller must release
# it), 1 = not taken; kp_mutex_owner then names the pid that was read. The stale
# rules match kp_mutex_acquire: a dead owner, or a file older than a minute, is
# reclaimed by renaming it away, checking that the file moved is the one
# inspected, and retrying the link once. It never sleeps and never releases.
kp_mutex_try() {
  local mutex=${1:?} tmp stolen seen moved old
  kp_mutex_owner=''
  mkdir -p "$(dirname "$mutex")" 2>/dev/null || return 1
  tmp=$(mktemp "${mutex}.tmp.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$$" > "$tmp" 2>/dev/null && ln "$tmp" "$mutex" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  seen=""
  [ -f "$mutex" ] && seen=$(head -n 1 "$mutex" 2>/dev/null || true)
  # shellcheck disable=SC2034 # read by the caller after this returns 1
  kp_mutex_owner=$seen
  old=""
  [ -n "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null)" ] && old=1
  if [ -z "$old" ] && { [ -z "$seen" ] || kill -0 "$seen" 2>/dev/null; }; then
    # A live owner, or a mutex created just now: do not wait for it.
    return 1
  fi
  stolen="${mutex}.stale.$$"
  rm -f "$stolen"
  if ! mv "$mutex" "$stolen" 2>/dev/null; then
    # Another contender reclaimed it first.
    return 1
  fi
  moved=""
  [ -f "$stolen" ] && moved=$(head -n 1 "$stolen" 2>/dev/null || true)
  if [ -n "$seen" ] && [ "$moved" != "$seen" ]; then
    # We moved a mutex that appeared after our read: hand it back untouched.
    if [ -e "$mutex" ]; then
      rm -f "$stolen"
    else
      mv "$stolen" "$mutex" 2>/dev/null || rm -f "$stolen"
    fi
    return 1
  fi
  rm -f "$stolen"
  tmp=$(mktemp "${mutex}.tmp.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$$" > "$tmp" 2>/dev/null && ln "$tmp" "$mutex" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# kp_mutex_release <mutex>
# Releases <mutex>, but only when this shell owns it (line 1 is `$$`): a release
# can never delete a mutex that another process has just taken. Always 0.
kp_mutex_release() {
  local mutex=${1:?} pid
  [ -e "$mutex" ] || return 0
  pid=$(head -n 1 "$mutex" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -f "$mutex"
  return 0
}
