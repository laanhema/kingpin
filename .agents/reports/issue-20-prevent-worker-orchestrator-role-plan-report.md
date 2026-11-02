# Implementation Report

**Plan**: `.agents/plans/completed/issue-20-prevent-worker-orchestrator-role-plan.md`
**Branch**: `kingpin/kingpin-20`
**Status**: COMPLETE

## Summary

Prevented background workers in leased worktrees from adopting the orchestrator persona when working on the `kingpin` repository. Added an explicit scope guard at the top of `AGENTS.md` restricting it exclusively to the root orchestrator and directing leased worktree workers to ignore it. Updated `worker/preamble.md` to instruct workers that they are background code workers who must write code directly and ignore `AGENTS.md`. Updated `bin/kingpin-spawn` to substitute `{{WORKTREE}}`, and added multi-harness test coverage in `tests/test-harnesses.sh` verifying role separation across `claude`, `agy`, and `opencode`.

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 1 | Add Scope Guard to AGENTS.md | `AGENTS.md` | PASS |
| 2 | Update worker/preamble.md Instructions | `worker/preamble.md` | PASS |
| 3 | Substitute WORKTREE in bin/kingpin-spawn | `bin/kingpin-spawn` | PASS |
| 4 | Add Worker Role Separation Tests to test-harnesses.sh | `tests/test-harnesses.sh` | PASS |
| 5 | Run Full Test Suite | `tests/test-acceptance.sh`, `tests/test-automation.sh`, `tests/test-harnesses.sh` | PASS |

## Validation Results

| Check | Result | Command / environment |
|-------|--------|-----------------------|
| Type check | PASS | `bash -n bin/kingpin bin/kingpin-spawn bin/kingpin-wait bin/kingpin-done` — host |
| Lint | PASS | `bash -n bin/kingpin bin/kingpin-spawn bin/kingpin-wait bin/kingpin-done` — host |
| Tests | PASS (all passed) | `bash tests/test-harnesses.sh && bash tests/test-automation.sh && bash tests/test-acceptance.sh` — host |
| Reproduction | PASS | `grep -qi "scope guard" AGENTS.md && grep -qi "background code worker" worker/preamble.md` — red before fix, green after fix |

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `AGENTS.md` | UPDATE | +6/-0 |
| `worker/preamble.md` | UPDATE | +9/-0 |
| `bin/kingpin-spawn` | UPDATE | +1/-1 |
| `tests/test-harnesses.sh` | UPDATE | +16/-0 |

## Deviations from Plan

None.

## Tests Written

| Test File | Test Cases |
|-----------|------------|
| `tests/test-harnesses.sh` | Claude preamble background worker & AGENTS.md ignore checks |
| `tests/test-harnesses.sh` | AGY rules background worker & AGENTS.md ignore checks |
| `tests/test-harnesses.sh` | OpenCode preamble background worker & AGENTS.md ignore checks |
| `tests/test-harnesses.sh` | Test 7: AGENTS.md Scope Guard & Role Separation |
