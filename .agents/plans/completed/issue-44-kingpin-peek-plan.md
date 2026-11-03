# Plan: `kingpin peek` - read-only view of a worker's pane

## Summary

Add `bin/kingpin-peek <task-id> [--lines N]` and a `peek` case in `bin/kingpin`. It resolves the worker's pane the same way `kingpin-send` does (`TMUX_WINDOW_ID` first, then `TMUX_TARGET`, then `kingpin:<id>`), captures the pane with `tmux capture-pane -p` including scrollback, drops blank lines, and prints the last N (default 20). It only calls `tmux list-panes` and `tmux capture-pane`, writes nothing, and exits 1 with a `kingpin-peek:` message for an unknown task, a bad `--lines`, or a window that is gone. A new Test 20 in `tests/test-automation.sh` covers each acceptance criterion; `README.md` and `AGENTS.md` document `peek` as the way to look at a worker.

## User Story

As the boss (orchestrator) supervising the fleet
I want a read-only `kingpin peek <task-id>`
So that I can diagnose a stuck worker without raw `tmux capture-pane` calls outside the contract

## Metadata

| Field | Value |
|-------|-------|
| Type | NEW_CAPABILITY |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-peek` (new), `bin/kingpin`, `tests/test-automation.sh`, `README.md`, `AGENTS.md` |
| GitHub Issue | #44 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| Baseline `bash tests/test-automation.sh` on HEAD | `ALL AUTOMATION TESTS PASSED` (about 39 s) |
| `shellcheck` | not installed; use `bash -n` only |
| Fake tmux in tests | `tests/test-automation.sh:25-35` wraps real tmux with `-L <private socket>` via `$T/bin/tmux` on `PATH`; windows are created with `tmux new-window -d -t kingpin: -n <name> cat` (Test 13, `:1109-1149`) |
| Existing capture use | `bin/kingpin-wait:119` `tmux capture-pane -pt "$tmux_target" -S -30` |
| Forward references to `#44` in source/docs/plans | none |

## Patterns to Follow

### Naming and target resolution
```
// SOURCE: bin/kingpin-send:11-39
KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}
[ $# -ge 2 ] || { echo "usage: kingpin-send <task-id> <text>" >&2; exit 1; }
task_dir="$KP_HOME/tasks/$id"
[ -d "$task_dir" ] || { echo "kingpin-send: task $id not found: $task_dir" >&2; exit 1; }
... tmux_target from TMUX_TARGET, overridden by TMUX_WINDOW_ID, shown_target for messages
if ! tmux list-panes -t "$tmux_target" >/dev/null 2>&1; then
  echo "kingpin-send: tmux window $shown_target is not alive" >&2
  exit 1
fi
```

### Dispatch
```
// SOURCE: bin/kingpin:76-78
  send)
    exec "$KP_BIN/kingpin-send" "$@"
    ;;
```

### Tests
```
// SOURCE: tests/test-automation.sh:1109-1149 (Test 13)
mkdir -p task dir; tmux new-window -d -t kingpin: -n <name> cat; write task.env with TMUX_TARGET=kingpin:<name>;
assert with pass "..." / fail "..."; cleanup with tmux kill-window and rm -rf.
```

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-peek` | CREATE | The read-only command |
| `bin/kingpin` | UPDATE | Header usage comment, help text, `peek)` dispatch |
| `tests/test-automation.sh` | UPDATE | Test 20 for the five acceptance criteria |
| `README.md` | UPDATE | Add `kingpin peek` row to the CLI Command Reference |
| `AGENTS.md` | UPDATE | Name `kingpin peek` as the way to look at a worker (Hard Rule 1 allowed commands, rule 4 / needs-input flow) |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Create `bin/kingpin-peek`

- **File**: `bin/kingpin-peek` (mode 755)
- **Action**: CREATE
- **Implement**:
  - `usage: kingpin-peek <task-id> [--lines N]`; `-h|--help` prints it and exits 0. Parse args: one positional id, `--lines N` or `--lines=N`; `N` must match `^[1-9][0-9]*$`, else `kingpin-peek: --lines needs a positive integer` exit 2; a missing id, an unknown option or a second positional prints usage to stderr, exit 2.
  - Resolve `task_dir="$KP_HOME/tasks/$id"`; missing -> `kingpin-peek: task $id not found: $task_dir` exit 1. Target resolution exactly as in `kingpin-send` (window ID wins, name target is the fallback and is shown in messages).
  - `tmux list-panes -t "$target" >/dev/null 2>&1` fails -> `kingpin-peek: tmux window $shown_target is not alive` exit 1.
  - Capture with `tmux capture-pane -p -J -t "$target" -S -2000` (joined wrapped lines, scrollback included), then `awk 'NF'` to drop empty and whitespace-only lines, then `tail -n "$lines"`. If capture-pane fails, report `kingpin-peek: could not read tmux window ...` exit 1. Use `set -euo pipefail`; read the capture into a variable first so a pipe failure is not masked.
  - Print only the pane lines on stdout, no header, no writes to the task dir, no `send-keys`.
- **Mirror**: `bin/kingpin-send:1-48`
- **Validate**: `bash -n bin/kingpin-peek && test -x bin/kingpin-peek`

### Task 2: Wire `peek` into `bin/kingpin`

- **File**: `bin/kingpin`
- **Action**: UPDATE
- **Implement**: add `#   kingpin peek <task-id> [--lines N]` to the header comment (after `send`), a `peek      Show the last lines of a worker's tmux pane (read-only)` line to the help text, and a `peek)` case that `exec`s `kingpin-peek`.
- **Mirror**: `bin/kingpin:76-78`
- **Validate**: `bash -n bin/kingpin && bash bin/kingpin --help | grep -q peek`

### Task 3: Add Test 20 to `tests/test-automation.sh`

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE (insert before the final `if [ "$FAILED" -eq 0 ]` block, after Test 19 cleanup)
- **Implement**: Test 20 on the existing private-socket tmux. Create task `t20-peek` with a window running `bash -c 'for i in $(seq 1 40); do echo "line-$i"; echo; done; echo "   "; exec cat'` and a `task.env` with `TMUX_TARGET=kingpin:t20-peek` and `TMUX_WINDOW_ID` taken from `tmux display-message -p -t ... '#{window_id}'`. Poll until the pane shows `line-40`. Then:
  1. default output has exactly 20 lines, the last is `line-40`, the first is `line-21`, and none is blank (AC1);
  2. `--lines 5` gives 5 lines ending in `line-40`; `--lines=3` works too; `--lines 0`, `--lines abc` exit 2 (AC1);
  3. rename the window (`tmux rename-window`) so `TMUX_TARGET` is stale, and peek still prints `line-40` (AC2); a legacy `task.env` with only `TMUX_TARGET` still works when the name matches;
  4. unknown task exits 1 with `not found`; killing the window gives exit 1 with `not alive` (AC3);
  5. no side effects (AC4): put a logging `tmux` shim dir first on `PATH` for one peek call (it appends its subcommand to a log and execs `$T/bin/tmux`); assert the log has only `list-panes` and `capture-pane`, no `send-keys`; assert a checksum of the task dir (`find ... | sort | xargs sha256sum` plus file list) is identical before and after, and the pane content (`capture-pane`) is identical before and after.
  Cleanup: kill the window, `rm -rf` the task dir and shim dir.
- **Mirror**: `tests/test-automation.sh:1109-1149`
- **Validate**: `bash tests/test-automation.sh 2>&1 | grep -E "t20|ALL AUTOMATION|FAIL"`

### Task 4: Document in README and AGENTS

- **File**: `README.md`, `AGENTS.md`
- **Action**: UPDATE
- **Implement**: README: add a `kingpin peek` row after `kingpin send` in the command table (`kingpin peek <task-id> [--lines N]`; last 20 non-empty lines, resolves the pane from the recorded window ID with the `TMUX_TARGET` fallback, read-only, errors exit 1) and a short mention under the terminal fleet overview. AGENTS.md: in Hard Rule 1 add that bash may also run `kingpin peek <task-id>` to look at a worker's pane (never raw `tmux`); in the `needs-input:` / `exited` handling say to use `kingpin peek <task-id>` when a worker is stuck or silent, and add it to the Supervise step. Keep it to a few lines; no persona text in the README.
- **Mirror**: `README.md` command table row for `kingpin send`; `AGENTS.md` Hard Rules 1 and 4
- **Validate**: `grep -c "kingpin peek" README.md AGENTS.md`

---

## Validation

```bash
# Syntax (shellcheck is not installed)
for f in bin/kingpin bin/kingpin-peek tests/test-automation.sh; do bash -n "$f"; done

# Tests (all five suites)
for t in tests/test-*.sh; do bash "$t"; done
```

## End-to-End Verification

Real-tmux run on a scratch socket and scratch `KINGPIN_HOME` (no touch of the user's tmux or `~/.kingpin`): `TMUX_TMPDIR=$(mktemp -d)`, start `tmux -L peek-e2e new-session -d -s kingpin 'cat'`, create a window printing 30 numbered lines with blanks, write a `task.env` with its `TMUX_WINDOW_ID`, run `KINGPIN_HOME=... bin/kingpin peek <id>` (expect 20 non-empty lines), `--lines 5` (expect 5), rename the window and rerun (still works), kill the window (expect `not alive`, exit 1). Test 20 runs this same flow inside the suite, so the scratch run is only the manual spot check.

## Risks

| Risk | Mitigation |
|------|------------|
| `capture-pane -S -2000` pulls a large scrollback for a long session | Output is cut by `tail`; the cost is one tmux call. In scope: fixed bound of 2000 lines. |
| Wrapped lines split a long message | `-J` joins wrapped lines. In scope. |
| Archived (finished) tasks have no live window | Reported as `task ... not found`; peek is for live workers. Out of scope to read archives. |
| Test 20 is timing-dependent on pane startup | Poll with a bounded loop like Test 13's `pane_has_line`. In scope. |
| Peek leaking into worker or harness code paths | It is a new standalone script; no existing script is changed except the dispatch case. |

## Acceptance Criteria

- [ ] All tasks completed
- [ ] `kingpin peek <id>` prints the last 20 non-empty lines; `--lines N` changes the count
- [ ] Pane resolved from the recorded window ID, so it survives a rename
- [ ] Unknown task and missing window exit non-zero with a clear message
- [ ] Sends no keys and changes no state (test)
- [ ] AGENTS.md lists `kingpin peek` for looking at a worker; README documents it
- [ ] `bash -n` clean and all five test suites pass
- [ ] Follows existing patterns
