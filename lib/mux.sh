# shellcheck shell=bash
# The one contract every command uses to reach a worker's terminal (issue #144).
# A worker lives either in a tmux window or in a Herdr pane, and no command may
# call a backend directly: it calls the verb here, and this file picks the
# backend from the task record (a `MUX=` line) or, for the fleet itself, from
# `KINGPIN_MUX`.
#
# The selection rule:
#   KINGPIN_MUX=tmux    tmux, always (the default outside a Herdr pane)
#   KINGPIN_MUX=herdr   Herdr, always
#   KINGPIN_MUX=auto    Herdr only inside a Herdr pane (HERDR_ENV=1), else tmux
#   unset               the same as auto
# An unknown value is refused by name; it never falls back silently.
#
# The mux belongs to the task record, not to the process: a fleet can hold a tmux
# task and a Herdr task at once, and a reader uses the record's mux. A record with
# no `MUX=` line reads as tmux forever, so a fleet that predates this change needs
# no migration step and no deadline.
#
# The tmux backend is `lib/tmux.sh` itself: every verb below calls the same
# `kp_tmux`/`kp_window_*` function with the same arguments and the same option
# order as the command called directly before this file existed, so a tmux run
# issues exactly the tmux commands it issued then. The Herdr backend lives in
# `lib/mux-herdr.sh` and is loaded only when a record or `KINGPIN_MUX` selects it,
# so a tmux-only host never reads that file.
#
# A caller that needs a new verb adds it here, never by calling a backend from a
# command. Source `lib/status.sh` first (this file sources it, and `lib/tmux.sh`,
# itself).
#
#   # shellcheck source=../lib/mux.sh
#   . "$KP_ROOT/lib/mux.sh"
#
# The variables `kp_mux_find` sets for its caller:
#   KP_MUX             the record's backend, `tmux` or `herdr`
#   KP_MUX_SESSION     the record's mux session (the tmux socket or the Herdr session)
#   KP_WINDOW_ID       the target to address (`@N` for tmux, `w1:p3` for Herdr)
#   KP_WINDOW_NAME     the recorded name or label
#   KP_WINDOW_SESSION  the recorded session/socket session
#   KP_WINDOW_SOCKET   the tmux socket, empty for the default server (Herdr: empty)
#   KP_WINDOW_LABEL    a human-readable `<session>:<name>` (plus the id when found)
#
# Verbs that take a target address the value `kp_mux_find` published (`KP_WINDOW_ID`)
# and use `KP_WINDOW_SOCKET`/`KP_MUX_SESSION` for the connection. A verb called
# without `kp_mux_find` first (the curator gate) reads a record or falls back to
# `kp_mux_name`, and `KP_MUX_SOCKET`/`KP_MUX_SESSION` override the connection.

# The task-record readers (kp_env_get, kp_task_is_live) live in lib/status.sh.
# shellcheck source=status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"
# The tmux backend (kp_tmux, kp_window_*) lives in lib/tmux.sh.
# shellcheck source=tmux.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmux.sh"

# kp_mux_name
# Prints the fleet's backend: tmux or herdr. Reads KINGPIN_MUX (default auto) and
# resolves auto as herdr only inside a Herdr pane. An unknown value is refused on
# stderr with exit 1.
kp_mux_name() {
  local mux=${KINGPIN_MUX:-auto}
  case $mux in
    tmux|herdr)
      printf '%s\n' "$mux"
      ;;
    auto)
      if [ "${HERDR_ENV:-}" = 1 ]; then
        printf 'herdr\n'
      else
        printf 'tmux\n'
      fi
      ;;
    *)
      printf "kingpin: KINGPIN_MUX must be auto, tmux or herdr, not '%s'\n" "$mux" >&2
      return 1
      ;;
  esac
}

# kp_mux_record <task-dir>
# Prints the backend one task record names: `MUX=herdr` reads as herdr, a missing
# `MUX=` or `MUX=tmux` reads as tmux, and an unknown value is refused on stderr
# with exit 1. This is the reader every command uses, so the process environment
# can never move a live task to another backend.
kp_mux_record() {
  local task_dir=${1:-} mux=''
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  [ -f "$task_dir/task.env" ] && mux=$(kp_env_get "$task_dir/task.env" MUX)
  case $mux in
    herdr) printf 'herdr\n' ;;
    ''|tmux) printf 'tmux\n' ;;
    *)
      printf "kingpin: task record %s/task.env names an unknown mux '%s'\n" "$task_dir" "$mux" >&2
      return 1
      ;;
  esac
}

# kp_mux_self
# Prints the caller's own handle: $TMUX for tmux, $HERDR_PANE_ID for Herdr, and
# nothing when the caller is not inside either.
kp_mux_self() {
  local mux
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr) [ -n "${HERDR_PANE_ID:-}" ] && printf '%s\n' "$HERDR_PANE_ID" ;;
    *) [ -n "${TMUX:-}" ] && printf '%s\n' "$TMUX" ;;
  esac
  return 0
}

# kp_mux_session_name
# Prints the fleet's mux session: the tmux socket name, or the Herdr session
# (`KINGPIN_HERDR_SESSION`, then `HERDR_SESSION` inside a pane, then `kingpin`).
kp_mux_session_name() {
  local mux
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_session_name
      ;;
    *) kp_tmux_socket_name ;;
  esac
}

# kp_mux_find <task-dir> [--no-record]
# Resolve the task's terminal through the backend its record names. tmux calls
# kp_window_find unchanged. Herdr matches the recorded MUX_LABEL in `pane list`
# first and the recorded MUX_TARGET second, rewriting a stale id; `--no-record`
# keeps the rewrite off, which is what a read-only caller (`kingpin peek`) needs.
# Exit 0 when a terminal was found and 1 otherwise; stderr carries the reason.
kp_mux_find() {
  local task_dir=${1:-} opt=${2:-} mux no_record=0
  case $opt in
    '') ;;
    --no-record) no_record=1 ;;
    *)
      printf "kp_mux_find: unknown option '%s'\n" "$opt" >&2
      return 2
      ;;
  esac
  KP_MUX='' KP_MUX_SESSION='' KP_WINDOW_ID='' KP_WINDOW_NAME='' KP_WINDOW_SESSION=''
  KP_WINDOW_LABEL='' KP_WINDOW_SOCKET=''
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  mux=$(kp_mux_record "$task_dir") || return 1
  KP_MUX=$mux
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_find "$task_dir" "$no_record"
      ;;
    *)
      kp_window_find "$task_dir" || return 1
      KP_MUX_SESSION=$KP_WINDOW_SOCKET
      ;;
  esac
}

# kp_mux_harness_live <task-dir>
# Exit 0 only when the task's terminal is found and the recorded harness runs in
# it. tmux keeps kp_window_harness_live's rule; Herdr compares the recorded
# harness.pid against the pane's process info.
kp_mux_harness_live() {
  local task_dir=${1:-} mux
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  mux=$(kp_mux_record "$task_dir") || return 1
  KP_MUX=$mux
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_harness_live "$task_dir"
      ;;
    *) kp_window_harness_live "$task_dir" ;;
  esac
}

# kp_mux_target_state <target>
# Prints alive, dead or none. tmux reads `#{pane_dead}` on the window; a Herdr
# pane is alive while `pane get` answers and none once it is gone, because Herdr
# never keeps a dead pane around.
kp_mux_target_state() {
  local target=${1:-} mux
  [ -n "$target" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_target_state "$target"
      ;;
    *) _kp_mux_tmux_target_state "$target" ;;
  esac
}

# kp_mux_capture <target> --scrollback N | --tail N
# Print the pane text: `--scrollback` includes history, `--tail` is the last N
# lines. tmux keeps today's `capture-pane` calls (with `-J` for scrollback, the
# `-pt` form for a tail); Herdr reads `pane read --source recent-unwrapped`.
kp_mux_capture() {
  local target=${1:-} mode=${2:-} n=${3:-} mux
  [ -n "$target" ] || return 2
  case $mode in
    --scrollback|--tail) ;;
    *)
      printf 'kp_mux_capture: expected --scrollback or --tail, not %s\n' "${mode:-<nothing>}" >&2
      return 2
      ;;
  esac
  [[ $n =~ ^[0-9]+$ ]] || { printf 'kp_mux_capture: %s needs a line count\n' "$mode" >&2; return 2; }
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_capture "$target" "$n"
      ;;
    *)
      if [ "$mode" = --scrollback ]; then
        kp_tmux "${KP_WINDOW_SOCKET:-}" capture-pane -p -J -t "$target" -S "-$n"
      else
        kp_tmux "${KP_WINDOW_SOCKET:-}" capture-pane -pt "$target" -S "-$n"
      fi
      ;;
  esac
}

# kp_mux_send_text <target> <text>
# Type <text> literally. tmux keeps `send-keys -l --`; Herdr uses `pane send-text`.
kp_mux_send_text() {
  local target=${1:-} mux
  [ -n "$target" ] || return 2
  [ $# -ge 2 ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_send_text "$target" "$2"
      ;;
    *) kp_tmux "${KP_WINDOW_SOCKET:-}" send-keys -t "$target" -l -- "$2" ;;
  esac
}

# kp_mux_send_enter <target>
# Press Enter. tmux keeps `send-keys Enter`; Herdr uses `pane send-keys <id> enter`.
kp_mux_send_enter() {
  local target=${1:-} mux
  [ -n "$target" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_send_enter "$target"
      ;;
    *) kp_tmux "${KP_WINDOW_SOCKET:-}" send-keys -t "$target" Enter ;;
  esac
}

# kp_mux_activity <target>
# Print an opaque token that changes when the pane's output changes. tmux is the
# pane's `window_activity` epoch; Herdr has no activity clock, so the backend
# hashes the recent pane text (see lib/mux-herdr.sh).
kp_mux_activity() {
  local target=${1:-} mux
  [ -n "$target" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_activity "$target"
      ;;
    *) kp_tmux "${KP_WINDOW_SOCKET:-}" display-message -p -t "$target" '#{window_activity}' ;;
  esac
}

# kp_mux_activity_age <task-dir>
# Print how many seconds the pane has been silent. tmux subtracts the
# `window_activity` epoch; Herdr keeps `<task-dir>/mux.activity` as `<epoch> <token>`
# and reports 0 the first time it sees a new token (see lib/mux-herdr.sh).
kp_mux_activity_age() {
  local task_dir=${1:-} mux token now
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  mux=$(kp_mux_record "$task_dir") || return 1
  KP_MUX=$mux
  case $mux in
    herdr)
      _kp_mux_load_herdr
      # Resolve the task's own pane: a KP_WINDOW_ID left by another call may name
      # a different task's pane.
      _kp_herdr_find "$task_dir" >/dev/null 2>&1 || return 1
      _kp_herdr_activity_age "$task_dir"
      ;;
    *)
      # Resolve the task's own window: a KP_WINDOW_ID left by another call may
      # name a different task's window, and reading its activity would report
      # another task's silence.
      kp_window_find "$task_dir" >/dev/null 2>&1 || return 1
      token=$(kp_tmux "${KP_WINDOW_SOCKET:-}" display-message -p -t "$KP_WINDOW_ID" '#{window_activity}' 2>/dev/null) || return 1
      [[ $token =~ ^[0-9]+$ ]] || return 1
      now=$(date +%s)
      printf '%s\n' $((now - token))
      ;;
  esac
}

# kp_mux_foreground_command <target>
# Print the foreground command word in the pane.
kp_mux_foreground_command() {
  local target=${1:-} mux
  [ -n "$target" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_foreground_command "$target"
      ;;
    *) kp_tmux "${KP_WINDOW_SOCKET:-}" display-message -p -t "$target" '#{pane_current_command}' ;;
  esac
}

# kp_mux_rename <target> <name>
# Rename the terminal. tmux keeps `rename-window`; Herdr uses `pane rename`.
kp_mux_rename() {
  local target=${1:-} name=${2:-} mux
  [ -n "$target" ] && [ -n "$name" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_rename "$target" "$name"
      ;;
    *) kp_tmux "${KP_WINDOW_SOCKET:-}" rename-window -t "$target" "$name" ;;
  esac
}

# kp_mux_kill <target>
# Close the terminal. tmux keeps `kill-window`; Herdr uses `pane close`.
kp_mux_kill() {
  local target=${1:-} mux
  [ -n "$target" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_kill "$target"
      ;;
    *) kp_tmux "${KP_WINDOW_SOCKET:-}" kill-window -t "$target" ;;
  esac
}

# kp_mux_reachable
# Exit 0 when the task's mux can be reached at all, so a caller can tell a worker
# that is gone from a mux that simply is not answering. tmux reads `list-sessions`;
# Herdr reads `api snapshot`.
kp_mux_reachable() {
  local task_dir=${1:-} mux sock
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  mux=$(kp_mux_record "$task_dir") || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      KP_MUX_SESSION=''
      if [ -f "$task_dir/task.env" ]; then
        KP_MUX_SESSION=$(kp_env_get "$task_dir/task.env" MUX_SESSION)
      fi
      _kp_herdr_reachable
      ;;
    *)
      sock=$(kp_tmux_socket_from_env "$task_dir/task.env")
      kp_tmux "$sock" list-sessions >/dev/null 2>&1
      ;;
  esac
}

# kp_mux_ensure_session <session>
# Make sure the fleet's mux session exists. tmux creates a detached session; Herdr
# refuses, because the server is not this project's to start.
kp_mux_ensure_session() {
  local session=${1:-} mux
  [ -n "$session" ] || return 2
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_ensure_session "$session"
      ;;
    *) kp_tmux_ensure_session "${KP_MUX_SOCKET:-$(kp_tmux_socket_name)}" "$session" ;;
  esac
}

# kp_mux_create <task-dir> <session> <name> <cwd> <launch> [--fresh]
# Create the task's terminal and print its target id. tmux keeps kp_window_start;
# Herdr refuses until the spawn path is migrated (issue #144 phase E), because the
# unmigrated `kingpin list`/`kingpin wait` cannot see a Herdr worker yet.
kp_mux_create() {
  local mux
  mux=$(_kp_mux_current) || return 1
  case $mux in
    herdr)
      _kp_mux_load_herdr
      _kp_herdr_create "$@"
      ;;
    *) kp_window_start "$@" ;;
  esac
}

# kp_mux_record_id <task-dir> <target-id>
# Record a resolved target id: TMUX_WINDOW_ID for a tmux record, MUX_TARGET for a
# Herdr one. Exit 1 with a stderr reason when it cannot write.
kp_mux_record_id() {
  local task_dir=${1:-} id=${2:-} mux
  [ -n "$task_dir" ] && [ -n "$id" ] || return 2
  task_dir=${task_dir%/}
  mux=$(kp_mux_record "$task_dir") || return 1
  case $mux in
    herdr) _kp_mux_record_set "$task_dir" MUX_TARGET "$id" ;;
    *) kp_window_record_id "$task_dir" "$id" ;;
  esac
}

# kp_mux_record_label <task-dir> <label>
# Record a Herdr pane label (the re-resolution key) after a rename. A tmux record
# needs none, so this is a no-op there.
kp_mux_record_label() {
  local task_dir=${1:-} label=${2:-} mux
  [ -n "$task_dir" ] && [ -n "$label" ] || return 2
  task_dir=${task_dir%/}
  mux=$(kp_mux_record "$task_dir") || return 1
  [ "$mux" = herdr ] || return 0
  _kp_mux_record_set "$task_dir" MUX_LABEL "$label"
}

# _kp_mux_current
# Print the backend the next verb should use: KP_MUX when kp_mux_find (or a
# caller) set it, else kp_mux_name.
_kp_mux_current() {
  if [ -n "${KP_MUX:-}" ]; then
    printf '%s\n' "$KP_MUX"
    return 0
  fi
  kp_mux_name
}

# _kp_mux_load_herdr
# Source lib/mux-herdr.sh once, and only when a record or KINGPIN_MUX selects
# Herdr, so a tmux-only host never reads it.
_KP_MUX_HERDR_LOADED=0
_kp_mux_load_herdr() {
  [ "$_KP_MUX_HERDR_LOADED" = 1 ] && return 0
  # shellcheck source=mux-herdr.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mux-herdr.sh"
  _KP_MUX_HERDR_LOADED=1
}

# _kp_mux_tmux_target_state <target>: the tmux half of kp_mux_target_state. An
# empty pane list means the window went away between the find and this read.
_kp_mux_tmux_target_state() {
  local target=${1:?} panes
  panes=$(kp_tmux "${KP_WINDOW_SOCKET:-}" list-panes -t "$target" -F '#{pane_dead}' 2>/dev/null) || {
    printf 'none\n'
    return 0
  }
  if [ -z "$panes" ]; then
    printf 'none\n'
  elif printf '%s\n' "$panes" | grep -q '^0$'; then
    printf 'alive\n'
  else
    printf 'dead\n'
  fi
}

# _kp_mux_record_set <task-dir> <KEY> <value>
# Rewrite one `KEY=` line through a temp file beside the record, adding it when
# the record has none. Only a changed value is written, so a repeated call leaves
# task.env byte-identical.
_kp_mux_record_set() {
  local task_dir=${1:?} key=${2:?} value=${3:?} env_file cur tmp
  task_dir=${task_dir%/}
  env_file="$task_dir/task.env"
  [ -f "$env_file" ] || { printf 'cannot record %s: %s is missing\n' "$key" "$env_file" >&2; return 1; }
  cur=$(kp_env_get "$env_file" "$key")
  [ "$cur" = "$value" ] && return 0
  tmp="$env_file.$key.$$"
  if grep -q "^$key=" "$env_file"; then
    sed "s|^$key=.*|$key=$value|" "$env_file" > "$tmp" \
      || { rm -f "$tmp"; printf 'cannot write %s\n' "$tmp" >&2; return 1; }
  else
    { cat "$env_file" && printf '%s=%s\n' "$key" "$value"; } > "$tmp" \
      || { rm -f "$tmp"; printf 'cannot write %s\n' "$tmp" >&2; return 1; }
  fi
  mv -f "$tmp" "$env_file" || { rm -f "$tmp"; printf 'cannot write %s\n' "$env_file" >&2; return 1; }
  return 0
}
