# Code Review: kingpin/kingpin-19 (re-review r1)

**Scope**: branch `kingpin/kingpin-19` vs the merge base with `main` (3ab4520), including uncommitted changes (3 modified test scripts; untracked `.agents/` plan, prototype patch, implementation report and prior review read as context)
**Recommendation**: APPROVE WITH NITS

## Summary

The change routes every `tmux` call in `tests/test-automation.sh`, `tests/test-harnesses.sh` and `tests/test-acceptance.sh` to a private server. Each script sets `TMUX_TMPDIR=$T/tmux-tmp`, picks a socket name `kingpin-test-<suite>-$$`, and prepends a `$T/bin/tmux` wrapper that runs `tmux -L <socket>` to `PATH`. An `EXIT` trap kills only that server and removes `$T`. The prior report's H1 (the `-L default has-session` probe) and L1 (redundant trailing `kill-server`) are both fixed in the current tree. I ran all three suites from inside a live tmux client and they all passed. I also checked the ambient server: the window list was identical before and after (11 windows, same checksum), no `kingpin-test*` process remained, and only `/tmp/tmux-1000/default` exists.

Acceptance criteria:
- **AC1, all scripts in `tests/` use an isolated private socket with an independent name: met.** `tests/test-acceptance.sh:22-33`, `tests/test-automation.sh:24-35`, `tests/test-harnesses.sh:24-35`. `grep` finds no direct `tmux` binary path in `bin/`, so every call goes through the wrapper. Each script also asserts `#{socket_path}` contains its socket name (`test-acceptance.sh:92`, `test-automation.sh:59`, `test-harnesses.sh:47`).
- **AC2, never modifies, inspects or kills sessions on the ambient default server: met.** The wrapper forces `-L`, and each script runs `unset TMUX` at line 5. Ambient windows were unchanged by a real run (see Summary). The default socket is no longer probed.
- **AC3, cleanup destroys only the private socket and temp files: met.** The trap runs `kill-server -L $TEST_SOCKET` and `rm -rf $T` (`test-acceptance.sh:34-39`, `test-automation.sh:31-35`, `test-harnesses.sh:31-35`). No tmux processes or leftover socket dirs remained after the runs. A SIGKILL would still leave the private server running, which is acceptable.

## Fix Verification

| ID | Status | Evidence |
|----|--------|----------|
| H1 | fixed | `grep -n "L default" tests/*.sh` returns nothing. The only isolation assertion left is the `#{socket_path}` check at `tests/test-acceptance.sh:92`, `tests/test-automation.sh:59`, `tests/test-harnesses.sh:47`. |
| L1 | fixed | The trailing `tmux kill-session`/`kill-window`/`rm -rf "$T"` blocks were removed. The scripts now end at `if [ "$FAILED" -eq 0 ]` (`test-acceptance.sh:~170`, `test-automation.sh:~376`, `test-harnesses.sh:~219`). |

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L2** `.agents/reports/issue-19-isolate-test-tmux-sockets-plan-report.md:46` — The implementation report ("Tests Written": "assert default tmux socket has no `kingpin` session") and the issue #19 implementation comment ("ambient default socket non-interference assertions") describe an assertion that no longer exists in the code. The plan (Tasks 1-3) and `.agents/plans/completed/issue-19-isolate-test-tmux-sockets-prototype.patch:36,84,133` still contain the `-L default has-session` check that H1 removed. **Why:** The docs contradict the code, and someone re-applying the prototype patch would bring back the AC2 violation and the false failure on a host that has an ambient `kingpin` session. **Fix:** Reword the report to say only the `#{socket_path}` assertion exists, and drop the three `-L default has-session` lines from the prototype patch, or note in the plan that they were removed.

**Noted, not a finding**: `tests/test-acceptance.sh:35,169` run `git checkout bin/kingpin-send`, which discards uncommitted local edits to that file. The line at 169 predates this change. The EXIT trap now repeats it, but only to undo the test's own overwrite at line 115. A SIGKILLed run can leave the private tmux server running. Neither is part of the issue.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash project, nothing to build |
| Warnings | NONE | `bash -n bin/* tests/*.sh` printed nothing |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host (no linter configured in the repo) |
| Tests | PASS | Run on host from inside a live tmux client. `tests/test-harnesses.sh`: 51 PASS, 0 FAIL. `tests/test-automation.sh`: 49 PASS, 0 FAIL. `tests/test-acceptance.sh`: 20 PASS, 0 FAIL. None skipped or env-guarded. Ambient tmux window list identical before and after. |
| UI verification | N/A | Test scripts only |

## What's Good

- The `PATH` wrapper isolates the scripts, the `bin/` commands they call, and Python's `subprocess` (`bin/kingpin-board`) without changing any product code.
- The EXIT trap covers early aborts, and the acceptance trap also restores the overwritten `bin/kingpin-send`.
- `unset TMUX` plus the forced `-L` makes the isolation hold even when the suite is launched from inside tmux. I confirmed this with a real run in an attached session.
- The H1 fix removed the ambient probe, so the suites no longer fail on hosts that run a real `kingpin` session.

## Recommendation

Merge-ready. Optionally fix L2 (docs-only) with `/fix-findings .agents/reviews/kingpin-kingpin-19-review-r1.md L2`. The branch is not yet committed, so it still needs to be committed before `/issue-flow-done 19`.
