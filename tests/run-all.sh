#!/usr/bin/env bash
# One command for the lint and every suite: takes one snapshot of the checkout (tracked and
# unignored files, plus a throwaway `git init` commit so the lint's `git ls-files` checks work),
# gives the lint and each tests/test-*.sh a private copy of it and a private TMPDIR, and runs a
# bounded number of them in parallel.
#
# It prints one line per job as the job ends (PASS, FAIL or TIMEOUT), then the full log of each
# failing job, then a last line: `run-all: ALL <n> JOBS PASSED` (exit 0) or
# `run-all: <m> of <n> FAILED: <labels>` (exit 1). A usage error exits 2.
#
# Guarantees: nothing is written to the invoking checkout, because every job runs in its own
# copy (so a suite that rewrites a tracked file cannot clash with another job), and two
# invocations at once share no path, because the whole run lives under one fresh
# ${TMPDIR:-/tmp}/ra.XXXXXX directory that an exit, INT or TERM removes. Each job
# runs with TMUX, TMUX_PANE and every KINGPIN_* variable unset, as in CI.
#
# Usage: tests/run-all.sh [-j N] [--root <dir>] [job ...]
#   -j N          run at most N jobs at once (default: half the cores, at least 1, at most 8)
#   --root <dir>  run that checkout instead of the one this script lives in, which is what
#                 tests/test-run-all.sh uses to drive the real runner against fake suites
#   job           a label to run instead of all: `lint` runs tests/lint.sh, `test-<name>` runs
#                 tests/test-<name>.sh; with none given, every job runs, lint first and the
#                 suites alphabetically
# RUN_ALL_TIMEOUT (seconds, default 900, the CI leg limit) bounds each job when `timeout` exists.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)

die() { echo "run-all: $*" >&2; exit 1; }
usage_die() {
  echo "run-all: $*" >&2
  echo "usage: tests/run-all.sh [-j N] [--root <dir>] [job ...]" >&2
  exit 2
}

jobs_max=
selected=()
while [ $# -gt 0 ]; do
  case $1 in
    -j)
      [ $# -ge 2 ] || usage_die "-j needs a number"
      jobs_max=$2
      shift 2
      ;;
    --root)
      [ $# -ge 2 ] || usage_die "--root needs a directory"
      root=$2
      shift 2
      ;;
    -*)
      usage_die "unknown argument: $1"
      ;;
    *)
      selected+=("$1")
      shift
      ;;
  esac
done

if [ -z "$jobs_max" ]; then
  cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  case $cores in '' | *[!0-9]*) cores=2 ;; esac
  jobs_max=$((cores / 2))
  [ "$jobs_max" -ge 1 ] || jobs_max=1
  [ "$jobs_max" -le 8 ] || jobs_max=8
else
  case $jobs_max in
    '' | *[!0-9]*) usage_die "-j needs a positive number, got: '$jobs_max'" ;;
  esac
  [ "$jobs_max" -ge 1 ] || usage_die "-j needs a positive number, got: '$jobs_max'"
fi

root=$(cd "$root" 2>/dev/null && pwd) || usage_die "no such directory: $root"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || usage_die "not a git checkout: $root"

time_limit=${RUN_ALL_TIMEOUT:-900}
case $time_limit in '' | *[!0-9]* | 0) usage_die "RUN_ALL_TIMEOUT must be a positive number of seconds" ;; esac

# The job list: label and script file, lint first and the suites sorted.
labels=()
files=()
if [ -f "$root/tests/lint.sh" ]; then
  labels+=(lint)
  files+=(lint.sh)
fi
suite_files=()
for f in "$root"/tests/test-*.sh; do
  [ -f "$f" ] && suite_files+=("$(basename "$f")")
done
if [ ${#suite_files[@]} -gt 0 ]; then
  while IFS= read -r f; do
    labels+=("${f%.sh}")
    files+=("$f")
  done < <(printf '%s\n' "${suite_files[@]}" | LC_ALL=C sort)
fi
[ ${#labels[@]} -gt 0 ] || usage_die "no tests/lint.sh or tests/test-*.sh under $root"

if [ ${#selected[@]} -gt 0 ]; then
  sel_labels=()
  sel_files=()
  for want in "${selected[@]}"; do
    found=0
    i=0
    while [ "$i" -lt ${#labels[@]} ]; do
      if [ "${labels[$i]}" = "$want" ]; then
        found=1
        sel_labels+=("${labels[$i]}")
        sel_files+=("${files[$i]}")
        break
      fi
      i=$((i + 1))
    done
    [ "$found" = 1 ] || usage_die "unknown job: $want (valid: ${labels[*]})"
  done
  labels=("${sel_labels[@]}")
  files=("${sel_files[@]}")
fi
n=${#labels[@]}

RUN=$(mktemp -d "${TMPDIR:-/tmp}/ra.XXXXXX")
pids=()
state=()

# cleanup: stop the running jobs (TERM first, so each suite's own exit trap kills its tmux
# server), then remove the whole run directory.
# shellcheck disable=SC2329 # invoked through the EXIT trap below
cleanup() {
  trap '' INT TERM
  set +e
  local i=0 alive tries
  while [ "$i" -lt ${#pids[@]} ]; do
    [ "${state[$i]:-}" = 1 ] && kill -TERM "${pids[$i]}" 2>/dev/null
    i=$((i + 1))
  done
  tries=0
  while [ "$tries" -lt 150 ]; do
    alive=0
    i=0
    while [ "$i" -lt ${#pids[@]} ]; do
      if [ "${state[$i]:-}" = 1 ] && kill -0 "${pids[$i]}" 2>/dev/null; then alive=1; fi
      i=$((i + 1))
    done
    [ "$alive" = 0 ] && break
    sleep 0.2
    tries=$((tries + 1))
  done
  i=0
  while [ "$i" -lt ${#pids[@]} ]; do
    [ "${state[$i]:-}" = 1 ] && kill -KILL "${pids[$i]}" 2>/dev/null
    i=$((i + 1))
  done
  rm -rf "$RUN"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$RUN/base" "$RUN/logs" "$RUN/rc"

# The snapshot: tracked and unignored files, skipping a tracked file deleted in the working
# tree (tar would fail on it), then a one-commit repository so `git ls-files` works in a copy.
(
  cd "$root"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi
  done | tar --null -T - -cf - | tar -xf - -C "$RUN/base"
) || die "could not snapshot $root"
(
  cd "$RUN/base"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  git init -q .
  git add -A
  git -c user.name=kingpin-run-all -c user.email=run-all@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m snapshot
) || die "could not commit the snapshot of $root"

# run_job <index> <file>: one job in its own copy, as a background subshell. The paths use the
# job's index, not its label, because a suite builds a tmux socket path under its TMPDIR and
# that path has a hard limit (about 107 characters): the job's TMPDIR is $RUN/<index>. The
# result is a `<rc> <seconds>` line in $RUN/rc/<index>, published last and atomically.
run_job() {
  local idx=$1 file=$2
  local copy=$RUN/c$idx tmp=$RUN/$idx log=$RUN/logs/$idx.log
  local start=$SECONDS rc=0 cpid=
  trap - EXIT
  trap 'kill -TERM "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null; exit 143' TERM INT
  mkdir -p "$tmp"
  if cp -pR "$RUN/base" "$copy"; then
    (
      cd "$copy"
      unset TMUX TMUX_PANE
      for v in $(compgen -v KINGPIN_ || true); do unset "$v"; done
      export TMPDIR=$tmp
      if command -v timeout >/dev/null 2>&1; then
        exec timeout "$time_limit" "./tests/$file" </dev/null >"$log" 2>&1
      fi
      exec "./tests/$file" </dev/null >"$log" 2>&1
    ) &
    cpid=$!
    wait "$cpid" || rc=$?
  else
    echo "run-all: could not copy the snapshot for job $idx" > "$log"
    rc=125
  fi
  rm -rf "$copy" "$tmp"
  echo "$rc $((SECONDS - start))" > "$RUN/rc/$idx.tmp"
  mv "$RUN/rc/$idx.tmp" "$RUN/rc/$idx"
}

echo "run-all: $n jobs, up to $jobs_max at once"

results=()
next=0
running=0
finished=0
while [ "$finished" -lt "$n" ]; do
  i=0
  while [ "$i" -lt "$next" ]; do
    if [ "${state[$i]}" = 1 ] && [ ! -f "$RUN/rc/$i" ] && ! kill -0 "${pids[$i]}" 2>/dev/null; then
      # The job's subshell is gone and published nothing (SIGKILL, the OOM killer, a full disk):
      # look once more, since it may have published between the two tests, then record the death
      # as rc 125 so the loop cannot wait for a result that will never come.
      if [ ! -f "$RUN/rc/$i" ]; then
        echo "run-all: the runner of job $i (${labels[$i]}) died without a result" >> "$RUN/logs/$i.log"
        echo "125 0" > "$RUN/rc/$i.dead"
        mv "$RUN/rc/$i.dead" "$RUN/rc/$i"
      fi
    fi
    if [ "${state[$i]}" = 1 ] && [ -f "$RUN/rc/$i" ]; then
      read -r rc secs < "$RUN/rc/$i"
      wait "${pids[$i]}" 2>/dev/null || true
      state[i]=2
      results[i]=$rc
      running=$((running - 1))
      finished=$((finished + 1))
      if [ "$rc" = 0 ]; then
        echo "PASS ${labels[$i]} (${secs}s)"
      elif [ "$rc" = 124 ]; then
        echo "TIMEOUT ${labels[$i]} (${secs}s)"
      else
        echo "FAIL ${labels[$i]} (rc=$rc, ${secs}s)"
      fi
    fi
    i=$((i + 1))
  done
  while [ "$next" -lt "$n" ] && [ "$running" -lt "$jobs_max" ]; do
    state[next]=1
    run_job "$next" "${files[$next]}" &
    pids[next]=$!
    next=$((next + 1))
    running=$((running + 1))
  done
  [ "$finished" -lt "$n" ] && sleep 0.2
done

failed=()
i=0
while [ "$i" -lt "$n" ]; do
  if [ "${results[$i]}" != 0 ]; then
    failed+=("${labels[$i]}")
    printf '\n==== %s ====\n' "${labels[$i]}"
    cat "$RUN/logs/$i.log"
  fi
  i=$((i + 1))
done

if [ ${#failed[@]} -eq 0 ]; then
  echo "run-all: ALL $n JOBS PASSED"
  exit 0
fi
echo "run-all: ${#failed[@]} of $n FAILED: ${failed[*]}"
exit 1
