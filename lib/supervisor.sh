# shellcheck shell=bash
# Shared reader for the fleet supervisor's pidfile, $KINGPIN_HOME/supervisor.pid.
# Sourced by kingpin-watch, kingpin-lock and `kingpin list`; it only defines
# functions (no `set` options, no output, every function returns 0).
#
# kingpin-watch writes the file while it loops: the pid on line 1 and the epoch it
# started on line 2, the same shape as orchestrator.lock. It removes the file when
# it exits. A file whose pid is dead, unreadable or not a kingpin-watch process is
# stale: the next supervisor reclaims it, and `kingpin list` reports no supervisor.

# kp_supervisor_pid <home>
# The live supervisor's pid, or nothing. The process check keeps a recycled pid (or
# a stale file that names some other live process) from counting as a supervisor.
kp_supervisor_pid() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}}
  local file="$home/supervisor.pid" pid args
  [ -f "$file" ] || return 0
  pid=$(sed -n 1p "$file" 2>/dev/null | tr -d ' ' || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pid" -gt 1 ] 2>/dev/null || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  args=$(ps -o args= -p "$pid" 2>/dev/null || true)
  case "$args" in *kingpin-watch*) ;; *) return 0 ;; esac
  printf '%s\n' "$pid"
}

# kp_supervisor_started <home>
# The epoch the supervisor recorded when it started, or nothing.
kp_supervisor_started() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}}
  local file="$home/supervisor.pid" epoch
  [ -f "$file" ] || return 0
  epoch=$(sed -n 2p "$file" 2>/dev/null | tr -d ' ' || true)
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$epoch"
}

# kp_supervisor_since <home>
# The start time as HH:MM, or "unknown" when the pidfile has no usable epoch.
kp_supervisor_since() {
  local epoch time
  epoch=$(kp_supervisor_started "${1:-}")
  [ -n "$epoch" ] || return 0
  # GNU date first, then BSD/macOS date.
  time=$(date -d "@$epoch" +%H:%M 2>/dev/null || true)
  [ -n "$time" ] || time=$(date -r "$epoch" +%H:%M 2>/dev/null || true)
  printf '%s\n' "${time:-unknown}"
}

# kp_supervisor_line <home>
# The one line `kingpin list` prints: running with the pid and start time, or how
# to start a supervisor when there is none.
kp_supervisor_line() {
  local home=${1:-${KINGPIN_HOME:-$HOME/.kingpin}} pid since
  pid=$(kp_supervisor_pid "$home")
  if [ -n "$pid" ]; then
    since=$(kp_supervisor_since "$home")
    printf 'Supervisor: running (pid %s, since %s)\n' "$pid" "${since:-unknown}"
  else
    printf 'Supervisor: none - run kingpin watch\n'
  fi
}
