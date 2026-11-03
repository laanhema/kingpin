# shellcheck shell=bash
# Shared reader for the task protocol files. Source it; it only defines functions
# (no `set` options, no output, every function returns 0 unless stated).
#
#   # shellcheck source=../lib/status.sh
#   . "$KP_BIN/../lib/status.sh"
#
# The task `status` file is the fleet's state machine. Workers append one event
# per line (ready:, fixed:, needs-input:, merged:, failed:, ...). kingpin-listen
# appends two kinds of notes, approved: and feedback:. They are reminders for the
# orchestrator, not worker events, so the worker's current state is the last line
# that is not one of them.

# kp_status_last <status-file>
# The worker's last event: the last line that is not an approved:/feedback: note.
# Empty for a missing or empty file. Use it to decide what state a task is in.
kp_status_last() {
  [ -f "${1:-}" ] || return 0
  grep -vE '^(approved|feedback):' "$1" 2>/dev/null | tail -n 1 || true
}

# kp_status_newest <status-file>
# The newest line of any kind, notes included. Only for a caller that reports or
# dispatches on the newest line itself (kingpin list, kingpin-watch).
kp_status_newest() {
  [ -f "${1:-}" ] || return 0
  tail -n 1 "$1" 2>/dev/null || true
}

# kp_status_worker_events <status-file>
# How many lines the worker reported (notes do not count). Always prints a number.
kp_status_worker_events() {
  local n=0
  [ -f "${1:-}" ] && n=$(grep -vcE '^(approved|feedback):' "$1" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

# kp_status_is_terminal <status-line>
# Exit 0 for a finished task's line (merged:, failed:, cleanup-refused:), else 1.
kp_status_is_terminal() {
  case "${1:-}" in
    merged:*|failed:*|cleanup-refused:*) return 0 ;;
    *) return 1 ;;
  esac
}

# kp_env_get <env-file> <KEY>
# The value of the last KEY=value line, or nothing. Same "last assignment wins" as
# sourcing the file; the file is never sourced, so its values are not executed.
kp_env_get() {
  [ -f "${1:-}" ] || return 0
  sed -n "s/^${2:?}=//p" "$1" 2>/dev/null | tail -n 1 || true
}
