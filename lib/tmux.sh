# shellcheck shell=bash
# Where the fleet's tmux windows live (issue #142) and which window belongs to a task
# (issue #149). One file, because both questions are answered from the same place: a
# task's window lives on the socket its record names, at its name first and its
# recorded id second.
#
# A new worker lands where the fleet says: `kp_tmux_resolve_target` resolves the socket
# and the session together, from --tmux-session, KINGPIN_TMUX_SESSION, TMUX_SESSION and
# TMUX_SOCKET in config.env, the caller's own tmux client, or the fleet server `kingpin`
# (issue #191). A socket is a `-L` name, or a path when it holds a `/`, which is how the
# caller's server is recorded. Every command that resolves a worker window goes through
# `kp_tmux`, so the socket is passed in one place, and `kp_tmux_label` and
# `kp_tmux_attach_cmd` are the one way a message or an attach hint spells it.
#
# A session is matched exactly (issues #149, #181): `kp_tmux_has_session` pins the
# target with tmux's `=` form, because a bare name is a unique prefix and a server
# holding only `kingpin-workers` would otherwise answer for `kingpin`. The one
# deliberate prefix resolver is `kp_tmux_resolve_session`, which a spawn uses for its
# explicit target (`--tmux-session` or `KINGPIN_TMUX_SESSION`) and then records the
# name tmux resolved.
#
# The window is resolved by name first and by id second (issue #149). Tmux window ids
# are per server and restart at `@0`, so an id recorded before the server died can
# name a different task's window; a reader that prefers the id blindly types into a
# stranger's pane and reports success. The exact name inside the task's own session
# is the one key that survives a restart, and the recorded id stays as the fallback
# for a hand-renamed window. Because `bin/kingpin-peek` promises to run only
# `list-panes` and `capture-pane`, the name lookup is a single `list-panes` call and
# the extra `list-windows` scan runs only to explain an ambiguous name.
#
# The harness identity is the pane pid: tmux runs the launch script as the pane
# process and the script `exec`s the harness, so `#{pane_pid}` and the `<task-dir>/
# harness.pid` a spawn records are the same number. A recorded pid that is not one of
# the pane pids means the window came back as a plain shell (a resurrected fleet).
#
# Source lib/status.sh first: `kp_tmux_socket_from_env` reads the task record with
# `kp_env_get`, and `kp_window_record_id` writes it with `kp_env_set`. These functions
# print only what they document.
#
#   # shellcheck source=../lib/status.sh
#   . "$KP_ROOT/lib/status.sh"
#   # shellcheck source=../lib/tmux.sh
#   . "$KP_ROOT/lib/tmux.sh"
#
# The variables `kp_window_find` sets for its caller:
#   KP_WINDOW_ID       the window id to address (`@N`), empty when none was found
#   KP_WINDOW_NAME     the recorded window name from TMUX_TARGET
#   KP_WINDOW_SESSION  the recorded session from TMUX_TARGET
#   KP_WINDOW_SOCKET   the socket the record names, empty for the default server
#   KP_WINDOW_LABEL    `<session>:<name>` or `<session>:<name> (@N)` when found

# The task-record readers (kp_env_get, kp_task_is_live) live in lib/status.sh.
# shellcheck source=status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"

# kp_tmux_socket_name
# The socket the fleet uses: KINGPIN_TMUX_SOCKET, or `kingpin`.
kp_tmux_socket_name() {
  printf '%s\n' "${KINGPIN_TMUX_SOCKET:-kingpin}"
}

# kp_tmux_socket_for <kp-home>
# The socket a new terminal lands on when no session names one: KINGPIN_TMUX_SOCKET,
# then TMUX_SOCKET in <kp-home>/config.env, then `kingpin`. A `/` in the value makes
# it a socket path (`tmux -S`), which is how a server started with a custom
# TMUX_TMPDIR or an explicit -S path is named without guessing where its socket lives.
kp_tmux_socket_for() {
  local home=${1:-} sock=''
  if [ -n "${KINGPIN_TMUX_SOCKET:-}" ]; then
    printf '%s\n' "$KINGPIN_TMUX_SOCKET"
    return 0
  fi
  [ -n "$home" ] && [ -f "$home/config.env" ] && sock=$(kp_env_get "$home/config.env" TMUX_SOCKET)
  printf '%s\n' "${sock:-kingpin}"
}

# kp_tmux_socket_from_env <task-env-file>
# The socket a task record names, or nothing for a record written before the
# fleet moved to its own server (those windows live on the default socket).
kp_tmux_socket_from_env() {
  [ -f "${1:-}" ] || return 0
  kp_env_get "$1" TMUX_SOCKET
}

# kp_tmux <socket> [tmux-args...]
# Run tmux on <socket>; an empty socket means the default tmux server, which is
# where a task record without TMUX_SOCKET points. The default is named
# explicitly, `-L default`, and never left to a bare `tmux`: a caller inside a
# tmux pane inherits TMUX, and a bare call would follow that socket instead of
# the default server the record means. A value holding a `/` is a socket path and
# is passed with `-S`, so a record can name the server whose socket lives outside
# the default directory.
kp_tmux() {
  local sock=${1:-}
  shift || true
  case $sock in
    */*) tmux -S "$sock" "$@" ;;
    *) tmux -L "${sock:-default}" "$@" ;;
  esac
}

# kp_tmux_label <socket>
# How a message names a server: `tmux`, `tmux -L <name>` or `tmux -S <path>`. An
# empty or `default` socket reads as a plain `tmux`, the same way attach does.
kp_tmux_label() {
  case "${1:-}" in
    ''|default) printf 'tmux' ;;
    */*) printf 'tmux -S %s' "$1" ;;
    *) printf 'tmux -L %s' "$1" ;;
  esac
}

# kp_tmux_attach_cmd <socket>
# The command that attaches a terminal to <socket>: a plain `tmux attach` for the
# default server, `tmux -S <path> attach` for a socket path, `tmux -L <name>
# attach` for a name.
kp_tmux_attach_cmd() {
  case "${1:-}" in
    ''|default) printf 'tmux attach' ;;
    */*) printf 'tmux -S %s attach' "$1" ;;
    *) printf 'tmux -L %s attach' "$1" ;;
  esac
}

# kp_tmux_caller_target
# Prints `<socket><TAB><session>` for the tmux client this process runs under, and
# nothing with exit 1 when $TMUX is unset, malformed, or names a session that no
# longer resolves. $TMUX is `<socket-path>,<server-pid>,<session-id>`, so the socket
# travels with the session and a server started with a custom TMUX_TMPDIR or with
# `-S` is recorded as the path it really is.
kp_tmux_caller_target() {
  local sock='' sid='' name=''
  [ -n "${TMUX:-}" ] || return 1
  sock=${TMUX%%,*}
  sid=${TMUX##*,}
  [ -n "$sock" ] && [ "$sock" != "$TMUX" ] || return 1
  case $sid in ''|*[!0-9]*) return 1 ;; esac
  name=$(kp_tmux "$sock" display-message -p -t "\$$sid" '#S' 2>/dev/null) || return 1
  [ -n "$name" ] || return 1
  printf '%s\t%s\n' "$sock" "$name"
}

# kp_tmux_socket_reachable <socket>
# Exit 0 when a tmux server answers on <socket> (empty means the default server),
# 1 when none does. `list-sessions` is the cheapest call that proves a server is
# there without creating one; a server with no sessions exits on its own, so a
# reachable server always answers. Never prints anything.
kp_tmux_socket_reachable() {
  kp_tmux "${1:-}" list-sessions >/dev/null 2>&1
}

# kp_tmux_socket_warn_line <socket> <task-id>...
# One stderr line for a server that is not running while live task records still
# name it: the socket, the tasks whose windows died with it, and the command that
# attaches once it is back. Prints nothing when the server answers, when no task
# id is given, or when KINGPIN_SKIP_SOCKET_WARN=1 silences it, so a caller can
# hand it every socket it saw. Returns 0 either way.
kp_tmux_socket_warn_line() {
  local sock=${1:-} ids='' id hint
  shift || true
  [ "${KINGPIN_SKIP_SOCKET_WARN:-}" != 1 ] || return 0
  for id in "$@"; do ids=${ids:+"$ids, "}$id; done
  [ -n "$ids" ] || return 0
  kp_tmux_socket_reachable "$sock" && return 0
  hint=$(kp_tmux_attach_cmd "$sock")
  printf "kingpin: the tmux server '%s' is not running; live tasks %s name it and their windows are gone. Attach once it is back: %s; kingpin watch restarts it and runs kingpin restore (or run kingpin restore yourself)\n" \
    "${sock:-default}" "$ids" "$hint" >&2
  return 0
}

# kp_tmux_resolve_target <kp-home> [<explicit-session> <explicit-source>]
# Prints `<socket><TAB><session><TAB><source><TAB><server-started>` for the terminal a
# new task should get, resolving the socket and the session in one place:
#
#   socket   KINGPIN_TMUX_SOCKET, then TMUX_SOCKET in <kp-home>/config.env, then the
#            caller's $TMUX socket when nothing names a socket and a session, then
#            `kingpin`.
#   session  <explicit-session> (the caller names its own source), then
#            KINGPIN_TMUX_SESSION, then TMUX_SESSION in config.env, each resolved on
#            that socket and refused when it does not exist; then, when nothing named
#            a socket or a session, the caller's own session; then the one session a
#            client is attached to; then the only session the socket holds; then a
#            `kingpin` session that is created. A user-typed target (the explicit
#            argument or KINGPIN_TMUX_SESSION) may be an unambiguous prefix and is
#            recorded as the name tmux resolved it to (issues #152, #181); a
#            TMUX_SESSION from config.env is matched exactly, like every other
#            session this function reads.
#
# <server-started> is 1 when the fallback had to start the tmux server itself. A
# refusal prints one sentence on stdout and returns 1, so the caller reads the reason
# from the same substitution and decides its own prefix and exit; a stderr note still
# rides the fallback paths. The session name tmux resolved is what gets printed, so a
# prefix never becomes a recorded target.
kp_tmux_resolve_target() {
  local home=${1:?kp_tmux_resolve_target needs a kp-home} explicit=${2:-} explicit_source=${3:-}
  local config_socket='' config_session='' socket='' name='' source='' resolved='' prefix_ok=0
  local caller='' caller_socket='' caller_session='' started=0
  local all=() attached_names=() joined='' attached_joined='' measured=''
  if [ -n "$home" ] && [ -f "$home/config.env" ]; then
    config_socket=$(kp_env_get "$home/config.env" TMUX_SOCKET)
    config_session=$(kp_env_get "$home/config.env" TMUX_SESSION)
  fi
  socket=$(kp_tmux_socket_for "$home")

  # A named session is resolved on the configured socket, and must already exist:
  # creating it would put the worker in a session nobody watches (issue #152).
  if [ -n "$explicit" ]; then
    name=$explicit source=$explicit_source prefix_ok=1
  elif [ -n "${KINGPIN_TMUX_SESSION:-}" ]; then
    name=$KINGPIN_TMUX_SESSION source='KINGPIN_TMUX_SESSION' prefix_ok=1
  elif [ -n "$config_session" ]; then
    name=$config_session source="TMUX_SESSION in $home/config.env"
  fi
  if [ -n "$name" ]; then
    if [ "$prefix_ok" -eq 1 ]; then
      # A user-typed target (--tmux-session, KINGPIN_TMUX_SESSION) accepts an
      # unambiguous prefix on purpose, and the name tmux resolved it to is recorded
      # (issues #152, #181). A configured TMUX_SESSION and every other source below
      # are matched exactly, so a `kingpin-workers` session is never taken for one.
      resolved=$(kp_tmux_resolve_session "$socket" "$name") || resolved=''
    else
      kp_tmux_has_session "$socket" "$name" && resolved=$name || resolved=''
    fi
    [ -n "$resolved" ] \
      || {
        printf "the session '%s' from %s does not exist on the tmux server '%s' (%s); start it, or name a session that does\n" \
          "$name" "$source" "${socket:-default}" "$(kp_tmux_label "$socket")"
        return 1
      }
    printf '%s\t%s\tfrom %s\t0\n' "$socket" "$resolved" "$source"
    return 0
  fi

  # Nothing named a session. When nothing named a socket either, follow the tmux client
  # this command runs under: the worker then lands in the orchestrator's own session,
  # and its socket travels with it. A named socket suppresses this, because that
  # session lives on another server; KINGPIN_TMUX_SOCKET=kingpin keeps the isolation
  # of issue #142.
  if [ -z "${KINGPIN_TMUX_SOCKET:-}" ] && [ -z "$config_socket" ]; then
    if caller=$(kp_tmux_caller_target); then
      IFS=$'\t' read -r caller_socket caller_session <<<"$caller"
      printf '%s\t%s\t%s\t0\n' "$caller_socket" "$caller_session" "the caller's tmux session (\$TMUX)"
      return 0
    fi
    # Only a set-but-stale $TMUX is worth a note: outside tmux is the normal case, and
    # the fallback is the documented one, so a plain shell gets no warning.
    if [ -n "${TMUX:-}" ]; then
      printf "kingpin: \$TMUX names no reachable session; falling back to the fleet tmux server '%s'\n" "${socket:-default}" >&2
    fi
  fi

  # Join a session on the fleet socket that cannot be mistaken for another: the one an
  # operator attached there, then the only one the server holds. One candidate is not
  # a guess.
  while IFS=$'\t' read -r name attached; do
    [ -n "$name" ] || continue
    all+=("$name")
    [ "$attached" = 0 ] || attached_names+=("$name")
  done < <(kp_tmux "$socket" list-sessions -F $'#{session_name}\t#{session_attached}' 2>/dev/null || true)
  if [ "${#attached_names[@]}" -eq 1 ]; then
    printf '%s\t%s\t%s\t0\n' "$socket" "${attached_names[0]}" 'the only attached session'
    return 0
  fi
  if [ "${#all[@]}" -eq 1 ]; then
    printf '%s\t%s\t%s\t0\n' "$socket" "${all[0]}" 'the only session on the server'
    return 0
  fi
  if [ "${#all[@]}" -gt 1 ]; then
    for name in "${all[@]}"; do joined=${joined:+"$joined, "}$name; done
    if [ "${#attached_names[@]}" -eq 0 ]; then
      measured="the tmux server '${socket:-default}' has ${#all[@]} sessions and none has a client attached ($joined)"
    else
      for name in "${attached_names[@]}"; do
        attached_joined=${attached_joined:+"$attached_joined, "}$name
      done
      measured="the tmux server '${socket:-default}' has ${#all[@]} sessions and ${#attached_names[@]} of them have a client attached ($attached_joined)"
    fi
    printf "no single target session on the tmux server '%s', and %s; name one with --tmux-session <name>, KINGPIN_TMUX_SESSION=<name>, or TMUX_SESSION in %s/config.env\n" \
      "${socket:-default}" "$measured" "$home"
    return 1
  fi
  # Nothing to join: the one case where a session is created, and the caller says so.
  kp_tmux_socket_reachable "$socket" || started=1
  kp_tmux "$socket" new-session -d -s kingpin -n home \
    || {
      printf "no session on the tmux server '%s' (%s) and the fallback session 'kingpin' could not be created\n" \
        "${socket:-default}" "$(kp_tmux_label "$socket")"
      return 1
    }
  printf "kingpin: no session on the fleet tmux server '%s'; created and using \"kingpin\" (name one with --tmux-session or KINGPIN_TMUX_SESSION)\n" "${socket:-default}" >&2
  printf '%s\t%s\t%s\t%s\n' "$socket" kingpin 'the named fallback (no session existed)' "$started"
  return 0
}

# kp_tmux_has_session <socket> <name>
# Exit 0 when <socket> holds a session named exactly <name>. The target is written
# `=<name>`, tmux's exact-match form: a bare name is a unique prefix, so a server
# holding only `kingpin-workers` answers yes for `kingpin` and the caller starts
# nothing (issues #149, #181). An empty name answers no. Prints nothing.
kp_tmux_has_session() {
  local sock=${1:-} name=${2:-}
  [ -n "$name" ] || return 1
  kp_tmux "$sock" has-session -t "=$name" 2>/dev/null
}

# kp_tmux_resolve_session <socket> <target>
# Print the name of the session <target> names on <socket>, accepting an
# unambiguous prefix the way tmux does on purpose, which is what a spawn's explicit
# target (`--tmux-session`, `KINGPIN_TMUX_SESSION`) promises (issue #152). Exit 1
# when no session matches and print nothing. A caller that must not accept a prefix
# uses kp_tmux_has_session.
kp_tmux_resolve_session() {
  local sock=${1:-} target=${2:-} name=''
  [ -n "$target" ] || return 1
  kp_tmux "$sock" has-session -t "$target" 2>/dev/null || return 1
  name=$(kp_tmux "$sock" display-message -p -t "$target" '#S' 2>/dev/null) || return 1
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# kp_tmux_ensure_session <socket> <session>
# Make sure <session> exists on <socket>, creating it detached when it does not.
# The check is exact, so a `kingpin-workers` session beside it is never taken for
# `kingpin` (issue #181). Prints nothing; the caller reports a failure.
kp_tmux_ensure_session() {
  local sock=${1:-} session=${2:?}
  kp_tmux_has_session "$sock" "$session" \
    || kp_tmux "$sock" new-session -d -s "$session" -n home
}

# Shell names a resurrected window runs: a pane running one of these is a plain
# shell, not a harness, so a recorded id pointing at it is not this task's window.
_kp_window_shell_names='bash sh zsh dash ksh fish'

# kp_window_parts <task-env-file>
# Prints `<session><TAB><name>` for the task. TMUX_TARGET is the record; its name
# part is the *recorded window name*, not the task id, because `kingpin-rename`
# renames a --text task's window while the id stays. A missing file or field reads
# as `kingpin` and the task id, the same default the readers used before this file.
kp_window_parts() {
  local env_file=${1:-} target='' session name id
  id=''
  [ -f "$env_file" ] && id=$(kp_env_get "$env_file" TASK_ID)
  [ -n "$id" ] || id=$(basename "$(dirname "$env_file")")
  [ -f "$env_file" ] && target=$(kp_env_get "$env_file" TMUX_TARGET)
  case $target in
    '') session=kingpin; name=$id ;;
    *:*) session=${target%%:*}; name=${target#*:} ;;
    *) session=$target; name=$id ;;
  esac
  [ -n "$session" ] || session=kingpin
  [ -n "$name" ] || name=$id
  printf '%s\t%s\n' "$session" "$name"
}

# _kp_window_found <window-id>: publish one resolved window to the caller.
_kp_window_found() {
  KP_WINDOW_ID=$1
  KP_WINDOW_LABEL="$KP_WINDOW_SESSION:$KP_WINDOW_NAME ($1)"
}

# _kp_window_claimed_elsewhere <kp-home> <task-dir> <window-id>
# Exit 0 when another *live* task record carries the same TMUX_WINDOW_ID, which is
# what makes a recorded id unsafe to follow after a restart: the id survives in more
# than one record, so it cannot be evidence of this task's window.
_kp_window_claimed_elsewhere() {
  local home=${1:-} task_dir=${2:-} id=${3:-} env other
  [ -n "$home" ] && [ -n "$id" ] || return 1
  for env in "$home"/tasks/*/task.env; do
    [ -f "$env" ] || continue
    other=$(dirname "$env")
    [ "$other" = "$task_dir" ] && continue
    kp_task_is_live "$other" || continue
    [ "$(kp_env_get "$env" TMUX_WINDOW_ID)" = "$id" ] && return 0
  done
  return 1
}

# kp_window_find <task-dir>
# Prints the window id to use and sets the KP_WINDOW_* variables. Exit 0 when a
# window was found, 1 otherwise; the reason for a refusal that names windows goes to
# stderr. The rule, in order:
#   1. the exact name inside the task's session (one `list-panes` call);
#   2. the recorded TMUX_WINDOW_ID when its window name still equals that name;
#   3. the recorded id when it is alive, no other live task record claims it, and its
#      pane does not run a plain shell (a hand-renamed window, as before);
#   4. nothing: a refusal, naming the id and the name when the id is alive.
kp_window_find() {
  local task_dir=${1:-}
  task_dir=${task_dir%/}
  KP_WINDOW_ID='' KP_WINDOW_NAME='' KP_WINDOW_SESSION='' KP_WINDOW_LABEL='' KP_WINDOW_SOCKET=''
  [ -n "$task_dir" ] || return 1
  local env_file="$task_dir/task.env" home session name recorded ids count rname cmd dupes sock
  home=$(dirname "$(dirname "$task_dir")")
  sock=$(kp_tmux_socket_from_env "$env_file")
  KP_WINDOW_SOCKET=$sock
  IFS=$'\t' read -r session name < <(kp_window_parts "$env_file")
  KP_WINDOW_SESSION=${session:-kingpin}
  KP_WINDOW_NAME=${name:-$(basename "$task_dir")}
  # shellcheck disable=SC2034 # read by the caller after this returns
  KP_WINDOW_LABEL="$KP_WINDOW_SESSION:$KP_WINDOW_NAME"

  ids=$(kp_tmux "$sock" list-panes -t "=$KP_WINDOW_SESSION:=$KP_WINDOW_NAME" -F '#{window_id}' 2>/dev/null | sort -u || true)
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  if [ "${count:-0}" -eq 1 ] && [ -n "$ids" ]; then
    _kp_window_found "$ids"
    return 0
  fi

  # `display-message` answers for an id the server no longer has (tmux 3.8 prints
  # nothing and exits 0), so a dead id would read as a live window and a gone task
  # would never report `exited`. Require the pane list to resolve the id, and a
  # non-empty window name, before treating it as a window.
  recorded=$(kp_env_get "$env_file" TMUX_WINDOW_ID)
  if [ -n "$recorded" ] && kp_tmux "$sock" list-panes -t "$recorded" -F '#{window_id}' >/dev/null 2>&1 \
    && rname=$(kp_tmux "$sock" display-message -p -t "$recorded" '#{window_name}' 2>/dev/null) \
    && [ -n "$rname" ]; then
    if [ "$rname" = "$KP_WINDOW_NAME" ]; then
      _kp_window_found "$recorded"
      return 0
    fi
    if ! _kp_window_claimed_elsewhere "$home" "$task_dir" "$recorded"; then
      cmd=$(kp_tmux "$sock" display-message -p -t "$recorded" '#{pane_current_command}' 2>/dev/null || true)
      case " $_kp_window_shell_names " in
        *" $cmd "*) : ;;
        *)
          _kp_window_found "$recorded"
          return 0
          ;;
      esac
    fi
    printf "window %s now names '%s'; this task's window is '%s'\n" \
      "$recorded" "$rname" "$KP_WINDOW_NAME" >&2
    return 1
  fi

  # Only the fallback path pays for this: say why an exact name found nothing when
  # more than one window carries it.
  dupes=$(kp_tmux "$sock" list-windows -t "$KP_WINDOW_SESSION" -F '#{window_name}' 2>/dev/null | grep -cxF -- "$KP_WINDOW_NAME" || true)
  if [ "${dupes:-0}" -gt 1 ]; then
    printf "window name '%s' is ambiguous in %s: %s windows carry it\n" \
      "$KP_WINDOW_NAME" "$KP_WINDOW_SESSION" "$dupes" >&2
  fi
  return 1
}

# kp_window_harness_live <task-dir>
# Exit 0 only when kp_window_find succeeds and the harness runs in that window. With
# `<task-dir>/harness.pid` (written by kp_window_start), the pid must be alive and
# must be one of the pane pids. Without it, the record predates that file, so the
# first pane's current command is used instead and a plain shell means no harness.
kp_window_harness_live() {
  local task_dir=${1:-}
  task_dir=${task_dir%/}
  kp_window_find "$task_dir" >/dev/null 2>&1 || return 1
  local pid_file="$task_dir/harness.pid" pid panes cmd
  if [ -f "$pid_file" ]; then
    pid=$(tr -dc '0-9' < "$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    panes=$(kp_tmux "$KP_WINDOW_SOCKET" list-panes -t "$KP_WINDOW_ID" -F '#{pane_pid}' 2>/dev/null) || return 1
    printf '%s\n' "$panes" | grep -qxF -- "$pid"
    return
  fi
  cmd=$(kp_tmux "$KP_WINDOW_SOCKET" display-message -p -t "$KP_WINDOW_ID" '#{pane_current_command}' 2>/dev/null) || return 1
  case " $_kp_window_shell_names " in
    *" $cmd "*) return 1 ;;
  esac
  return 0
}

# kp_window_record_id <task-dir> <window-id>
# Record the TMUX_WINDOW_ID= line of the task's record, and add the line when the record
# has none. `kp_env_set` (lib/status.sh) does the write: only a changed value is
# written, so a repeated restore leaves task.env byte-identical. Exit 1 with a stderr
# reason when it cannot write.
kp_window_record_id() {
  local task_dir=${1:?kp_window_record_id needs a task dir} id=${2:?kp_window_record_id needs a window id}
  task_dir=${task_dir%/}
  kp_env_set "$task_dir/task.env" TMUX_WINDOW_ID "$id"
}

# _kp_window_same_name <socket> <session> <name>: prints the id of a window on
# <socket> in <session> whose name is exactly <name>, or nothing. `=session` is
# exact: a session called `kingpin-workers` must not answer for `kingpin` (issue
# #149).
_kp_window_same_name() {
  local sock=${1:-} session=${2:?} name=${3:?} ids
  ids=$(kp_tmux "$sock" list-panes -t "=$session:=$name" -F '#{window_id}' 2>/dev/null | sort -u || true)
  [ "$(printf '%s\n' "$ids" | grep -c . || true)" = "1" ] || return 0
  printf '%s\n' "$ids"
}

# kp_window_name_claimed <task-dir> <session> <name>
# Prints the id of another *live* task record that resolves to the same session and
# window name, and exits 0; prints nothing and exits 1 when the name is this task's
# alone. A name is not a unique claim (two `--text` tasks can rename to the same issue
# title, and an operator window can carry a task's name), so a caller that would
# respawn a same-named window asks first: `respawn-pane -k` on another task's pane
# destroys that task (issue #149).
kp_window_name_claimed() {
  local task_dir=${1:?kp_window_name_claimed needs a task dir} session=${2:?} name=${3:?}
  task_dir=${task_dir%/}
  local home env other s n
  home=$(dirname "$(dirname "$task_dir")")
  for env in "$home"/tasks/*/task.env; do
    [ -f "$env" ] || continue
    other=$(dirname "$env")
    [ "$other" = "$task_dir" ] && continue
    kp_task_is_live "$other" || continue
    IFS=$'\t' read -r s n < <(kp_window_parts "$env")
    if [ "$s" = "$session" ] && [ "$n" = "$name" ]; then
      basename "$other"
      return 0
    fi
  done
  return 1
}

# kp_window_start <task-dir> <session> <name> <worktree> <launch-script> [--fresh]
# The one place that creates or reclaims a task's window, on the socket its record
# names. With --fresh a same-named window in <session> is refused on stderr (a spawn
# must never take over another task's window). Without it, a same-named window is
# respawned in place with `respawn-pane -k`, so its id and name survive and its old
# pane process is replaced; otherwise a window is created. A caller refuses a name
# another live task record also resolves to (`kp_window_name_claimed`) before it gets
# here. The name is pinned, the pane pid is written to `<task-dir>/harness.pid`, and
# the window id is printed.
kp_window_start() {
  local task_dir=${1:?kp_window_start needs a task dir} session=${2:?} name=${3:?}
  local worktree=${4:?} launch=${5:?} fresh=0 existing id panes_pid sock
  shift 5
  case "${1:-}" in
    --fresh) fresh=1 ;;
    '') ;;
    *) echo "kingpin: unknown option for kp_window_start: $1" >&2; return 2 ;;
  esac
  task_dir=${task_dir%/}
  [ -d "$worktree" ] || { echo "worktree is not a directory: $worktree" >&2; return 1; }
  [ -f "$launch" ] || { echo "launch script is missing: $launch" >&2; return 1; }
  sock=$(kp_tmux_socket_from_env "$task_dir/task.env")
  KP_WINDOW_SOCKET=$sock
  KP_WINDOW_SESSION=$session
  KP_WINDOW_NAME=$name

  existing=$(_kp_window_same_name "$sock" "$session" "$name")
  if [ -n "$existing" ]; then
    if [ "$fresh" = 1 ]; then
      echo "a window named $name already exists in $session ($existing)" >&2
      return 1
    fi
    kp_tmux "$sock" respawn-pane -k -t "$existing" -c "$worktree" "$(printf '%q' "$launch")" \
      || { echo "cannot respawn the pane of $session:$name ($existing)" >&2; return 1; }
    id=$existing
  else
    id=$(kp_tmux "$sock" new-window -d -P -F '#{window_id}' -t "=$session:" -n "$name" -c "$worktree" "$launch") \
      || { echo "cannot create a window in $session" >&2; return 1; }
    [ -n "$id" ] || { echo "cannot create a window in $session" >&2; return 1; }
  fi

  # Pin the name: ambient `automatic-rename on` and `allow-rename on` (tmux config, or
  # an escape sequence from a worker's child commands) would otherwise rename it. Only
  # kingpin-rename and kingpin-wait rename it, explicitly, and a failed pin is
  # cosmetic: it must not tear down a started worker.
  kp_tmux "$sock" set-window-option -t "$id" automatic-rename off 2>/dev/null || true
  kp_tmux "$sock" set-window-option -t "$id" allow-rename off 2>/dev/null || true

  panes_pid=$(kp_tmux "$sock" list-panes -t "$id" -F '#{pane_pid}' 2>/dev/null | head -n 1 || true)
  if [ -n "$panes_pid" ]; then
    printf '%s\n' "$panes_pid" > "$task_dir/harness.pid" \
      || { echo "cannot record the pane pid in $task_dir/harness.pid" >&2; return 1; }
  fi
  printf '%s\n' "$id"
  return 0
}
