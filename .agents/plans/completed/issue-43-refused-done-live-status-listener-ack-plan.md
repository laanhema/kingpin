# Plan: Refused `kingpin done` keeps a live worker's status; stop leftover listener; ack on archived task

## Summary

`bin/kingpin-done` writes `cleanup-refused: <reason>` to a task's `status` in `refuse_cleanup` regardless of the worker's state, so a live worker's `needs-input:` (or `ready:`) is masked in `kingpin list` and `kingpin-wait`. We make `refuse_cleanup` append the line only when the task's last worker status is terminal (`merged:`, `failed:`, `cleanup-refused:`; listener notes `approved:`/`feedback:` are skipped when finding it); for a live worker it only prints the reason on stderr and exits 1. In the same finished-task branch it stops the dossier listener (the stop code moves into a function that the success path also calls), because a merged task's listener is dead weight. `bin/kingpin-ack` prints a short note and exits 0 for an id that is already in `$KP_HOME/archive`. Tests for the four acceptance criteria go into a new Test 19 in `tests/test-automation.sh`.

## User Story

As the boss supervising the fleet
I want a refused `kingpin done` not to hide what a live worker is waiting on, and no leftovers after cleanup
So that `kingpin list` is trustworthy and `kingpin ack` after `done` is not an error

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-done`, `bin/kingpin-ack`, `tests/test-automation.sh`, `README.md` |
| GitHub Issue | #43 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| Baseline `bash tests/test-automation.sh` on HEAD | `ALL AUTOMATION TESTS PASSED` |
| Success path of `kingpin-done` (`bin/kingpin-done:127-143`) | already kills the listener and removes `listener.pid` (covered by Test 11, `tests/test-automation.sh:1028-1032`); the leftover appears only when `done` refuses before reaching that block, since a refused task keeps its dir and `listener.pid` |
| `kingpin list` listener info (`bin/kingpin:131-139`) | prints `(listening: pid N)` while `listener.pid` names a live pid |
| `kingpin-ack` on missing task (`bin/kingpin-ack:84-87`) | `task not found`, exit 1, also for archived ids |

## Patterns to Follow

### Refusal
```
// SOURCE: bin/kingpin-done:56-69
refuse_cleanup() { ... echo "$line" >> "$task_dir/status" ... release_landing_lock_and_advance_queue; exit 1 }
```

### Already-archived handling
```
// SOURCE: bin/kingpin-done:15-19
if [ ! -d "$task_dir" ] && [ -d "$KP_HOME/archive/$id" ]; then
  echo "OK: task $id already cleaned up (archived)"
  exit 0
fi
```

### Tests
```
// SOURCE: tests/test-automation.sh:1028-1032
"$KP_BIN/kingpin" done task-lavish-1 --force >/dev/null
[ ! -f "$t11_task/listener.pid" ] && ... && pass "..." || fail "..."
```

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-done` | UPDATE | status append only for finished tasks; listener stop function used on refusal of a finished task and on success |
| `bin/kingpin-ack` | UPDATE | archived id: note + exit 0 |
| `tests/test-automation.sh` | UPDATE | new Test 19 covering the four criteria |
| `README.md` | UPDATE | `kingpin done` / `kingpin ack` behaviour in the command table |

## Tasks

### Task 1: Gate the refusal status line and stop the listener

- **File**: `bin/kingpin-done`
- **Action**: UPDATE
- **Implement**: Move the listener-stop block into `stop_listener()`. In `refuse_cleanup`, find the last status line that does not start with `approved:` or `feedback:`. If it matches `merged:*|failed:*|cleanup-refused:*` (finished): append the `cleanup-refused:` line (deduped against that same line) and call `stop_listener`. Otherwise (live worker, empty status) only print the reason to stderr; the stderr message already exists. Keep the landing-lock release and `exit 1`. Replace the inline block in the success path with `stop_listener`.
- **Mirror**: `bin/kingpin-done:56-69`, `bin/kingpin-done:127-143`
- **Validate**: `bash -n bin/kingpin-done`

### Task 2: Ack on an archived task

- **File**: `bin/kingpin-ack`
- **Action**: UPDATE
- **Implement**: In the per-id loop, when `$tasks_dir/$id` is missing but `$KP_HOME/archive/$id` exists, print `kingpin-ack: task $id is already archived; nothing to acknowledge` to stdout and `continue`. A truly unknown id still errors with exit 1.
- **Mirror**: `bin/kingpin-done:15-19`
- **Validate**: `bash -n bin/kingpin-ack`

### Task 3: Tests

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: Add Test 19 before the final PASS/FAIL block with its own mock lavish (`KINGPIN_LAVISH`), temp git worktrees, and tmux windows on the private socket: (a) live `needs-input:` task with a dirty worktree: `done` exits 1, last status is still `needs-input:`, `kingpin list` shows `needs-input` and no `cleanup-refused`; (b) live `ready:` task with a running listener: refused `done` leaves the listener alive; (c) `merged:` task with a dirty worktree and a running listener: `done` refuses, `cleanup-refused:` is the last status, the listener pid is gone, `listener.pid` is gone, `list` has no `listening`; (d) after `done --force`, `kingpin ack <id>` exits 0 with "archived" in the output, and `kingpin ack` of an unknown id still exits 1. Restore `KINGPIN_LAVISH` afterwards.
- **Mirror**: `tests/test-automation.sh:776-860`, `tests/test-automation.sh:1257-1271`
- **Validate**: `bash tests/test-automation.sh`

### Task 4: README

- **File**: `README.md`
- **Action**: UPDATE
- **Implement**: In the `kingpin done` row, add that a refusal records `cleanup-refused:` only for a finished task, never over a live worker's status, and that done stops the dossier listener; add a short `kingpin ack` mention is not needed beyond one sentence below the table is avoided: put it in the `done` row ("`kingpin ack` of an archived task is a no-op").
- **Mirror**: `README.md:104`
- **Validate**: `grep -n "cleanup-refused" README.md`

## Validation

```bash
bash -n bin/kingpin-done bin/kingpin-ack tests/test-automation.sh
bash tests/test-automation.sh
bash tests/test-report.sh
# Reproduction: Test 19 (a) fails on HEAD (status becomes cleanup-refused)
```

## End-to-End Verification

Test 19 runs the real `kingpin-done`, `kingpin list`, `kingpin-listen --background` and `kingpin ack` against temp fixtures (`KINGPIN_HOME` in a temp dir, a private tmux socket, a mock lavish). Expected: all PASS lines. Verify red on HEAD by running Test 19 with the `bin/` changes stashed via a temporary copy (scratch copy of HEAD's `bin/` in `/tmp`).

## Risks

| Risk | Mitigation |
|------|------------|
| `kingpin-watch` retry loop relies on a `cleanup-refused:` last status | Only finished tasks get that line; a live task is not a retry candidate, which is intended (in scope) |
| A task with an empty/pending status is treated as live and no refusal event is recorded | Reason still goes to stderr and exit 1; acceptable (in scope) |
| A `ready:` task that is refused loses the retry | Not a merged task; the boss decides. Out of scope |

## Open Questions

None.

## Acceptance Criteria

- [ ] A refused `done` on a live-worker task keeps its last status line (Test 19a)
- [ ] A refusal on a finished task still reports `cleanup-refused:` (Test 10 + 19c)
- [ ] `kingpin done` stops the dossier listener, including on a refusal of a finished task (Test 19c)
- [ ] `kingpin ack` on an archived task exits 0 with a note (Test 19d)
- [ ] `bash -n` clean, test-automation and test-report pass
