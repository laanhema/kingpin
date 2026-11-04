#!/usr/bin/env bash
# Verification test for Kingpin: the linked-worktree checks hold on the git 2.30 that
# README.md promises (issue #86).
#
# Every command in this suite runs behind a git shim that models what a real git 2.30
# does with an option it does not know. Its default `echo` mode is the real behaviour:
# the argument is printed on stdout and dropped, and the rest of the command runs with
# exit 0. Its `reject` mode is the literal case the issue asks for: git's own error and
# exit 129. A helper that feature-detects the option and cannot tell an echoed line from
# a rejection fails here, because an echoed line joins the path it prints.
#
# Set KP_TEST_REAL_GIT to run the suite against another git binary (for example a built
# git 2.30.0); it defaults to the host's git.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "git-compat"
# Keep the host's global git ignore out of the suite: a line there can make an install
# look like it never asked git for the exclude path.
export XDG_CONFIG_HOME=$T/xdg
mkdir -p "$XDG_CONFIG_HOME"
kp_test_project
mkdir -p "$T/proj/sub"

echo "=== Test 1: the git 2.30 shim ==="
real_git=${KP_TEST_REAL_GIT:-$(command -v git)}
[ -x "$real_git" ] || { echo "KP_TEST_REAL_GIT is not an executable git: $real_git" >&2; exit 1; }
export KP_TEST_REAL_GIT=$real_git
# Every argument the shim is asked for is recorded, so a test can prove that a command
# sent the option at all and that the helper never does. `seen_calls` counts them.
export KP_TEST_GIT_SEEN_LOG=$T/git-seen.log
: > "$KP_TEST_GIT_SEEN_LOG"
cat > "$T/bin/git" << 'GITEOF'
#!/usr/bin/env bash
# A git 2.30 shim. In `echo` mode (the real 2.30) each --path-format argument is printed
# on its own stdout line, dropped from the argument list, and the rest is forwarded to
# the real binary; in `reject` mode it prints git's error and exits 129. Both modes
# record the full call in KP_TEST_GIT_SEEN_LOG before answering.
set -uo pipefail
mode=${KP_TEST_GIT_MODE:-echo}
args=()
for arg in "$@"; do
  case $arg in
    --path-format|--path-format=*)
      printf '%s\n' "$*" >> "${KP_TEST_GIT_SEEN_LOG:?}"
      if [ "$mode" = reject ]; then
        echo "error: unknown option 'path-format'" >&2
        exit 129
      fi
      printf '%s\n' "$arg"
      continue
      ;;
  esac
  args+=("$arg")
done
exec "${KP_TEST_REAL_GIT:?}" ${args[@]+"${args[@]}"}
GITEOF
chmod +x "$T/bin/git"
# The shell caches the path it resolved `git` to, so the shim would only reach
# subprocesses until the cache is dropped.
hash -r

export KP_TEST_GIT_MODE=echo
echoed=$(cd "$T/proj" && git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
case $echoed in
  *--path-format=absolute*) pass "the shim echoes --path-format on stdout like real git 2.30" ;;
  *) fail "the shim did not echo --path-format: '$echoed'" ;;
esac
[ "$(printf '%s\n' "$echoed" | tail -n 1)" = ".git" ] \
  && pass "the echoing shim still forwards the rest of the command" \
  || fail "the echoing shim did not forward --git-dir: '$echoed'"
[ "$(command -v git)" = "$T/bin/git" ] && pass "the shim is the git on PATH" || fail "the shim is not first on PATH"

# seen_calls: how many calls the shim answered by removing --path-format.
seen_calls() { wc -l < "$KP_TEST_GIT_SEEN_LOG" | tr -d ' '; }

# check_helper_plain <label> <dir>: kp_git_dir, kp_git_common_dir and kp_git_path must
# return plain paths, with no echoed --path-format line mixed into one.
check_helper_plain() {
  local label=$1 dir=$2 git_dir common_dir exclude_path bad=0
  git_dir=$(kp_git_dir "$dir") || { fail "$label: kp_git_dir failed in $dir"; return; }
  common_dir=$(kp_git_common_dir "$dir") || { fail "$label: kp_git_common_dir failed in $dir"; return; }
  exclude_path=$(kp_git_path "$dir" info/exclude) || { fail "$label: kp_git_path failed in $dir"; return; }
  case "$git_dir$common_dir$exclude_path" in
    *--path-format*) bad=1 ;;
  esac
  if [ "$bad" = 0 ]; then
    pass "$label: helper paths from $dir carry no --path-format line"
  else
    fail "$label: a helper path carries a --path-format line: git='$git_dir' common='$common_dir' path='$exclude_path'"
  fi
}

echo "=== Test 2: the helper asks git for the plain form ==="
: > "$KP_TEST_GIT_SEEN_LOG"
check_helper_plain "main checkout" "$T/proj"
check_helper_plain "main-checkout subdirectory" "$T/proj/sub"
[ "$(seen_calls)" -eq 0 ] \
  && pass "the helper never sent --path-format to git" \
  || fail "the helper sent --path-format to git: $(cat "$KP_TEST_GIT_SEEN_LOG")"

# run_checks <label> <mode> <suffix>: the same command assertions under either shim mode.
# Each call owns its linked worktree, fresh checkout and spawn task id so the two modes
# do not collide.
run_checks() {
  local label=$1 mode=$2 suffix=$3 proj wt excl id rc out err env_file task_wt wt_git wt_common
  proj=$T/proj wt=$T/wt-$suffix excl=$T/excl-$suffix id=git-compat-spawn-$suffix
  export KP_TEST_GIT_MODE=$mode
  : > "$KP_TEST_GIT_SEEN_LOG"

  echo "=== $label: sync keeps treating a main checkout as the main checkout ==="
  rc=0
  out=$(cd "$proj" && "$KP_BIN/kingpin" sync 2>"$T/sync-main-$suffix.err") || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "already up to date" ] && pass "$label: sync runs in the main checkout (rc=0, already up to date)" \
    || fail "$label: sync in the main checkout: rc=$rc out=$out err=$(cat "$T/sync-main-$suffix.err")"

  # git prints the git dir absolute and the common dir relative below a subdirectory, so
  # the two forms must resolve to the same checkout (lib/guard-hook.mjs does the same).
  rc=0
  out=$(cd "$proj/sub" && "$KP_BIN/kingpin" sync 2>"$T/sync-sub-$suffix.err") || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "already up to date" ] && pass "$label: sync treats a subdirectory of the main checkout as the main checkout" \
    || fail "$label: sync in a main-checkout subdirectory: rc=$rc out=$out err=$(cat "$T/sync-sub-$suffix.err")"

  echo "=== $label: sync refuses a linked worktree ==="
  git -C "$proj" worktree add -q -b "git-compat-wt-$suffix" "$wt" HEAD
  check_helper_plain "$label linked worktree" "$wt"
  rc=0
  err=$(cd "$wt" && "$KP_BIN/kingpin" sync 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] && echo "$err" | grep -q "is a linked worktree" && pass "$label: sync refuses a linked worktree" \
    || fail "$label: sync in a linked worktree: rc=$rc err=$err"

  echo "=== $label: guard install refuses a linked worktree ==="
  "$KP_BIN/kingpin-guard" install --dir "$proj" >/dev/null 2>"$T/guard-main-$suffix.err" && pass "$label: guard install still works in the main checkout" \
    || fail "$label: guard install in the main checkout: $(cat "$T/guard-main-$suffix.err")"
  rc=0
  err=$("$KP_BIN/kingpin-guard" install --dir "$wt" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] && echo "$err" | grep -q "is a linked worktree" && pass "$label: guard install refuses a linked worktree" \
    || fail "$label: guard install in a linked worktree: rc=$rc err=$err"
  [ ! -e "$wt/.claude/settings.local.json" ] && pass "$label: guard install wrote nothing into the linked worktree" \
    || fail "$label: guard install wrote .claude/settings.local.json into the linked worktree"

  # The edit guard in lib/guard-hook.mjs reads the plain form too; a shim that broke it
  # would let the orchestrator edit outside a worktree.
  rc=0
  printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/README.md"}}' "$proj" "$proj" \
    | "$KP_BIN/kingpin-guard" hook orchestrator >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass "$label: the orchestrator hook still denies in the main checkout" \
    || fail "$label: the orchestrator hook allowed an edit in the main checkout: rc=$rc"

  # --git-path info/exclude goes through the same reader: install into a checkout the
  # guard did not prepare, so its ignore check must ask git for the exclude path.
  echo "=== $label: guard install resolves info/exclude ==="
  git init -q -b main "$excl"
  git -C "$excl" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  "$KP_BIN/kingpin-guard" install --dir "$excl" >/dev/null 2>"$T/guard-excl-$suffix.err" \
    && pass "$label: guard install works in a fresh checkout" \
    || fail "$label: guard install in a fresh checkout: $(cat "$T/guard-excl-$suffix.err")"
  grep -qxF '.claude/settings.local.json' "$excl/.git/info/exclude" 2>/dev/null \
    && pass "$label: the exclude line landed in the checkout's real info/exclude" \
    || fail "$label: the exclude line did not land in $excl/.git/info/exclude"

  echo "=== $label: spawn accepts a valid lease ==="
  # A Kingpin-shaped line in the main checkout's exclude file is the file spawn reads
  # with --git-path; the warning proves that lookup reached it.
  grep -qxF '.agents' "$proj/.git/info/exclude" || printf '.agents\n' >> "$proj/.git/info/exclude"
  rc=0
  out=$("$KP_BIN/kingpin" spawn demo-auto --issue 860 --id "$id" --mode review 2>"$T/spawn-$suffix.err") || rc=$?
  [ "$rc" -eq 0 ] && echo "$out" | grep -q "spawned $id " && pass "$label: spawn accepts a valid lease" \
    || fail "$label: spawn: rc=$rc output: $out err=$(cat "$T/spawn-$suffix.err")"
  grep -q 'carries a Kingpin-shaped exclude (.agents)' "$T/spawn-$suffix.err" \
    && pass "$label: spawn resolved info/exclude and named the shared line" \
    || fail "$label: spawn did not name the shared exclude line: $(cat "$T/spawn-$suffix.err")"

  env_file=$KINGPIN_HOME/tasks/$id/task.env
  task_wt=$(sed -n 's/^WORKTREE=//p' "$env_file" 2>/dev/null || true)
  [ -n "$task_wt" ] && [ -d "$task_wt" ] && pass "$label: spawn recorded the leased worktree" || fail "$label: spawn recorded no worktree"

  wt_git=$(git -C "${task_wt:-/nonexistent}" rev-parse --git-dir 2>/dev/null || true)
  wt_common=$(git -C "${task_wt:-/nonexistent}" rev-parse --git-common-dir 2>/dev/null || true)
  [ -n "$wt_git" ] && [ -n "$wt_common" ] && [ "$wt_git" != "$wt_common" ] && pass "$label: the accepted lease is a linked worktree" \
    || fail "$label: the accepted lease is not a linked worktree: git-dir='$wt_git' common-dir='$wt_common'"
  [ "$(git -C "${task_wt:-/nonexistent}" branch --show-current 2>/dev/null || true)" = "kingpin/$id" ] \
    && pass "$label: the accepted lease is on the task branch" || fail "$label: the accepted lease is on the wrong branch"

  # lib/gitdir.sh always calls `git -C <dir> rev-parse ...`. Treehouse itself calls
  # `git rev-parse --path-format=absolute --git-common-dir`; this shim models 2.30 for
  # that call too, but it is not Kingpin's read, so only a helper-shaped entry fails here.
  if grep -q '^-C ' "$KP_TEST_GIT_SEEN_LOG" 2>/dev/null; then
    fail "$label: a helper-shaped git call sent --path-format to git: $(grep '^-C ' "$KP_TEST_GIT_SEEN_LOG")"
  else
    pass "$label: no helper-shaped git call sent --path-format to git"
  fi
}

echo "=== Test 3: the 2.30 echo mode end to end ==="
run_checks "2.30 echo" echo echo

echo "=== Test 4: the shim also rejects --path-format ==="
export KP_TEST_GIT_MODE=reject
: > "$KP_TEST_GIT_SEEN_LOG"
rc=0
reject_err=$(cd "$T/proj" && git rev-parse --path-format=absolute --git-dir 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 129 ] && echo "$reject_err" | grep -q "unknown option 'path-format'" \
  && pass "the shim rejects --path-format with git's message and exit 129" \
  || fail "the rejecting shim: rc=$rc err=$reject_err"

echo "=== Test 5: the rejecting 2.30 end to end ==="
run_checks "2.30 reject" reject reject

kp_test_finish GIT-COMPAT
