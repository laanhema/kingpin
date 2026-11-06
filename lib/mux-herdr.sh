# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154 # the KP_* variables and _kp_window_shell_names are defined by lib/mux.sh and lib/tmux.sh, which source this file
# The Herdr backend of lib/mux.sh (issue #144), written against herdr 0.9.3 and
# the measurements in `.agents/reports/issue-144-herdr-evidence.md`.
#
# lib/mux.sh sources this file only when a task record or KINGPIN_MUX selects
# Herdr, so a tmux-only host never reads it. Do not source it directly, and never
# call `herdr` from a command: `_kp_herdr` and `_kp_herdr_at` are the only places
# this repository reaches the binary.
#
# What Herdr 0.9.3 does, and what that costs here:
#
#   * A control call from outside a pane must name its session (`--session <s>`);
#     a command running inside a pane inherits it and must not. `_kp_herdr_at`
#     passes `--session` unless the caller really is in that session's pane, so a
#     fleet command can never fall through to the operator's default session.
#   * `pane list`, `pane get`, `pane process-info` and `api snapshot` print JSON;
#     `pane read` prints plain text and `pane run`/`pane send-text` print nothing.
#     The two shapes are read by different code here: JSON goes through `node`
#     (there is no `jq` dependency in this repository), text is passed through
#     untouched. Reading a `pane read` body as JSON would blank a real worker's
#     tail.
#   * A pane id survives a tab move and a rename but is renumbered when the pane
#     moves across workspaces, and Herdr has no activity clock. So the record keeps
#     the pane id (`MUX_TARGET`) and the pane label (`MUX_LABEL`), a find prefers
#     the label, and activity is a hash of the recent output: the pane `revision`
#     in 0.9.3 does not move with output (measured), so it cannot answer "is this
#     worker still printing?".
#   * `pane close` closes an emptied workspace, and there is no force flag.
#
# The record keys a Herdr task carries:
#   MUX=herdr   MUX_SESSION=<herdr session>   MUX_TARGET=<pane id>   MUX_LABEL=<pane label>

# The task-record reader and writer (kp_env_get, kp_env_set) live in lib/status.sh,
# which lib/mux.sh sources. This file is sourced from lib/mux.sh, so those functions
# already exist.

# _kp_herdr_session_name
# The fleet's Herdr session: KINGPIN_HERDR_SESSION, then HERDR_SESSION inside a
# pane, then `kingpin` (the name the tmux fleet uses too).
_kp_herdr_session_name() {
  if [ -n "${KINGPIN_HERDR_SESSION:-}" ]; then
    printf '%s\n' "$KINGPIN_HERDR_SESSION"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_SESSION:-}" ]; then
    printf '%s\n' "$HERDR_SESSION"
    return 0
  fi
  printf 'kingpin\n'
}

# _kp_herdr_session
# The session the next call addresses: the task record's MUX_SESSION when
# kp_mux_find published one, else _kp_herdr_session_name.
_kp_herdr_session() {
  if [ -n "${KP_MUX_SESSION:-}" ]; then
    printf '%s\n' "$KP_MUX_SESSION"
    return 0
  fi
  _kp_herdr_session_name
}

# _kp_herdr_at <session> [herdr-args...]
# Run herdr against one named session. Inside a pane of that same session no
# `--session` is passed (the pane inherits it); everywhere else the session is
# named explicitly, so a bare `herdr` can never reach the operator's session.
_kp_herdr_at() {
  local session=${1:?}
  shift
  if [ "${HERDR_ENV:-}" = 1 ] && [ "${HERDR_SESSION:-}" = "$session" ]; then
    herdr "$@"
  else
    herdr --session "$session" "$@"
  fi
}

# _kp_herdr [herdr-args...]
# Run herdr against the resolved session. The one helper every verb below uses.
_kp_herdr() {
  local session
  session=$(_kp_herdr_session) || return 1
  _kp_herdr_at "$session" "$@"
}

# _kp_herdr_json <expression>
# Read one JSON document from stdin and print the value of <expression>, which is
# evaluated with `v` bound to the document. An array prints one element per line.
# Exit 3 when stdin is not JSON, 4 when the expression cannot be evaluated.
_kp_herdr_json() {
  local expr=${1:?}
  node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  let v;
  try { v = JSON.parse(raw); } catch (e) { process.exit(3); }
  let out;
  try { out = Function("v", "return (" + process.argv[1] + ");")(v); }
  catch (e) { process.exit(4); }
  if (out === undefined || out === null) return;
  if (Array.isArray(out)) { for (const item of out) console.log(item); }
  else console.log(String(out));
});
' "$expr"
}

# _kp_herdr_pane_pairs
# Read `pane list` JSON on stdin and print `pane_id<TAB>label` per pane, an empty
# second field for a pane without a label. herdr 0.9.3 prints `"label": null` for
# an unlabelled pane, so both null and a missing field read as unlabelled.
_kp_herdr_pane_pairs() {
  _kp_herdr_json 'v.result.panes.map((p) => p.pane_id + "\t" + (p.label == null ? "" : p.label)).join("\n")'
}

# _kp_herdr_pane_exists <pane-id>
# Exit 0 when `pane get` resolves the id. Errors are told apart by the exit code
# only where a caller needs it (a find just needs "no").
_kp_herdr_pane_exists() {
  _kp_herdr pane get "$1" >/dev/null 2>&1
}

# _kp_herdr_record_session <task-dir>
# The session a Herdr record names: `MUX_SESSION`, then the fleet's Herdr session (a
# pane belongs to its session, and `pane get` reports none). `_kp_herdr_find` resolves
# by this and so do the readers that need only the record's identity, so the rule
# lives in one place.
_kp_herdr_record_session() {
  local task_dir=${1:-} session=''
  [ -n "$task_dir" ] && [ -f "$task_dir/task.env" ] && session=$(kp_env_get "$task_dir/task.env" MUX_SESSION)
  [ -n "$session" ] || session=$(_kp_herdr_session_name)
  printf '%s\n' "$session"
}

# _kp_herdr_record_label <task-dir>
# The pane label a Herdr record resolves by: `MUX_LABEL`, then `TASK_ID`, then the
# task directory's basename, in the order `_kp_herdr_find` matches panes.
_kp_herdr_record_label() {
  local task_dir=${1:-} label=''
  task_dir=${task_dir%/}
  [ -n "$task_dir" ] && [ -f "$task_dir/task.env" ] && label=$(kp_env_get "$task_dir/task.env" MUX_LABEL)
  if [ -z "$label" ] && [ -n "$task_dir" ] && [ -f "$task_dir/task.env" ]; then
    label=$(kp_env_get "$task_dir/task.env" TASK_ID)
  fi
  [ -n "$label" ] || label=$(basename "$task_dir")
  printf '%s\n' "$label"
}

# _kp_herdr_find <task-dir> [no-record]
# Resolve a task's pane. The order is: the recorded MUX_LABEL matched against
# `pane list` (session-wide, so a cross-workspace move still resolves), then the
# recorded MUX_TARGET when `pane get` answers. A stale id is rewritten through
# kp_mux_record_id unless the second argument is 1, which a read-only caller
# passes. Exit 1 with a stderr reason when neither resolves; an ambiguous label is
# a refusal, not a guess.
_kp_herdr_find() {
  local task_dir=${1:-} no_record=${2:-0} env_file session label recorded panes matches count id
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  env_file="$task_dir/task.env"
  session=$(_kp_herdr_record_session "$task_dir")
  label=$(_kp_herdr_record_label "$task_dir")
  recorded=''
  [ -f "$env_file" ] && recorded=$(kp_env_get "$env_file" MUX_TARGET)

  KP_MUX=herdr
  KP_MUX_SESSION=$session
  KP_WINDOW_SESSION=$session
  KP_WINDOW_NAME=$label
  KP_WINDOW_SOCKET=''
  # shellcheck disable=SC2034 # read by the caller after this returns
  KP_WINDOW_LABEL="$session:$label"

  panes=$(_kp_herdr pane list 2>/dev/null) || return 1
  matches=$(printf '%s\n' "$panes" | _kp_herdr_pane_pairs | awk -F '\t' -v want="$label" '$2 == want { print $1 }')
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [ "${count:-0}" -eq 1 ]; then
    id=$matches
  elif [ "${count:-0}" -gt 1 ]; then
    printf "pane label '%s' is ambiguous in herdr session %s: %s panes carry it\n" \
      "$label" "$session" "$count" >&2
    return 1
  elif [ -n "$recorded" ] && _kp_herdr_pane_exists "$recorded"; then
    id=$recorded
  else
    if [ -n "$recorded" ]; then
      printf "herdr pane %s is gone and no pane in session %s carries the label '%s'\n" \
        "$recorded" "$session" "$label" >&2
    else
      printf "no pane in herdr session %s carries the label '%s'\n" "$session" "$label" >&2
    fi
    return 1
  fi

  KP_WINDOW_ID=$id
  # shellcheck disable=SC2034 # read by the caller after this returns
  KP_WINDOW_LABEL="$session:$label ($id)"
  if [ "$no_record" != 1 ] && [ "$recorded" != "$id" ] && [ -f "$env_file" ]; then
    kp_mux_record_id "$task_dir" "$id" >/dev/null 2>&1 || true
  fi
  return 0
}

# _kp_herdr_harness_live <task-dir>
# Exit 0 only when the pane is found and the recorded harness runs in it. With
# `<task-dir>/harness.pid` the pid must be alive and must be the pane's foreground
# leader (or one of its foreground processes); without it, the foreground command
# must not be a plain shell. A pane is a login shell above the harness, so the
# recorded pid is the harness, not the shell that `pane run` typed into.
_kp_herdr_harness_live() {
  local task_dir=${1:-} pid_file pid info cmd
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  # Resolve read-only: the harness check asks whether the recorded worker runs, and a
  # reader must not rewrite a stale MUX_TARGET on the way (issue #203).
  _kp_herdr_find "$task_dir" 1 >/dev/null 2>&1 || return 1
  pid_file="$task_dir/harness.pid"
  if [ -f "$pid_file" ]; then
    pid=$(tr -dc '0-9' < "$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    info=$(_kp_herdr pane process-info --pane "$KP_WINDOW_ID" 2>/dev/null) || return 1
    printf '%s\n' "$info" | _kp_herdr_json \
      'String(v.result.process_info.shell_pid) + "\n" + v.result.process_info.foreground_processes.map((p) => String(p.pid)).join("\n")' \
      | grep -qxF -- "$pid"
    return
  fi
  cmd=$(_kp_herdr_foreground_command "$KP_WINDOW_ID") || return 1
  case " $_kp_window_shell_names " in
    *" $cmd "*) return 1 ;;
  esac
  return 0
}

# _kp_herdr_target_state <target>
# Print alive when `pane get` answers, none when it does not. Herdr never leaves a
# dead pane behind: a pane that is lost is a closed pane.
_kp_herdr_target_state() {
  local target=${1:?}
  if _kp_herdr pane get "$target" >/dev/null 2>&1; then
    printf 'alive\n'
  else
    printf 'none\n'
  fi
}

# _kp_herdr_capture <target> <lines>
# Print the pane's recent text, plain. `recent-unwrapped` joins soft wraps, which
# is what the tmux backend's `-J` does.
_kp_herdr_capture() {
  local target=${1:?} lines=${2:?}
  _kp_herdr pane read "$target" --source recent-unwrapped --lines "$lines"
}

# _kp_herdr_send_text <target> <text>
_kp_herdr_send_text() {
  local target=${1:?}
  [ $# -ge 2 ] || return 2
  _kp_herdr pane send-text "$target" "$2"
}

# _kp_herdr_send_enter <target>
_kp_herdr_send_enter() {
  local target=${1:?}
  _kp_herdr pane send-keys "$target" enter
}

# _kp_herdr_activity <target>
# Print an opaque token that changes when the pane's output changes. `revision`
# does not move with output in 0.9.3, so the token is a checksum of the recent
# text; `pane read` prints text, and this never tries to parse it as JSON.
_kp_herdr_activity() {
  local target=${1:?} text
  text=$(_kp_herdr pane read "$target" --source recent-unwrapped --lines 200 2>/dev/null) || return 1
  printf '%s\n' "$text" | cksum | awk '{ print $1 "-" $2 }'
}

# _kp_herdr_activity_age <task-dir>
# Print the seconds the pane has been silent, as far as this reader can tell: the
# token file `<task-dir>/mux.activity` holds `<epoch> <token>`; a changed token
# rewrites it and reports 0, an unchanged one reports `now - epoch`.
_kp_herdr_activity_age() {
  local task_dir=${1:-} token now epoch saved rest
  [ -n "$task_dir" ] || return 1
  task_dir=${task_dir%/}
  [ -n "${KP_WINDOW_ID:-}" ] || _kp_herdr_find "$task_dir" >/dev/null 2>&1 || return 1
  token=$(_kp_herdr_activity "$KP_WINDOW_ID") || return 1
  now=$(date +%s)
  epoch=''
  saved=''
  if [ -f "$task_dir/mux.activity" ]; then
    read -r epoch saved rest < "$task_dir/mux.activity" || true
  fi
  case ${epoch:-} in
    ''|*[!0-9]*) epoch='' ;;
  esac
  if [ -z "$epoch" ] || [ "$saved" != "$token" ]; then
    printf '%s %s\n' "$now" "$token" > "$task_dir/mux.activity" 2>/dev/null || true
    printf '0\n'
    return 0
  fi
  printf '%s\n' $((now - epoch))
}

# _kp_herdr_foreground_command <target>
# Print the foreground command word: the basename of `foreground_processes[0].argv[0]`
# (the `name` field reports the interpreter, `sleep` for a wrapper script). Nothing
# when the pane has no foreground process.
_kp_herdr_foreground_command() {
  local target=${1:?} info
  info=$(_kp_herdr pane process-info --pane "$target" 2>/dev/null) || return 1
  printf '%s\n' "$info" | _kp_herdr_json \
    '((p) => { const f = p && p.foreground_processes && p.foreground_processes[0]; if (!f) return ""; const argv = f.argv && f.argv.length ? String(f.argv[0]) : ""; return argv ? argv.split("/").pop() : String(f.name || ""); })(v.result.process_info)'
}

# _kp_herdr_rename <target> <name>
_kp_herdr_rename() {
  _kp_herdr pane rename "${1:?}" "${2:?}" >/dev/null
}

# _kp_herdr_kill <target>
_kp_herdr_kill() {
  _kp_herdr pane close "${1:?}" >/dev/null
}

# _kp_herdr_reachable
# Exit 0 when the session answers `api snapshot`, which is the named-session
# liveness probe (herdr's own `status server` reads the default session only).
_kp_herdr_reachable() {
  _kp_herdr api snapshot >/dev/null 2>&1
}

# _kp_herdr_ensure_session <session>
# Exit 0 when the session is running; otherwise print both ways to start it and
# exit 1. `herdr server` is a foreground process, so starting and supervising it
# is the operator's call (issue #165), not a spawn's side effect.
_kp_herdr_ensure_session() {
  local session=${1:?}
  _kp_herdr_at "$session" api snapshot >/dev/null 2>&1 && return 0
  printf "herdr session '%s' is not running; start it with: herdr --session %s server\n" \
    "$session" "$session" >&2
  return 1
}

# _kp_herdr_create <task-dir> <session> <name> <cwd> <launch> [--fresh]
# Refused in this change: a Herdr worker cannot be created until Herdr worker
# creation lands with issue #204. `kingpin list`, `kingpin wait` and `kingpin brief`
# already read a Herdr record, so the readers are no longer the blocker.
_kp_herdr_create() {
  printf 'herdr: creating a terminal for a task is not wired up yet (issue #144 phase E); run with KINGPIN_MUX=tmux\n' >&2
  return 1
}
