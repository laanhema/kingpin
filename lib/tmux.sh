# shellcheck shell=bash
# One place that finds a task's tmux window, says whether its harness is in it, and
# creates or reclaims it. Source it; it defines the functions below and the
# `KP_WINDOW_*` result variables `kp_window_find` sets, and nothing else (no `set`
# options, no output beyond what each states, every function returns 0 unless stated).
#
#   # shellcheck source=../lib/tmux.sh
#   . "$KP_ROOT/lib/tmux.sh"
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
# The variables `kp_window_find` sets for its caller:
#   KP_WINDOW_ID       the window id to address (`@N`), empty when none was found
#   KP_WINDOW_NAME     the recorded window name from TMUX_TARGET
#   KP_WINDOW_SESSION  the recorded session from TMUX_TARGET
#   KP_WINDOW_LABEL    `<session>:<name>` or `<session>:<name> (@N)` when found

# The task-record readers (kp_env_get, kp_task_is_live) live in lib/status.sh.
# shellcheck source=status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"

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
  KP_WINDOW_ID='' KP_WINDOW_NAME='' KP_WINDOW_SESSION='' KP_WINDOW_LABEL=''
  [ -n "$task_dir" ] || return 1
  local env_file="$task_dir/task.env" home session name recorded ids count rname cmd dupes
  home=$(dirname "$(dirname "$task_dir")")
  IFS=$'\t' read -r session name < <(kp_window_parts "$env_file")
  KP_WINDOW_SESSION=${session:-kingpin}
  KP_WINDOW_NAME=${name:-$(basename "$task_dir")}
  # shellcheck disable=SC2034 # read by the caller after this returns
  KP_WINDOW_LABEL="$KP_WINDOW_SESSION:$KP_WINDOW_NAME"

  ids=$(tmux list-panes -t "$KP_WINDOW_SESSION:=$KP_WINDOW_NAME" -F '#{window_id}' 2>/dev/null | sort -u || true)
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
  if [ -n "$recorded" ] && tmux list-panes -t "$recorded" -F '#{window_id}' >/dev/null 2>&1 \
    && rname=$(tmux display-message -p -t "$recorded" '#{window_name}' 2>/dev/null) \
    && [ -n "$rname" ]; then
    if [ "$rname" = "$KP_WINDOW_NAME" ]; then
      _kp_window_found "$recorded"
      return 0
    fi
    if ! _kp_window_claimed_elsewhere "$home" "$task_dir" "$recorded"; then
      cmd=$(tmux display-message -p -t "$recorded" '#{pane_current_command}' 2>/dev/null || true)
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
  dupes=$(tmux list-windows -t "$KP_WINDOW_SESSION" -F '#{window_name}' 2>/dev/null | grep -cxF -- "$KP_WINDOW_NAME" || true)
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
    panes=$(tmux list-panes -t "$KP_WINDOW_ID" -F '#{pane_pid}' 2>/dev/null) || return 1
    printf '%s\n' "$panes" | grep -qxF -- "$pid"
    return
  fi
  cmd=$(tmux display-message -p -t "$KP_WINDOW_ID" '#{pane_current_command}' 2>/dev/null) || return 1
  case " $_kp_window_shell_names " in
    *" $cmd "*) return 1 ;;
  esac
  return 0
}

# kp_window_record_id <task-dir> <window-id>
# Rewrite the TMUX_WINDOW_ID= line through a temp file beside it, and add the line
# when the record has none. Only a changed value is written, so a repeated restore
# leaves task.env byte-identical. Exit 1 with a stderr reason when it cannot write.
kp_window_record_id() {
  local task_dir=${1:?kp_window_record_id needs a task dir} id=${2:?kp_window_record_id needs a window id}
  task_dir=${task_dir%/}
  local env_file="$task_dir/task.env" cur tmp
  [ -f "$env_file" ] || { echo "cannot record the window id: $env_file is missing" >&2; return 1; }
  cur=$(kp_env_get "$env_file" TMUX_WINDOW_ID)
  [ "$cur" = "$id" ] && return 0
  tmp="$env_file.id.$$"
  if grep -q '^TMUX_WINDOW_ID=' "$env_file"; then
    sed "s|^TMUX_WINDOW_ID=.*|TMUX_WINDOW_ID=$id|" "$env_file" > "$tmp" \
      || { rm -f "$tmp"; echo "cannot write $tmp" >&2; return 1; }
  else
    { cat "$env_file" && printf 'TMUX_WINDOW_ID=%s\n' "$id"; } > "$tmp" \
      || { rm -f "$tmp"; echo "cannot write $tmp" >&2; return 1; }
  fi
  mv -f "$tmp" "$env_file" || { rm -f "$tmp"; echo "cannot write $env_file" >&2; return 1; }
  return 0
}

# _kp_window_same_name <session> <name>: prints the id of a window in <session>
# whose name is exactly <name>, or nothing. `=session` is exact: a session called
# `kingpin-workers` must not answer for `kingpin` (issue #149).
_kp_window_same_name() {
  local session=${1:?} name=${2:?} ids
  ids=$(tmux list-panes -t "=$session:=$name" -F '#{window_id}' 2>/dev/null | sort -u || true)
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
# The one place that creates or reclaims a task's window. With --fresh a same-named
# window in <session> is refused on stderr (a spawn must never take over another
# task's window). Without it, a same-named window is respawned in place with
# `respawn-pane -k`, so its id and name survive and its old pane process is replaced;
# otherwise a window is created. A caller refuses a name another live task record also
# resolves to (`kp_window_name_claimed`) before it gets here. The name is pinned, the
# pane pid is written to `<task-dir>/harness.pid`, and the window id is printed.
kp_window_start() {
  local task_dir=${1:?kp_window_start needs a task dir} session=${2:?} name=${3:?}
  local worktree=${4:?} launch=${5:?} fresh=0 existing id panes_pid
  shift 5
  case "${1:-}" in
    --fresh) fresh=1 ;;
    '') ;;
    *) echo "kingpin: unknown option for kp_window_start: $1" >&2; return 2 ;;
  esac
  task_dir=${task_dir%/}
  [ -d "$worktree" ] || { echo "worktree is not a directory: $worktree" >&2; return 1; }
  [ -f "$launch" ] || { echo "launch script is missing: $launch" >&2; return 1; }

  existing=$(_kp_window_same_name "$session" "$name")
  if [ -n "$existing" ]; then
    if [ "$fresh" = 1 ]; then
      echo "a window named $name already exists in $session ($existing)" >&2
      return 1
    fi
    tmux respawn-pane -k -t "$existing" -c "$worktree" "$(printf '%q' "$launch")" \
      || { echo "cannot respawn the pane of $session:$name ($existing)" >&2; return 1; }
    id=$existing
  else
    id=$(tmux new-window -d -P -F '#{window_id}' -t "=$session:" -n "$name" -c "$worktree" "$launch") \
      || { echo "cannot create a window in $session" >&2; return 1; }
    [ -n "$id" ] || { echo "cannot create a window in $session" >&2; return 1; }
  fi

  # Pin the name: ambient `automatic-rename on` and `allow-rename on` (tmux config, or
  # an escape sequence from a worker's child commands) would otherwise rename it. Only
  # kingpin-rename and kingpin-wait rename it, explicitly, and a failed pin is
  # cosmetic: it must not tear down a started worker.
  tmux set-window-option -t "$id" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$id" allow-rename off 2>/dev/null || true

  panes_pid=$(tmux list-panes -t "$id" -F '#{pane_pid}' 2>/dev/null | head -n 1 || true)
  if [ -n "$panes_pid" ]; then
    printf '%s\n' "$panes_pid" > "$task_dir/harness.pid" \
      || { echo "cannot record the pane pid in $task_dir/harness.pid" >&2; return 1; }
  fi
  printf '%s\n' "$id"
  return 0
}
