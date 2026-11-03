# Plan: issue #45 — kingpin-wait wakes on informational lines and repeats quiet and false exited events

Approach (full path, no prime focus; plan, implementation and review ran inline because the worker had no separate subagent run):
- `bin/kingpin-wait`: a new status line wakes the waiter only if some unseen line is not `issue:`/blank (rename side effect kept); an acknowledged `needs-input:` worker is not `quiet` again while its pane `window_activity` equals the value `kingpin-ack` stored in `seen_activity`; an unfound window is not `exited` while `kingpin-spawn`'s fresh `launching` marker exists (120 s grace); pane text `/tasks to see subagents` counts as busy (comment on #45).
- `bin/kingpin-ack`: records `seen_activity`. `bin/kingpin-spawn`: writes `launching` before `task.env`, removes it after `TMUX_WINDOW_ID` is recorded.
- Tests in `tests/test-automation.sh` (Test 6b, t17); README note.
