# Implementation Report

**Plan**: `.agents/plans/completed/issue-47-kingpin-wait-timeout-exit-plan.md`
**Branch**: `kingpin/kp-47-kingpin-wait-exits`
**Status**: COMPLETE

## Summary

`kingpin-wait` now exits 0 with no output on a plain timeout; `--once` with no events still exits 1; bad arguments (including non-numeric `--timeout`) exit 2 with a message; an unusable fleet directory exits 1 with a message. Usage, header comment, `bin/kingpin` header and AGENTS.md updated.

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 1 | Exit codes, validation, usage | `bin/kingpin-wait` | PASS |
| 2 | Docs | `AGENTS.md`, `bin/kingpin` | PASS |
| 3 | Tests (Test 6b) | `tests/test-automation.sh` | PASS |

## Validation Results

| Check | Result | Command |
|-------|--------|---------|
| Syntax | PASS | `bash -n bin/kingpin-wait bin/kingpin tests/test-automation.sh` |
| Tests | PASS | `bash tests/test-automation.sh` |
| Tests | PASS | `bash tests/test-harnesses.sh` |
| E2E | PASS | manual timeout/--once/--bogus runs |
| Reproduction | PASS | timeout exit 1 on HEAD, 0 after |

## Files Changed

bin/kingpin-wait UPDATE, bin/kingpin UPDATE, AGENTS.md UPDATE, tests/test-automation.sh UPDATE

## Deviations from Plan

README.md not changed (it does not document wait semantics). Added `--timeout` numeric validation (exit 2).

## Tests Written

Test 6b in `tests/test-automation.sh`: timeout, --once, bad arg, bad --timeout, unusable fleet dir.
