# Code Review: kingpin/kingpin-20

**Scope**: branch `kingpin/kingpin-20`
**Recommendation**: APPROVE

## Summary

Reviewed branch `kingpin/kingpin-20` addressing Issue #20 ("Prevent workers from adopting orchestrator role when working on kingpin repo"). The change introduces an explicit, prominent scope guard at the top of `AGENTS.md` clarifying that the orchestrator contract applies exclusively to the root orchestrator session and must be ignored by background workers in leased worktrees. It updates `worker/preamble.md` to instruct workers across all harnesses (`claude`, `agy`, `opencode`) that they are background code workers who must write code directly and ignore root orchestrator instructions (`AGENTS.md`). It also updates `bin/kingpin-spawn` to substitute `{{WORKTREE}}` in the preamble and adds comprehensive multi-harness regression tests in `tests/test-harnesses.sh`.

All acceptance criteria from Issue #20 are met:
- [x] `AGENTS.md` includes an explicit scope guard at the top stating it applies exclusively to the root orchestrator session and does NOT apply to background workers in leased worktrees (`~/.treehouse/...`): Met. Verified in `AGENTS.md:3-8` and automated in `tests/test-harnesses.sh` Test 7.
- [x] `worker/preamble.md` explicitly instructs workers that they are background code workers in a leased worktree, not the orchestrator, and that any root orchestrator instructions (`AGENTS.md`) in the worktree must be ignored in favor of directly implementing the task: Met. Verified in `worker/preamble.md:3-11` and automated in `tests/test-harnesses.sh` Test 7.
- [x] Spawning a worker on the `kingpin` repo with `agy`, `claude`, or `opencode` results in the worker immediately proceeding with implementation without role confusion: Met. Verified in `tests/test-harnesses.sh` Tests 1, 2, and 3 verifying that `claude`, `agy`, and `opencode` worktree configurations receive the anti-role-confusion instructions and substituted `WORKTREE` path.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
None

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n bin/* tests/*.sh` on host; syntax clean |
| Warnings | NONE | Zero warnings emitted during syntax checks and test suite executions |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host |
| Tests | PASS | `tests/test-harnesses.sh` (7/7 passed); `tests/test-automation.sh` (6/6 passed); `tests/test-acceptance.sh` (15/15 passed) |
| UI verification | N/A | Orchestrator CLI and agent prompt templates; no frontend UI |

## What's Good

- Solves the role confusion at both ends: the ambient workspace rule (`AGENTS.md`) is scoped out with an explicit top guard, and the worker preamble explicitly commands workers to ignore `AGENTS.md` and write code.
- Cleanly parameterizes `{{WORKTREE}}` in `bin/kingpin-spawn` for complete path context in worker instructions.
- Seamless multi-harness support verified across Claude (`--append-system-prompt-file`), AGY (`.agents/rules/kingpin.md`), and OpenCode (`config.json` instructions).
- Comprehensive test coverage added to `tests/test-harnesses.sh` without regressions in existing automation or acceptance suites.

## Recommendation

Approve. The branch is clean, fully validated, and ready for landing.
