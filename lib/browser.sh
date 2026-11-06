# shellcheck shell=bash
# Shared readers for the browser daemons a worker leaves behind (issue #160).
# Source it; it only defines functions (no `set` options, no output beyond what each states,
# every function returns 0 unless stated).
#
#   # shellcheck source=../lib/browser.sh
#   . "$KP_ROOT/lib/browser.sh"
#
# A `chrome-devtools-axi` session is a bridge daemon: `node .../chrome-devtools-axi-bridge.js`
# in its own process group, with `chrome-devtools-mcp` and a headless Chrome tree beneath it.
# Only an argv word that is that script makes a process a daemon, so a command line that
# merely mentions the name (a `tail -f` of a log, an editor, a `grep`) is not one.
# The daemon has no task id of its own, but it inherits the working directory of the command
# that started it, so a worker's daemon carries that worker's task folder or worktree. That is
# the ownership rule `kingpin done` and `kingpin spawn` act on: a daemon is this task's exactly
# when its cwd is inside this task's folder or worktree, matched on a path boundary, so
# `/x/task` never claims `/x/task-other`. Nothing else is deleted: a process at the same cwd
# that is not a bridge daemon is someone else's.
#
# The table is `pid<TAB>rss-kb<TAB>cwd` per live daemon, where the RSS total covers the whole
# recorded process tree (the bridge, the MCP server and Chrome), because a bridge alone reports
# a small share of what the session really holds. `kingpin list` prints it; `kingpin done` and
# `kingpin spawn` stop what it names.

# kp_browser_alive <pid>
# Exit 0 while the process runs. A pid that exited but has not been reaped yet (a zombie)
# answers `kill -0`, so the state is read from `ps` and a zombie counts as gone.
kp_browser_alive() {
  local pid=${1:-} stat
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  [ -n "$stat" ] || return 1
  case "$stat" in Z*) return 1 ;; esac
  return 0
}

# kp_browser_cwd <pid>
# Prints the process's working directory, resolved through /proc on Linux and `lsof` on
# macOS. Exit 1 and print nothing when neither reader names one, so a caller never compares
# an empty path against a task folder.
kp_browser_cwd() {
  local pid=${1:-} cwd=''
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -L "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  fi
  if [ -z "$cwd" ] && command -v lsof >/dev/null 2>&1; then
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)
  fi
  [ -n "$cwd" ] || return 1
  # A directory replaced or removed under the process reads as "<path> (deleted)".
  cwd=${cwd% (deleted)}
  printf '%s\n' "$cwd"
}

# kp_browser_args_is_bridge <args>
# Exit 0 when <args> runs the bridge script: an argv word that is either the bare
# `chrome-devtools-axi-bridge` (a PATH launch) or a path ending in
# `/chrome-devtools-axi-bridge.js`, which is the shape `chrome-devtools-axi` starts
# (`node .../dist/bin/chrome-devtools-axi-bridge.js`). A word that only carries the name,
# such as `chrome-devtools-axi-bridge.log`, does not count.
kp_browser_args_is_bridge() {
  local word
  local words=()
  read -r -a words <<< "${1:-}"
  for word in ${words[@]+"${words[@]}"}; do
    case "$word" in
      chrome-devtools-axi-bridge|*/chrome-devtools-axi-bridge.js) return 0 ;;
    esac
  done
  return 1
}

# kp_browser_pid_is_daemon <pid>
# Exit 0 when the process's command line runs the bridge script (kp_browser_args_is_bridge).
# Re-checked right before a kill, so a pid reused between the scan and the signal is never
# killed blind.
kp_browser_pid_is_daemon() {
  local pid=${1:-} args
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  args=$(ps -o args= -p "$pid" 2>/dev/null || true)
  kp_browser_args_is_bridge "$args"
}

# kp_browser_tree_pids <pid> [snapshot]
# Prints <pid> and every descendant, one per line. <snapshot> is a `ps -eo pid=,ppid=` capture
# the caller already holds; without one the function takes its own. Exit 1 and print nothing
# when the pid is unusable or `ps` returned nothing.
kp_browser_tree_pids() {
  local root=${1:-} snapshot=${2:-}
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$snapshot" ] || snapshot=$(ps -eo pid=,ppid= 2>/dev/null || true)
  [ -n "$snapshot" ] || return 1
  printf '%s\n' "$snapshot" | awk -v root="$root" '
    { ppid[$1] = $2; if ($2 != "") kids[$2] = kids[$2] " " $1 }
    END {
      n = 0; stack[++n] = root
      while (n > 0) {
        p = stack[n--]
        printf "%s\n", p
        m = split(kids[p], child, " ")
        for (i = 1; i <= m; i++) if (child[i] != "") stack[++n] = child[i]
      }
    }'
}

# kp_browser_daemons
# Prints `pid<TAB>rss-kb<TAB>cwd` for every live bridge daemon whose cwd can be read. One `ps`
# pass finds the candidates, and one `awk` pass over its snapshot tests each command line and
# totals each daemon's tree RSS (the bridge, the MCP server and Chrome), so the call runs `ps`
# exactly once however many daemons it finds; a daemon with no readable cwd is skipped, never
# guessed at.
kp_browser_daemons() {
  local snapshot rows pid rss cwd
  snapshot=$(ps -eo pid=,ppid=,rss=,args= 2>/dev/null || true)
  [ -n "$snapshot" ] || return 0
  rows=$(printf '%s\n' "$snapshot" |
    awk '
      # The daemon test of kp_browser_args_is_bridge: one whitespace-split argv word that is
      # either the bare `chrome-devtools-axi-bridge` (a PATH launch) or a path ending in
      # `/chrome-devtools-axi-bridge.js`, which is the shape `chrome-devtools-axi` starts
      # (`node .../dist/bin/chrome-devtools-axi-bridge.js`). A word that only carries the
      # name, such as `chrome-devtools-axi-bridge.log`, does not count.
      function is_bridge(argv,      n, word, i) {
        n = split(argv, word, /[ \t]+/)
        for (i = 1; i <= n; i++) {
          if (word[i] == "chrome-devtools-axi-bridge") return 1
          if (word[i] ~ /\/chrome-devtools-axi-bridge\.js$/) return 1
        }
        return 0
      }
      # The tree walk that totals each daemon RSS over the snapshot already in
      # memory: the sum of the rss value of the root and of every descendant.
      function tree_rss(root,      total, n, p, m, i, child) {
        total = 0
        n = 0; stack[++n] = root
        while (n > 0) {
          p = stack[n--]
          total += rss_of[p]
          m = split(kids[p], child, " ")
          for (i = 1; i <= m; i++) if (child[i] != "") stack[++n] = child[i]
        }
        return total
      }
      {
        pid = $1
        if (pid !~ /^[0-9]+$/) next
        if ($2 != "") kids[$2] = kids[$2] " " pid
        rss_of[pid] = $3
        argline = ""
        for (i = 4; i <= NF; i++) argline = argline (i > 4 ? " " : "") $i
        if (is_bridge(argline)) daemon_pid[++nd] = pid
      }
      END {
        for (i = 1; i <= nd; i++) printf "%s\t%d\n", daemon_pid[i], tree_rss(daemon_pid[i])
      }')
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r pid rss; do
    cwd=$(kp_browser_cwd "$pid" 2>/dev/null || true)
    [ -n "$cwd" ] || continue
    case "$rss" in ''|*[!0-9]*) rss=0 ;; esac
    printf '%s\t%s\t%s\n' "$pid" "$rss" "$cwd"
  done <<< "$rows"
  return 0
}

# kp_browser_rows_under <dir>...
# A pure filter: reads the kp_browser_daemons table on stdin and prints the rows whose cwd is
# <dir> itself or below it. Directories are resolved to their physical path first (the cwd
# /proc reports is physical), and the comparison is a whole path segment, so a shared prefix
# is not a match.
kp_browser_rows_under() {
  local pid rss cwd dir target hit
  local dirs=()
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if target=$(cd "$dir" 2>/dev/null && pwd -P); then
      dirs+=("${target%/}")
    else
      dirs+=("${dir%/}")
    fi
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r pid rss cwd; do
    [ -n "$pid" ] || continue
    hit=0
    for dir in "${dirs[@]}"; do
      if [ "$cwd" = "$dir" ]; then hit=1; break; fi
      case "$cwd" in "$dir"/*) hit=1; break ;; esac
    done
    [ "$hit" -eq 1 ] || continue
    printf '%s\t%s\t%s\n' "$pid" "$rss" "$cwd"
  done
}

# kp_browser_daemons_under <dir>...
# The kp_browser_daemons table filtered to the daemons owned by <dir>... (the convenience form
# of `kp_browser_daemons | kp_browser_rows_under`).
kp_browser_daemons_under() {
  kp_browser_daemons | kp_browser_rows_under "$@"
}

# kp_browser_stop_under <dir>...
# Stops every daemon whose cwd is <dir>... and prints `count<TAB>rss-kb`, the daemons stopped
# and their RSS total before the stop. SIGTERM goes to the bridge and its recorded tree first,
# so the bridge runs its own shutdown; after two seconds the group it leads gets SIGKILL
# whether or not the bridge itself still runs (a bridge can exit while a child it forked on
# the way out lives on), plus whatever is left of the recorded tree, so chrome-devtools-mcp
# and Chrome cannot be orphaned. Always returns 0: a cleanup is not failed by a daemon that
# refuses to die.
kp_browser_stop_under() {
  local rows pid rss cwd total=0 count=0 p pgid tree
  local tree_pids=()
  rows=$(kp_browser_daemons_under "$@")
  [ -n "$rows" ] || { printf '0\t0\n'; return 0; }
  while IFS=$'\t' read -r pid rss cwd; do
    [ -n "$pid" ] || continue
    [ "$pid" != "$$" ] || continue
    kp_browser_pid_is_daemon "$pid" || continue
    # Read the group now: the wait below outlives the bridge, and a pgid read after it is
    # gone with the pid.
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    tree=$(kp_browser_tree_pids "$pid" 2>/dev/null || true)
    tree_pids=()
    while IFS= read -r p; do
      [ -n "$p" ] && tree_pids+=("$p")
    done <<< "$tree"
    for p in ${tree_pids[@]+"${tree_pids[@]}"}; do
      kill -TERM "$p" 2>/dev/null || true
    done
    for _ in {1..40}; do
      kp_browser_alive "$pid" || break
      sleep 0.05
    done
    if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
      kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
    for p in ${tree_pids[@]+"${tree_pids[@]}"}; do
      kp_browser_alive "$p" && kill -KILL "$p" 2>/dev/null || true
    done
    count=$((count + 1))
    total=$((total + rss))
  done <<< "$rows"
  printf '%s\t%s\n' "$count" "$total"
  return 0
}

# kp_browser_size <kilobytes>
# Prints a short human form such as `412 MB` or `1.2 GB`. Bad input reads as 0.
kp_browser_size() {
  local kb=${1:-0}
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  if [ "$kb" -ge 1048576 ]; then
    printf '%d.%d GB\n' $((kb / 1048576)) $(((kb % 1048576) * 10 / 1048576))
  else
    printf '%d MB\n' $((kb / 1024))
  fi
}
