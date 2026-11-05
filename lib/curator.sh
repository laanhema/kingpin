# shellcheck shell=bash
# Shared gate for the automatic skill curator (issue #88). Sourced by
# bin/kingpin-curate, bin/kingpin-watch and bin/kingpin-done; it only defines
# functions (no `set` options, no output unless stated, every function returns 0
# unless stated).
#
#   # shellcheck source=../lib/curator.sh
#   . "$KP_BIN/../lib/curator.sh"
#
# The trigger rides the fleet's existing idle moments (the supervisor's sweep and
# the last `kingpin done`) instead of a daemon or a timer. It reads local files
# only, never waits for the curator mutex (`kp_mutex_try`), and never fails its
# caller: the fleet must not miss a landing because a critique day is due.
#
# A critique is pending while its task has a non-empty `critique` that does not
# match its `critique.consumed` stamp byte for byte. `kingpin curate` archives an
# applied critique as `critique.applied.<epoch>` and, when it was applied through
# a PR, writes the URL beside it as `critique.applied.<epoch>.pr`.
#
# The day stamp is $KP_HOME/curator/last-run: line 1 the epoch, line 2 the local
# calendar day. It is written once the window exists, so a launch that failed
# before the window is retried on the next tick, and one that failed after it
# consumes the day.

# shellcheck source=status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"
# shellcheck source=landing.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/landing.sh"
# shellcheck source=mutex.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mutex.sh"
# shellcheck source=tmux.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmux.sh"
# shellcheck source=mux.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mux.sh"

# kp_curate_pending_task <task-dir>
# Exit 0 when the task still has an unapplied critique: the file is non-empty and
# is not byte-identical to its `critique.consumed` snapshot. A rewritten critique
# no longer matches, so it is collected again.
kp_curate_pending_task() {
  local task_dir=${1:-} crit_file stamp_file
  [ -n "$task_dir" ] || return 1
  crit_file="$task_dir/critique"
  [ -f "$crit_file" ] && [ -s "$crit_file" ] || return 1
  stamp_file="$task_dir/critique.consumed"
  if [ -f "$stamp_file" ] && cmp -s "$stamp_file" "$crit_file"; then
    return 1
  fi
  return 0
}

# kp_curate_pending_count <kp-home>
# Prints how many task ids have an unapplied critique. Scans tasks/ then archive/
# and counts each id once, so the symlink `kingpin done` leaves at tasks/<id> and
# the archive it points at are not two tasks.
kp_curate_pending_count() {
  local home=${1:?} search_dir task_dir task_id seen_tasks="" n=0
  for search_dir in "$home/tasks" "$home/archive"; do
    [ -d "$search_dir" ] || continue
    for task_dir in "$search_dir"/*; do
      [ -d "$task_dir" ] || continue
      task_id=$(basename "$task_dir")
      case " $seen_tasks " in
        *" $task_id "*) continue ;;
      esac
      kp_curate_pending_task "$task_dir" || continue
      seen_tasks="$seen_tasks $task_id"
      n=$((n + 1))
    done
  done
  printf '%s\n' "$n"
}

# kp_curate_in_flight_task <kp-home>
# Prints the fleet's first task record whose work is not over, as two lines: its
# id and its last worker status line (or `none`), and exits 0. Prints nothing and
# exits 1 when every live record is finished. An archived record's dossier link
# is not a record, a record carrying `done_cleaned` or a last line of
# `merged:`/`failed:` is finished, and everything else, `cleanup-refused:`
# included, is still in flight.
kp_curate_in_flight_task() {
  local home=${1:?} dir id last
  for dir in "$home"/tasks/*; do
    kp_task_is_live "$dir" || continue
    kp_task_is_finished "$dir" && continue
    id=$(basename "$dir")
    last=$(kp_status_last "$dir/status")
    printf '%s\n%s\n' "$id" "${last:-none}"
    return 0
  done
  return 1
}

# kp_curate_idle <kp-home>
# Exit 0 only when the fleet is idle: every live task record under tasks/ is
# finished (it carries `done_cleaned` or its last worker status line is `merged:`
# or `failed:`; a `cleanup-refused:` record is still in flight, because
# kingpin-watch retries it), every projects/*.landing_queue is empty, and every
# project's landing holder is no longer live. A landing in flight is never
# touched by the trigger.
kp_curate_idle() {
  local home=${1:?} q lock project holder
  if kp_curate_in_flight_task "$home" >/dev/null; then
    return 1
  fi
  for q in "$home"/projects/*.landing_queue; do
    [ -f "$q" ] || continue
    [ -s "$q" ] && return 1
  done
  for lock in "$home"/projects/*.landing; do
    [ -f "$lock" ] || continue
    project=$(basename "$lock" .landing)
    holder=$(kp_landing_holder "$home" "$project")
    kp_landing_holder_live "$home" "$holder" && return 1
  done
  return 0
}

# kp_curate_due <kp-home>
# Exit 0 when no curator run has been stamped today: the stamp is missing, or its
# second line is not today's local calendar day.
kp_curate_due() {
  local home=${1:?} stamp last
  stamp="$home/curator/last-run"
  [ -f "$stamp" ] || return 0
  last=$(sed -n 2p "$stamp" 2>/dev/null || true)
  [ "$last" != "$(date +%F)" ]
}

# kp_curate_stamp <kp-home>
# Claim today: write the epoch and the local calendar day, two lines, through a
# temp file and `mv`, so a reader never sees half a line.
kp_curate_stamp() {
  local home=${1:?} dir tmp
  dir="$home/curator"
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/last-run.XXXXXX") || return 1
  if printf '%s\n%s\n' "$(date +%s)" "$(date +%F)" > "$tmp"; then
    mv -f "$tmp" "$dir/last-run"
  else
    rm -f "$tmp"
    return 1
  fi
}

# kp_curate_window_label <kp-home>
# Prints the `<session>:curator` window the curator probe names, read-only: the
# `MUX_TARGET` the record holds, or, with no record yet, the configured
# `TMUX_SESSION` (issue #191) or `<kingpin>:curator`. A caller prints it in a skip
# or refusal message before the launch target is resolved, so the probe and the
# message name the same window without starting a server.
kp_curate_window_label() {
  local home=${1:?} env_file target configured=''
  env_file="$home/tasks/curator/task.env"
  if [ -f "$env_file" ]; then
    target=$(kp_env_get "$env_file" MUX_TARGET)
    printf '%s\n' "${target:-kingpin:curator}"
    return 0
  fi
  [ -f "$home/config.env" ] && configured=$(kp_env_get "$home/config.env" TMUX_SESSION)
  printf '%s\n' "${configured:-kingpin}:curator"
}

# kp_curate_window_state <kp-home>
# Prints alive, dead, none or unknown for the curator terminal. The mux and the
# target come from the curator record (`tasks/curator/task.env`), like every other
# terminal reader, so a record written under another KINGPIN_TMUX_SOCKET, or before
# the fleet had its own server (no TMUX_SOCKET, so the default server), is probed
# where its terminal actually lives; a Herdr record is probed by the pane id it
# names. A record that names a mux this reader cannot read prints `unknown`: the
# selection rule refuses an unknown mux by name, so guessing tmux here would probe
# the wrong backend. With no record yet, the current environment's mux and socket
# are the ones the launch will use. A tmux window whose only panes have exited is
# dead, not a curator: on a host with tmux's remain-on-exit set, a failed launch
# leaves that pane behind and treating it as live would block every later run. A
# Herdr pane is alive or gone, never dead.
kp_curate_window_state() {
  local home=${1:?} env_file mux sock target session state
  env_file="$home/tasks/curator/task.env"
  target=$(kp_curate_window_label "$home")
  sock=''
  session=''
  if [ -f "$env_file" ]; then
    mux=$(kp_mux_record "$home/tasks/curator" 2>/dev/null) || mux=unknown
    sock=$(kp_tmux_socket_from_env "$env_file")
    session=$(kp_env_get "$env_file" MUX_SESSION)
  else
    mux=$(kp_mux_name 2>/dev/null) || mux=unknown
    # No record yet: name the server the launch will use, without starting anything
    # (the fallback session is the launch's to create). A caller's own tmux client is
    # not consulted, because this gate must stay read-only.
    sock=$(kp_tmux_socket_for "$home")
  fi
  # The mux is published before the session fallback reads it, so a Herdr record
  # without MUX_SESSION resolves the Herdr session, not the tmux socket. An
  # unreadable mux publishes nothing, so no later verb inherits a bad backend.
  case $mux in
    herdr)
      KP_MUX=$mux
      [ -n "$session" ] || session=$(kp_mux_session_name)
      ;;
    tmux)
      KP_MUX=$mux
      [ -n "$session" ] || session=$sock
      # `kingpin:curator` is a session prefix, so a `kingpin-workers` session beside
      # `kingpin` answers for it and this probe would read, reap or refuse another
      # session's window (issues #149, #181). Both halves are pinned to an exact
      # match; a target with no colon (a window id) is left alone.
      case $target in
        *:*) target="=${target%%:*}:=${target#*:}" ;;
      esac
      ;;
    *)
      printf 'unknown\n'
      return 0
      ;;
  esac
  KP_WINDOW_SOCKET=$sock
  KP_MUX_SESSION=$session
  state=$(kp_mux_target_state "$target")
  case $state in
    alive|dead|none) printf '%s\n' "$state" ;;
    *) printf 'none\n' ;;
  esac
}

# kp_curate_critique_for_task <kp-home> <task-id>
# Prints the critique path of a task, whatever `kingpin done` did to it while the
# curator ran: still live, archived, or archived as <id>.<n> on a name collision.
# Exit 1 when no record holds a critique.
kp_curate_critique_for_task() {
  local home=${1:?} id=${2:?} dir
  for dir in "$home/tasks/$id" "$home/archive/$id"; do
    if [ -f "$dir/critique" ]; then
      printf '%s\n' "$dir/critique"
      return 0
    fi
  done
  for dir in "$home/archive/$id".*; do
    if [ -f "$dir/critique" ]; then
      printf '%s\n' "$dir/critique"
      return 0
    fi
  done
  return 1
}

# kp_curate_mark_applied <kp-home> <pr-url>
# Consume the batch that was published for the run: for every critique the curator
# was given, stamp `critique.consumed` with the collected snapshot, rename the
# critique to `critique.applied.<epoch>`, and write the PR URL beside it as
# `critique.applied.<epoch>.pr`. A critique rewritten while the curator ran is
# left pending. Prints `OK: marked <n> critique(s) applied in <url>`; exit 1 when
# the published batch or its collected snapshots are missing.
kp_curate_mark_applied() {
  local home=${1:?} url=${2:-} curator_dir collected_dir crit_file task_id target snapshot
  local stamp epoch applied_path applied=0
  curator_dir="$home/curator"
  [ -f "$curator_dir/batch-critiques.txt" ] || return 1
  [ -d "$curator_dir/collected" ] || return 1
  collected_dir="$curator_dir/collected"
  while IFS= read -r crit_file; do
    [ -n "$crit_file" ] || continue
    task_id=$(basename "$(dirname "$crit_file")")
    target=$(kp_curate_critique_for_task "$home" "$task_id") || continue
    # The stamp is a copy of the bytes the curator was given, not of the file at
    # completion, so a critique rewritten during the run is not marked consumed.
    snapshot="$collected_dir/$task_id"
    if [ ! -f "$snapshot" ]; then
      echo "kingpin-curate: no collected copy for $task_id; leaving its critique pending" >&2
      continue
    fi
    if ! cmp -s "$snapshot" "$target"; then
      echo "kingpin-curate: critique for $task_id changed while the curator ran; leaving it pending" >&2
      continue
    fi
    # The stamp is written first: a process killed between the stamp and the
    # rename still leaves the critique consumed on the next run.
    stamp="$target.consumed"
    if cp -f "$snapshot" "$stamp.tmp.$$" && mv -f "$stamp.tmp.$$" "$stamp"; then
      epoch=$(date +%s)
      applied_path="$target.applied.$epoch"
      mv -f "$target" "$applied_path"
      if [ -n "$url" ]; then
        printf '%s\n' "$url" > "$applied_path.pr"
      fi
      applied=$((applied + 1))
    fi
  done < "$curator_dir/batch-critiques.txt"
  printf 'OK: marked %s critique(s) applied in %s\n' "$applied" "${url:-no PR}"
}

# kp_curate_maybe <kp-home> <kp-bin>
# Give the auto trigger one chance and always return 0. The caller is a hot fleet
# path (a supervisor sweep, the last `kingpin done`), so nothing here may fail it:
# KINGPIN_CURATOR_AUTO=0 disables the trigger (the suites set it), and `--auto`
# itself exits 0 on every path, including a missing skills checkout.
kp_curate_maybe() {
  local home=${1:?} bin=${2:?}
  if [ "${KINGPIN_CURATOR_AUTO:-1}" = "0" ]; then
    return 0
  fi
  "$bin/kingpin-curate" --auto || true
  return 0
}
