# Plan: Track worker windows by tmux window ID

## Summary

Workers are addressed by `TMUX_TARGET=<session>:<task-id>`, a window name. Renaming a window or moving it to another session makes `kingpin-send`, `kingpin-wait`, `kingpin-ack`, `kingpin-done` and `kingpin-board` read the live worker as dead. Fix: `kingpin-spawn` creates the window with `tmux new-window -P -F '#{window_id}'` and appends `TMUX_WINDOW_ID=@N` to `task.env`. Every reader prefers `TMUX_WINDOW_ID` and falls back to `TMUX_TARGET` (then `kingpin:<id>`) when the key is absent, so task.env files written before this change keep working. `TMUX_TARGET` stays in `task.env` as the human-readable name. When a window ID is recorded and no longer exists, the task reads as exited; the readers do not fall back to the name in that case.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-spawn`, `bin/kingpin-send`, `bin/kingpin-wait`, `bin/kingpin-ack`, `bin/kingpin-done`, `bin/kingpin-board`, `tests/test-automation.sh`, `README.md` |
| GitHub Issue | #9 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| `bash tests/test-automation.sh` on HEAD | green: `ALL AUTOMATION TESTS PASSED` |
| shellcheck | not installed; use `bash -n` |
| tmux isolation | `tests/test-automation.sh:22-35` wraps `tmux` with `-L kingpin-test-auto-$$`; window IDs (`@N`) are per server, so tests operate only on the private server |
| Readers of `TMUX_TARGET` | `bin/kingpin-send:25`, `bin/kingpin-wait:83`, `bin/kingpin-ack:63`, `bin/kingpin-done:109` (sources task.env), `bin/kingpin-board:56,124` (python dict) |
| Forward references to #9 | none in source or prior plans; #3 (active-session targeting) keeps name-based `TMUX_TARGET`, which stays as the fallback |
| Docs | README and AGENTS.md do not mention `TMUX_TARGET`; README gets one short note |

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-spawn` | UPDATE | create window with `-P -F '#{window_id}'`, append `TMUX_WINDOW_ID` to task.env |
| `bin/kingpin-send` | UPDATE | target the window ID, fall back to `TMUX_TARGET` |
| `bin/kingpin-wait` | UPDATE | same, for liveness and pane capture |
| `bin/kingpin-ack` | UPDATE | same, for the `seen_exited` check |
| `bin/kingpin-done` | UPDATE | same, for `kill-window` |
| `bin/kingpin-board` | UPDATE | same, for liveness and pane preview |
| `tests/test-automation.sh` | UPDATE | Test 15 covering the three acceptance criteria, plus legacy task.env check |
| `README.md` | UPDATE | note that workers are tracked by window ID |

## Tasks

Execute in order.

### Task 1: Record the window ID at spawn

- **File**: `bin/kingpin-spawn` (line 307)
- **Action**: UPDATE
- **Implement**: replace the bare `tmux new-window ...` with `window_id=$(tmux new-window -d -P -F '#{window_id}' -t "$target_session:" -n "$id" -c "$worktree" "$task_dir/launch.sh")`; then `printf 'TMUX_WINDOW_ID=%s\n' "$window_id" >> "$task_dir/task.env"` before `launched=1`. Keep `TMUX_TARGET` unchanged. Add a comment that the ID survives rename and move. The existing `launched`/cleanup trap logic is untouched: if `new-window` fails, `set -e` aborts and the trap cleans up.
- **Mirror**: `bin/kingpin-spawn:186` (task.env keys), `:307`
- **Validate**: `bash -n bin/kingpin-spawn`

### Task 2: Resolve the target from the window ID in the readers

- **File**: `bin/kingpin-send`, `bin/kingpin-wait`, `bin/kingpin-ack`, `bin/kingpin-done`, `bin/kingpin-board`
- **Action**: UPDATE
- **Implement**: in each shell script, after the existing `TMUX_TARGET` read, read `TMUX_WINDOW_ID` the same way (`sed -n 's/^TMUX_WINDOW_ID=//p'`); `tmux_target` becomes the window ID when non-empty, else the name target. `kingpin-send` keeps a display name for its message: `OK: sent to <TMUX_TARGET name> (<id>)` when an ID is used, so the existing wording `OK: sent to kp-test-active:task-target-inside` still matches as a prefix; its not-alive error names the ID. `kingpin-done` sources task.env, so use `tmux_target=${TMUX_WINDOW_ID:-${TMUX_TARGET:-kingpin:$id}}`. `kingpin-board` (python): `tmux_target = task_env.get("TMUX_WINDOW_ID") or task_env.get("TMUX_TARGET", f"kingpin:{task_dir.name}")` at both sites (lines 56 and 124).
- **Mirror**: `bin/kingpin-wait:82-84`, `bin/kingpin-send:23-28`
- **Validate**: `bash -n bin/kingpin-send bin/kingpin-wait bin/kingpin-ack bin/kingpin-done && python3 -I -m py_compile bin/kingpin-board`

### Task 3: Tests for the three acceptance criteria

- **File**: `tests/test-automation.sh` (new Test 15 before the final `if [ "$FAILED" -eq 0 ]`; update the Test 5 case A/B checks to also assert `TMUX_WINDOW_ID`)
- **Action**: UPDATE
- **Implement**: (a) in Test 5 after the spawn, assert task.env holds `TMUX_WINDOW_ID=@N` and `N` equals the `#{window_id}` of the window named after the task (`tmux list-windows -t <session> -F '#{window_id} #{window_name}'`). (b) Test 15: create task `t15-move` with a `cat` window, record `TMUX_WINDOW_ID` and the (soon stale) name `TMUX_TARGET=kingpin:t15-move` in task.env; `tmux new-session -d -s kp-t15-other`; `tmux rename-window -t $wid renamed-t15`; `tmux move-window -d -s $wid -t kp-t15-other:`; assert the old name target is dead (`list-panes -t kingpin:t15-move` fails) so the test proves the old behaviour would break; then `kingpin-send t15-move "moved-ok"` and poll `capture-pane -pJt $wid` for the line; `kingpin wait --once` must not print `t15-move exited`; `kingpin ack` must not create `seen_exited`; `kingpin done t15-move --force` is not usable (no PROJECT_PATH), so assert `tmux kill-window` via the real `kingpin-done` instead: give the task.env `PROJECT_PATH=$T/proj`, `WORKTREE=$T/missing` and run `kingpin-done t15-move --force`, then assert the window is gone from `kp-t15-other`. Clean up the extra session. (c) Task `t15-gone` with a recorded `TMUX_WINDOW_ID` of a window that is then killed: `kingpin wait --once` prints `t15-gone exited`. (d) Legacy file: a task.env with only `TMUX_TARGET=kingpin:t15-legacy` and a live window: `kingpin-send` reaches it (back-compat). Use an empty `status` file and `echo 0 > seen`, as in Test 6.
- **Mirror**: `tests/test-automation.sh:192-260` (Test 6 wait/ack), `:1105-1140` (Test 13 pane polling)
- **Validate**: `bash tests/test-automation.sh`; the new move/rename checks must fail on HEAD (temporarily run them with `TMUX_WINDOW_ID` lines stripped from the task.env, which models HEAD behaviour, and confirm send/wait fail)

### Task 4: README note

- **File**: `README.md`
- **Action**: UPDATE
- **Implement**: one sentence near the `kingpin spawn` row or the worker notes: workers are tracked by tmux window ID (`TMUX_WINDOW_ID` in `task.env`), so renaming or moving a worker window is safe; task.env files without it fall back to `TMUX_TARGET`.
- **Mirror**: `README.md:100`, `:161`
- **Validate**: `grep -n TMUX_WINDOW_ID README.md`

## Validation

```bash
# Syntax
for f in bin/kingpin-spawn bin/kingpin-send bin/kingpin-wait bin/kingpin-ack bin/kingpin-done tests/test-automation.sh; do bash -n "$f"; done
python3 -I -m py_compile bin/kingpin-board

# Lint: shellcheck is not installed here; skip if absent
command -v shellcheck >/dev/null && shellcheck bin/kingpin-send bin/kingpin-wait bin/kingpin-ack bin/kingpin-done bin/kingpin-spawn || true

# Tests
bash tests/test-automation.sh
bash tests/test-worker-settings.sh
bash tests/test-harnesses.sh
bash tests/test-report.sh

# Reproduction: Test 15 red on the unfixed code, green after
bash tests/test-automation.sh 2>&1 | grep -i "window id\|renamed\|moved"
```

## End-to-End Verification

Test 15 is the end-to-end check: it spawns nothing live but drives the real `bin/kingpin-send`, `kingpin wait`, `kingpin ack` and `kingpin-done` against real windows on the private tmux server, after a real rename and a move to a second session. Test 5 exercises the real `kingpin spawn` (with the fake worker) and checks the recorded ID against tmux. Do not touch the user's tmux server or session `sesh-1`.

## Risks

| Risk | Mitigation |
|------|------------|
| Old task.env files lack `TMUX_WINDOW_ID` | Fall back to `TMUX_TARGET`, then `kingpin:<id>`; covered by the legacy test (in scope) |
| tmux server restart reuses `@N` IDs, so a dead task could map to another window | Out of scope; a restart also kills all workers, and the ID is only recorded after a successful spawn. Flag in the report |
| Window ID written after the window starts, so a reader could run in between | Readers fall back to the name target for that instant; harmless (in scope, no change) |
| `kingpin-curate` uses `kingpin:curator` by name | Out of scope: not a task worker and not in the issue |

## Acceptance Criteria

- [ ] `kingpin-spawn` records the window ID in `task.env` (test)
- [ ] `kingpin-send`, `kingpin-wait`, `kingpin-done` reach a renamed and moved window (test)
- [ ] A task whose recorded window no longer exists reads as exited (test)
- [ ] Legacy task.env files with only `TMUX_TARGET` still work
- [ ] All tasks completed, syntax checks and all test scripts pass
