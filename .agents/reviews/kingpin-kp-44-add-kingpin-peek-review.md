# Code Review: kingpin/kp-44-add-kingpin-peek

**Scope**: branch `kingpin/kp-44-add-kingpin-peek` vs merge base `2aaf252` (main), incl. uncommitted and untracked changes, against issue #44
**Recommendation**: APPROVE (no findings)

## Summary

Adds the read-only `kingpin peek <task-id> [--lines N]` (new `bin/kingpin-peek`, dispatch and help in `bin/kingpin`, Test 20, README and AGENTS.md). It mirrors `kingpin-send` for pane resolution (window ID first, `TMUX_TARGET` fallback) and runs only `tmux list-panes` and `tmux capture-pane`. No findings. The untracked plan and implementation report match the code.

Acceptance criteria:
- Last 20 non-empty lines, `--lines N` changes the count: met (`bin/kingpin-peek:18,53,86`; Test 20 default, `--lines 5`, `--lines=3`, invalid values).
- Resolves the pane from the recorded tmux target, works after rename: met (`bin/kingpin-peek:65-74`; Test 20 rename and legacy-fallback cases).
- Non-zero with a clear message for unknown task or missing window: met (`bin/kingpin-peek:56,76-79`; exit 1, "not found" / "not alive", tested).
- Sends no keys, changes no state: met (logging tmux shim shows only list-panes and capture-pane; task folder and pane compared before and after).
- AGENTS.md lists peek, README documents it: met (AGENTS.md Hard Rule 1 and the `exited` step; README command table and fleet overview).

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
None

**Noted, not a finding**: the task-id handling (`tasks/$id` with no sanitising) matches `kingpin-send`, and peek is read-only, so it adds no new exposure.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n bin/kingpin-peek`; shell project, no build step; host |
| Warnings | N/A | no warnings gate in the project |
| Lint | SKIPPED | shellcheck is not installed and the project has no lint command |
| Tests | PASS | `for t in tests/test-*.sh; do bash "$t"; done` on the host (private tmux socket): 5 of 5 suites pass, including Test 20; no skipped tests |
| UI verification | N/A | no UI change |

## What's Good

- Reuses the `kingpin-send` resolution pattern, so renamed or moved windows work.
- The argument parsing is strict (exit 2 for bad `--lines`, unknown options, extra arguments) and the exit codes are documented.
- Test 20 proves read-only behaviour with a tmux shim and before/after comparisons instead of just asserting output.

## Recommendation

Ready to land. Nothing to fix.
