# shellcheck shell=bash
# Where the fleet's tmux windows live (issue #142).
#
# Workers run on a tmux server of their own, named by `kingpin` unless
# KINGPIN_TMUX_SOCKET names another socket. The default socket stays the operator's:
# an operator session kill, or a `tmux kill-server` on the default socket, does not
# reach a worker. Every command that resolves a worker window goes through `kp_tmux`,
# so the socket is passed in one place.
#
# Source lib/status.sh first: `kp_tmux_socket_from_env` reads the task record with
# `kp_env_get`. These functions print only what they document.
#
#   # shellcheck source=../lib/status.sh
#   . "$KP_ROOT/lib/status.sh"
#   # shellcheck source=../lib/tmux.sh
#   . "$KP_ROOT/lib/tmux.sh"

# kp_tmux_socket_name
# The socket the fleet uses: KINGPIN_TMUX_SOCKET, or `kingpin`.
kp_tmux_socket_name() {
  printf '%s\n' "${KINGPIN_TMUX_SOCKET:-kingpin}"
}

# kp_tmux_socket_from_env <task-env-file>
# The socket a task record names, or nothing for a record written before the
# fleet moved to its own server (those windows live on the default socket).
kp_tmux_socket_from_env() {
  [ -f "${1:-}" ] || return 0
  kp_env_get "$1" TMUX_SOCKET
}

# kp_tmux <socket> [tmux-args...]
# Run tmux on <socket>; an empty socket means the default tmux server, which is
# where a task record without TMUX_SOCKET points. The default is named
# explicitly, `-L default`, and never left to a bare `tmux`: a caller inside a
# tmux pane inherits TMUX, and a bare call would follow that socket instead of
# the default server the record means.
kp_tmux() {
  local sock=${1:-}
  shift || true
  tmux -L "${sock:-default}" "$@"
}

# kp_tmux_ensure_session <socket> <session>
# Make sure <session> exists on <socket>, creating it detached when it does not.
# Prints nothing; the caller reports a failure.
kp_tmux_ensure_session() {
  local sock=${1:-} session=${2:?}
  kp_tmux "$sock" has-session -t "$session" 2>/dev/null \
    || kp_tmux "$sock" new-session -d -s "$session" -n home
}
