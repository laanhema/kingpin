# shellcheck shell=bash
# Shared session-pid reader for the commands that record which orchestrator
# session owns fleet state: `kingpin lock` writes it to orchestrator.lock and
# `kingpin afk` writes it to the afk file. Sourced by both; it only defines
# functions (no `set` options, no output beyond what each states, every function
# returns 0 unless stated).
#
# The calling shell is usually a short-lived child of the session: a harness runs
# `kingpin lock acquire` or `kingpin afk on` through a shell that exits at once. So
# a recorded pid must be the nearest agent-harness ancestor, not the command's own
# parent, or the record would look dead the moment the command returns.

# kp_is_harness_pid <pid>
# Exit 0 when <pid> is a live process that looks like an agent harness. The
# command name covers the supported harnesses, and the argv pattern catches a
# harness started through a wrapper. A shell, dash, tmux or : is not a harness.
kp_is_harness_pid() {
  local p=$1
  [ -n "$p" ] || return 1
  [ "$p" -gt 1 ] 2>/dev/null || return 1
  kill -0 "$p" 2>/dev/null || return 1
  local comm
  comm=$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ' || true)
  case "$comm" in
    bash|sh|zsh|dash|tmux*) return 1 ;;
    claude|claude-*|agy|agy-*|opencode|opencode-*|codex|codex-*|pi|pi-*|grok|grok-*|kimi|kimi-*) return 0 ;;
  esac
  local args
  args=$(ps -o args= -p "$p" 2>/dev/null || true)
  local pattern='(^|[ /])(claude|agy|opencode|codex|pi|grok|kimi)(-[^ ]*)?([ ]|$)'
  if [[ "$args" =~ $pattern ]]; then
    return 0
  fi
  return 1
}

# kp_session_pid [explicit-pid]
# Print the pid of the orchestrator session: a numeric <explicit-pid> when given,
# then the nearest harness ancestor of the calling shell, then the calling shell's
# parent. The walk goes one level up only, which covers a harness that runs the
# command directly or through one `bash -c` child.
kp_session_pid() {
  local explicit=${1:-}
  if [ -n "$explicit" ] && [[ "$explicit" =~ ^[0-9]+$ ]]; then
    echo "$explicit"
    return 0
  fi
  local c1=$PPID
  if kp_is_harness_pid "$c1"; then
    echo "$c1"
    return 0
  fi
  local c2
  c2=$(ps -o ppid= -p "$c1" 2>/dev/null | tr -d ' ' || true)
  if [ -n "$c2" ] && kp_is_harness_pid "$c2"; then
    echo "$c2"
    return 0
  fi
  echo "$c1"
}
