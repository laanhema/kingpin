# shellcheck shell=bash
# Per-worktree excludes for the harness files a spawn writes into a worker's checkout
# (issue #77). Source it; it defines the functions below and the two
# `KP_GUARD_EXCLUDE_*` marker constants, and nothing else (no `set` options, no output
# unless stated, every function returns 0 unless stated, and a failed write names its
# reason on stderr for the caller to report through its own `die`).
#
# A linked worktree has no `.git/info/exclude` of its own: `git rev-parse --git-path
# info/exclude` resolves into the common dir, so that file is the main checkout's and
# carries the user's own lines. A spawn that appended to it changed the user's repository
# on every task and deleted lines it never wrote. A worktree therefore reads a
# Kingpin-owned file instead, through a worktree-scoped `core.excludesFile`. Git reads
# `$GIT_DIR/config.worktree` only once the repository sets `extensions.worktreeConfig`,
# so that flag is the one repository-config line a spawn writes; it is idempotent and
# changes no ignore rule by itself.
#
#   kp_exclude_write <worktree> <task-dir> <task-id> <harness> <path>...
#   kp_exclude_clear <worktree> <task-dir>
#
# The main checkout's `.git/info/exclude` is the user's file, and the only part of it
# `kingpin guard install` rewrites is the block it owns there for its contract copies
# (`KP_GUARD_EXCLUDE_*` below); the install may also append a plain
# `.claude/settings.local.json` line outside that block. A spawn names a Kingpin-shaped
# line outside the block and skips the lines inside it, because the guard rewrites the
# block on every install (issue #123).
#
# `kp_exclude_write` also mirrors the ignore file the worktree would otherwise inherit:
# a worktree-scoped core.excludesFile replaces it, and a worker that started seeing the
# paths the user hides would leave the tree dirty (`kingpin done` refuses that). The
# value is resolved the way git resolves it for a command run in the worktree, and a
# file that exists but cannot be read fails the spawn instead of dropping the user's
# ignore rules without a word.

# The files a spawn writes into a worktree, and the historical paths an older spawn
# wrote, one path per line. `kp_exclude_clear` removes the ones a spawn recorded for its
# task, `kingpin-spawn` looks for any of them a reused slot already carries, and it names
# any of these lines an older version left in the shared exclude file. The list is
# therefore the only definition of a Kingpin-owned path.
#
# `.opencode/config.json` is historical: OpenCode V2 reads opencode.json(c) or
# `.opencode/opencode.json` and ignores this path without a word (the fact
# `bin/kingpin-spawn` records at its opencode branch), but the OpenCode wiring before
# #96 wrote it. A pooled slot can still carry it, so it stays on the list (issue #127).
kp_exclude_injected_paths() {
  printf '%s\n' \
    .agents/rules/kingpin.md \
    .agents/hooks.json \
    .opencode/opencode.json \
    .opencode/config.json \
    .opencode/plugins/package.json \
    .opencode/plugins/kingpin-stop.js
}

# The markers of the block `kingpin guard install` owns in the main checkout's
# `.git/info/exclude`. A spawn names a Kingpin-shaped line outside it and skips the
# lines inside it, because the guard rewrites the block on every install (issue #123).
KP_GUARD_EXCLUDE_BEGIN='# kingpin guard'
KP_GUARD_EXCLUDE_END='# end kingpin guard'

# kp_exclude_guard_block <exclude-file> <path>...
# Add <path>... to the guard-owned block of <exclude-file>, rewriting the whole block so
# a repeated install leaves no duplicate line. Everything outside the block keeps its
# order, and an unmarked line that equals one of <path>... is adopted into the block
# instead of duplicated, so one install silences the warning an older install left behind
# (issue #123). A file that cannot be read or written names its reason on stderr and
# returns 1.
kp_exclude_guard_block() {
  local file=$1
  shift
  local line keep want tmp
  local in_block=0
  local outside=() inside=() entries=()
  if [ -f "$file" ]; then
    [ -r "$file" ] || { echo "cannot read $file" >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
        "$KP_GUARD_EXCLUDE_BEGIN") in_block=1; continue ;;
        "$KP_GUARD_EXCLUDE_END") in_block=0; continue ;;
      esac
      if [ "$in_block" = 1 ]; then
        inside+=("$line")
        continue
      fi
      keep=1
      for want in "$@"; do
        if [ "$line" = "$want" ]; then keep=0; break; fi
      done
      if [ "$keep" = 1 ]; then outside+=("$line"); fi
    done < "$file"
  fi
  # Keep the entries an earlier install left in the block, without duplicates.
  for line in ${inside[@]+"${inside[@]}"}; do
    [ -n "$line" ] || continue
    keep=1
    for want in ${entries[@]+"${entries[@]}"}; do
      if [ "$line" = "$want" ]; then keep=0; break; fi
    done
    [ "$keep" = 1 ] && entries+=("$line")
  done
  for want in "$@"; do
    keep=1
    for line in ${entries[@]+"${entries[@]}"}; do
      if [ "$line" = "$want" ]; then keep=0; break; fi
    done
    [ "$keep" = 1 ] && entries+=("$want")
  done
  mkdir -p "$(dirname "$file")" || { echo "cannot create the directory of $file" >&2; return 1; }
  tmp="$file.tmp.$$"
  {
    for line in ${outside[@]+"${outside[@]}"}; do
      printf '%s\n' "$line"
    done
    printf '%s\n' "$KP_GUARD_EXCLUDE_BEGIN"
    for line in ${entries[@]+"${entries[@]}"}; do
      printf '%s\n' "$line"
    done
    printf '%s\n' "$KP_GUARD_EXCLUDE_END"
  } > "$tmp" || { rm -f "$tmp"; echo "cannot write $file" >&2; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; echo "cannot write $file" >&2; return 1; }
  return 0
}

# kp_exclude_file <task-dir>: the exclude file Kingpin owns for one task.
kp_exclude_file() {
  printf '%s/exclude\n' "${1:?kp_exclude_file needs a task dir}"
}

# kp_exclude_inherited_file <worktree>: the absolute path of the ignore file the worktree
# would read without Kingpin's pointer, or nothing when the user disabled one explicitly.
# A value git cannot resolve names its reason on stderr and returns 1.
kp_exclude_inherited_file() {
  local worktree=$1 value rc=0
  value=$(git -C "$worktree" config --path --get core.excludesFile) || rc=$?
  case $rc in
    0) ;;
    1) value=${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore ;;
    *)
      echo "cannot resolve core.excludesFile for $worktree" >&2
      return 1
      ;;
  esac
  # Git resolves a relative core.excludesFile against the directory it runs in. The
  # worker runs inside the worktree, not in this process's working directory, so make
  # the path absolute against the worktree before reading it.
  case $value in
    ''|/*) ;;
    *) value=$worktree/$value ;;
  esac
  printf '%s\n' "$value"
}

# kp_exclude_write <worktree> <task-dir> <task-id> <harness> <path>...
kp_exclude_write() {
  local worktree=$1 task_dir=$2 id=$3 harness=$4
  shift 4
  local file first=$1 global_file mirrored=''
  file=$(kp_exclude_file "$task_dir")
  global_file=$(kp_exclude_inherited_file "$worktree") || return 1
  if [ -n "$global_file" ] && [ "$global_file" != "$file" ] && [ -e "$global_file" ]; then
    # A file the worktree would inherit but cannot read would silently drop the user's
    # ignore rules: the worker could then stage a path the user hides, so refuse instead.
    [ -r "$global_file" ] \
      || { echo "cannot read the ignore file $global_file this worktree would inherit; the worker would see the paths it hides as untracked" >&2; return 1; }
    mirrored=$(cat "$global_file") \
      || { echo "cannot read $global_file" >&2; return 1; }
  fi
  {
    printf '# Generated by kingpin-spawn for task %s (%s); rewritten on every spawn, do not edit.\n' "$id" "$harness"
    printf '# Patterns are relative to the worktree root. The ignore file this worktree would\n'
    printf '# otherwise inherit is mirrored below, because this file replaces it.\n'
    if [ -n "$mirrored" ]; then
      printf '# --- mirrored from %s ---\n' "$global_file"
      printf '%s\n' "$mirrored"
      printf '# --- end mirrored ---\n'
    fi
    printf '# Kingpin harness files for this task\n'
    printf '%s\n' "$@"
  } > "$file" || { echo "cannot write $file" >&2; return 1; }
  git -C "$worktree" config extensions.worktreeConfig true \
    || { echo "cannot enable extensions.worktreeConfig in $worktree" >&2; return 1; }
  git -C "$worktree" config --worktree core.excludesFile "$file" \
    || { echo "cannot point the ignores of $worktree at $file" >&2; return 1; }
  # Fail here rather than launch a worker whose harness files show up as untracked.
  git -C "$worktree" check-ignore -q -- "$first" \
    || { echo "$worktree does not apply $file" >&2; return 1; }
  return 0
}

# kp_exclude_clear <worktree> <task-dir>
# Undo what a spawn added to one worktree and one task folder: the pointer, the files the
# spawn recorded in `<task-dir>/injected` (unless the project tracks them), the task's
# exclude file and that record. Only recorded paths are removed: a file a person left at
# another harness's path is not Kingpin's to delete.
kp_exclude_clear() {
  local worktree=$1 task_dir=$2 rel
  if [ -d "$worktree" ] && git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$worktree" config --worktree --unset core.excludesFile 2>/dev/null || true
    if [ -f "$task_dir/injected" ]; then
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -e "$worktree/$rel" ] || continue
        git -C "$worktree" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && continue
        rm -f "$worktree/$rel"
      done < "$task_dir/injected"
    fi
  fi
  rm -f "$(kp_exclude_file "$task_dir")" "$task_dir/injected"
  return 0
}
