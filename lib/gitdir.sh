# shellcheck shell=bash
# Where a checkout's git directory, common directory and resolved git paths live, read
# the same way on every git Kingpin supports. Source it; it only defines functions
# (no `set` options, no output beyond what each states).
#
# `git rev-parse --path-format=absolute` makes git print an absolute path, which is the
# form the linked-worktree checks need: a linked worktree's git dir and common dir must
# compare unequal, and a main checkout's must compare equal from its root and from any
# subdirectory of it. The option arrived in git 2.31 while README.md promises git 2.30,
# and 2.30 does not reject an option it does not know: its `rev-parse` echoes the option
# on stdout and exits 0 (builtin/rev-parse.c falls through to show_flag), so a probe on
# the exit status cannot tell support from rejection. Every reader therefore runs the
# plain form and resolves its output against the checkout the way lib/guard-hook.mjs
# does: git prints `.git` in a main checkout's root, an absolute path for the git dir and
# `../.git` for the common dir below a subdirectory, and absolute paths inside a linked
# worktree.
#
#   kp_git_dir <dir>          git directory of <dir>, as an absolute path
#   kp_git_common_dir <dir>   common directory of <dir>, as an absolute path
#   kp_git_path <dir> <path>  location git resolves <path> to in <dir>, as an absolute path
#
# Each returns 1 and prints nothing when git cannot answer, so a caller reports the
# failure instead of comparing two empty strings.

# kp_git_resolve <base> <path>
# Prints <path> as an absolute path: a relative <path> is taken from <base>, the
# nearest existing directory is made physical with `cd` and `pwd -P`, and the
# components below it are appended unchanged. A path that names a file (such as
# `info/exclude`) resolves through its parent, not through itself.
kp_git_resolve() {
  local base=${1:-} p=${2:-} cur tail=''
  [ -n "$p" ] || return 1
  case $p in
    /*) ;;
    *) p=$base/$p ;;
  esac
  cur=$p
  while [ ! -d "$cur" ]; do
    tail=/${cur##*/}$tail
    cur=${cur%/*}
    [ -n "$cur" ] || { cur=/; break; }
  done
  printf '%s%s\n' "$(cd "$cur" && pwd -P)" "$tail"
}

# kp_git_rev_parse <dir> <rev-parse option>...
# Prints the absolute path git names for <option>... in <dir>, resolved against <dir>.
# Returns 1 and prints nothing when git cannot answer.
kp_git_rev_parse() {
  local dir=${1:?kp_git_rev_parse needs a directory} base raw
  shift
  base=$(cd "$dir" && pwd -P) || return 1
  raw=$(git -C "$dir" rev-parse "$@" 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  kp_git_resolve "$base" "$raw"
}

# kp_git_dir <dir>: prints <dir>'s git directory as an absolute path.
kp_git_dir() {
  kp_git_rev_parse "${1:?kp_git_dir needs a directory}" --git-dir
}

# kp_git_common_dir <dir>: prints <dir>'s common git directory, which differs from the
# git directory exactly in a linked worktree.
kp_git_common_dir() {
  kp_git_rev_parse "${1:?kp_git_common_dir needs a directory}" --git-common-dir
}

# kp_git_path <dir> <path>: prints the absolute location git resolves <path> to for a
# command run in <dir> (for example `info/exclude`).
kp_git_path() {
  kp_git_rev_parse "${1:?kp_git_path needs a directory}" --git-path "${2:?kp_git_path needs a path}"
}
