# Code Review: kingpin/kingpin-10-claude (re-review r1)

**Scope**: branch `kingpin/kingpin-10-claude` vs merge base with `main` (uncommitted, 8 files + artifacts), issue #10; re-review after the fix pass for M1, L1, L2, L3, L4
**Recommendation**: APPROVE (no findings)

## Summary

The fix pass adds automatic retry of refused cleanups to `kingpin-watch`, dedupes the `cleanup-refused:` status line, makes the landing-queue pop conditional on this task having held the lock, tightens the `AGENTS.md` guidance, and extends Test 10. All five prior findings are fixed. This re-review ran in the same session as the fixes (no subagent tool), so it is not independent of them.

Acceptance criteria (all met):
- **AC1** `done_cleaned` only after a successful cleanup: `bin/kingpin-done:106` (touch after cleanup); Test 10 asserts it is absent after a refusal and present after the watch retry.
- **AC2** refusal is a task event with the reason: `bin/kingpin-done:55-61`; Test 10 asserts the line, the reason, and that `kingpin-wait` reports it.
- **AC3** refusal does not hold the landing lock: `bin/kingpin-done:36-38` releases it and hands off; Test 10 asserts the handoff and that `kingpin-land` takes the lock from a `merged:`, `failed:` or `cleanup-refused:` holder but still queues behind a live one.
- **Issue text "surfaced and retried"**: met via `retry_pending_cleanups` (M1).

## Fix Verification

| ID | Status | Evidence |
|----|--------|----------|
| M1 | fixed | `bin/kingpin-watch:93-105` defines `retry_pending_cleanups`, called after each cycle in `--once` (`:127`) and loop mode (`:141`); Test 10 "kingpin-watch retried the refused cleanup and wrote done_cleaned"; fails when the call is disabled (negative control run in a scratch copy) |
| L1 | fixed | `bin/kingpin-done:53-64` appends only when the last status line differs; Test 10 asserts one line after a watch cycle plus two manual repeats |
| L2 | fixed | `bin/kingpin-done:36-38` returns unless the lock holder is this task; Test 10 asserts the queue and the holder are unchanged after a non-holder refusal |
| L3 | fixed | `AGENTS.md:55` names both refusal reasons and says `--force` discards uncommitted changes or unmerged commits |
| L4 | fixed | Test 10 now covers retry, dedupe, `kingpin-wait` visibility, the non-holder queue case, the terminal-holder rule for three statuses plus a live holder, and a forced cleanup of a dirty worktree |

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
None

**Noted, not a finding**: each retry of a `HEAD not yet merged` refusal runs `git fetch origin`, once per watch cycle (default 300 s, or per event); that cost is bounded and is what lets the retry notice the merge. `tests/test-automation.sh` still uses the real `kingpin` tmux session (issue #19); it was run only against a private tmux server.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n` on `bin/kingpin*` and `tests/*.sh`, `python3 ast.parse` on `bin/kingpin-board`; host |
| Warnings | N/A | no compiled build |
| Lint | N/A | no linter configured (shellcheck not installed) |
| Tests | PASS | `tests/test-automation.sh` (87 PASS), `tests/test-acceptance.sh` (19 PASS), `tests/test-harnesses.sh` (50 PASS); host, private tmux server via `TMUX_TMPDIR` |
| UI verification | N/A | board change from r0 (badge, Force Done button) not rendered |

## What's Good

The retry reuses `kingpin-done` as the single owner of `done_cleaned` and of the lock release, dedupe keeps retries from waking the orchestrator, and the new tests check the behaviors at each step rather than only the end state.

## Recommendation

Ready to land.
