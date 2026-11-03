# Implementation Report

**Plan**: `.agents/plans/completed/issue-43-refused-done-live-status-listener-ack-plan.md`
**Branch**: `kingpin/kp-43-refused-kingpin-done`
**Status**: COMPLETE

## Summary

`kingpin-done` now records `cleanup-refused:` only when the task's last worker status (ignoring the listener's `approved:`/`feedback:` notes) is `merged:`, `failed:` or `cleanup-refused:`; a possibly live worker keeps its status and the reason goes to stderr. A refusal of a finished task also stops its dossier listener (stop code moved into `stop_listener`, shared with the success path). `kingpin-ack` on an archived id prints a note and exits 0.

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 1 | Gate refusal status line, stop listener | `bin/kingpin-done` | PASS |
| 2 | Ack on archived task | `bin/kingpin-ack` | PASS |
| 3 | Test 19 | `tests/test-automation.sh` | PASS |
| 4 | README | `README.md` | PASS |

## Validation Results

| Check | Result | Command / environment |
|-------|--------|-----------------------|
| Syntax | PASS | `bash -n bin/kingpin-done bin/kingpin-ack tests/test-automation.sh` — host |
| Lint | N/A | no linter configured |
| Tests | PASS | `bash tests/test-automation.sh` — host (ALL AUTOMATION TESTS PASSED) |
| Tests | PASS | `bash tests/test-report.sh`, `test-harnesses.sh`, `test-worker-settings.sh`, `test-acceptance.sh` — host |
| Reproduction | PASS | Test 19 on HEAD `bin/`: red (status replaced by `cleanup-refused:`, listener left running, ack rc=1); green after the fix |

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `bin/kingpin-done` | UPDATE | see git diff |
| `bin/kingpin-ack` | UPDATE | +5 |
| `tests/test-automation.sh` | UPDATE | +~95 |
| `README.md` | UPDATE | 1 row |

## Deviations from Plan

- Test 19 captures `kingpin list` output in a variable instead of piping into `grep -q` (pipefail plus early grep exit gave a false negative).
- The red run was against the unmodified `bin/` (tests written first), not a scratch copy.

## Tests Written

| Test File | Test Cases |
|-----------|------------|
| `tests/test-automation.sh` (Test 19) | live needs-input not masked and shown in list; live ready worker's listener survives a refusal; merged-task refusal reports cleanup-refused and stops the listener (pid gone, list not listening); ack on archived task exits 0 with note; ack on unknown task still exits 1 |
