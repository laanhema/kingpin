# Plan: Wake the Orchestrator on Worker Events with a Background kingpin-wait

## Summary

This plan implements event-driven orchestration in Kingpin by transforming `bin/kingpin-wait` into a blocking event waiter, introducing `bin/kingpin-ack` for explicit event acknowledgment, exposing `ack` and `wait` through the `bin/kingpin` CLI, and updating `AGENTS.md` so the orchestrator runs exactly one background `kingpin-wait` process whenever tasks are live. Currently, the orchestrator only discovers worker state changes (such as ready for review, needs input, or unexpected exit) when manually polled via `kingpin list` or user prompts. With this change, `bin/kingpin-wait` blocks until a new task event occurs (status change, quiet worker, or unexpected exit), outputs `<task-id> <reason>` lines, and exits 0 within 5 seconds of an event. The orchestrator is woken by the process exit, inspects the task's state files (which `AGENTS.md` now explicitly permits reading), acts or prompts the boss, acknowledges the event with `bin/kingpin ack <task-id>` to advance `seen` counters, and re-arms the background wait.

## User Story

As the Kingpin orchestrator
I want to run a background `kingpin-wait` that terminates and returns an event line whenever a worker needs input or reaches a reviewable/terminal state
So that I can immediately respond to worker events without requiring manual polling or leaving workers waiting idle.

## Metadata

| Field | Value |
|---|---|
| Type | ENHANCEMENT |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-wait`, `bin/kingpin-ack`, `bin/kingpin`, `bin/kingpin-watch`, `AGENTS.md`, `tests/test-automation.sh` |
| GitHub Issue | #4 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Patterns to Follow

### Naming

Standard Kingpin script root and environment variable resolution:

```bash
// SOURCE: bin/kingpin-watch:13-15
KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}
KP_BIN="$KP_ROOT/bin"
```

### Error Handling

Standard CLI argument parsing and error reporting:

```bash
// SOURCE: bin/kingpin-wait:19-29
while [ $# -gt 0 ]; do
  case $1 in
    --timeout) TIMEOUT=${2:?--timeout needs seconds}; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help)
      echo "usage: kingpin-wait [--timeout <seconds>] [--once]"
      exit 0
      ;;
    *) echo "kingpin-wait: unknown argument $1" >&2; exit 2 ;;
  esac
done
```

Subcommand dispatch pattern in unified CLI:

```bash
// SOURCE: bin/kingpin:49-55
case "$cmd" in
  init)
    exec "$KP_BIN/kingpin-init" "$@"
    ;;
  spawn)
    exec "$KP_BIN/kingpin-spawn" "$@"
    ;;
```

### Tests

Assertion pattern with isolated test directories:

```bash
// SOURCE: tests/test-automation.sh:17-19
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0
```

---

## Files to Change

| File | Action | Purpose |
|---|---|---|
| `bin/kingpin-ack` | CREATE | Dedicated command to advance `seen` status count, `seen_stopped` timestamp, and `seen_exited` marker for given task IDs or `--all` |
| `bin/kingpin` | UPDATE | Expose `ack` and `wait` subcommands in CLI dispatch and usage help |
| `bin/kingpin-wait` | UPDATE | Implement polling loop with bounded inotifywait / sleep intervals and `seen_exited` suppression so `kingpin-wait` blocks until an event occurs or timeout |
| `bin/kingpin-watch` | UPDATE | Delegate event acknowledgment to `kingpin-ack` (or synchronize `seen_exited`) in `process_task_event` |
| `AGENTS.md` | UPDATE | Permit orchestrator to read `~/.kingpin/tasks/<id>/` files directly, mandate keeping one background `kingpin-wait` running when tasks are live, and document the wake-ack-rearm lifecycle |
| `tests/test-automation.sh` | UPDATE | Add Test 6 verifying blocking wait wake under 5s, single delivery after ack, and quiet/exit event acking |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Create `bin/kingpin-ack`

- **File**: `bin/kingpin-ack`
- **Action**: CREATE
- **Implement**: Create an executable Bash script that accepts `<task-id>...` or `--all`. For each specified task directory under `$KP_HOME/tasks/<task-id>`:
  1. If `status` exists, count lines and write to `seen`: `wc -l < "$status_file" | tr -d ' ' > "$task_dir/seen"`.
  2. If `stopped` exists, read timestamp and write to `seen_stopped`: `cat "$stopped_file" 2>/dev/null | tr -d ' ' > "$task_dir/seen_stopped"`.
  3. If the task's tmux window is no longer alive, touch `seen_exited`: `touch "$task_dir/seen_exited"`.
  Make the file executable (`chmod +x bin/kingpin-ack`).
- **Mirror**: `bin/kingpin-send:1-35`
- **Validate**: `./bin/kingpin-ack -h` prints usage and exits 0 or 2.

### Task 2: Register `ack` and `wait` in `bin/kingpin`

- **File**: `bin/kingpin`
- **Action**: UPDATE
- **Implement**:
  1. Add `ack` and `wait` to the `Commands:` listing in `usage()`.
  2. In `case "$cmd" in`, add:
     ```bash
     ack)
       exec "$KP_BIN/kingpin-ack" "$@"
       ;;
     wait)
       exec "$KP_BIN/kingpin-wait" "$@"
       ;;
     ```
- **Mirror**: `bin/kingpin:49-76`
- **Validate**: `./bin/kingpin --help` displays `ack` and `wait` commands.

### Task 3: Update `bin/kingpin-wait` with loop-based blocking wait and `seen_exited` suppression

- **File**: `bin/kingpin-wait`
- **Action**: UPDATE
- **Implement**:
  1. In `check_task`: check `seen_exited_file="$dir/seen_exited"`. When `window_alive -eq 0` and task is not in terminal status, only emit `$id exited` if `[ ! -f "$seen_exited_file" ]`.
  2. In the wait logic (replacing lines 158-178), implement a loop:
     ```bash
     start_time=$(date +%s)
     while true; do
       if check_all; then
         exit 0
       fi

       if [ "$ONCE" -eq 1 ]; then
         exit 1
       fi

       now=$(date +%s)
       elapsed=$((now - start_time))
       if [ "$elapsed" -ge "$TIMEOUT" ]; then
         exit 1
       fi

       remaining=$((TIMEOUT - elapsed))
       step=2
       [ "$remaining" -lt "$step" ] && step="$remaining"
       [ "$step" -le 0 ] && exit 1

       if command -v inotifywait >/dev/null 2>&1; then
         inotifywait -q -r -e modify,create,delete,attrib -t "$step" "$tasks_dir" >/dev/null 2>&1 || true
       else
         sleep "$step"
       fi
     done
     ```
- **Mirror**: `bin/kingpin-wait:144-178`
- **Validate**: `./bin/kingpin-wait --once` exits 0 if events exist, or exits 1 immediately when fleet is quiet.

### Task 4: Integrate `kingpin-ack` into `bin/kingpin-watch`

- **File**: `bin/kingpin-watch`
- **Action**: UPDATE
- **Implement**: In `process_task_event`, invoke `"$KP_BIN/kingpin-ack" "$id"` to advance `seen`, `seen_stopped`, and `seen_exited` uniformly across all entrypoints.
- **Mirror**: `bin/kingpin-watch:48-62`
- **Validate**: `./tests/test-automation.sh` Test 3 (watch auto-lifecycle) passes.

### Task 5: Update `AGENTS.md` orchestrator contract

- **File**: `AGENTS.md`
- **Action**: UPDATE
- **Implement**:
  1. Update Hard Rule 1 to allow reading task files: "Use bash only to run `kingpin` commands and read task files under `~/.kingpin/tasks/<id>/` (such as `status`, `question.md`, and `report.html`)."
  2. Add background wait mandate: "Whenever tasks are live in the fleet, keep exactly one background `bin/kingpin-wait` (or `bin/kingpin wait`) running. Never run two at once."
  3. Update "How to Handle Requests" (Spawn and Supervise sections):
     - When a task is spawned, if no background `kingpin-wait` is running, arm one.
     - When an event wakes the orchestrator, read the `<task-id>` and `<reason>`, inspect `~/.kingpin/tasks/<task-id>/status` (or `question.md`/`report.html`), handle or relay the event, acknowledge it with `bin/kingpin ack <task-id>`, and re-arm the background `bin/kingpin-wait` before completing the turn.
- **Mirror**: `AGENTS.md:15-41`
- **Validate**: Read `AGENTS.md` to confirm all 4 acceptance criteria points are represented clearly.

### Task 6: Add automated tests in `tests/test-automation.sh`

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: Add `Test 6: kingpin-wait blocking and kingpin ack single-event delivery`:
  1. Setup mock task directory `$KINGPIN_HOME/tasks/test-wait-1` with `task.env`.
  2. Ensure `kingpin-wait --once` exits 1 initially.
  3. Start `kingpin-wait` in background, verify it blocks while idle.
  4. Append a status line (`needs-input: test question`) to `status`.
  5. Measure time until background `kingpin-wait` exits; assert exit code is 0, elapsed time is < 5 seconds, and output matches `test-wait-1 status`.
  6. Verify event persists on next `kingpin-wait --once` before ack.
  7. Run `kingpin ack test-wait-1`, assert `seen` is updated.
  8. Run `kingpin-wait --once`, assert it exits 1 (event not printed again).
  9. Test `quiet` event: write to `stopped`, verify `kingpin-wait --once` reports `quiet`, ack it, verify quiet suppressed.
  10. Test `exited` event: kill window or point to dead target, verify `kingpin-wait --once` reports `exited`, ack it, verify exit suppressed.
- **Mirror**: `tests/test-automation.sh:42-57`
- **Validate**: `./tests/test-automation.sh` passes all tests including Test 6.

### Task 7: Run full test suite validation

- **File**: `tests/`
- **Action**: CHECK
- **Implement**: Run all project test suites:
  1. `./tests/test-acceptance.sh`
  2. `./tests/test-automation.sh`
  3. `./tests/test-harnesses.sh`
- **Mirror**: `tests/test-acceptance.sh:1-159`
- **Validate**: All three test scripts exit 0.

---

## Validation

```bash
# Type check / Build (N/A for Bash/Node repository)
bash -n bin/kingpin bin/kingpin-ack bin/kingpin-wait bin/kingpin-watch

# Test suite
./tests/test-acceptance.sh
./tests/test-automation.sh
./tests/test-harnesses.sh
```

## End-to-End Verification

To verify the event loop end-to-end:
1. Start a fresh task: `bin/kingpin spawn demo --text "test event loop" --id task-e2e`.
2. Start background wait: `bin/kingpin wait > /tmp/wait-out.txt & WAIT_PID=$!`.
3. Worker writes status update: `echo "ready: branch=feature review=APPROVE report=none" >> ~/.kingpin/tasks/task-e2e/status`.
4. Wait for background process to exit: `wait $WAIT_PID`. Expected exit code: `0`.
5. Verify output: `/tmp/wait-out.txt` contains `task-e2e status`.
6. Orchestrator acknowledges event: `bin/kingpin ack task-e2e`.
7. Verify subsequent wait: `bin/kingpin wait --once` exits `1` with no output.
8. Teardown: `bin/kingpin done task-e2e --force`.

## Risks

| Risk | Mitigation | Scope |
|---|---|---|
| Inotify event missed or filesystem watcher unsupported | The wait loop bounds inotifywait / sleep to 2 seconds, ensuring timely fallback checks for any misses | In-Scope |
| Infinite loop in orchestrator if `kingpin ack` is omitted | `AGENTS.md` explicitly specifies calling `bin/kingpin ack <task-id>` in the same turn an event is handled before re-arming the wait | In-Scope |
| Multiple background `kingpin-wait` processes spawned simultaneously | `AGENTS.md` explicitly warns "never run two at once" and instructs checking background tasks before arming | In-Scope |
| Unexpected worker exit triggers repeated alerts | `seen_exited` marker is tracked in the task directory and touched by `kingpin-ack`, ensuring dead window alert is emitted exactly once | In-Scope |
| Orchestrator editing repository code directly | Allowed scope in `AGENTS.md` is strictly limited to read-only access of task files in `~/.kingpin/tasks/<id>/` | In-Scope |

## Open Questions

None. The requirements in Issue #4 and technical notes are fully specified and concrete.

## Acceptance Criteria

- [ ] `bin/kingpin-wait` without `--once` blocks until at least one task event exists and prints one `<task-id> <reason>` line per event, then exits 0 (verified: test appends status line while wait runs and sees line within 5 seconds)
- [ ] An event is printed once: after the orchestrator handles it (via `kingpin ack <task-id>`), the next `kingpin-wait` run does not print it again
- [ ] `AGENTS.md` tells the orchestrator to keep one background `kingpin-wait` running whenever a task is live, to re-arm it after handling each event, and never to run two at once
- [ ] `AGENTS.md` lets the orchestrator read files under `~/.kingpin/tasks/<id>/` (`status`, `question.md`, `report.html`), not only run `kingpin` commands
- [ ] All automated tests pass (`test-acceptance.sh`, `test-automation.sh`, `test-harnesses.sh`)
