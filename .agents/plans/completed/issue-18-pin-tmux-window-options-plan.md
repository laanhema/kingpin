# Plan: Pin tmux window options on spawn

## Summary

`bin/kingpin-spawn` creates each worker window with `tmux new-window -d -P -F '#{window_id}' -t "$target_session:" -n "$id" ...` and records the window ID. We add, right after that call, two `tmux set-window-option -t "$window_id"` commands that set `automatic-rename off` and `allow-rename off`, so ambient tmux configuration (`automatic-rename on`, `allow-rename on`) cannot rename a task window. A new test block in `tests/test-automation.sh` turns both options on globally on the private tmux server, spawns a worker, and asserts the window options and that a worker-emitted rename escape sequence does not change the window name. The legitimate rename by `bin/kingpin-rename` (an explicit `tmux rename-window`) is unaffected and is re-asserted by the existing Test 17.

## User Story

As the boss running a fleet of workers in tmux
I want task windows to keep the name Kingpin gave them
So that the status line is stable and name-based targets (`TMUX_TARGET`, `kingpin send`) stay readable

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-spawn`, `tests/test-automation.sh`, `README.md` |
| GitHub Issue | #18 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings (probed on a private `tmux -L` socket, tmux 3.8)

| Probe | Result |
|-------|--------|
| Baseline `./tests/test-automation.sh` on HEAD | `ALL AUTOMATION TESTS PASSED` (green; the test file ends with that line) |
| Global `automatic-rename on`, `allow-rename on`; `new-window -n pinned` | window option `automatic-rename` is already `off` (tmux turns it off when `-n` is given); `allow-rename` is still `1` (inherited from global) |
| Same, window created without `-n` | `automatic-rename` is `1`, name becomes the running command (`tmux`) |
| Worker prints `printf '\033kevil\033\\'` in a window created with `-n`, `allow-rename on` globally | window name becomes `evil` (HEAD behaviour, bug reproduced) |
| Same, after `set-window-option -t $w automatic-rename off` and `allow-rename off` | window name stays `pin-fixed` |
| `set-window-option -t @N automatic-rename off` works with a window ID target | yes; `display-message -p -t @N '#{automatic-rename} #{allow-rename}'` prints `0 0` |

Consequences: `-n` alone protects against automatic renaming only by an implicit tmux side effect, and does nothing against the escape-sequence rename (`allow-rename`), which is the real hole. The explicit `automatic-rename off` is still required by the issue and makes the intent independent of that tmux behaviour. `show-window-options` takes at most one option name; use `display-message -p '#{...}'` to read several.

## Patterns to Follow

### Spawn window creation (insert after it)
```
// SOURCE: bin/kingpin-spawn:324-329
# Record the window ID (@N): unlike the name in TMUX_TARGET, it survives a
# rename or a move to another session.
window_id=$(tmux new-window -d -P -F '#{window_id}' -t "$target_session:" -n "$id" -c "$worktree" "$task_dir/launch.sh")
printf 'TMUX_WINDOW_ID=%s\n' "$window_id" >> "$task_dir/task.env"
launched=1
```

### Window-ID targeted tmux call
```
// SOURCE: bin/kingpin-rename:47-49
window=${window_id:-$target}
if tmux list-panes -t "$window" >/dev/null 2>&1; then
  tmux rename-window -t "$window" "$new"
```

### Tests (private socket, assertions per spawned window)
```
// SOURCE: tests/test-automation.sh:159-166
spawn_out_outside=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 203 --id task-target-outside --mode review)
...
outside_wid=$(tmux list-windows -t kingpin -F '#{window_id} #{window_name}' | awk '$2=="task-target-outside"{print $1}')
grep -qx "TMUX_WINDOW_ID=$outside_wid" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && ... && pass "..." || fail "..."
"$KP_BIN/kingpin" done task-target-outside --force >/dev/null
```

The `tmux` in the tests is a wrapper script around `tmux -L $TEST_SOCKET` (`tests/test-automation.sh:28-35`), and `kingpin-spawn` calls the same `tmux` through `PATH`, so global options set from the test apply to the spawned windows on that private server only.

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-spawn` | UPDATE | Pin `automatic-rename off` and `allow-rename off` on the new window right after creation |
| `tests/test-automation.sh` | UPDATE | New Test 18: windows keep their assigned name under ambient `automatic-rename on` / `allow-rename on` |
| `README.md` | UPDATE | One sentence in the `kingpin spawn` row: the window is pinned against automatic and escape-sequence renames; only `kingpin-wait` renames it |

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Reproduce red test first (test)

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: Insert a `# Test 18: ...` block before the final `if [ "$FAILED" -eq 0 ]` (`tests/test-automation.sh:1433-1435`, right after `unset KINGPIN_GH` that ends the Test 17 block). Steps:
  1. `tmux set-option -g automatic-rename on` and `tmux set-option -g allow-rename on` (use `-gw` is fine too; on tmux 3.8 `-g` on these window options works). Add a comment that this simulates a user config. The private server is killed in `cleanup`, so nothing leaks.
  2. Create a fake worker `$T/fake-renamer` that waits for a marker, then emits a rename escape sequence and a child-command-like output, then keeps the window alive: `until [ -f "$KINGPIN_TASK_DIR/go" ]; do sleep 0.1; done; printf '\033kevil\033\\'; : > "$KINGPIN_TASK_DIR/emitted"; exec bash` (the `go` marker removes the race between the worker and the post-creation `set-window-option`; `KINGPIN_TASK_DIR` is exported by `launch.sh` for agy, see Test 4's fake runner at `tests/test-automation.sh:129-146`). Set `export KINGPIN_AGY=$T/fake-renamer`.
  3. `"$KP_BIN/kingpin" spawn demo-auto --issue 306 --id t18-pinned --mode review >/dev/null`; read `t18_wid` from `TMUX_WINDOW_ID=` in its `task.env`.
  4. Assert `tmux display-message -p -t "$t18_wid" '#{automatic-rename} #{allow-rename}'` equals `0 0`.
  5. `touch "$KINGPIN_HOME/tasks/t18-pinned/go"`, poll up to ~5s for `emitted` (same loop style as Test 15's `seq 1 50` / `sleep 0.1`), sleep 0.3, then assert `#{window_name}` is still `t18-pinned`.
  6. Clean up: `"$KP_BIN/kingpin" done t18-pinned --force >/dev/null`; restore `export KINGPIN_AGY=$T/fake-worker`; unset the two globals with `tmux set-option -gu automatic-rename` and `tmux set-option -gu allow-rename`.
- **Mirror**: `tests/test-automation.sh:159-166` (spawn plus window-ID assertion) and `tests/test-automation.sh:1235-1250` (poll loop for pane output).
- **Validate**: `./tests/test-automation.sh 2>&1 | grep -E "t18|FAIL"` must show `FAIL: t18: ...` lines on HEAD (red) before Task 2, i.e. the options read `0 1` and the name becomes `evil`.

### Task 2: Pin the window options in the spawner

- **File**: `bin/kingpin-spawn`
- **Action**: UPDATE
- **Implement**: Directly after the `window_id=$(tmux new-window ...)` line (`bin/kingpin-spawn:326`), before the `TMUX_WINDOW_ID` write, add:
  ```
  # Pin the name: ambient `automatic-rename on` and `allow-rename on` (tmux config,
  # or an escape sequence from the worker's child commands) would otherwise
  # rename the window. Only kingpin-rename/kingpin-wait renames it, explicitly.
  tmux set-window-option -t "$window_id" automatic-rename off
  tmux set-window-option -t "$window_id" allow-rename off
  ```
  Keep them under `set -e`: if tmux cannot set the option the window was never created properly, and failing loudly is correct. But note `launched=1` is set after; a failure here would trigger `cleanup` (worktree returned, task dir removed) while the window runs. To keep that consistent, either set `launched=1` right after `window_id` is assigned, or append `|| true` to both pin commands. Decision: append `|| true` (a failed pin is cosmetic, not worth tearing down a started worker), and print nothing.
  Do not touch `bin/kingpin-rename`: an explicit `rename-window` works regardless of these options.
- **Mirror**: `bin/kingpin-rename:47-49` (tmux call by window ID).
- **Validate**: `bash -n bin/kingpin-spawn && ./tests/test-automation.sh 2>&1 | grep -E "t18|FAIL|ALL AUTOMATION"` shows `PASS: t18...` lines and `ALL AUTOMATION TESTS PASSED`.

### Task 3: Document

- **File**: `README.md`
- **Action**: UPDATE
- **Implement**: In the `kingpin spawn` row (`README.md:100`), after the sentence about `TMUX_WINDOW_ID`, add: "The window is pinned with `automatic-rename off` and `allow-rename off`, so ambient tmux settings and worker child commands cannot rename it; only `kingpin-wait` renames it."
- **Mirror**: surrounding sentences in the same table row.
- **Validate**: `grep -n "allow-rename off" README.md bin/kingpin-spawn` shows both files.

### Task 4: Full regression

- **File**: all test scripts
- **Action**: CHECK
- **Implement**: Run every suite; they all spawn through `kingpin-spawn`.
- **Validate**: see Validation block.

## Validation

```bash
# Syntax
bash -n bin/kingpin-spawn tests/test-automation.sh

# Tests (baseline on HEAD: automation suite green)
./tests/test-automation.sh
./tests/test-harnesses.sh
./tests/test-worker-settings.sh
./tests/test-report.sh
./tests/test-acceptance.sh

# Reproduction: red on HEAD (t18 FAIL lines), green after Task 2
./tests/test-automation.sh 2>&1 | grep -E "t18"
```

There is no lint or typecheck config in the repo (no manifest, no `.github/workflows`).

## End-to-End Verification

On a scratch tmux server (never the user's): `T="tmux -L e2e-$$ -f /dev/null"`, create a session `kingpin`, set `automatic-rename on` and `allow-rename on` globally, run the real spawner through the test's wrapper (Test 18 does exactly this with a fake `agy`). Expected: the new window reports `0 0` for `#{automatic-rename} #{allow-rename}`, keeps its name after the worker prints `\033kevil\033\\`, and after `echo "issue: #N ..." >> status` plus `kingpin-wait --once` it is renamed to `kp-N-<slug>` by `kingpin-rename` (Test 17 covers this and must stay green).

## Risks

| Risk | Mitigation |
|------|------------|
| Window options are set after `new-window`, so the worker could emit a rename in the first milliseconds | Negligible: the harness takes far longer to start than the two tmux calls; the test gates the worker on a marker file for determinism. Out of scope: creating the window paused (would change launch flow). Flag only. |
| `-n "$id"` already disables `automatic-rename` in tmux, so the new test cannot show a red state for that option alone | The red state comes from `allow-rename` (`0 1` on HEAD) and the escape-sequence rename; assert both options anyway, as the issue asks. |
| A failing `set-window-option` under `set -e` would trigger `cleanup` (returns worktree, deletes task dir) with a live window | Add `\|\| true` to both pin commands (in scope). |
| Pinning could block `kingpin-rename` | An explicit `rename-window` is unaffected by both options; Test 17 (`tests/test-automation.sh:1361-1433`) re-asserts the rename and must stay green (in scope, verified). |
| The test sets global options on the shared private server and later tests rely on default naming | Test 18 is last; later code is only the summary. Unset the two globals at the end of the block anyway (`tmux set-option -gu ...`). |
| `kingpin-curate` also creates a window (`bin/kingpin-curate:110`, `-n curator`) | Out of scope: the issue names `kingpin-spawn` only. Flag it in the PR as a possible follow-up. |

## Open Questions

- Should `bin/kingpin-curate:110` pin the same options for its `curator` window? Proposed default: no, keep to the issue's scope (`bin/kingpin-spawn`); mention in the PR.

## Acceptance Criteria

- [ ] `bin/kingpin-spawn` sets `automatic-rename off` and `allow-rename off` on the new window by ID
- [ ] Test 18 in `tests/test-automation.sh` fails on HEAD and passes after the change, with ambient `automatic-rename on` and `allow-rename on`
- [ ] Test 17 (rename by `kingpin-rename`) still passes
- [ ] All five test suites pass
- [ ] README spawn row documents the pinning
- [ ] Follows existing patterns
