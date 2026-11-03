# shellcheck shell=bash
# Shared setup for the tests/test-*.sh suites that run the kingpin CLI end to end.
#
# A suite sources this file, then calls kp_test_setup once. It gets an isolated
# KINGPIN_HOME, a private tmux server, a git identity, a scratch project repo with an
# origin remote, and a cleanup trap. Everything lives under $T and goes away on exit.
#
# Usage in a suite:
#   . "$(dirname "$0")/lib.sh"
#   kp_test_setup <suite-name>
#   kp_test_project           # unless the suite tests `kingpin init` itself
#   ... pass "..." / fail "..." ...
#   kp_test_finish <LABEL>    # prints ALL <LABEL> TESTS PASSED, or exits 1

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# kp_test_setup <suite-name>: sets T, KP_ROOT, KP_BIN, REAL_TMUX, TEST_SOCKET and the KINGPIN_* environment.
kp_test_setup() {
  local suite=$1 w
  unset TMUX CLAUDECODE OPENCODE KINGPIN_HARNESS

  T=$(mktemp -d)
  export KINGPIN_HOME=$T/kp
  export KINGPIN_SKIP_GUARD=1
  # CI runners have no global git identity
  export GIT_AUTHOR_NAME=kingpin-test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=kingpin-test GIT_COMMITTER_EMAIL=test@example.com
  export TREEHOUSE_ROOT=$T/pool
  export CLAUDE_CONFIG_DIR=$T/cfg
  export GEMINI_CONFIG_DIR=$T/cfg-gemini

  mkdir -p "$T/cfg" "$T/cfg-gemini" "$KINGPIN_HOME/projects" "$KINGPIN_HOME/tasks"
  echo '{"projects":{}}' > "$T/cfg/.claude.json"
  echo '{"trustedWorkspaces":[]}' > "$T/cfg-gemini/settings.json"

  KP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  KP_BIN="$KP_ROOT/bin"

  # Set up isolated private tmux server on a temporary socket
  export TMUX_TMPDIR="$T/tmux-tmp"
  mkdir -p "$TMUX_TMPDIR" "$T/bin"
  TEST_SOCKET="kingpin-test-$suite-$$"
  REAL_TMUX=$(command -v tmux)
  cat > "$T/bin/tmux" << EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
  chmod +x "$T/bin/tmux"
  export PATH="$T/bin:$PATH"
  trap kp_test_cleanup EXIT

  # Test repo with an origin remote
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/proj" 2>/dev/null
  (
    cd "$T/proj" || exit 1
    git checkout -q -b main
    echo "initial code" > app.txt
    git add app.txt
    git commit -qm "init"
    git push -q -u origin main
    git remote set-head origin main
  )

  tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home
  for w in $(tmux list-windows -t kingpin -F '#{window_id}' 2>/dev/null | tail -n +2 || true); do
    tmux kill-window -t "$w" 2>/dev/null || true
  done
  # Silent guard: a suite on the wrong tmux server must stop before it touches anything.
  # test-lifecycle.sh keeps the one pass/fail assertion about the socket.
  tmux display-message -p '#{socket_path}' | grep -q "$TEST_SOCKET" || { echo "kp_test_setup: tmux is not on the private socket" >&2; exit 1; }

  # Worker stand-in: an idle shell.
  cat > "$T/fake-worker" << 'F'
#!/usr/bin/env bash
exec bash
F
  chmod +x "$T/fake-worker"
  export KINGPIN_AGY=$T/fake-worker
}

kp_test_cleanup() {
  # A suite that swaps in a fake command leaves its original beside it as
  # <name>.orig; put every one back (test-lifecycle.sh: kingpin-send,
  # test-watch-supervisor.sh: kingpin-wait).
  local f
  for f in "$T"/kingpin-*.orig; do
    [ -f "$f" ] || continue
    cp -p "$f" "$KP_BIN/$(basename "${f%.orig}")" 2>/dev/null || true
  done
  "$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$T"
}

# kp_test_project: register the demo-auto project the way test-lifecycle.sh does, without assertions.
kp_test_project() {
  "$KP_BIN/kingpin" init demo-auto "$T/proj" --harness agy --setup "echo setup" >/dev/null
}

# kp_test_stub_lavish: a quiet stand-in for lavish-axi (poll idles, every other call answers OK).
kp_test_stub_lavish() {
  cat > "$T/mock-lavish-quiet" << 'MLEOF'
#!/usr/bin/env bash
case "${1:-}" in
  poll) sleep 0.2 ;;
  *) echo "OK" ;;
esac
MLEOF
  chmod +x "$T/mock-lavish-quiet"
  export KINGPIN_LAVISH="$T/mock-lavish-quiet"
}

# kp_test_stub_treehouse: a stand-in for `treehouse return` that succeeds and
# records each call. A suite whose synthetic WORKTREE is a plain directory (never
# leased from a TREEHOUSE_ROOT pool) gets `worktree <path> is not managed by
# treehouse` from the real binary, and kingpin-done now refuses the cleanup when
# the return fails (issue #75). Suites that assert the pool itself (spawn,
# lifecycle, acceptance) must not call this.
kp_test_stub_treehouse() {
  cat > "$T/bin/treehouse" << 'TREEEOF'
#!/usr/bin/env bash
printf 'return %s\n' "$*" >> "${KP_TREEHOUSE_CALLS:-/dev/null}"
exit 0
TREEEOF
  chmod +x "$T/bin/treehouse"
}

# kp_test_bsd_shims: put BSD-shaped `stat`, `date` and `sed` wrappers in front of
# PATH, so a Linux CI runner exercises the path macOS takes. They model the BSD
# forms the scripts must use (`stat -f %m`, `date -r`, `date -j -f`) and refuse
# the GNU-only ones (`stat -c`/`--format`, `date -I`/`-d`/`--date`, any `sed -i`).
# Call it right after kp_test_setup; a suite that does not call it keeps the host
# tools. On a host whose own tools are already BSD the shims stand down: they
# translate BSD calls into the host's GNU flags, so there they would shadow
# working tools with failing ones, and the host takes the BSD path anyway.
kp_test_bsd_shims() {
  local dir="$T/bsd"
  # A BSD `date` rejects `-d`, and a BSD `stat` rejects `-c`. Either one means
  # this host is the platform the shims imitate, so leave its tools in place.
  [ "$(date -d @0 +%s 2>/dev/null || true)" = 0 ] || return 0
  stat -c %Y / >/dev/null 2>&1 || return 0
  mkdir -p "$dir"
  export KP_TEST_REAL_STAT KP_TEST_REAL_DATE KP_TEST_REAL_SED
  KP_TEST_REAL_STAT=$(command -v stat)
  KP_TEST_REAL_DATE=$(command -v date)
  KP_TEST_REAL_SED=$(command -v sed)
  cat > "$dir/bsd-shim" << 'SHIM'
#!/usr/bin/env bash
# BSD-shaped stat/date/sed for the Kingpin suites: the forms the scripts must use,
# with the GNU-only flags refused as BSD does. Selected by the name it is called as.
set -uo pipefail
name=$(basename "$0")
case $name in
  stat)
    case ${1:-} in
      -f)
        fmt=${2:-}
        shift 2
        case $fmt in
          %m) exec "${KP_TEST_REAL_STAT:?}" -c %Y "$@" ;;
          *) echo "stat: unsupported BSD format: $fmt" >&2; exit 1 ;;
        esac
        ;;
      -c|--format|--format=*|--printf|--printf=*)
        echo "stat: GNU-only option '$1' (BSD takes -f FORMAT)" >&2
        exit 1
        ;;
    esac
    echo "stat: illegal option -- ${1#-}" >&2
    exit 1
    ;;
  date)
    args=()
    while [ $# -gt 0 ]; do
      case $1 in
        -I*|--iso-8601|--iso-8601=*|-d*|--date|--date=*|--rfc-3339|--rfc-3339=*)
          echo "date: GNU-only option '$1' (BSD takes -r EPOCH or -j -f FORMAT VALUE)" >&2
          exit 1
          ;;
        -r)
          epoch=${2:?-r needs seconds}
          shift 2
          if [ $# -gt 0 ]; then exec "${KP_TEST_REAL_DATE:?}" -d "@$epoch" "$1"; fi
          exec "${KP_TEST_REAL_DATE:?}" -d "@$epoch"
          ;;
        -j)
          [ "${2:-}" = "-f" ] || { echo "date: unsupported -j form" >&2; exit 1; }
          value=${4:?-j -f needs a value}
          shift 4
          if [ $# -gt 0 ]; then exec "${KP_TEST_REAL_DATE:?}" -d "$value" "$1"; fi
          exec "${KP_TEST_REAL_DATE:?}" -d "$value"
          ;;
        *) args+=("$1"); shift ;;
      esac
    done
    exec "${KP_TEST_REAL_DATE:?}" "${args[@]}"
    ;;
  sed)
    for a in "$@"; do
      case $a in
        -[!-]*i*)
          # BSD sed has no `-i` without a suffix argument, and the suites rewrite
          # in place through kp_test_sub instead, so every `-i` form is refused,
          # including a combined cluster such as `-Ei`.
          echo "sed: GNU-only -i option '$a' (BSD needs an explicit suffix; use kp_test_sub)" >&2
          exit 1
          ;;
      esac
    done
    exec "${KP_TEST_REAL_SED:?}" "$@"
    ;;
esac
SHIM
  chmod +x "$dir/bsd-shim"
  ln -sf "$dir/bsd-shim" "$dir/stat"
  ln -sf "$dir/bsd-shim" "$dir/date"
  ln -sf "$dir/bsd-shim" "$dir/sed"
  export PATH="$dir:$PATH"
}

# kp_test_sub <file> <sed-script>: rewrite <file> in place through a temp file.
# GNU and BSD `sed -i` disagree on the suffix argument, so a suite never uses it.
kp_test_sub() {
  local file=${1:?} script=${2:?} tmp
  tmp=$(mktemp "$file.XXXXXX")
  sed -e "$script" "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# kp_test_iso_ago <seconds>: an ISO 8601 timestamp that many seconds in the past,
# in the shape kp_now_iso writes. GNU date first, then BSD date.
kp_test_iso_ago() {
  local secs=${1:?} epoch
  epoch=$(( $(date +%s) - secs ))
  date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null \
    || date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z
}

# kp_test_touch_ago <file> <seconds>: set <file>'s mtime that many seconds in the
# past. `touch -d` is GNU, `touch -t` is the form both platforms accept.
kp_test_touch_ago() {
  local file=${1:?} secs=${2:?} epoch stamp
  epoch=$(( $(date +%s) - secs ))
  touch -d "@$epoch" "$file" 2>/dev/null && return 0
  stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$epoch" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$file"
}

# kp_test_finish <LABEL>
kp_test_finish() {
  if [ "$FAILED" -eq 0 ]; then
    echo "ALL $1 TESTS PASSED"
  else
    echo "$1 TESTS FAILED"
    exit 1
  fi
}
