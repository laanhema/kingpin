# Code Review: kingpin/kp-60-guard-test-test

**Scope**: branch `kingpin/kp-60-guard-test-test` vs merge base d290271 (main), including uncommitted changes (`tests/test-worker-settings.sh`); untracked `.agents/` plan, prototype patch, and plan report read as context only.
**Recommendation**: APPROVE WITH NITS

## Summary

One-file fix: Test 4 of `tests/test-worker-settings.sh` now runs `kingpin guard check --dir "$T/proj"` instead of `cd "$T/proj" && kingpin guard check`, and reports both outcomes. `kingpin-guard` ignores the working directory and defaults `--dir` to its own checkout (`bin/kingpin-guard:32`), so the old call read the host checkout's guard. The fix is correct and verified in a scratch clone. The one nit is an incomplete host-state audit.

Acceptance criteria:
- **Call checks the fixture with `--dir "$T/proj"`**: met (`tests/test-worker-settings.sh:205-206`).
- **Suite passes with and without a guard in the host checkout**: met. In a scratch clone with `bin/kingpin-guard install` run, the branch's test printed `PASS: proj wrapper check fails without a guard` and `ALL WORKER SETTINGS TESTS PASSED`. The merge-base version of the test in the same clone printed `FAIL: proj wrapper check saw a guard it should not`. With the guard file removed, the branch version passes. It also passes in the leased worktree (no guard).
- **Other suites checked for the same host-state leak; any leak fixed or listed in the PR**: partly met. I found no host read in the four other suites (all export `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD=1`, `TREEHOUSE_ROOT`, and the rest), and all five suites pass here. The audit lists only `test-acceptance.sh` for the in-place overwrite of `bin/kingpin-send`. `test-automation.sh` does the same and is not listed (L1).

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `tests/test-automation.sh:95-110` — the issue comment, plan, and report list only `test-acceptance.sh` as overwriting the real checkout's `bin/kingpin-send`, but `test-automation.sh` does the same (backup at 95, stub at 96-103, restore at 110) and its `cleanup` trap (line 36-39) has no restore, unlike `test-acceptance.sh:36`. **Why:** the third criterion asks that host-state leaks found be fixed or listed; an interrupted `test-automation.sh` run leaves the stub `kingpin-send` in the real checkout, and the audit misstates the scope. **Fix:** add `test-automation.sh` to the listed leaks (mention it in the PR or a follow-up issue), and optionally add the `kingpin-send` restore to its cleanup trap as `test-acceptance.sh` does.

**Noted, not a finding**: the `kingpin-send` overwrite is a write to a tracked script, not a guard/lock/`~/.kingpin` read; the plan scoped it out. The intentional host reads in `test-worker-settings.sh` (lines 62-64, 129) are unchanged and correct.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Shell-only repo; no build step |
| Warnings | N/A | No compiled build |
| Lint | N/A | No lint command in AGENTS.md or CI (no `.github/workflows`) |
| Tests | PASS | `bash tests/<suite>.sh` for all five suites on the host (leased worktree, no guard): test-acceptance, test-automation, test-harnesses, test-report, test-worker-settings all print ALL ... PASSED. No skipped tests seen in the tail output. Scratch clone with guard installed: test-worker-settings passes on the branch version, fails on the merge-base version, passes with the guard removed. |
| UI verification | N/A | No UI change |

## What's Good

- Minimal, correct one-line fix with a comment that names the reason.
- The `&& fail || pass` form matches the neighbouring negative checks and adds a visible PASS line, so the check no longer reports nothing on success.
- The red-green reproduction in a guard-carrying clone is real, not argued.

## Recommendation

Merge after optionally addressing L1 (list `test-automation.sh` among the `kingpin-send` overwriters). Run `/fix-findings .agents/reviews/kingpin-kp-60-guard-test-test-review.md` if you want L1 handled; `/issue-flow-done 60` otherwise.
