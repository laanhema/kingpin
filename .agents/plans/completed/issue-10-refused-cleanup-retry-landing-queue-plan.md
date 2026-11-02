# Plan: Handle Refused Cleanup, Surface Refusal Event, and Prevent Landing Queue Wedging

## Summary

When a merged task's cleanup is refused by `bin/kingpin-done` (e.g. due to uncommitted worktree changes or unmerged commits), Kingpin currently touches `done_cleaned` before calling `kingpin-done`, leaving a premature marker that prevents cleanup retries and leaves the project landing lock held forever. This plan fixes `bin/kingpin-watch` so `done_cleaned` is only written when `kingpin-done` succeeds, updates `bin/kingpin-done` to record a `cleanup-refused: <reason>` event to `status` and release the project landing lock / advance the landing queue on refusal, and updates `bin/kingpin-land` and `bin/kingpin-wait` to treat tasks in terminal states (including `cleanup-refused:`) as non-blocking so queued tasks can proceed.

## User Story

As a Kingpin fleet orchestrator
I want refused task cleanups to be surfaced as task events without prematurely marking cleanup complete or holding the project landing lock indefinitely
So that queued tasks for the project can continue landing and the orchestrator can see and retry the refused cleanup.

## Metadata

| Field | Value |
|---|---|
| Type | BUG_FIX |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-done`, `bin/kingpin-watch`, `bin/kingpin-land`, `bin/kingpin-wait`, `bin/kingpin-board`, `bin/kingpin`, `AGENTS.md`, `tests/test-automation.sh` |
| GitHub Issue | #10 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Files to Change

| File | Action | Purpose |
|---|---|---|
| `bin/kingpin-done` | UPDATE | Record `cleanup-refused: <reason>` on refusal, release landing lock and advance queue, touch `done_cleaned` only upon successful cleanup |
| `bin/kingpin-watch` | UPDATE | Remove premature `touch done_cleaned`, handle `cleanup-refused:` status events |
| `bin/kingpin-land` | UPDATE | Treat holders with terminal statuses (`merged:*`, `failed:*`, `cleanup-refused:*`) as non-blocking so queued tasks can land |
| `bin/kingpin-wait` | UPDATE | Recognize `cleanup-refused:*` in `is_terminal_status` |
| `bin/kingpin-board` | UPDATE | Support `cleanup-refused` state in badge and card display with Force Done action |
| `bin/kingpin` | UPDATE | Check `done_cleaned` marker on `kingpin run` completion |
| `AGENTS.md` | UPDATE | Document `cleanup-refused:` event handling for the orchestrator |
| `tests/test-automation.sh` | UPDATE | Add tests for refused cleanup, refusal event detection, landing lock release, and queued task advancement |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Update `bin/kingpin-done` to handle cleanup refusals and touch `done_cleaned` on success

- **File**: `bin/kingpin-done`
- **Action**: UPDATE
- **Implement**:
  - Add a helper to handle refusals: print error to stderr, append `cleanup-refused: <reason>` to `$task_dir/status`, release the project landing lock if held by this task, advance the queue by popping `$queue_file` and invoking `kingpin-land` on the next task, and exit 1.
  - Call this refusal helper when uncommitted changes exist in `$WORKTREE` (without `--force`) or when `HEAD` is not yet merged into the remote default branch.
  - On successful cleanup (after releasing the landing lock and triggering the next task), touch `"$task_dir/done_cleaned"`.
- **Mirror**: `bin/kingpin-done:66-90`
- **Validate**: `bash -n bin/kingpin-done`

### Task 2: Update `bin/kingpin-watch` to write `done_cleaned` only on success and handle `cleanup-refused:`

- **File**: `bin/kingpin-watch`
- **Action**: UPDATE
- **Implement**:
  - In `process_task_event`, remove `touch "$task_dir/done_cleaned"` before calling `kingpin-done`.
  - Add a case for `cleanup-refused:*)` that logs the refusal reason.
- **Mirror**: `bin/kingpin-watch:70-84`
- **Validate**: `bash -n bin/kingpin-watch`

### Task 3: Update `bin/kingpin-land`, `bin/kingpin-wait`, and `bin/kingpin-board` to recognize terminal holder statuses

- **File**: `bin/kingpin-land`, `bin/kingpin-wait`, `bin/kingpin-board`, `bin/kingpin`
- **Action**: UPDATE
- **Implement**:
  - In `bin/kingpin-land`, add `is_terminal_status()` recognizing `merged:*|failed:*|cleanup-refused:*`. When checking `$project_landing_lock`, treat a holder in terminal status as free, acquiring the lock and removing the new task from the queue file if present.
  - In `bin/kingpin-wait`, include `cleanup-refused:*` in `is_terminal_status()`.
  - In `bin/kingpin-board`, handle `cleanup-refused` in `derive_task_state` and badge mappings.
  - In `bin/kingpin`, check `[ -f "$task_dir/done_cleaned" ]` after running `kingpin-done` in `merged:` handling.
- **Mirror**: `bin/kingpin-wait:34-40` and `bin/kingpin-land:95-103`
- **Validate**: `bash -n bin/kingpin-land bin/kingpin-wait bin/kingpin bin/kingpin-board`

### Task 4: Update `AGENTS.md` orchestrator documentation

- **File**: `AGENTS.md`
- **Action**: UPDATE
- **Implement**: Document the `cleanup-refused:` event in `AGENTS.md` under event handling rules.
- **Mirror**: `AGENTS.md:52-60`
- **Validate**: `git diff AGENTS.md`

### Task 5: Add comprehensive tests in `tests/test-automation.sh`

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: Add Test 10 covering:
  1. `done_cleaned` is not written when `kingpin-done` refuses on dirty worktree.
  2. Refused cleanup writes `cleanup-refused: ...` to `status` and `kingpin-wait` detects the event.
  3. Refused cleanup releases project landing lock and advances queue so the next queued task lands.
  4. Force cleanup (`kingpin-done --force`) succeeds, cleans up, and writes `done_cleaned`.
- **Mirror**: `tests/test-automation.sh:84-105`
- **Validate**: `bash -n tests/test-automation.sh && tests/test-automation.sh`

---

## Validation

```bash
# Syntax
bash -n bin/* tests/*

# Acceptance tests
tests/test-acceptance.sh

# Automation tests
tests/test-automation.sh

# Reproduction: verify uncommitted worktree leaves done_cleaned absent and appends cleanup-refused
tests/test-automation.sh
```

## End-to-End Verification

1. Run `tests/test-automation.sh` and verify all tests including Test 10 pass cleanly.
2. Run `tests/test-acceptance.sh` to ensure fleet parallel spawn, landing queue serialization, and teardown remain completely intact.
3. Validate syntax across all modified scripts with `bash -n bin/* tests/*`.

## Risks

| Risk | Mitigation | Scope |
|---|---|---|
| Advancing the queue on cleanup refusal could cause the next task to merge if previous task had unmerged commits | `kingpin-done` checks worktree dirty state and remote merge base before tearing down; releasing the landing lock allows subsequent tasks with their own independent worktrees to proceed without deadlock | IN-SCOPE |
| Duplicate queue pop if both `kingpin-done` and `kingpin-land` advance the queue | Popping uses atomic `head -n 1` + `sed -i '1d'` and `kingpin-land` ensures tasks already in queue are deduplicated with `sed -i "/^$id$/d"` | IN-SCOPE |

## Acceptance Criteria

- [ ] `done_cleaned` is written only after `kingpin-done` succeeds (verify: test with a dirty worktree leaves no marker)
- [ ] A refused cleanup appears as a task event the orchestrator sees, with the refusal reason (verify: test)
- [ ] A refused cleanup does not leave the project's landing lock held by that task forever: the next queued task can land, or the refusal is reported as blocking the queue (verify: test with two queued tasks)
- [ ] Syntax check `bash -n bin/* lib/* tests/*` passes
- [ ] Acceptance suite `tests/test-acceptance.sh` passes
- [ ] Automation suite `tests/test-automation.sh` passes
