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

# kp_test_finish <LABEL>
kp_test_finish() {
  if [ "$FAILED" -eq 0 ]; then
    echo "ALL $1 TESTS PASSED"
  else
    echo "$1 TESTS FAILED"
    exit 1
  fi
}
