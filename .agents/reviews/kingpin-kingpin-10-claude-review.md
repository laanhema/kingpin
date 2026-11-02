# Code Review: kingpin/kingpin-10-claude

**Scope**: branch `kingpin/kingpin-10-claude` vs merge base with `main` (uncommitted changes, 8 files + plan/report artifacts), checked against issue #10
**Recommendation**: APPROVE WITH NITS (only Medium/Low findings)

## Summary

The change makes `kingpin-done` own the `done_cleaned` marker (written only after a successful cleanup), reports a refusal as a `cleanup-refused: <reason>` status event, releases the project landing lock and hands off to the next queued task on refusal, and teaches `kingpin-land`/`kingpin-wait`/`kingpin-board`/`kingpin run` about the new terminal status. The implementation was handed over from an earlier worker (`kingpin/kingpin-10`) and verified here. This review was run in the same session that verified the work (no subagent tool), so it is not independent of the verification.

Acceptance criteria:
- **AC1 `done_cleaned` only after success**: met. `bin/kingpin-done:101` touches the marker after cleanup; `bin/kingpin-watch` no longer touches it; Test 10 asserts it is absent after a dirty-worktree refusal.
- **AC2 refusal visible as a task event with the reason**: met. `bin/kingpin-done:56` appends `cleanup-refused: <reason>`; Test 10 asserts the line and that it names "uncommitted changes".
- **AC3 refusal does not leave the landing lock held**: met. `bin/kingpin-done:57` releases the lock and triggers the queued task; Test 10 asserts the lock holder becomes `t10-queued` and `landing_sent` exists. `bin/kingpin-land` also treats a holder in a terminal status as free.
- **Issue text "a refusal is surfaced and retried"** (Description, not a numbered criterion): not met, see M1.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
- **M1** `bin/kingpin-watch:76` — a refused cleanup is surfaced but never retried. **Why:** the issue's Expected sentence says "surfaced and retried". After a refusal the last status line is `cleanup-refused:`, which `kingpin-wait` treats as terminal (`bin/kingpin-wait:37`) and `kingpin-watch` only logs. Verified in a scratch run: refuse once, remove the dirty file, run `kingpin-watch --once` twice, and `done_cleaned` never appears, so the worktree lease leaks until someone runs `kingpin done` by hand. **Fix:** in `kingpin-watch`, rescan task dirs on each cycle and rerun `kingpin-done` for tasks whose last status is `cleanup-refused:*` and that have no `done_cleaned` (with the dedupe from L1 so the retry adds no new status line), or state in the issue that manual retry via `kingpin done` is the intended retry.

### Suggestions (Low)
- **L1** `bin/kingpin-done:56` — every refused run appends another identical `cleanup-refused:` line. **Why:** verified: two manual `kingpin done` runs on a still-dirty worktree add two duplicate lines, and each new line is a fresh wake-up event for `kingpin-wait`; a retry loop (M1) would turn this into an event storm. **Fix:** skip the append when the last status line already equals the new one.
- **L2** `bin/kingpin-done:43` — `release_landing_lock_and_advance_queue` pops and re-triggers the next queued task even when this task does not hold the landing lock. **Why:** a repeated refused `kingpin done` while task B holds the lock pops C and runs `kingpin-land C`, which queues C again at the tail, so queue order is scrambled (C moves behind D). **Fix:** pop and trigger only when this task's id was the lock holder and the lock was released.
- **L3** `AGENTS.md:55` — the `cleanup-refused:` guidance says to run `--force` "if uncommitted changes can be discarded", but the other refusal reason is "HEAD is not yet merged into origin default"; forcing then deletes unmerged commits. **Fix:** name both reasons and say that `--force` on the second one discards unmerged work.
- **L4** `tests/test-automation.sh` (Test 10) — covers refusal, lock handoff and force cleanup, but not a retry, the duplicate-line case (L1), or the terminal-holder rule in `kingpin-land` on its own. **Fix:** add assertions with M1/L1/L2 fixes.

**Noted, not a finding**: `tests/test-automation.sh` runs against the real `kingpin` tmux session (tracked in issue #19); it was run here only against a private tmux server.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n` on `bin/kingpin*` and `tests/*.sh`, `python3 ast.parse` on `bin/kingpin-board`, `node --check lib/*.mjs`; host |
| Warnings | N/A | no compiled build |
| Lint | N/A | no linter configured (shellcheck not installed) |
| Tests | PASS | `tests/test-automation.sh` (74 PASS, incl. Test 10), `tests/test-acceptance.sh` (19 PASS), `tests/test-harnesses.sh` (50 PASS); host, private tmux server via `TMUX_TMPDIR` |
| UI verification | N/A | `kingpin-board` gains a state badge and a "Force Done" button; the board HTML was not rendered or screenshotted |

## What's Good

The refusal path reuses the existing lock/queue handoff, `kingpin-land` also tolerates a stale terminal holder, `kingpin run` no longer reports success when cleanup was refused, and Test 10 uses a real git repo with a remote so both refusal gates are exercised.

## Recommendation

Merge-ready with nits. Fix M1 (or record the manual-retry decision on the issue) and L1/L2 before merging if automatic retry is wanted.
