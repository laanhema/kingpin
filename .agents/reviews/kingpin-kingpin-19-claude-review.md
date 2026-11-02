# Code Review: kingpin/kingpin-19-claude (re-review of the imported kingpin/kingpin-19 work)

**Scope**: branch `kingpin/kingpin-19-claude` vs the merge base with `main`, including uncommitted changes (3 modified test scripts; untracked `.agents/` plan, prototype patch, implementation report and two prior reviews read as context). The diff was imported from the earlier worker's branch `kingpin/kingpin-19` and rebased by 3-way apply onto current `main`; the one conflict (`tests/test-automation.sh`, the Test 9 block added by #6 versus the removed trailing cleanup) was resolved by keeping Test 9 and dropping the old cleanup.
**Recommendation**: APPROVE WITH NITS

> This review ran inline in the implementing session (no subagent tool was available), so it is not independent of the import and conflict resolution.

## Summary

Each of `tests/test-automation.sh`, `tests/test-harnesses.sh` and `tests/test-acceptance.sh` now sets `TMUX_TMPDIR=$T/tmux-tmp`, a socket name `kingpin-test-<suite>-$$`, and a `$T/bin/tmux` wrapper that runs `tmux -L <socket>`, prepended to `PATH`. An `EXIT` trap kills only that server and removes `$T`. The wrapper covers the scripts, the `bin/` commands they call and Python subprocesses. `unset TMUX` (line 5 of each script) keeps the isolation valid when the suite is launched from inside tmux. No product code changed.

- **AC1, every script in `tests/` uses an isolated private socket with an independent name: met.** `tests/test-acceptance.sh:22-33`, `tests/test-automation.sh:24-35`, `tests/test-harnesses.sh:24-35`; each asserts `#{socket_path}` contains its socket name (`test-acceptance.sh:92`, `test-automation.sh:59`, `test-harnesses.sh:47`). No tmux call bypasses the wrapper (grep of `tests/` for `-L`/direct binary use shows only the wrapper, trap and `REAL_TMUX` lines).
- **AC2, never modifies, inspects or kills sessions on the ambient default server: met.** The default socket is never probed. I ran all three suites from inside the live orchestrator's environment: the ambient window list (`tmux list-windows -a`) was identical before and after, and only `/tmp/tmux-1000/default` exists.
- **AC3, cleanup destroys only the private socket and temp files: met.** The trap runs `kill-server` on `-L $TEST_SOCKET` and `rm -rf "$T"` (`test-acceptance.sh:34-39`, `test-automation.sh:31-35`, `test-harnesses.sh:31-35`). No `kingpin-test*` process remained after the runs.

## Fix Verification

Prior reports: `.agents/reviews/kingpin-kingpin-19-review.md` (H1, L1) and `.agents/reviews/kingpin-kingpin-19-review-r1.md` (L2).

| ID | Status | Evidence |
|----|--------|----------|
| H1 | fixed | `grep -n 'L default' tests/*.sh` returns nothing; only the `#{socket_path}` assertion remains. |
| L1 | fixed | The trailing `kill-session`/`kill-window`/`rm -rf "$T"` blocks are gone; each script ends at its `if [ "$FAILED" -eq 0 ]` block. |
| L2 | partly fixed, still open (see L1 below) | The implementation report (`.agents/reports/issue-19-isolate-test-tmux-sockets-plan-report.md:9,46-48`), the plan (summary paragraph) and the prototype patch (`grep -n 'L default'` returns nothing) now agree with the code. The posted issue #19 implementation comment still says "ambient default socket non-interference assertions". |

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L2** issue #19 comment `6587817084` — The implementation comment still says "Added socket isolation and ambient default socket non-interference assertions" and "ensuring no session leak onto ambient default socket", but the suites contain only the `#{socket_path}` assertion. **Why:** The posted record contradicts the code. **Fix:** Edit that comment to say "a `#{socket_path}` isolation assertion (the ambient default socket is never probed)". The edit was attempted from this run and denied by the permission classifier, so it is left for the owner.

**Noted, not a finding**: `tests/test-acceptance.sh:35,169` run `git checkout bin/kingpin-send`, which discards uncommitted local edits to that file. Line 169 predates this change; the trap only repeats it to undo the test's own overwrite. A SIGKILLed run can leave the private tmux server running; that is outside the issue.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash project, nothing to build |
| Warnings | NONE | `bash -n bin/* tests/*.sh` printed nothing |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host; no linter configured |
| Tests | PASS | Host, private tmux sockets. `tests/test-harnesses.sh`, `tests/test-automation.sh` (includes #6's Test 9) and `tests/test-acceptance.sh` each ended with their "ALL ... TESTS PASSED" line. None skipped or env-guarded. Ambient tmux window list unchanged. |
| UI verification | N/A | Test scripts only |

## What's Good

- One wrapper on `PATH` isolates the scripts, `bin/` helpers and Python subprocesses without touching product code.
- The `EXIT` trap covers early aborts, and the acceptance trap also restores the overwritten `bin/kingpin-send`.
- The review-driven removal of the ambient `has-session` probe keeps the suites from inspecting or failing on a host that runs a real `kingpin` session.

## Recommendation

Merge-ready. L2 is a wording fix on an issue comment only; no code change is needed. Commit the branch before `/issue-flow-done 19`.
