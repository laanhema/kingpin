# shellcheck shell=bash
# Shared reader for the task protocol files, plus the one writer every note shares.
# Source it; it only defines functions (no `set` options, no output beyond what each
# states, every function returns 0 unless stated).
#
#   # shellcheck source=../lib/status.sh
#   . "$KP_BIN/../lib/status.sh"
#
# The task `status` file is the fleet's state machine. Workers append one event
# per line (ready:, fixed:, needs-input:, merged:, failed:, ...). kingpin-listen
# appends the approved: and feedback: notes, and kingpin-watch appends the
# approved: auto (afk) note; both write through `kp_status_note`, so neither can
# move the Stop hook's turn boundary on its own. They are reminders for the
# orchestrator, not worker events, so the worker's current state is the last line
# that is not one of them.
#
# The `review=` verdict of a ready:/fixed: line is read here too (`kp_status_field`,
# `kp_status_field_count`, `kp_status_verdict`, `kp_verdict_kind`), so the landing
# gate in kingpin-land and the approval gate in kingpin-listen share one parser.
# The one pane decision the outcome writers share (`kp_pane_shows_working`) lives
# here as well, so the per-harness working-marker list exists once. The one command
# builder the fleet sends share (`kp_skill_command`) lives here for the same reason:
# spawn and land must ask a harness for the skill name it really expands.
#
# Where a task record lives is decided here too (`kp_task_is_live`,
# `kp_task_archive_dir`): `kingpin done` leaves a symlink at tasks/<id> for the
# archived task, so every reader that globs tasks/* has to tell the two apart.

# kp_status_last <status-file>
# The worker's last event: the last line that is not an approved:/feedback: note.
# Empty for a missing or empty file. Use it to decide what state a task is in.
kp_status_last() {
  [ -f "${1:-}" ] || return 0
  grep -vE '^(approved|feedback):' "$1" 2>/dev/null | tail -n 1 || true
}

# kp_status_newest <status-file>
# The newest line of any kind, notes included. Only for a caller that reports or
# acts on the newest line itself (kingpin list, kingpin-stop).
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

# kp_status_note <status-file> <stopped-file> <line>
# Append a note that is not the worker's report (an approved:/feedback: line)
# without moving the Stop hook's turn boundary. kingpin-stop treats a status file
# newer than the `stopped` marker as written during this turn (bin/kingpin-stop:82-90),
# so a note must leave that boundary as it found it when the worker already
# reported, and move it when the note arrived instead of a report. Otherwise the
# next silent turn looks reported and never gets its `failed: no status:` line.
# kingpin-listen and kingpin-watch must write every note through this one helper,
# or the two disagree about the boundary again.
#
#   before the note  the worker reported  -> keep the boundary (the report owns it)
#   before the note  no report            -> touch `stopped` after the append
#   no `stopped` file                     -> first turn: nothing to move
#
# The mtime is the whole point; kingpin-wait, kingpin-launch-check and kingpin-ack
# read the file's contents, which the note does not touch.
kp_status_note() {
  local status_file=${1:?} stopped_file=${2:?} line=${3:-} reported=0
  if [ -f "$stopped_file" ] && [ "$status_file" -nt "$stopped_file" ]; then
    reported=1
  fi
  printf '%s\n' "$line" >> "$status_file"
  if [ "$reported" -eq 0 ] && [ -f "$stopped_file" ]; then
    touch "$stopped_file" 2>/dev/null \
      || echo "kp_status_note: cannot move the stop boundary $stopped_file" >&2
  fi
}

# kp_status_is_terminal <status-line>
# Exit 0 for a finished task's line (merged:, failed:, cleanup-refused:), else 1.
kp_status_is_terminal() {
  case "${1:-}" in
    merged:*|failed:*|cleanup-refused:*) return 0 ;;
    *) return 1 ;;
  esac
}

# kp_status_is_waiting <status-line>
# Exit 0 when the line means the worker is blocked on a human: its own needs-input:,
# the listener's feedback: note, or the Stop hook's waiting: line. `kingpin list`
# marks such a task WAITING, and kingpin-wait holds a repeated quiet for it.
kp_status_is_waiting() {
  case "${1:-}" in
    needs-input:*|feedback:*|waiting:*) return 0 ;;
    *) return 1 ;;
  esac
}

# kp_status_is_silent <status-line>
# Exit 0 for the line the Stop hook (kingpin-stop) and kingpin-launch-check write
# when a worker stopped without reporting. `kingpin list` marks a live task SILENT.
# Both writers share the "failed: no status:" prefix.
kp_status_is_silent() {
  case "${1:-}" in
    "failed: no status:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# kp_status_field <status-line> <key>
# The value of one key= field of a status line, whatever its position: everything
# up to the next "<word>=" field or the end of the line, trimmed. Empty when the
# line has no such field, and also when it repeats the field: two values for one
# key are ambiguous, so the gate must not trust either. Used for the ready:/fixed:
# fields review=, report= and high=.
kp_status_field() {
  local line=${1:-} key=${2:-} out="" seen=0 w
  [ -n "$key" ] || return 0
  [ "$(kp_status_field_count "$line" "$key")" -le 1 ] || return 0
  local -a words=()
  read -ra words <<< "$line"
  for w in ${words[@]+"${words[@]}"}; do
    if [ "$seen" -eq 0 ]; then
      case $w in
        "$key="*) out=${w#"$key="}; seen=1 ;;
      esac
    else
      case $w in
        # The next field ends the value, so a reordered line parses the same.
        [A-Za-z_][A-Za-z0-9_]*=*) break ;;
        *) out="$out $w" ;;
      esac
    fi
  done
  printf '%s\n' "$out"
}

# kp_status_field_count <status-line> <key>
# How many key= fields the status line carries (always prints a number). Lets a
# caller tell an absent field from an empty one and from a repeated one, which
# decide different refusal messages in kingpin-land.
kp_status_field_count() {
  local line=${1:-} key=${2:-} n=0 w
  [ -n "$key" ] || { printf '0\n'; return 0; }
  local -a words=()
  read -ra words <<< "$line"
  for w in ${words[@]+"${words[@]}"}; do
    case $w in
      "$key="*) n=$((n + 1)) ;;
    esac
  done
  printf '%s\n' "$n"
}

# kp_status_verdict <status-line>
# The review verdict of a ready:/fixed: line, normalized for the landing gate:
# upper case, "-" and "_" read as spaces, a trailing "(...)" note dropped, runs of
# spaces squeezed. Empty when the line carries no review= field.
#   review=needs_changes (2 high)  ->  NEEDS CHANGES
kp_status_verdict() {
  local v
  v=$(kp_status_field "${1:-}" review)
  [ -n "$v" ] || return 0
  printf '%s\n' "$v" \
    | tr '[:lower:]' '[:upper:]' \
    | tr '_-' '  ' \
    | sed -E 's/[[:space:]]*\([^()]*\)[[:space:]]*$//' \
    | tr -s '[:space:]' ' ' \
    | sed -e 's/^ //' -e 's/ $//'
}

# kp_verdict_kind <verdict>
# What the landing gate does with a verdict: "clean" (APPROVE, land),
# "findings" (APPROVE WITH NITS, NEEDS CHANGES: run /fix-findings first) or
# "unknown" (anything else, including an empty verdict: never land).
kp_verdict_kind() {
  case "${1:-}" in
    APPROVE) printf 'clean\n' ;;
    "APPROVE WITH NITS"|"NEEDS CHANGES") printf 'findings\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# kp_env_get <env-file> <KEY>
# The value of the last KEY=value line, or nothing. Same "last assignment wins" as
# sourcing the file; the file is never sourced, so its values are not executed.
kp_env_get() {
  [ -f "${1:-}" ] || return 0
  sed -n "s/^${2:?}=//p" "$1" 2>/dev/null | tail -n 1 || true
}

# kp_skill_command <harness> <skill> [args...]
# The wire command that fires one skill on a harness: `/<skill>` for claude, agy and
# opencode, `/skill:<skill>` for pi, whose command list exposes skills only under that
# prefix (spike.md, Check 3: a plain `/review` reaches the model as ordinary text).
# kingpin-spawn's prompt and kingpin-land's sends go through this helper, so a fleet
# send always names a command the worker's harness really expands. An empty harness
# reads as claude (older task.env files), and an unknown one prints the plain form and
# returns 0: callers validate harness names, and a send must not silently vanish.
kp_skill_command() {
  local harness=${1:-} skill=${2:-}
  [ $# -ge 2 ] || return 0
  shift 2
  case "$harness" in
    pi) printf '/skill:%s' "$skill" ;;
    *) printf '/%s' "$skill" ;;
  esac
  local arg
  for arg in "$@"; do printf ' %s' "$arg"; done
  printf '\n'
}

# kp_pane_shows_working <pane-tail> <harness>
# Exit 0 when a capture of the worker's pane still shows the harness's working
# marker: a background agent, or a turn that has not finished. The three callers
# that must not call a working worker idle or failed (kingpin-stop's hook,
# kingpin-wait's `quiet` check, kingpin-launch-check) share this one list, so a
# marker added for one harness cannot drift out of step between them. The list
# covers all four harnesses (claude, agy, opencode, pi). The pane is captured by
# the caller; an unknown harness shows nothing (exit 1).
kp_pane_shows_working() {
  local pane_tail=${1:-} harness=${2:-claude} bottom=""
  case "$harness" in
    claude)
      printf '%s\n' "$pane_tail" | grep -qE 'Waiting for [0-9]+ background agent|Background agent|/tasks to see subagents'
      ;;
    agy)
      # This marker sits in the bottom rows of the pane, not in its scrollback.
      bottom=$(printf '%s\n' "$pane_tail" | grep -v '^[[:space:]]*$' | tail -12 || true)
      printf '%s\n' "$bottom" | grep -qiE 'esc[[:space:]]+to[[:space:]]+cancel'
      ;;
    opencode)
      bottom=$(printf '%s\n' "$pane_tail" | grep -v '^[[:space:]]*$' | tail -12 || true)
      printf '%s\n' "$bottom" | grep -qiE 'esc[[:space:]]+to[[:space:]]+cancel|Interrupt'
      ;;
    pi)
      # Measured on Pi 1.5.0 (spike.md, Check 4): the rule sits directly above the
      # model footer and reads "── ⠏ Working ───...". Match the box rule and the
      # word, not the braille spinner, which changes per frame; re-measure the line
      # on a Pi version bump rather than widening this pattern.
      bottom=$(printf '%s\n' "$pane_tail" | grep -v '^[[:space:]]*$' | tail -12 || true)
      printf '%s\n' "$bottom" | grep -qE '──.*Working'
      ;;
    *) return 1 ;;
  esac
}

# kp_task_is_live <task-dir>
# Exit 0 when the path is a live task record: a real directory, not the symlink
# `kingpin done` leaves at tasks/<id> once it archives the task. Every reader that
# globs tasks/* calls this, so a finished task is never listed, waited on, landed
# or cleaned a second time through its dossier link.
kp_task_is_live() {
  local dir=${1:-}
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ]
}

# kp_task_archive_dir <kp-home> <id>
# Prints the archived record of a finished task and exits 0; prints nothing and
# exits 1 while the task is live or unknown. The two shapes `kingpin done` leaves
# behind are its symlink at tasks/<id> and, for a fleet cleaned up before that
# link existed, no live directory with archive/<id> in its place.
kp_task_archive_dir() {
  local home=${1:-} id=${2:-} dir resolved
  [ -n "$home" ] && [ -n "$id" ] || return 1
  dir="$home/tasks/$id"
  if [ -L "$dir" ]; then
    if [ -d "$dir" ] && resolved=$(cd "$dir" && pwd -P); then
      printf '%s\n' "$resolved"
    else
      # A dangling link (the archive went away by hand) still names the record
      # the caller has to talk about.
      printf '%s\n' "$home/archive/$id"
    fi
    return 0
  fi
  if [ ! -d "$dir" ] && [ -d "$home/archive/$id" ]; then
    printf '%s\n' "$home/archive/$id"
    return 0
  fi
  return 1
}
