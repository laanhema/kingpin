# Plan: kingpin-send sends text literally, then Enter separately

## Summary

`bin/kingpin-send` ends with `tmux send-keys -t "$tmux_target" "$keys" Enter`. Without `-l`, tmux parses the text as key names (`Escape`, `C-c`, `Enter` become keypresses), and the text plus Enter in one call can land inside a TUI paste instead of submitting. Fix: send the text with `send-keys -l -- "$keys"`, pause briefly (`KINGPIN_SEND_DELAY`, default 0.2s), then send `Enter` in a second call. Callers (`bin/kingpin-land`, `bin/kingpin`) only pass plain text such as `/review --issue 3`, so literal sending is safe. Tests go in `tests/test-automation.sh` on its private tmux server.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-send`, `tests/test-automation.sh`, `tests/test-acceptance.sh` |
| GitHub Issue | #12 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| `bash tests/test-automation.sh` on HEAD | green: `ALL AUTOMATION TESTS PASSED` |
| tmux | 3.x at `/usr/bin/tmux`; shellcheck not installed |
| Callers of `kingpin-send` | `bin/kingpin-land:45,47,82,84,126,129` and `bin/kingpin:83`; all plain text |
| Hazard | `tests/test-automation.sh:109` and `tests/test-acceptance.sh:170` run `git checkout bin/kingpin-send` to undo their stub, which discards uncommitted edits to the real script |

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-send` | UPDATE | literal text send, pause, separate Enter |
| `tests/test-automation.sh` | UPDATE | restore the stub from a backup copy instead of `git checkout`; add Test 12 (literal `Escape`/`C-c`, 2,000-char message) |
| `tests/test-acceptance.sh` | UPDATE | same backup-copy restore (cleanup trap and end of file) |

## Tasks

### Task 1: Fix kingpin-send

- **File**: `bin/kingpin-send`
- **Action**: UPDATE
- **Implement**: replace the final `send-keys` with `tmux send-keys -t "$tmux_target" -l -- "$keys"`, `sleep "${KINGPIN_SEND_DELAY:-0.2}"`, `tmux send-keys -t "$tmux_target" Enter`. `--` keeps text that starts with `-` from being parsed as a flag. Note the delay variable in the header comment.
- **Mirror**: existing style in `bin/kingpin-send`
- **Validate**: `bash -n bin/kingpin-send`

### Task 2: Make the stub restore safe in the existing tests

- **File**: `tests/test-automation.sh`, `tests/test-acceptance.sh`
- **Action**: UPDATE
- **Implement**: before each stub overwrite, `cp -p "$KP_BIN/kingpin-send" "$T/kingpin-send.orig"`; replace each `git -C "$KP_ROOT" checkout bin/kingpin-send` with `cp -p "$T/kingpin-send.orig" "$KP_BIN/kingpin-send"` (in `test-acceptance.sh` also the cleanup trap, guarded with `[ -f ... ]`). This keeps uncommitted edits of the real script.
- **Mirror**: `tests/test-automation.sh:94-109`, `tests/test-acceptance.sh:36,115-124,170`
- **Validate**: `bash tests/test-automation.sh && git diff --stat bin/kingpin-send` (edit still present)

### Task 3: Add Test 12 to test-automation.sh

- **File**: `tests/test-automation.sh` (before the final `if [ "$FAILED" -eq 0 ]`)
- **Action**: UPDATE
- **Implement**: create task dir `t12-send` with `task.env` (`TMUX_TARGET=kingpin:t12-send`) and a `cat` window. Through the real `$KP_BIN/kingpin-send`: (a) send `Escape`, then `C-c`; poll `capture-pane -pJ` until the pane has a line exactly `Escape` and one exactly `C-c`, assert the window is still alive (a real C-c would kill `cat`); (b) send a 2,000-character message (`printf '%04d' $(seq 1 500)`), assert a pane line (joined with `-J`) equals it in full; (c) assert a message that starts with `-` arrives. Kill the window, remove the task dir.
- **Mirror**: `tests/test-automation.sh:498-527` (`cat` window + `capture-pane`), `pass`/`fail` helpers at lines 18-19
- **Validate**: `bash tests/test-automation.sh`; the new checks must fail against HEAD's `kingpin-send` (back up the edited script to `/tmp`, put `git show HEAD:bin/kingpin-send` in its place, run the test, then restore the backup)

## Validation

```bash
bash -n bin/kingpin-send tests/test-automation.sh tests/test-acceptance.sh
bash tests/test-automation.sh
bash tests/test-acceptance.sh
bash tests/test-harnesses.sh
bash tests/test-worker-settings.sh

# Reproduction (red on HEAD's bin/kingpin-send, green after the fix): the new Test 12 checks in tests/test-automation.sh
```

## End-to-End Verification

Run `bash tests/test-automation.sh`. Test 12 drives the real `bin/kingpin-send` against a `cat` pane on the private tmux socket: `Escape` and `C-c` come back as text lines, the pane survives, and the 2,000-character message comes back whole. Confirm the same Test 12 fails with the pre-fix `kingpin-send`. Confirm `git diff --stat bin/kingpin-send` still shows the edit after `test-acceptance.sh` and `test-automation.sh` ran.

## Risks

| Risk | Mitigation |
|------|------------|
| Fixed delay may be too short for a slow TUI | Overridable via `KINGPIN_SEND_DELAY`; default 0.2s (in scope) |
| A caller relied on key-name interpretation | Grepped all callers: plain text only (in scope: checked) |
| Multi-line text via `-l` sends newlines as keys | Callers send single-line text; not changed (out of scope, flag only) |
| Test pane timing flakiness | Poll with a bounded retry loop, not a bare sleep (in scope) |

## Acceptance Criteria

- [ ] All tasks completed
- [ ] Text is sent with `send-keys -l`, then Enter in a separate call after a short pause; test sends `Escape` and `C-c` literally to a `cat` pane and reads them back
- [ ] A 2,000-character message arrives intact (tested)
- [ ] All tests in `tests/` pass
- [ ] Follows existing patterns
