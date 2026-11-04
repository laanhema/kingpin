# shellcheck shell=bash
# Shared reader/writer for the session-scoped AFK switch, $KINGPIN_HOME/afk.
# Sourced by `kingpin afk`, `kingpin lock`, `kingpin watch` and `kingpin list`;
# it only defines functions (no `set` options, no output beyond what each states).
#
# The file sits next to orchestrator.lock and holds three lines:
#   1  the holder pid (the orchestrator session)
#   2  the epoch AFK was armed at
#   3  the epoch it expires at
# `kingpin afk on` writes it, `kingpin afk off` and `kingpin lock release` remove
# it, and nothing writes it into a project config or the global config: the switch
# belongs to one session, not to the fleet's configuration.
#
# AFK is armed only while the recorded pid is live and the expiry is in the future.
# A missing file, a dead pid, pid 0 or 1, a past expiry and an unreadable line all
# read as off, so a session that died cannot leave the fleet landing on its own.

# kp_afk_pid <home>
# The recorded holder pid, or nothing. Prints a number only when line 1 is one.
kp_afk_pid() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} pid
  [ -f "$home/afk" ] || return 0
  pid=$(sed -n 1p "$home/afk" 2>/dev/null | tr -d ' ' || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$pid"
}

# kp_afk_expiry <home>
# The recorded expiry epoch, or nothing.
kp_afk_expiry() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} expiry
  [ -f "$home/afk" ] || return 0
  expiry=$(sed -n 3p "$home/afk" 2>/dev/null | tr -d ' ' || true)
  case "$expiry" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$expiry"
}

# kp_afk_armed <home>
# Exit 0 only while AFK is armed: the recorded pid is a real holder (greater than
# 1) and alive, and the expiry is in the future. Every caller that decides whether
# to auto-land uses this one rule. Pid 0 targets the caller's own process group and
# pid 1 is init, so lib/supervisor.sh rejects both the same way.
kp_afk_armed() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} pid expiry now
  pid=$(kp_afk_pid "$home")
  [ -n "$pid" ] || return 1
  [ "$pid" -gt 1 ] 2>/dev/null || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  expiry=$(kp_afk_expiry "$home")
  [ -n "$expiry" ] || return 1
  now=$(date +%s 2>/dev/null || true)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -lt "$expiry" ]
}

# kp_afk_line <home>
# The one line `kingpin list` and `kingpin afk status` print while AFK is armed,
# and nothing while it is off: "AFK: on until 16:40 (pid 12345)".
kp_afk_line() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} pid expiry time
  kp_afk_armed "$home" || return 0
  pid=$(kp_afk_pid "$home")
  expiry=$(kp_afk_expiry "$home")
  # GNU date first, then BSD/macOS date, as lib/supervisor.sh does.
  time=$(date -d "@$expiry" +%H:%M 2>/dev/null || true)
  [ -n "$time" ] || time=$(date -r "$expiry" +%H:%M 2>/dev/null || true)
  printf 'AFK: on until %s (pid %s)\n' "${time:-unknown}" "$pid"
}

# kp_afk_write <home> <pid> <ttl-seconds>
# Publish the three-line state file atomically: a private temp file in the same
# directory, then `mv`, so a reader never sees a half-written pid or expiry.
kp_afk_write() {
  local home=${1:?} pid=${2:?} ttl=${3:?} now expiry tmp
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ttl" -gt 0 ] || return 1
  now=$(date +%s 2>/dev/null) || return 1
  expiry=$((now + ttl))
  mkdir -p "$home" || return 1
  tmp=$(mktemp "$home/afk.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n%s\n%s\n' "$pid" "$now" "$expiry" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$home/afk" || { rm -f "$tmp"; return 1; }
}

# kp_afk_clear <home>
# Remove the state file. A missing file is not an error, so `afk off` and
# `lock release` are idempotent.
kp_afk_clear() {
  local home=${1:?}
  rm -f "$home/afk"
}
