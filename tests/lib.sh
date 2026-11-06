# shellcheck shell=bash
# Shared setup for the tests/test-*.sh suites that run the kingpin CLI end to end.
#
# A suite sources this file, then calls kp_test_setup once. It gets an isolated
# KINGPIN_HOME, a private tmux server, a git identity, a scratch project repo with an
# origin remote, a default lavish-axi stub, and a cleanup trap. Everything lives under
# $T and goes away on exit.
#
# The default stub (kp_test_stub_lavish) answers every call without touching a Lavish
# session and records each call's argv in $KP_TEST_LAVISH_CALLS_LOG. $T/bin, first on
# PATH, also holds a `lavish-axi` shim that records a call that resolved the real
# binary in $KP_TEST_LAVISH_REAL_LOG and exits 1, so unsetting KINGPIN_LAVISH cannot
# reach Lavish either. A call no suite declared is a leak, so kp_test_finish fails and
# names it; a suite that drives the stub on purpose declares that with
# kp_test_expect_lavish_calls, which is checked too: the log must grow after the
# declaration, and every recorded line must match one of the patterns it was given.
# A suite that asserts specific calls installs its own mock over KINGPIN_LAVISH
# instead (tests/test-listen.sh).
#
# Usage in a suite:
#   . "$(dirname "$0")/lib.sh"
#   kp_test_setup <suite-name>
#   kp_test_project           # unless the suite tests `kingpin init` itself
#   kp_test_expect_lavish_calls [pattern...]   # only when the suite drives the stub
#   ... pass "..." / fail "..." ...
#   kp_test_finish <LABEL>    # prints ALL <LABEL> TESTS PASSED, or exits 1

# The suites read git dirs and exclude paths with the same helper the commands use, so a
# check resolves them the same way the commands do, including on git 2.30 (issue #86).
# shellcheck source=../lib/gitdir.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gitdir.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# kp_test_now_us: a microsecond reading, for the deadline a wait computes. EPOCHREALTIME
# needs bash 5; an older shell falls back to whole seconds, so a sub-second window rounds
# up there rather than down.
kp_test_now_us() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    printf '%s\n' "${EPOCHREALTIME/[.,]/}"
  else
    printf '%s000000\n' "$(date +%s)"
  fi
}

# kp_test_seconds_us <seconds>: the microseconds in a decimal seconds value, converted by
# awk so 0.05 and 16 both work without a float in bash.
kp_test_seconds_us() {
  awk -v s="${1:?kp_test_seconds_us: missing seconds}" 'BEGIN { printf "%.0f\n", s * 1000000 }'
}

# kp_wait_until <seconds> <cmd...>: poll every 0.05 s until <cmd> succeeds, and return 0 as
# soon as it does, or 1 once the wall-clock window of <seconds> runs out. The window is a
# deadline rather than a try count, so a loaded runner gets the same window instead of
# fewer samples, and a bounded poll keeps a check from depending on machine speed
# (issue #164). <cmd> is a predicate: it runs up to seconds / 0.05 times, so it must be
# read-only, its output is discarded, and its return code is the whole answer (a check that
# needs a value reads it after the wait). A predicate that needs `!`, a pipe or an
# assignment has to be a function, because "$@" never re-parses a control operator.
kp_wait_until() {
  local seconds=${1:?kp_wait_until: missing seconds} deadline
  shift
  [ $# -gt 0 ] || { echo "kp_wait_until: missing command" >&2; return 2; }
  case $seconds in
    '' | *[!0-9.]* | *.*.*)
      echo "kp_wait_until: <seconds> must be a number, got: '$seconds'" >&2
      return 2
      ;;
  esac
  deadline=$(( $(kp_test_now_us) + $(kp_test_seconds_us "$seconds") ))
  while :; do
    "$@" >/dev/null 2>&1 && return 0
    [ "$(kp_test_now_us)" -ge "$deadline" ] && return 1
    sleep 0.05
  done
}

# kp_holds_for <seconds> <cmd...>: the "nothing happened" counterpart, for a check that a
# thing stayed true for a whole window. It samples <cmd> every 0.05 s and returns 0 only
# when the predicate held at every sample until the deadline, or 1 at the first sample that
# failed. A single read after a fixed pause cannot tell a thing that never happened from one
# that happened and went away. <cmd> carries the same read-only rule as kp_wait_until.
kp_holds_for() {
  local seconds=${1:?kp_holds_for: missing seconds} deadline
  shift
  [ $# -gt 0 ] || { echo "kp_holds_for: missing command" >&2; return 2; }
  case $seconds in
    '' | *[!0-9.]* | *.*.*)
      echo "kp_holds_for: <seconds> must be a number, got: '$seconds'" >&2
      return 2
      ;;
  esac
  deadline=$(( $(kp_test_now_us) + $(kp_test_seconds_us "$seconds") ))
  while :; do
    "$@" >/dev/null 2>&1 || return 1
    [ "$(kp_test_now_us)" -ge "$deadline" ] && return 0
    sleep 0.05
  done
}

# kp_run <out-var> <rc-var> <cmd...>: run <cmd> and store its combined stdout and stderr in
# <out-var> and its exit status in <rc-var>, without tripping `set -e`. A bare
# `out=$(cmd)` followed by `rc=$?` aborts the suite when <cmd> fails, so the assertion's
# fail branch never runs; kp_run captures the status instead and always returns 0, which
# makes it the guarded form `out=$(cmd) || rc=$?` in one call (issue #180). The variable
# names use a prefix no suite uses, so a caller's own `local out` is not shadowed. An
# environment assignment needs `env` in front (`kp_run out rc env PATH=... cmd`), because
# "$@" does not re-parse an assignment as an environment prefix.
kp_run() {
  local __kp_run_out_var=${1:?kp_run: missing output variable}
  local __kp_run_rc_var=${2:?kp_run: missing status variable}
  shift 2
  [ $# -gt 0 ] || { echo "kp_run: missing command" >&2; return 2; }
  local __kp_run_out __kp_run_rc=0
  __kp_run_out=$("$@" 2>&1) || __kp_run_rc=$?
  printf -v "$__kp_run_out_var" '%s' "$__kp_run_out"
  printf -v "$__kp_run_rc_var" '%s' "$__kp_run_rc"
  return 0
}

# kp_test_setup <suite-name>: sets T, KP_ROOT, KP_BIN, REAL_TMUX, TEST_SOCKET and the KINGPIN_* environment.
kp_test_setup() {
  local suite=$1 w
  unset TMUX CLAUDECODE OPENCODE KINGPIN_HARNESS
  # No suite may reach a real Herdr server, and none may select Herdr by accident
  # (issue #144): clear the pane context a developer's shell may carry, pin the mux
  # to tmux, and let the fake herdr installed below shadow the real binary.
  unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_WORKSPACE_ID \
    HERDR_TAB_ID HERDR_BIN_PATH KINGPIN_HERDR_SESSION
  export KINGPIN_MUX=tmux

  T=$(mktemp -d)
  export KINGPIN_HOME=$T/kp
  export KP_TEST_LAVISH_CALLS_LOG=$T/lavish-calls.log
  export KP_TEST_LAVISH_REAL_LOG=$T/real-lavish-calls.log
  export KP_TEST_HERDR_CALLS=$T/herdr-calls.log
  export KP_TEST_HERDR_REAL_LOG=$T/real-herdr-calls.log
  unset KP_TEST_HERDR_STATE KP_TEST_ALLOW_REAL_HERDR
  export KINGPIN_SKIP_GUARD=1
  # No suite may launch a real curator against ~/.claude/skills: the auto trigger
  # rides every supervisor sweep and every kingpin done, so it is off by default
  # here. tests/test-curate-auto.sh turns it back on with a temp skills checkout.
  export KINGPIN_CURATOR_AUTO=0
  # CI runners have no global git identity
  export GIT_AUTHOR_NAME=kingpin-test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=kingpin-test GIT_COMMITTER_EMAIL=test@example.com
  export TREEHOUSE_ROOT=$T/pool
  export CLAUDE_CONFIG_DIR=$T/cfg
  export GEMINI_CONFIG_DIR=$T/cfg-gemini
  # A codex spawn seeds a trusted-project entry in $CODEX_HOME/config.toml, so keep the
  # store inside the scratch tree: no suite may read the developer's global Codex skills
  # or write their config.
  export CODEX_HOME=$T/cfg-codex

  mkdir -p "$T/cfg" "$T/cfg-gemini" "$T/cfg-codex" "$KINGPIN_HOME/projects" "$KINGPIN_HOME/tasks"
  echo '{"projects":{}}' > "$T/cfg/.claude.json"
  echo '{"trustedWorkspaces":[]}' > "$T/cfg-gemini/settings.json"

  KP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  KP_BIN="$KP_ROOT/bin"

  # Set up isolated private tmux servers: a private TMUX_TMPDIR plus the fleet's own
  # socket name (issue #142), so the run never reaches the user's real `kingpin`
  # server. A bare `tmux` call in a suite lands on the fleet server, which is the
  # socket a task record from `kingpin spawn` names; a suite that needs a second
  # server names it with an explicit `-L`, which wins because it comes last.
  # The wrapper names the fleet socket at call time rather than baking it in: a spawn
  # branch unsets KINGPIN_TMUX_SOCKET to reach the config and caller paths, and a bare
  # `tmux` must still land on the suite's fleet server. A `-S` path passed by
  # lib/tmux.sh wins over the wrapper's `-L`, because it comes after it.
  export TMUX_TMPDIR="$T/tmux-tmp"
  mkdir -p "$TMUX_TMPDIR" "$T/bin"
  TEST_SOCKET="kingpin-test-$suite-$$"
  export KINGPIN_TMUX_SOCKET=kingpin
  REAL_TMUX=$(command -v tmux)
  cat > "$T/bin/tmux" << EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "\${KINGPIN_TMUX_SOCKET:-kingpin}" "\$@"
EOF
  chmod +x "$T/bin/tmux"
  export PATH="$T/bin:$PATH"
  # The fake `herdr` rides in the same directory, so no suite resolves the real
  # binary by accident and every call is recorded (issue #144).
  kp_test_install_fake_herdr
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
  tmux display-message -p '#{socket_path}' | grep -qF "$TMUX_TMPDIR/" || { echo "kp_test_setup: tmux is not on the private socket directory" >&2; exit 1; }

  # Worker stand-in: an idle shell.
  cat > "$T/fake-worker" << 'F'
#!/usr/bin/env bash
exec bash
F
  chmod +x "$T/fake-worker"
  export KINGPIN_AGY=$T/fake-worker

  # No suite reaches the real Lavish server by omission (issue #129): the default stub
  # records each call, so kp_test_finish can fail on one the suite did not declare.
  kp_test_stub_lavish

  # ...and none reaches it by unsetting or overriding KINGPIN_LAVISH: $T/bin is first
  # on PATH for the whole run, so a `lavish-axi` resolved there lands here, is recorded,
  # and exits 1. kp_test_finish fails on a non-empty log and names every argument.
  : > "$KP_TEST_LAVISH_REAL_LOG"
  cat > "$T/bin/lavish-axi" << 'LAVEOF'
#!/usr/bin/env bash
# kp_test_setup: a suite reached the real lavish-axi. Record it and refuse the call.
printf '%s\n' "$*" >> "${KP_TEST_LAVISH_REAL_LOG:?kp_test_setup: KP_TEST_LAVISH_REAL_LOG is unset}"
echo "lavish-axi: refusing a real call from a test suite" >&2
exit 1
LAVEOF
  chmod +x "$T/bin/lavish-axi"
  # A `merged: pr=<url>` fixture makes the supervisor and `kingpin done` read that pull
  # request's checks through gh (issue #221). The default gh fails, so no suite reaches
  # the network with a made-up URL; the read records UNREADABLE and writes no status
  # line. A suite that cares about gh installs its own over this one.
  cat > "$T/bin/gh" << 'GHEOF'
#!/usr/bin/env bash
exit 1
GHEOF
  chmod +x "$T/bin/gh"
  KP_TEST_LAVISH_CALLS_PATTERNS=()
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
  "$REAL_TMUX" -L "$KINGPIN_TMUX_SOCKET" kill-server 2>/dev/null || true
  "$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$T"
}

# kp_test_install_fake_herdr: install $T/bin/herdr, a recording fake of the herdr
# CLI (issue #144). It answers every verb lib/mux-herdr.sh uses from the state a
# suite declares with kp_test_fake_herdr_state, records each call's argv in
# $KP_TEST_HERDR_CALLS, and refuses to answer at all until a suite declares that
# state, so a suite that reaches herdr by accident fails instead of passing on a
# guess. The real binary is never on PATH during a suite; $T/bin/herdr-real runs
# it for the one opt-in suite, records the call in $KP_TEST_HERDR_REAL_LOG, and
# kp_test_finish fails on such a call unless the suite declares it.
kp_test_install_fake_herdr() {
  KP_TEST_REAL_HERDR=$(command -v herdr 2>/dev/null || true)
  export KP_TEST_REAL_HERDR
  : > "$KP_TEST_HERDR_CALLS"
  : > "$KP_TEST_HERDR_REAL_LOG"
  cat > "$T/bin/herdr-fake.cjs" << 'HERDREOF'
#!/usr/bin/env node
// The recording fake `herdr` (tests/lib.sh, issue #144). It imitates the CLI's
// observed contract, not the socket: JSON on stdout for the read verbs, plain
// text for `pane read`, silence for `pane run`/`send-text`/`send-keys`, and JSON
// on stderr with exit 1 for an error. Its world is a directory:
//   panes.tsv            pane_id<TAB>label<TAB>revision
//   read/<pane-id>       the text `pane read` prints
//   process/<pane-id>.json  the `pane process-info` result
//   down                 present means the server is not running
const fs = require("fs");
const path = require("path");

const stateDir = process.env.KP_TEST_HERDR_STATE;
if (!stateDir) {
  process.stderr.write("fake herdr: KP_TEST_HERDR_STATE is unset; call kp_test_fake_herdr_state in the suite\n");
  process.exit(1);
}

let args = process.argv.slice(2);
let session = process.env.HERDR_SESSION || "kingpin";
if (args[0] === "--session") {
  session = args[1] || "";
  args = args.slice(2);
}

const statePath = (rel) => path.join(stateDir, rel);
const down = () => fs.existsSync(statePath("down"));

function allPanes() {
  const file = statePath("panes.tsv");
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => {
    const parts = line.split("\t");
    const paneId = parts[0];
    const workspace = paneId.split(":")[0];
    return {
      agent_status: "unknown",
      pane_id: paneId,
      // herdr 0.9.3 prints `"label": null` for a pane without a label, so the
      // fake does too; a suite must be able to catch a null that is read as text.
      label: parts[1] === "" || parts[1] === undefined ? null : parts[1],
      revision: Number(parts[2] || 0),
      tab_id: workspace + ":t1",
      workspace_id: workspace
    };
  });
}

function panes() {
  return allPanes();
}

function workspaces() {
  const seen = new Map();
  for (const pane of allPanes()) {
    seen.set(pane.workspace_id, {
      workspace_id: pane.workspace_id,
      label: pane.workspace_id,
      number: seen.size + 1,
      agent_status: "unknown",
      pane_count: 1,
      tab_count: 1
    });
  }
  return Array.from(seen.values());
}

function paneInfo(paneId) {
  const pane = panes().find((p) => p.pane_id === paneId);
  if (!pane) {
    process.stderr.write(JSON.stringify({ id: "cli:pane:get", error: { code: "pane_not_found", message: "pane " + paneId + " not found" } }) + "\n");
    process.exit(1);
  }
  return pane;
}

function out(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

function setLabel(paneId, label) {
  const file = statePath("panes.tsv");
  const rows = fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean) : [];
  const next = rows.filter((row) => row.split("\t")[0] !== paneId);
  const old = rows.find((row) => row.split("\t")[0] === paneId);
  const revision = Number((old && old.split("\t")[2]) || 0) + 1;
  next.push([paneId, label, revision].join("\t"));
  fs.writeFileSync(file, next.join("\n") + "\n");
}

function closePane(paneId) {
  const file = statePath("panes.tsv");
  const rows = fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean) : [];
  const next = rows.filter((row) => row.split("\t")[0] !== paneId);
  fs.writeFileSync(file, next.length ? next.join("\n") + "\n" : "");
  for (const rel of [path.join("read", paneId), path.join("process", paneId + ".json")]) {
    try { fs.unlinkSync(statePath(rel)); } catch (e) { /* not there */ }
  }
}

function serverDown(id) {
  process.stderr.write(JSON.stringify({
    id: id || "cli:api:snapshot",
    error: { code: "server_not_running", message: "no herdr server is running for session " + session }
  }) + "\n");
  process.exit(1);
}

const group = args[0];
const verb = args[1];

if (group === "server") process.exit(0);
if (group === "session" && verb === "list") {
  out({ sessions: [{ name: session, running: !down() }] });
  process.exit(0);
}
if (group === "api" && verb === "snapshot") {
  if (down()) serverDown();
  out({ id: "cli:api:snapshot", result: { type: "snapshot", snapshot: {
    version: "0.9.3",
    protocol: 22,
    panes: panes(),
    tabs: [],
    workspaces: workspaces()
  } } });
  process.exit(0);
}
if (group === "workspace" && verb === "list") {
  if (down()) serverDown();
  out({ id: "cli:workspace:list", result: { type: "workspace_list", workspaces: workspaces() } });
  process.exit(0);
}

if (group === "pane") {
  // Every pane verb names the server first: a stopped session answers
  // `server_not_running`, as the real binary does, rather than "no such pane".
  if (down()) serverDown("cli:pane:" + verb);
  switch (verb) {
    case "list":
      out({ id: "cli:pane:list", result: { type: "pane_list", panes: panes() } });
      break;
    case "get":
      out({ id: "cli:pane:get", result: { type: "pane_info", pane: paneInfo(args[2]) } });
      break;
    case "read": {
      paneInfo(args[2]);
      const file = statePath(path.join("read", args[2]));
      process.stdout.write(fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "");
      break;
    }
    case "send-text":
    case "send-keys":
    case "run":
      paneInfo(args[2]);
      break;
    case "rename": {
      paneInfo(args[2]);
      setLabel(args[2], args.slice(3).join(" "));
      out({ id: "cli:pane:rename", result: { type: "pane_info", pane: paneInfo(args[2]) } });
      break;
    }
    case "close":
      paneInfo(args[2]);
      closePane(args[2]);
      out({ id: "cli:pane:close", result: { type: "ok" } });
      break;
    case "process-info": {
      const paneId = args[2] === "--pane" ? args[3] : args[2];
      paneInfo(paneId);
      const file = statePath(path.join("process", paneId + ".json"));
      if (fs.existsSync(file)) {
        process.stdout.write(fs.readFileSync(file, "utf8"));
      } else {
        out({ id: "cli:pane:process_info", result: { type: "pane_process_info", process_info: {
          pane_id: paneId,
          shell_pid: 1,
          foreground_processes: [{ argv: ["bash"], name: "bash", pid: 1 }]
        } } });
      }
      break;
    }
    default:
      process.stderr.write("fake herdr: unsupported pane command: " + verb + "\n");
      process.exit(1);
  }
  process.exit(0);
}

process.stderr.write("fake herdr: unsupported command: " + args.join(" ") + "\n");
process.exit(1);
HERDREOF
  cat > "$T/bin/herdr" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${KP_TEST_HERDR_CALLS:?kp_test_install_fake_herdr: KP_TEST_HERDR_CALLS is unset}"
exec node "$T/bin/herdr-fake.cjs" "\$@"
EOF
  chmod +x "$T/bin/herdr"
  cat > "$T/bin/herdr-real" << EOF
#!/usr/bin/env bash
# Runs the real herdr for the one opt-in suite; every call is recorded so a second
# suite cannot reach it unnoticed.
printf '%s\n' "\$*" >> "\${KP_TEST_HERDR_REAL_LOG:?kp_test_install_fake_herdr: KP_TEST_HERDR_REAL_LOG is unset}"
exec "\${KP_TEST_REAL_HERDR:?kp_test_install_fake_herdr: no real herdr was found}" "\$@"
EOF
  chmod +x "$T/bin/herdr-real"
}

# kp_test_allow_real_herdr: declare that this suite drives the real Herdr binary
# through $T/bin/herdr-real, which is what stops kp_test_finish failing on its log.
kp_test_allow_real_herdr() {
  export KP_TEST_ALLOW_REAL_HERDR=1
}

# kp_test_check_herdr_real: return 1 and name every recorded argument when the
# suite reached the real herdr binary without declaring it.
kp_test_check_herdr_real() {
  local log=${KP_TEST_HERDR_REAL_LOG:-} line
  [ "${KP_TEST_ALLOW_REAL_HERDR:-0}" = "1" ] && return 0
  [ -n "$log" ] && [ -s "$log" ] || return 0
  echo "FAIL: a real herdr ran during this suite; a suite must reach the fake on PATH, so check for a hard-coded binary path:" >&2
  while IFS= read -r line; do
    printf '  herdr %s\n' "$line" >&2
  done < "$log"
  return 1
}

# kp_test_fake_herdr_state: declare the fake herdr's world and reset it. A suite
# that drives lib/mux.sh in herdr mode calls this first; the fake refuses to answer
# until it does, so a forgotten declaration is a failure, not a silent pass.
kp_test_fake_herdr_state() {
  export KP_TEST_HERDR_STATE=$T/herdr-state
  rm -rf "$KP_TEST_HERDR_STATE"
  mkdir -p "$KP_TEST_HERDR_STATE/read" "$KP_TEST_HERDR_STATE/process"
  : > "$KP_TEST_HERDR_STATE/panes.tsv"
  : > "$KP_TEST_HERDR_CALLS"
}

# kp_test_herdr_pane <pane-id> [label] [revision]: add or replace one pane in the
# fake's inventory.
kp_test_herdr_pane() {
  local id=${1:?} label=${2-} revision=${3:-1} file tmp
  file=$KP_TEST_HERDR_STATE/panes.tsv
  tmp=$file.tmp
  [ -f "$file" ] || : > "$file"
  awk -F '\t' -v id="$id" '$1 != id' "$file" > "$tmp"
  printf '%s\t%s\t%s\n' "$id" "$label" "$revision" >> "$tmp"
  mv "$tmp" "$file"
}

# kp_test_herdr_pane_remove <pane-id>: drop one pane, as `pane close` does.
kp_test_herdr_pane_remove() {
  local id=${1:?} file tmp
  file=$KP_TEST_HERDR_STATE/panes.tsv
  tmp=$file.tmp
  [ -f "$file" ] || return 0
  awk -F '\t' -v id="$id" '$1 != id' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# kp_test_herdr_read <pane-id> <text>: set what `pane read` prints for a pane.
kp_test_herdr_read() {
  printf '%s\n' "${2-}" > "$KP_TEST_HERDR_STATE/read/${1:?}"
}

# kp_test_herdr_process <pane-id> <pid> [argv0]: set a pane's process info.
kp_test_herdr_process() {
  local id=${1:?} pid=${2:-1} argv=${3:-bash}
  printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[{"argv":["%s"],"name":"%s","pid":%s}]}}}\n' \
    "$id" "$pid" "$argv" "$(basename "$argv")" "$pid" > "$KP_TEST_HERDR_STATE/process/$id.json"
}

# kp_test_herdr_down / kp_test_herdr_up: make the fake's server unreachable, then
# reachable again.
kp_test_herdr_down() { : > "$KP_TEST_HERDR_STATE/down"; }
kp_test_herdr_up() { rm -f "$KP_TEST_HERDR_STATE/down"; }

# kp_test_project: register the demo-auto project the way test-lifecycle.sh does, without assertions.
kp_test_project() {
  "$KP_BIN/kingpin" init demo-auto "$T/proj" --harness agy --setup "echo setup" >/dev/null
}

# kp_test_stub_lavish: the suite-wide stand-in for lavish-axi, installed by kp_test_setup.
# `poll` idles and every other call answers OK without touching a session, so no dossier
# reaches Lavish's state and no browser opens; each call's argv is appended to
# $KP_TEST_LAVISH_CALLS_LOG. Re-calling it is safe (the file is written only when missing),
# so a suite that overrode KINGPIN_LAVISH with its own mock can put the default back.
kp_test_stub_lavish() {
  if [ ! -x "$T/mock-lavish-quiet" ]; then
    cat > "$T/mock-lavish-quiet" << 'MLEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KP_TEST_LAVISH_CALLS_LOG:?kp_test_stub_lavish: KP_TEST_LAVISH_CALLS_LOG is unset}"
case "${1:-}" in
  poll) sleep 0.2 ;;
  *) echo "OK" ;;
esac
MLEOF
    chmod +x "$T/mock-lavish-quiet"
  fi
  export KINGPIN_LAVISH="$T/mock-lavish-quiet"
}

# kp_test_expect_lavish_calls [pattern...]: declare that this suite drives the default
# stub on purpose (it runs a listener, or kingpin-done against a report.html). Without
# this, kp_test_finish fails when the stub recorded any call: a call no suite declared
# is the leak issue #129 describes, not noise to be ignored. The declaration is checked
# in turn, so it cannot switch the guard off for good: the log must grow after this call,
# and when patterns are given every recorded line must match one of them (a shell glob,
# so a suite that drives the stub for one task keeps the guard armed for the rest).
kp_test_expect_lavish_calls() {
  export KP_TEST_LAVISH_CALLS_EXPECTED=1
  export KP_TEST_LAVISH_CALLS_BASELINE
  KP_TEST_LAVISH_CALLS_BASELINE=$(kp_test_lavish_count "${KP_TEST_LAVISH_CALLS_LOG:-}")
  KP_TEST_LAVISH_CALLS_PATTERNS=("$@")
}

# kp_test_lavish_count <log>: the number of calls recorded in <log>, or 0.
kp_test_lavish_count() {
  local log=${1:-}
  [ -n "$log" ] && [ -f "$log" ] || { echo 0; return 0; }
  wc -l < "$log" | tr -d ' '
}

# kp_test_check_lavish_calls: return 1 and name every recorded argument when the suite
# reached a real lavish-axi, when the default stub was called and the suite did not
# declare it expects calls, when a declaration recorded nothing, or when a declared call
# does not match the patterns it gave. kp_test_finish runs it; a suite also tests it
# directly, which is how the failure path stays covered.
kp_test_check_lavish_calls() {
  local log=${KP_TEST_LAVISH_CALLS_LOG:-} real=${KP_TEST_LAVISH_REAL_LOG:-}
  local line count baseline pattern matched rc=0
  if [ -n "$real" ] && [ -s "$real" ]; then
    echo "FAIL: a real lavish-axi ran during this suite; a suite must reach the default stub, so check for an unset or overridden KINGPIN_LAVISH:" >&2
    while IFS= read -r line; do
      printf '  lavish-axi %s\n' "$line" >&2
    done < "$real"
    rc=1
  fi
  if [ "${KP_TEST_LAVISH_CALLS_EXPECTED:-0}" = "1" ]; then
    count=$(kp_test_lavish_count "$log")
    baseline=${KP_TEST_LAVISH_CALLS_BASELINE:-0}
    if [ "$count" -le "$baseline" ]; then
      echo "FAIL: kp_test_expect_lavish_calls declared default-stub calls, but the stub recorded none after the declaration (baseline $baseline, now $count)" >&2
      return 1
    fi
    if [ "${#KP_TEST_LAVISH_CALLS_PATTERNS[@]}" -gt 0 ]; then
      while IFS= read -r line; do
        matched=0
        for pattern in "${KP_TEST_LAVISH_CALLS_PATTERNS[@]}"; do
          # shellcheck disable=SC2254 # the declaration passes shell globs on purpose
          case "$line" in $pattern) matched=1; break ;; esac
        done
        if [ "$matched" -eq 0 ]; then
          echo "FAIL: the default lavish-axi stub recorded a call that matches none of the patterns this suite declared: $line" >&2
          rc=1
        fi
      done < "$log"
    fi
    return "$rc"
  fi
  [ -n "$log" ] && [ -s "$log" ] || return "$rc"
  echo "FAIL: the default lavish-axi stub recorded calls this suite did not declare (call kp_test_expect_lavish_calls if they are intended):" >&2
  while IFS= read -r line; do
    printf '  lavish-axi %s\n' "$line" >&2
  done < "$log"
  return 1
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
  kp_test_check_lavish_calls || FAILED=1
  kp_test_check_herdr_real || FAILED=1
  if [ "$FAILED" -eq 0 ]; then
    echo "ALL $1 TESTS PASSED"
  else
    echo "$1 TESTS FAILED"
    exit 1
  fi
}
