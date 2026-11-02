# Review: kingpin/kingpin-1102-232253 (issue #34)

**Reviewer note**: this session had no subagent tool, so the review was run by the same session that implemented the change. It is not independent.

## Summary

Adds harness recording to the orchestrator lock and the new spawn precedence. All six acceptance criteria of #34 are met; `kingpin list` is left unchanged, which the criterion allows ("if cheap").

## Issues Found

### Critical
None.

### High Priority
None.

### Medium Priority
None.

### Suggestions (Low)

- **L1** `README.md:64` Project files written by earlier `kingpin init` runs contain `HARNESS=claude` and cannot be told apart from an explicit choice, so they still beat the lock holder. Documented in the README; no migration is attempted. On this machine only `sandbox.env` sets a `HARNESS` (`agy`), so nothing needs editing.
- **L2** `bin/kingpin-lock:74` An invalid `KINGPIN_HARNESS` exported in the orchestrator's shell makes every `lock acquire` fail with `unsupported harness`. Intended (fail loudly instead of recording a wrong harness), and covered by a test.
- **L3** `bin/kingpin:98` `kingpin list` does not show the lock holder's harness; `kingpin lock status` does. Optional follow-up if the boss wants it in the fleet table.

## Validation Results

| Check | Result |
|-------|--------|
| `bash -n` on changed scripts | PASS |
| `tests/test-automation.sh` | PASS |
| `tests/test-harnesses.sh` | PASS |
| `tests/test-acceptance.sh` | PASS |

## What's Good

- The pid stays on line 1 of the lock file, so older readers keep working.
- A stale lock never leaks its harness (liveness is checked on read; `acquire` rewrites the file).
- Tests unset `CLAUDECODE`, `OPENCODE` and `KINGPIN_HARNESS`, so results do not depend on the agent that runs them.

## Recommendation

APPROVE WITH NITS
