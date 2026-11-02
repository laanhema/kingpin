# Code Review: kingpin/kingpin-9

**Scope**: branch `kingpin/kingpin-9` vs merge base 700c456 (main), uncommitted changes included, checked against issue #9
**Recommendation**: APPROVE WITH NITS

## Summary

Reviewed the 8 modified files (spawn, send, wait, ack, done, board, test-automation.sh, README) plus the untracked plan and implementation report (context only). The change records `TMUX_WINDOW_ID=@N` at spawn and every reader prefers it, with a fallback to `TMUX_TARGET` for older task.env files. No other code in `bin/`, `lib/` or `worker/` addresses a worker window by name (`kingpin-curate` targets its own `kingpin:curator` window, out of scope).

Acceptance criteria:
- Spawn records the window ID via `new-window -P -F '#{window_id}'` (`bin/kingpin-spawn:309-310`): met. Test 5 asserts the recorded ID equals the real window's ID, both outside and inside tmux.
- send, wait, done target the window ID and reach a renamed and moved window: met. Test 15 renames a window, moves it to another session, confirms the old name target no longer resolves, and then checks that text arrives in its pane, that wait/ack see it as alive, and that done closes it.
- A task whose recorded window no longer exists still reads as exited: met. Test 15 `t15-gone` kills the recorded window, recreates a window with the same name, and checks wait reports exited and ack writes `seen_exited`.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-board:124` — `tmux_target` now holds the window ID, and `bin/kingpin-board:223` renders it as the pane preview title ("Terminal tail (@5)"). **Why:** the board used to show a readable `session:name`, and now shows an opaque ID. **Fix:** keep the name in the displayed label (for example show `TMUX_TARGET` in the title and use the ID only for the tmux calls).

**Noted, not a finding**: the window ID is appended to task.env after `new-window` returns (`bin/kingpin-spawn:310`), so readers in that instant fall back to the name target. That is the same behaviour as before the change, and the window is not renamed in that interval.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n` on every `bin/kingpin-*` bash script; host |
| Warnings | N/A | no warnings-as-errors build in this repo |
| Lint | SKIPPED | shellcheck is not installed on the host, and the repo defines no lint command |
| Tests | PASS | `bash tests/test-automation.sh`, `test-worker-settings.sh`, `test-harnesses.sh`, `test-report.sh`, `test-acceptance.sh` on the host with private tmux sockets; all print their ALL ... PASSED line, no skipped tests |
| UI verification | N/A | the only visual change is a label in the board's pane preview title (L1); no layout change |

## What's Good

- Consistent precedence in every reader (window ID, then `TMUX_TARGET`, then `kingpin:<id>`), with no name fallback once an ID is recorded, so a dead ID is not masked by a new window with the old name.
- Test 15 covers rename plus move, gone window with a recycled name, and legacy task.env; it uses isolated tmux sockets and per-task worktree paths.
- README row updated.

## Recommendation

Merge after optionally addressing L1. Run `/fix-findings .agents/reviews/kingpin-kingpin-9-review.md L1` to apply it.
