# shellcheck shell=bash
# The retired-dossier contract (issue #186): how a task's review dossier stops
# looking live once the task is finished.
#
# Source it after lib/status.sh, whose readers it calls; it only defines functions and
# one marker constant.
#
#   # shellcheck source=../lib/dossier.sh
#   . "$KP_BIN/../lib/dossier.sh"
#
# A finished task's page must not keep offering Approve and Request Changes, and the
# Lavish session a reviewer left open on it must not stay open forever. `bin/kingpin-done`
# marks the page of the task it archives, `bin/kingpin-watch` sweeps the records that
# finished without that step (an older archive, a `failed:` task, a cleanup that was
# refused), and `bin/kingpin list` names the ones still open. The marker below is the
# one string all three agree on: it is written by lib/dossier-finish.mjs into the page,
# and its presence is what makes a second mark a no-op.

KP_DOSSIER_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KP_DOSSIER_FINISHED_MARKER='<!-- kingpin:finished -->'

# kp_dossier_marked <page>
# Exit 0 when the page already carries the finished banner, 1 otherwise.
kp_dossier_marked() {
  local page=${1:-}
  [ -n "$page" ] && grep -qF "$KP_DOSSIER_FINISHED_MARKER" "$page" 2>/dev/null
}

# kp_dossier_file <record-dir>
# Print the page file a record owns, and exit 0; print nothing and exit 1 when the
# record has no report.html. The record's own copy is read and written, never the
# dossier link, so an archive is marked even when the link is missing.
kp_dossier_file() {
  local dir=${1:-}
  [ -n "$dir" ] && [ -f "$dir/report.html" ] || return 1
  printf '%s\n' "$dir/report.html"
}

# kp_dossier_session_path <kp-home> <record-dir>
# Print the path the Lavish session was opened on. `kingpin-listen` opens
# tasks/<id>/report.html, and `kingpin done` leaves that path as a link to the archive,
# so a session outlives the archive under the same name. An archived record with no
# link (a hand move) falls back to its own path.
kp_dossier_session_path() {
  local home=${1:-} dir=${2:-} id link
  [ -n "$home" ] && [ -n "$dir" ] || return 1
  id=$(basename "$dir")
  link="$home/tasks/$id"
  if [ -L "$link" ] && [ -f "$link/report.html" ]; then
    printf '%s\n' "$link/report.html"
  else
    printf '%s\n' "$dir/report.html"
  fi
}

# kp_dossier_mark <record-dir> <task-id> [state]
# Mark the record's page finished through lib/dossier-finish.mjs and print the line the
# helper printed. <state> is merged, failed or finished (the default); without it the
# state is read from the record's last worker event. Exit 1 when the page cannot be
# written, with the helper's reason on stderr; exit 2 for a missing record.
kp_dossier_mark() {
  local dir=${1:-} id=${2:-} state=${3:-} page last pr
  [ -n "$dir" ] && [ -n "$id" ] || return 2
  page=$(kp_dossier_file "$dir") || return 1
  if [ -z "$state" ]; then
    last=$(kp_status_last "$dir/status")
    case "$last" in
      merged:*) state=merged ;;
      failed:*) state=failed ;;
      *) state=finished ;;
    esac
  fi
  pr=''
  if [ "$state" = merged ]; then
    pr=$(kp_status_field "$(kp_status_last "$dir/status")" pr)
  fi
  set -- --state "$state" --task "$id"
  [ -z "$pr" ] || set -- "$@" --pr "$pr"
  node "$KP_DOSSIER_ROOT/lib/dossier-finish.mjs" "$page" "$@"
}

# kp_dossier_end <kp-home> <record-dir>
# End the Lavish session open on a task's dossier, once, and record it with a
# `dossier.ended` marker in the record. Nothing is called for a record that recorded no
# `dossier.url` (no session was ever opened) or one already ended, and nothing when the
# Lavish command is not installed. Prints one line when it ended a session, nothing when
# there was nothing to do. Exit 0 on success or nothing to do, 1 when the command failed,
# so the caller can retry the next sweep.
kp_dossier_end() {
  local home=${1:-} dir=${2:-} cmd page
  [ -n "$home" ] && [ -n "$dir" ] || return 2
  [ -s "$dir/dossier.url" ] || return 0
  [ -f "$dir/dossier.ended" ] && return 0
  cmd=${KINGPIN_LAVISH:-lavish-axi}
  command -v "$cmd" >/dev/null 2>&1 || return 0
  page=$(kp_dossier_session_path "$home" "$dir") || return 1
  "$cmd" end "$page" >/dev/null 2>&1 || return 1
  printf 'ended the leftover dossier session\n' > "$dir/dossier.ended"
  printf 'ended the leftover dossier session\n'
}

# kp_dossier_open <kp-home> <record-dir>
# Exit 0 when a finished record still has an open dossier the sweep can close: it
# recorded a session URL, its page exists, and it has no `dossier.ended` marker. Only a
# finished record is asked; a live task's dossier is `kingpin list`'s review line, not a
# leftover. A record with no page is not named either, because the sweep skips it and
# the session it would have to end cannot be resolved (issue #186 review L2).
kp_dossier_open() {
  local dir=${2:-}
  kp_task_is_finished "$dir" || return 1
  [ -s "$dir/dossier.url" ] || return 1
  kp_dossier_file "$dir" >/dev/null || return 1
  [ ! -f "$dir/dossier.ended" ]
}
