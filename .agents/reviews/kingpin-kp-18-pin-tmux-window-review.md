# Code Review: kingpin/kp-18-pin-tmux-window

**Scope**: branch `kingpin/kp-18-pin-tmux-window` vs merge base `9e594dc` (main), uncommitted changes included, checked against issue #18
**Recommendation**: APPROVE (no findings)

## Summary

The change pins `automatic-rename off` and `allow-rename off` on each spawned worker window (by window ID, right after `tmux new-window`), adds Test 18, and documents it in the README spawn row. Reviewed: `bin/kingpin-spawn`, `tests/test-automation.sh`, `README.md`; the untracked plan and implementation report under `.agents/` were read as context only.

Acceptance criteria:
- Disable automatic renaming after creating the window with both options: met. `bin/kingpin-spawn:331-332` run both `tmux set-window-option` calls against `$window_id` (the window ID, sturdier than the name). The `|| true` is a deliberate choice, disclosed in the code comment and the issue comment; a failed cosmetic pin must not tear down a started worker.
- Automated test that windows keep their names under ambient tmux config: met. Test 18 (`tests/test-automation.sh:1435-1464`) turns both options on globally on the private tmux server, spawns a worker that emits a rename escape sequence, and asserts the options read `0 0`, that the worker really emitted the sequence (so the name check cannot pass vacuously), and that the name is unchanged. I ran it on the merge base with the new test file: it fails (`t18: window options not pinned: 0 1`, `t18: window renamed to evil`); with the change it passes.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
None

**Noted, not a finding**: the `curator` window in `bin/kingpin-curate:110` is not pinned. The implementer decided this is out of scope (issue comment and report list it as a possible follow-up); the issue's criteria cover only `bin/kingpin-spawn`.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash project, no build. `bash -n bin/kingpin-spawn tests/test-automation.sh` passes (host). |
| Warnings | N/A | No warnings gate; none in the test output. |
| Lint | N/A | No lint config in the repo or CI. |
| Tests | PASS | Host, private tmux sockets: test-automation 215 pass / 0 fail (incl. 3 t18), test-harnesses 57/0, test-worker-settings 79/0, test-report 17/0, test-acceptance 20/0. No skipped tests observed. Pre-fix run of the new Test 18 on the merge base fails as expected. |
| UI verification | N/A | No UI change. |

## What's Good

- Pin by window ID, immediately after creation, before the ID is recorded; consistent with the existing `TMUX_WINDOW_ID` design.
- The test proves a real failure mode (escape-sequence rename) rather than just reading options, restores the global options and `KINGPIN_AGY` afterwards, and runs on an isolated tmux socket.
- Explicit rename paths (`kingpin-rename` via `kingpin-wait`, Test 17) still work, since `tmux rename-window` is not blocked by `allow-rename`.
- README documents the behaviour accurately.

## Recommendation

Nothing to fix. Ready to land: `/issue-flow-done 18`.
