# shellcheck shell=bash
# The checks of a merged task's pull request: read once, recorded in the task record,
# and named by the two commands that act on a `merged:` line (issue #221).
#
# Source it after lib/status.sh, whose readers and note writer it calls; it only
# defines functions (no `set` options, every function returns 0 unless stated).
#
#   # shellcheck source=../lib/checks.sh
#   . "$KP_BIN/../lib/checks.sh"
#
# A worker that merges on a red or unfinished check rollup used to archive as a clean
# task. `kp_checks_ensure` reads the rollup of the `pr=` URL on the worker's `merged:`
# line through `gh`, classifies it with lib/pr-checks.mjs and keeps the result in
# `<task>/checks.result`, which moves with the record into the archive. The file is
# also the guard: a task is read once, whoever asks first (the supervisor's `merged:`
# dispatch or `kingpin done`), so the two cannot disagree. A FAILED or PENDING result
# appends one `checks: pr=<url> checks=<RESULT>` note through `kp_status_note`. The
# note is not a worker event (`kp_status_last` skips it like approved: and
# feedback:), so `merged:` stays the last event and the task stays finished.
#
# The result file has three lines:
#   1  PASSED, FAILED, PENDING or UNREADABLE
#   2  the pull request URL
#   3  the names of the failing checks (FAILED) or the reason (UNREADABLE), one line
# UNREADABLE (no gh, no node, a gh failure) is recorded and never writes a note, and
# no caller holds a cleanup for it.

KP_CHECKS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# kp_checks_oneline <text>
# The first line of the text, whitespace squeezed, cut to 200 characters.
kp_checks_oneline() {
  local text=${1:-}
  text=${text%%$'\n'*}
  text=$(printf '%s' "$text" | tr '\t\r' '  ' | tr -s ' ')
  printf '%s\n' "${text:0:200}"
}

# kp_checks_write <task-dir> <word> <url> <detail>
# Write the result file through a temp file and mv, so a concurrent reader never
# sees half of it. A failure to write is not an error: the next read just repeats.
kp_checks_write() {
  local dir=${1:?} word=${2:?} url=${3:-} detail=${4:-} tmp
  tmp=$(mktemp "$dir/checks.result.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n%s\n%s\n' "$word" "$url" "$(kp_checks_oneline "$detail")" > "$tmp" 2>/dev/null \
     && mv "$tmp" "$dir/checks.result" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 0
}

# kp_checks_result <task-dir>
# The recorded result word (PASSED, FAILED, PENDING or UNREADABLE), or nothing when
# the task was never read.
kp_checks_result() {
  local dir=${1:-}
  [ -n "$dir" ] && [ -f "$dir/checks.result" ] || return 0
  sed -n 1p "$dir/checks.result" 2>/dev/null || true
}

# kp_checks_describe <task-dir>
# The one phrase `kingpin done` and the supervisor log share for a recorded result.
# Nothing for PASSED and for a task that was not read.
kp_checks_describe() {
  local dir=${1:-} word url detail
  word=$(kp_checks_result "$dir")
  url=$(sed -n 2p "$dir/checks.result" 2>/dev/null || true)
  detail=$(sed -n 3p "$dir/checks.result" 2>/dev/null || true)
  case "$word" in
    FAILED) printf 'pull request checks FAILED (%s)\n' "$url" ;;
    PENDING) printf 'pull request checks still PENDING at merge (%s)\n' "$url" ;;
    UNREADABLE) printf 'pull request checks not read (%s)\n' "${detail:-no reason recorded}" ;;
  esac
}

# kp_checks_ensure <task-dir> <gh-command> <project-path>
# Read, classify and record the rollup of the pull request on the worker's last
# event, once. Does nothing when the result is already recorded, when the last event
# is not a `merged:` line, and when that line has no usable `pr=` field (a legacy
# line is skipped silently). Always returns 0: a pull request that cannot be read is
# recorded as UNREADABLE with its reason and never fails the caller's cleanup.
kp_checks_ensure() {
  local dir=${1:-} gh=${2:-gh} project=${3:-} last url rollup cls word detail errf reason
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  [ -f "$dir/checks.result" ] && return 0
  last=$(kp_status_last "$dir/status")
  case "$last" in merged:*) ;; *) return 0 ;; esac
  url=$(kp_status_field "$last" pr)
  # The URL becomes a gh argument: only an http(s) URL is ever passed.
  case "$url" in http://*|https://*) ;; *) return 0 ;; esac
  case "$url" in *[[:space:]]*) return 0 ;; esac

  if ! command -v "$gh" >/dev/null 2>&1; then
    kp_checks_write "$dir" UNREADABLE "$url" "$gh is not available"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    kp_checks_write "$dir" UNREADABLE "$url" "node is not available"
    return 0
  fi

  # With no temp file the diagnostics go to /dev/null, which the removals below skip.
  errf=$(mktemp 2>/dev/null) || errf=/dev/null
  if [ -n "$project" ] && [ -d "$project" ]; then
    rollup=$(cd "$project" && "$gh" pr view "$url" --json statusCheckRollup 2>"$errf") || rollup=''
    [ -n "$rollup" ] || reason=$(head -n 1 "$errf" 2>/dev/null || true)
  else
    rollup=$("$gh" pr view "$url" --json statusCheckRollup 2>"$errf") || rollup=''
    [ -n "$rollup" ] || reason=$(head -n 1 "$errf" 2>/dev/null || true)
  fi
  if [ -z "$rollup" ]; then
    [ "$errf" = /dev/null ] || rm -f "$errf"
    kp_checks_write "$dir" UNREADABLE "$url" "gh pr view failed: ${reason:-no output}"
    return 0
  fi
  if ! cls=$(printf '%s' "$rollup" | node "$KP_CHECKS_ROOT/lib/pr-checks.mjs" 2>"$errf"); then
    reason=$(head -n 1 "$errf" 2>/dev/null || true)
    [ "$errf" = /dev/null ] || rm -f "$errf"
    kp_checks_write "$dir" UNREADABLE "$url" "the rollup could not be classified: ${reason:-no output}"
    return 0
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"

  word=$(printf '%s\n' "$cls" | sed -n 1p)
  detail=$(printf '%s\n' "$cls" | sed -n 2p)
  case "$word" in
    PASSED|FAILED|PENDING) ;;
    *) kp_checks_write "$dir" UNREADABLE "$url" "unexpected classifier output: $(kp_checks_oneline "$cls")"; return 0 ;;
  esac
  kp_checks_write "$dir" "$word" "$url" "$detail"
  # Only a recorded result may produce the note, so the file stays the one guard.
  if [ -f "$dir/checks.result" ]; then
    case "$word" in
      FAILED|PENDING)
        kp_status_note "$dir/status" "$dir/stopped" "checks: pr=$url checks=$word"
        ;;
    esac
  fi
  return 0
}
