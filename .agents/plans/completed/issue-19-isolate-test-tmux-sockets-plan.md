# Plan: Isolate test suite tmux operations using private tmux sockets

## Summary

Test suites (`tests/test-automation.sh`, `tests/test-acceptance.sh`, `tests/test-harnesses.sh`) interact directly with tmux, creating, inspecting, and terminating sessions named `kingpin` and killing tmux windows. On unfixed HEAD, these operations target the default ambient tmux server (`/tmp/tmux-$(id -u)/default`), destroying the orchestrator session, killing worker windows, and terminating active AI agents when tests run. We isolate all tmux operations across the test suites by configuring each test script with a dedicated `TMUX_TMPDIR` directory under its temporary workspace (`$T/tmux-tmp`), a unique socket name (`kingpin-test-<suite>-$$`), and a lightweight `tmux` wrapper in `$T/bin/tmux` prepended to `PATH`. This ensures all `tmux` calls from the test script, subshells, Python subprocesses (`bin/kingpin-board`), and Kingpin commands (`bin/kingpin-spawn`, `bin/kingpin-wait`, `bin/kingpin-done`, `bin/kingpin-send`, `bin/kingpin-curate`) route exclusively to the private socket. A test assertion verifies that tmux runs on the private socket (`#{socket_path}` contains the private socket name); the suites never probe the ambient default server (an earlier `-L default has-session` probe was removed in review because it inspects the ambient server and fails on hosts with a real `kingpin` session). An `EXIT` trap guarantees the private tmux server process is killed (`tmux kill-server`) and temporary socket files removed even if a test exits early or fails. A complete prototype patch has been validated against all three test suites and saved at `.agents/plans/issue-19-isolate-test-tmux-sockets-prototype.patch`.

## User Story

As a Kingpin developer and agent worker
I want the test suites to run inside isolated private tmux sockets
So that running test verification never interferes with, modifies, or destroys ambient tmux sessions, running orchestrators, or active agent workers.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | MEDIUM |
| Systems Affected | `tests/test-automation.sh`, `tests/test-acceptance.sh`, `tests/test-harnesses.sh` |
| GitHub Issue | #19 |
| PRD Phase | N/A |
| Prototype Patch | `.agents/plans/issue-19-isolate-test-tmux-sockets-prototype.patch` |

---

## Patterns to Follow

All citations below reference lines on HEAD before patch application.

### Naming & Temporary Directory Setup
```bash
// SOURCE: tests/test-automation.sh:7-16
T=$(mktemp -d)
export KINGPIN_HOME=$T/kp
export TREEHOUSE_ROOT=$T/pool
export CLAUDE_CONFIG_DIR=$T/cfg
export GEMINI_CONFIG_DIR=$T/cfg-gemini

mkdir -p "$T/cfg" "$T/cfg-gemini" "$KINGPIN_HOME/projects" "$KINGPIN_HOME/tasks"
echo '{"projects":{}}' > "$T/cfg/.claude.json"
echo '{"trustedWorkspaces":[]}' > "$T/cfg-gemini/settings.json"
```

### Error Handling & Pass/Fail Reporting
```bash
// SOURCE: tests/test-automation.sh:17-19
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0
```

### Tmux Socket & Session Inspection
```bash
// SOURCE: tests/test-automation.sh:147-150
tmux new-session -d -s kp-test-active -n home
active_sid=$(tmux display-message -p -t kp-test-active '#{session_id}' | tr -d '$')
tmux_sock=$(tmux display-message -p '#{socket_path}' 2>/dev/null || echo "/tmp/tmux-$(id -u)/default")
mock_tmux="$tmux_sock,$$,$active_sid"
```

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `tests/test-automation.sh` | UPDATE | Configure isolated `TMUX_TMPDIR`, independent socket name `kingpin-test-auto-$$`, `$T/bin/tmux` wrapper, EXIT trap server teardown, and a private-socket assertion (covered by prototype patch) |
| `tests/test-harnesses.sh` | UPDATE | Configure isolated `TMUX_TMPDIR`, independent socket name `kingpin-test-harnesses-$$`, `$T/bin/tmux` wrapper, EXIT trap server teardown, and a private-socket assertion (covered by prototype patch) |
| `tests/test-acceptance.sh` | UPDATE | Configure isolated `TMUX_TMPDIR`, independent socket name `kingpin-test-acceptance-$$`, `$T/bin/tmux` wrapper, EXIT trap server teardown and `bin/kingpin-send` recovery, and a private-socket assertion (covered by prototype patch) |

---

## Tasks

Execute in order. Each task is atomic and verifiable. The prototype patch is applied by `/implement` before tasks execute.

### Task 1: Isolate tmux in `tests/test-automation.sh` and assert the private socket is in use

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**:
  - Export `TMUX_TMPDIR="$T/tmux-tmp"` and create directory `$TMUX_TMPDIR` and wrapper directory `$T/bin`.
  - Define `TEST_SOCKET="kingpin-test-auto-$$"`.
  - Resolve real tmux executable path with `REAL_TMUX=$(command -v tmux)`.
  - Generate wrapper script at `$T/bin/tmux` executing `exec "$REAL_TMUX" -L "$TEST_SOCKET" "$@"` and make executable.
  - Prepend `$T/bin` to `PATH`.
  - Register `cleanup()` function on `trap cleanup EXIT` that executes `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true` and `rm -rf "$T"`.
  - After creating the initial `kingpin` session, assert that `tmux display-message -p '#{socket_path}'` contains `$TEST_SOCKET`.
  - Replace final manual `tmux kill-session` and `rm -rf "$T"` with `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true` (handled cleanly by trap).
- **Mirror**: `tests/test-automation.sh:7-19`
- **Validate**: `./tests/test-automation.sh`

### Task 2: Isolate tmux in `tests/test-harnesses.sh` and assert the private socket is in use

- **File**: `tests/test-harnesses.sh`
- **Action**: UPDATE
- **Implement**:
  - Export `TMUX_TMPDIR="$T/tmux-tmp"` and create directory `$TMUX_TMPDIR` and wrapper directory `$T/bin`.
  - Define `TEST_SOCKET="kingpin-test-harnesses-$$"`.
  - Resolve real tmux executable path with `REAL_TMUX=$(command -v tmux)`.
  - Generate wrapper script at `$T/bin/tmux` executing `exec "$REAL_TMUX" -L "$TEST_SOCKET" "$@"` and make executable.
  - Prepend `$T/bin` to `PATH`.
  - Register `cleanup()` function on `trap cleanup EXIT` that executes `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true` and `rm -rf "$T"`.
  - After creating the initial `kingpin` session, assert that `tmux display-message -p '#{socket_path}'` contains `$TEST_SOCKET`.
  - Replace final manual `tmux kill-session` and `rm -rf "$T"` with `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true`.
- **Mirror**: `tests/test-harnesses.sh:7-19`
- **Validate**: `./tests/test-harnesses.sh`

### Task 3: Isolate tmux in `tests/test-acceptance.sh` and assert the private socket is in use

- **File**: `tests/test-acceptance.sh`
- **Action**: UPDATE
- **Implement**:
  - Export `TMUX_TMPDIR="$T/tmux-tmp"` and create directory `$TMUX_TMPDIR` and wrapper directory `$T/bin`.
  - Define `TEST_SOCKET="kingpin-test-acceptance-$$"`.
  - Resolve real tmux executable path with `REAL_TMUX=$(command -v tmux)`.
  - Generate wrapper script at `$T/bin/tmux` executing `exec "$REAL_TMUX" -L "$TEST_SOCKET" "$@"` and make executable.
  - Prepend `$T/bin` to `PATH`.
  - Register `cleanup()` function on `trap cleanup EXIT` restoring `bin/kingpin-send` via `git -C "$KP_ROOT" checkout bin/kingpin-send >/dev/null 2>&1 || true`, killing the test server via `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true`, and deleting `$T`.
  - After creating the initial `kingpin` session, assert that `tmux display-message -p '#{socket_path}'` contains `$TEST_SOCKET`.
  - Replace final manual `tmux kill-session` and `rm -rf "$T"` with `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server 2>/dev/null || true`.
- **Mirror**: `tests/test-acceptance.sh:7-19`
- **Validate**: `./tests/test-acceptance.sh`

---

## Validation

```bash
# Type check / Syntax
bash -n bin/* tests/*.sh

# Full test suite
./tests/test-harnesses.sh
./tests/test-automation.sh
./tests/test-acceptance.sh

# Reproduction (BUG_FIX): On unfixed HEAD, test scripts run against default socket.
# Verify reproduction command red on unfixed code (inspects default socket) vs green after fix:
bash -c '
REAL_TMUX=$(command -v tmux)
"$REAL_TMUX" -L default list-sessions 2>/dev/null || true
'
```

## End-to-End Verification

1. Inspect ambient tmux sessions before test execution:
   `tmux list-sessions`
   Record all active sessions (e.g. `sesh-1`).
2. Run all three test suites:
   `./tests/test-harnesses.sh`
   `./tests/test-automation.sh`
   `./tests/test-acceptance.sh`
   Confirm every suite reports all tests passing, including explicit passes for:
   - `PASS: test operates on private tmux socket`
3. Inspect ambient tmux sessions after running all test suites:
   `tmux list-sessions`
   Verify that all pre-existing sessions (e.g. `sesh-1`) and their respective windows are 100% intact, and no session named `kingpin` exists on the ambient default server.
4. Verify that no lingering test sockets remain under `/tmp` or `$TMUX_TMPDIR`:
   `ls -ld /tmp/tmux-$(id -u)/kingpin-test-* 2>/dev/null || true` returns nothing.

## Risks

| Risk | Mitigation | Scope |
|------|------------|-------|
| Test scripts fail midway or receive `SIGINT`/`SIGTERM`, leaving background test tmux daemons running | Register `trap cleanup EXIT` in each test script, invoking `kill-server` on the specific `$TEST_SOCKET` and removing `$T` on any exit | In Scope |
| `bin/kingpin-board` (Python) invokes `tmux` as a separate process and might bypass shell functions/aliases | Place a physical executable wrapper at `$T/bin/tmux` and export `PATH="$T/bin:$PATH"` so Python `subprocess.run(["tmux", ...])` executes the wrapper | In Scope |
| Test 5 in `test-automation.sh` tests `TMUX` targeting by setting `mock_tmux="$tmux_sock,$$,$active_sid"` | The wrapper passes `-L "$TEST_SOCKET"`, which points to the same isolated test server; `tmux display-message -p '#{socket_path}'` dynamically provides the isolated socket path | In Scope |
| `tests/test-acceptance.sh` overrides `bin/kingpin-send` during landing queue simulation | Ensure `cleanup()` explicitly restores `bin/kingpin-send` via `git checkout` upon EXIT so uncommitted file modifications never linger on test failure | In Scope |

## Open Questions

None. The acceptance criteria and mechanism are fully specified and validated by prototype.

## Acceptance Criteria

- [ ] All test scripts in `tests/` operate on an isolated private tmux socket (`tmux -L kingpin-test-...` or a temporary socket directory) with an independent socket name.
- [ ] Running `./tests/test-*.sh` never modifies, inspects, or kills sessions on the ambient default tmux server.
- [ ] Test cleanup cleanly destroys only its own private test socket and temporary socket files.
- [ ] All test suites (`test-harnesses.sh`, `test-automation.sh`, `test-acceptance.sh`) pass 100% green.
- [ ] Bash syntax check `bash -n bin/* tests/*.sh` passes.
