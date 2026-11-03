# Review: kingpin/kp-45-kingpin-wait-wakes (issue #45)

Note: self-review by the implementing worker; not independent of the implementation.

**Verdict**: APPROVE WITH NITS

All four acceptance criteria are covered by tests (Test 6b, t17, existing tests green).

## Findings

1. **Low** — `bin/kingpin-wait:65-72` — The hold lifts as soon as `window_activity` differs from the ack-time value. Output the worker draws after the ack (its final redraw after `needs-input:`) can change it, so a single `quiet` can still slip through in that race. Window activity has one-second granularity. Residual, not a regression.
2. **Low** — `bin/kingpin-wait:158` — `/tasks to see subagents` is matched within the last 30 pane lines, so text left in scrollback after the subagents finish can hide a real `quiet` (same weakness as the existing `Background agent` pattern).
