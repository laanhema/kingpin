# Code Review: kingpin/kingpin-24

**Scope**: branch `kingpin/kingpin-24` vs `main` (uncommitted changes), issue #24
**Recommendation**: APPROVE WITH NITS

## Summary

Reviewed `bin/kingpin-done`, `bin/kingpin` (`list`, `run`), `tests/test-automation.sh` and `README.md` in full, plus the callers that read the task directory (`kingpin-watch`, `kingpin-wait`, `kingpin-ack`, `kingpin-land`, `kingpin-curate`). Note: this review ran in the same session as the implementation (no subagent tool was available), so it is not independent of the implementer.

Acceptance criteria:
- Cleanup moves the task dir out of `tasks/` into `archive/`: met. `kingpin-done` archives last (`bin/kingpin-done:146-163`); Test 12.1 and the updated Test 3/10 assertions check it.
- `kingpin list` hides finished tasks, `--all` shows them: met. `bin/kingpin:92-167`; Test 12.2 uses one merged and one live task.
- `kingpin done` refuses, even with `--force`, when another unfinished task records the same `WORKTREE`: met. Slot guard at `bin/kingpin-done:70-86`, before any teardown; Test 12.5 uses two records sharing a slot and also checks that cleanup proceeds once the holder is finished.
- Archived skill critiques still collected by `kingpin curate`: met. `bin/kingpin-curate:25-45` already scanned `archive/`; Test 12.3 covers an archived task produced by the real `kingpin-done`.

Technical Notes of the issue: archive happens after the existing steps and a refused cleanup leaves the record (guard and checks exit earlier); `kingpin run` handles the moved directory (`bin/kingpin:185-200`); watch/wait/ack iterate only `tasks/`.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-done:155-162` — when `archive/<id>` already exists the record is archived as `archive/<id>.2`, but the idempotent no-op in `bin/kingpin-done:16-19` and the `run` check in `bin/kingpin:185-200` only look at `archive/<id>`. **Why:** only reachable when a task id is reused after an earlier archive; the later task then reports "not found" rather than "already archived" if `done` is repeated. **Fix:** acceptable as is (task ids are unique per spawn); if ids can be reused, glob `archive/$id*`.

**Noted, not a finding**: stale records that predate this change and sit in `tasks/` with an unfinished last status keep guarding their slot; automatic repair of such records is out of scope for the issue.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n bin/kingpin bin/kingpin-done tests/test-automation.sh`; host |
| Warnings | N/A | shell scripts |
| Lint | N/A | no linter configured in the repository |
| Tests | PASS | `./tests/test-automation.sh`, `./tests/test-acceptance.sh`, `./tests/test-harnesses.sh`; host, private tmux socket; none skipped. Test 12 run against `bin/` of HEAD in a scratch repo: 11 FAIL lines (red before the change) |
| UI verification | N/A | no UI change |

## What's Good

The guard runs before any destructive step and reuses `refuse_cleanup` (deduplicated status, landing lock handed on). Idempotent `kingpin done` on archived ids keeps `kingpin-watch` and `kingpin run` safe when they race. Test 12 is red on the old code. Existing fixtures that unknowingly shared a slot were corrected rather than the guard weakened.

## Recommendation

Merge after the owner's manual check; L1 is optional.
