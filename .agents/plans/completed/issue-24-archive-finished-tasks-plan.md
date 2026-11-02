# Plan: Archive finished task records and guard shared worktree slots

## Summary

`bin/kingpin-done` will (1) refuse, even with `--force`, to clean up a task whose `WORKTREE` is also recorded by another unfinished task, and (2) after all its cleanup steps succeed, move `$KP_HOME/tasks/<id>/` to `$KP_HOME/archive/<id>/`. `kingpin list` hides finished tasks (archived ones, and legacy records carrying a `done_cleaned` marker) unless `--all` is given. `kingpin-curate` already scans `$KP_HOME/archive/*/critique` (bin/kingpin-curate:27), so critiques keep being collected; a new test covers the real `kingpin-done` to curate path. `kingpin run` checks the `done_cleaned` marker in the archive once the directory has moved, and `kingpin-done` on an already-archived task is an idempotent no-op.

## User Story

As the orchestrator
I want finished task records archived out of the live fleet and a cleanup that can never release another worker's slot
So that `kingpin list` shows only live work and a stale record cannot `treehouse return` a live worktree

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | MEDIUM |
| Systems Affected | bin/kingpin-done, bin/kingpin (list, run), tests/test-automation.sh, tests/test-acceptance.sh, README.md |
| GitHub Issue | #24 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Patterns to Follow

### Refusal
`bin/kingpin-done:56-68` `refuse_cleanup` appends `cleanup-refused: <reason>` (deduplicated), hands on the landing lock, exits 1. The slot guard reuses it.

### Terminal status
`bin/kingpin-land:98-104` and `bin/kingpin-wait:34-40`: `merged:*|failed:*|cleanup-refused:*` are terminal. The issue defines "unfinished" as "no merged:/failed: last status"; a `cleanup-refused:` line only follows `merged:`, so the guard treats all three as finished.

### Archive scanning
`bin/kingpin-curate:25-45` already scans `"$KP_HOME/tasks"` and `"$KP_HOME/archive"` for `critique`. Archive location is `$KP_HOME/archive/<id>`.

### Tests
`tests/test-automation.sh:323-332` (curate with an archive dir), `:649-665` (Test 10 force cleanup): `pass`/`fail` helpers, per-test dirs under `$KINGPIN_HOME/tasks`.

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-done` | UPDATE | Slot guard before any teardown; idempotent for archived tasks; archive the directory last |
| `bin/kingpin` | UPDATE | `list [--all]` hides finished tasks; `run` finds `done_cleaned` in the archive |
| `tests/test-automation.sh` | UPDATE | Read `done_cleaned` from the archive; add archive, list, guard, curate tests; give the Test 10 force case its own worktree |
| `tests/test-acceptance.sh` | CHECK | Adjust any assertion that expects cleaned task dirs under `tasks/` |
| `README.md` | UPDATE | Document `kingpin list [--all]`, archiving, slot guard |

---

## Tasks

### Task 1: Slot guard and idempotence in kingpin-done

- **File**: `bin/kingpin-done`
- **Action**: UPDATE
- **Implement**: (a) Before the `-d "$task_dir"` check: if `tasks/<id>` is missing but `archive/<id>` exists, print `OK: task $id already cleaned up (archived)` and exit 0. (b) After sourcing `task.env`, scan `$KP_HOME/tasks/*/task.env` for other ids with the same `WORKTREE`; if that task's last status line is not `merged:*|failed:*|cleanup-refused:*`, call `refuse_cleanup` naming the holder, even with `--force`. This runs before the dirty/merged checks and before any teardown (tmux, listener, `treehouse return`).
- **Mirror**: `bin/kingpin-done:56-68`, `bin/kingpin-land:98-104`
- **Validate**: `bash -n bin/kingpin-done`

### Task 2: Archive after a successful cleanup

- **File**: `bin/kingpin-done`
- **Action**: UPDATE
- **Implement**: After `touch "$task_dir/done_cleaned"` (the marker travels with the record), `mkdir -p "$KP_HOME/archive"` and `mv` the directory to `archive/<id>` (numeric suffix if the target exists). Keep the `OK: cleaned up task $id` prefix. Refused cleanups exit earlier and leave the record in place.
- **Mirror**: `bin/kingpin-done:128-129`
- **Validate**: `bash -n bin/kingpin-done`

### Task 3: `kingpin list --all` and `run` follow the archive

- **File**: `bin/kingpin`
- **Action**: UPDATE
- **Implement**: Parse `--all` in `list|status`. Move row printing into a function. Default: iterate `tasks/*`, skipping dirs holding `done_cleaned`. With `--all`: also iterate `archive/*`, marking the status ` (archived)`. Print `No tasks in fleet.` when nothing is shown. In `run`, look for `done_cleaned` in `tasks/<id>` or `archive/<id>`.
- **Mirror**: `bin/kingpin:80-125`, `bin/kingpin:149-160`
- **Validate**: `bash -n bin/kingpin`

### Task 4: Tests

- **File**: `tests/test-automation.sh`, `tests/test-acceptance.sh`
- **Action**: UPDATE
- **Implement**: Existing `done_cleaned` assertions (lines 123, 618, 664) look in `archive/<id>`. Give the Test 10 `t10-force` case a third worktree, since it would share `wt2` with the unfinished `t10-queued`. Test 11's `task-lavish-1` shares `$T/proj` style worktrees: check for collisions. Add Test 12: (1) after `kingpin-done` the dir is gone from `tasks/` and present in `archive/`; (2) `kingpin list` hides the archived task and shows the live one, `--all` shows both; (3) two records sharing a `WORKTREE`, one unfinished: `kingpin-done --force` refuses and the record stays; with the other `merged:` it succeeds; (4) a `critique` in an archived task is listed by `kingpin-curate --dry-run`; (5) `kingpin-done` on an archived id exits 0.
- **Mirror**: `tests/test-automation.sh:323-332`, `:649-665`
- **Validate**: `./tests/test-automation.sh && ./tests/test-acceptance.sh`

### Task 5: README

- **File**: `README.md`
- **Action**: UPDATE
- **Implement**: Update the `list` and `done` rows of the command table and the "Terminal Fleet Overview" paragraph.
- **Validate**: `grep -n -e '--all' README.md`

---

## Validation

```bash
bash -n bin/kingpin bin/kingpin-done
./tests/test-automation.sh
./tests/test-acceptance.sh
./tests/test-harnesses.sh
# Reproduction: Test 12 in test-automation.sh fails on HEAD (no archive, no guard) and passes after the fix
```

Baseline on HEAD: `./tests/test-automation.sh` prints ALL AUTOMATION TESTS PASSED (about 18 s).

## End-to-End Verification

Test 12 drives the real `bin/kingpin-done`, `bin/kingpin list`, and `bin/kingpin-curate --dry-run` against a scratch `KINGPIN_HOME`: merged task is archived and hidden; shared-slot record is refused with `--force`; archived critique is collected.

## Risks

| Risk | Mitigation |
|------|------------|
| Code that expects a cleaned dir under `tasks/` (`run`, watch) | `run` checks the archive; watch, ack and wait iterate only `tasks/`, so archived tasks leave their loops; `kingpin-done` is idempotent for archived ids. In scope |
| Guard refuses forever on a stale record (watch retries `cleanup-refused`) | Intended; status dedupe prevents event spam. Out of scope: automatic repair of stale records |
| Legacy cleaned records already in `tasks/` | `list` hides dirs holding `done_cleaned`; migrating them is out of scope |
| Archive target name collision | Numeric suffix |

## Open Questions

- None. Defaults adopted: archive at `$KP_HOME/archive/<id>` (already scanned by curate); `cleanup-refused:` counts as finished for the guard.

## Acceptance Criteria

- [x] All tasks completed
- [x] After cleanup the task dir is in `archive/`, not `tasks/`
- [x] `kingpin list` hides finished tasks; `--all` shows them
- [x] `kingpin done` refuses with `--force` when an unfinished task shares the `WORKTREE`
- [x] Archived critiques are still collected by `kingpin curate`
- [x] All three test scripts pass
