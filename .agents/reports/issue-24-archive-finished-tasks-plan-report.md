# Implementation Report

**Plan**: `.agents/plans/completed/issue-24-archive-finished-tasks-plan.md`
**Branch**: `kingpin/kingpin-24`
**Status**: COMPLETE

## Summary

`bin/kingpin-done` now refuses (even with `--force`) to clean up a task whose `WORKTREE` is recorded by another task whose last status is not `merged:`/`failed:`/`cleanup-refused:`, and moves the finished task directory to `$KINGPIN_HOME/archive/<id>` as its last step. `kingpin done` on an already archived id is a no-op. `kingpin list` hides finished tasks (archived, or carrying `done_cleaned`) and `--all` shows them; `kingpin run` finds `done_cleaned` in the archive. `kingpin-curate` already scanned `archive/`, so critiques stay collected (covered by a new test).

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 1 | Slot guard and idempotence | `bin/kingpin-done` | PASS |
| 2 | Archive after cleanup | `bin/kingpin-done` | PASS |
| 3 | `list --all`, `run` follows archive | `bin/kingpin` | PASS |
| 4 | Tests (Test 12 and updated assertions) | `tests/test-automation.sh` | PASS |
| 5 | README | `README.md` | PASS |

## Validation Results

| Check | Result | Command / environment |
|-------|--------|-----------------------|
| Type check | PASS | `bash -n bin/kingpin bin/kingpin-done tests/test-automation.sh` |
| Lint | N/A | No bash linter configured |
| Tests | PASS | `./tests/test-automation.sh`, `./tests/test-acceptance.sh`, `./tests/test-harnesses.sh` |
| Reproduction | PASS | Test 12 fails on HEAD's `bin/` (11 FAIL lines), passes after the change |

## Deviations from Plan

- Test 11's `task-lavish-1` shared `$T/proj` with the unfinished `task-lavish-2`; given its own `WORKTREE` path so the slot guard does not refuse the fixture.
- `tests/test-acceptance.sh` needed no change.
