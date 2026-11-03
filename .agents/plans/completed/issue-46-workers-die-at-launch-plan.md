# Plan: Mark workers that die at launch as failed

## Summary

A worker that stops without ever writing a status line stays `(pending)` in `kingpin list` and only produces `exited` or `quiet` events that read like normal idling. This plan adds a small helper, `bin/kingpin-launch-check <task-dir>`, that `kingpin-wait` calls for every task whose `status` file is empty. Once a grace period has passed (30 s, `KINGPIN_STATUS_GRACE` overrides) and the worker has stopped, the helper appends one line, `failed: no status: <task> (<harness>) <cause>; never reported a status (<N>s since ...)`, to the task's `status` file. "Stopped" means the tmux window is gone or its panes are dead, or the Stop hook has fired (`stopped` file) and the window has printed nothing for the grace period (the case in the archived dead-agy tasks, see Environment Findings). Because the line is a normal `failed:` status, `kingpin-wait` reports it as a `status` event, `kingpin list` shows it instead of `(pending)`, `kingpin run` stops with `FAILED`, and `kingpin done` releases the slot. A prototype patch implements the helper, the one-line wiring in `kingpin-wait`, and a 20-assertion Test 21; the tasks cover review of the patch, the docs, and the full validation.

All `file:line` references below are lines of HEAD (`b8c2f8e`) before the patch is applied.

## User Story

As the boss supervising the fleet
I want a worker that dies at launch to be reported as failed, with its task and harness named
So that I do not mistake a dead worker for one that is waiting for input, and its worktree slot is not held on paper forever

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-launch-check` (new), `bin/kingpin-wait`, `tests/test-automation.sh`, `README.md`, `AGENTS.md` |
| GitHub Issue | #46 |
| PRD Phase | N/A |
| Prototype Patch | `.agents/plans/issue-46-workers-die-at-launch-prototype.patch` |

## Environment Findings

| Probe | Result |
|-------|--------|
| Baseline on HEAD (`b8c2f8e`) | `test-automation.sh` 247 PASS, 0 FAIL, about 31 s; `test-report.sh` 17; `test-harnesses.sh` 57; `test-worker-settings.sh` 79; `test-acceptance.sh` 19. All green. |
| Linters | `shellcheck` is not installed; no CI directory. Syntax check is `bash -n`. |
| Real evidence of the bug | `~/.kingpin/archive/kingpin-{10,17,19,24,31}-agy-dead/`: all `HARNESS=agy`, `status` is 0 bytes, `stopped` exists. `kingpin-31` stopped 4 s after `CREATED`, `kingpin-24` 18 s after; the others 1145 s to 2347 s after. `quiet` fires only when the window is alive (`bin/kingpin-wait:98-104` returns first for a gone window), so the observed workers had a live window, a fired Stop hook and an empty status. |
| tmux, window whose command exits | `tmux new-window ... 'exit 3'` closes the window at once: `tmux list-panes -t @N` fails ("can't find window"). That is what `bin/kingpin-wait:94` reads as dead. |
| tmux, `remain-on-exit on` | The window stays; `#{pane_dead}` is 1 and `#{pane_dead_status}` is the exit code. `kingpin-wait` reads such a window as alive today. |
| tmux, `#{window_activity}` | Epoch of the last pane output, updated without `monitor-activity` (probe: 1793679238, then 1793679242 when the pane printed). A silent window keeps the old value. |
| tmux server unreachable | `tmux list-panes` fails exactly like a gone window ("no server running"), so a gone window and an unreachable server look the same unless `tmux list-sessions` is checked first. |
| `date -d ""` | Prints today's midnight (1793656800) and exits 0, so an empty `CREATED` would pass a naive age check. `date -d garbage` exits 1. |
| `task.env` fields | `CREATED=$(date -Iseconds)` (`bin/kingpin-spawn:204`) is the only launch time; `kingpin-rename` rewrites `task.env` by `mv` (`bin/kingpin-rename:53-55`), so its mtime is not a launch time. |
| `kingpin done` on a dead-at-launch task | Succeeds without `--force` (clean worktree, HEAD already on `origin/main`): Test 21 asserts it. |
| Red run | Only the Test 21 hunk applied on unpatched HEAD: 11 FAIL (event is `exited`, list shows `(pending)`, nothing recorded, `kingpin run` polls until its `timeout 60`), 256 PASS (247 + 9 assertions that already hold). The red run takes about 1 m 45 s because of that timeout. |
| Green run | Prototype applied to HEAD: `ALL AUTOMATION TESTS PASSED`, 267 PASS (247 + 20 in Test 21), plus the four other suites unchanged and green. |
| Sibling branches | #45 (`d69e6c7`, `Filter kingpin-wait wakes ...`) and #47 (`eb8bbc2`, exit codes) also edit `bin/kingpin-wait`. `git apply --check` of the patch passes on HEAD and on the #45 tip, and `test-automation.sh` on the #45 tip plus the patch passes (284 PASS). The patch does not touch `kingpin-wait`'s header comment, because both siblings rewrite it. |
| Forward references to `#46` in source, docs, plans | None. Related: #24 (archive, `kingpin done`), #45 (`launching` marker, `issue:` lines do not wake). |

## Pinned Semantics

- **Empty status**: the `status` file is missing or has no line with a non-blank character. A worker that wrote any line (even `issue:`) is never touched by this change.
- **Stopped**: (a) the task's tmux window is gone (`list-panes` fails while `list-sessions` works), or every pane has `#{pane_dead}` 1; or (b) the Stop hook has fired (`stopped` holds an epoch), the window is alive, and `#{window_activity}` is at least the grace period old.
- **Grace period**: `KINGPIN_STATUS_GRACE` seconds (non-negative integer, default 30), counted from the epoch in `stopped` when there is one, otherwise from `CREATED`. A live window with no `stopped` file is never failed, however old it is (a slow start).
- **Recorded line**: `failed: no status: <task-id> (<harness>) <cause>; never reported a status (<N>s since launch|its last stop[; kingpin peek <task-id> shows why])`, with cause `exited, tmux window gone`, `exited, tmux pane dead` or `stopped and went silent`. It is a normal last status line: if the worker later writes another line, that line wins everywhere.
- **Events**: the line is a new status line, so `kingpin-wait` prints `<task-id> status` in the same pass. The existing `exited` event for a gone window is unchanged, so a worker whose window closed at once is reported `exited` first and `status` once the grace period is over.
- **Writer**: only `kingpin-wait` (through the helper) writes the line; `kingpin list` stays read-only and shows what is in the file.

## Patterns to Follow

### Naming and helper shape (a helper that `kingpin-wait` calls, silent on stdout)
```
// SOURCE: bin/kingpin-rename:12-26
set -euo pipefail

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}
...
[ $# -ge 1 ] || { echo "usage: kingpin-rename <task-id>" >&2; exit 1; }
...
[ -d "$task_dir" ] && [ -f "$env_file" ] || exit 0
```

### Window target resolution (window ID wins over the name)
```
// SOURCE: bin/kingpin-wait:83-96
  # Read tmux target
  local tmux_target=""
  tmux_target=$(sed -n 's/^TMUX_TARGET=//p' "$task_env" 2>/dev/null || true)
  [ -n "$tmux_target" ] || tmux_target="kingpin:$id"
  # The window ID survives rename and move; older task.env files lack it.
  local window_id=""
  window_id=$(sed -n 's/^TMUX_WINDOW_ID=//p' "$task_env" 2>/dev/null || true)
  [ -n "$window_id" ] && tmux_target=$window_id
```

### Terminal statuses (a `failed:` last line ends further checks, and `kingpin run` stops on it)
```
// SOURCE: bin/kingpin-wait:37-43 and bin/kingpin:242-245
    merged:*|failed:*|cleanup-refused:*) return 0 ;;
...
        failed:*)
          echo "FAILED: $task_id failed: $last_st" >&2
          exit 1
```

### Tests (hand-made task with a real window on the private tmux socket)
```
// SOURCE: tests/test-automation.sh:1219-1236 (mk_t15)
  wid=$(tmux new-window -d -P -F '#{window_id}' -t kingpin: -n "$name" "$cmd")
  cat > "$d/task.env" << ENVEOF
TASK_ID=$name
...
TMUX_WINDOW_ID=$wid
ENVEOF
  : > "$d/status"
  echo 0 > "$d/seen"
```

---

## Files to Change

| File | Action | Purpose | In patch |
|------|--------|---------|----------|
| `bin/kingpin-launch-check` | CREATE | The helper: decides and records `failed: no status: ...` | yes |
| `bin/kingpin-wait` | UPDATE | One guarded call at the top of `check_task` (only when `status` is empty) | yes |
| `tests/test-automation.sh` | UPDATE | Test 21 with 20 assertions (see Task 1) | yes |
| `README.md` | UPDATE | Document the behavior, the grace period and `KINGPIN_STATUS_GRACE` | no |
| `AGENTS.md` | UPDATE | Add a `failed:` branch to the Supervise list | no |

The helper is mode 755 in the patch.

---

## Tasks

Execute in order. `/implement` applies the patch before the first task (Metadata names it); for Task 1 it applies the `tests/test-automation.sh` hunk alone first, for the red run.

### Task 1: Reproduce red, then green

- **File**: `tests/test-automation.sh` (Test 21 at the end of the file, after Test 20)
- **Action**: CHECK
- **Implement**: With only the Test 21 hunk applied, run the reproduction command: it must report 11 `FAIL: t21: ...` lines (the dead worker is only `exited`, `list` shows `(pending)`, no `failed:` line, `kingpin run` polls until its 60 s timeout). Then apply the rest of the patch: no `FAIL` is left. Test 21 covers each acceptance criterion:
  - AC1: a dead window plus an old `CREATED` gives a `failed: no status:` line and a `status` event; the line is written once and not repeated after `kingpin ack`.
  - AC2: the line starts `failed: no status: t21-dead (agy)` and names the cause.
  - AC3: `kingpin list` shows that row with the failed text and without `(pending)`.
  - AC4: a dead window within the grace period, a live window with no stop, a worker that stopped inside the grace period, and a worker whose window still prints are all left alone; `KINGPIN_STATUS_GRACE=1` shortens the period.
  - Also: a worker with a status line is not rewritten; a dead pane under `remain-on-exit` is failed; an unreachable tmux (a `tmux` shim that exits 1) records nothing; a real `kingpin spawn` whose harness exits at once is reported, shown failed, and released by `kingpin done` without `--force`; `kingpin run` exits 1 with `FAILED: ... failed: no status:`.
- **Mirror**: `tests/test-automation.sh:1217-1272` (Test 15)
- **Validate**: `bash tests/test-automation.sh 2>&1 | grep -E "^(PASS|FAIL): t21|ALL AUTOMATION|AUTOMATION TESTS FAILED"`

### Task 2: Review the patched code for placement and comments

- **File**: `bin/kingpin-launch-check`, `bin/kingpin-wait`
- **Action**: CHECK
- **Implement**: Read the patched files once. Confirm: the helper header states usage, the three exit codes, the "stopped" definition and `KINGPIN_STATUS_GRACE`; the call in `check_task` sits right after the `task.env` guard (`bin/kingpin-wait:50`), is guarded by `[ -s "$dir/status" ] ||` so running tasks cost no process, and sends the helper's stdout to `/dev/null` (the function's stdout is the event channel, captured by `check_all` at `bin/kingpin-wait:162`). Do not edit `kingpin-wait`'s header comment: #45 and #47 rewrite it. Fix nothing unless a line contradicts Pinned Semantics.
- **Mirror**: `bin/kingpin-rename:1-24`
- **Validate**: `bash -n bin/kingpin-launch-check && bash -n bin/kingpin-wait && test -x bin/kingpin-launch-check && bash bin/kingpin-launch-check --help 2>&1 | grep -q usage`

### Task 3: Document in README and AGENTS

- **File**: `README.md`, `AGENTS.md`
- **Action**: UPDATE
- **Implement**:
  - `README.md`: after the paragraph that ends `directly below the task row.` (line 125, under "Terminal Fleet Overview"), add one short paragraph: a worker that stops without ever writing a status line is marked `failed: no status: <task> (<harness>) ...` by `kingpin wait` (and so by `kingpin watch` and `kingpin run`); "stopped" means the window or pane is gone, or the Stop hook fired and the window stayed silent for the grace period; the grace period is 30 s from launch (or from the last stop) and `KINGPIN_STATUS_GRACE` sets it; `kingpin list` then shows the failed line, `kingpin peek <id>` shows the pane while the window is open, and `kingpin done <id>` releases the worktree. Put it beside, not inside, the `kingpin wait` paragraph that #45 adds at the same spot, if that has landed; on a conflict keep both.
  - `AGENTS.md`: in the Supervise event list, after the `exited` bullet (line 71), add `On \`failed:\`: relay the reason to the boss. A \`failed: no status:\` line means the worker stopped without reporting anything (a harness that died at launch): run \`kingpin peek <task-id>\` if the window is still open, and \`bin/kingpin done <task-id>\` releases its worktree once the boss agrees.` Keep persona text out of the README.
- **Mirror**: `README.md:105` (the `kingpin done` row) and `AGENTS.md:68-71`
- **Validate**: `grep -c "failed: no status" README.md AGENTS.md`

### Task 4: Full validation

- **File**: `tests/test-automation.sh`, `tests/test-report.sh`, `tests/test-harnesses.sh`, `tests/test-worker-settings.sh`, `tests/test-acceptance.sh`
- **Action**: CHECK
- **Implement**: Run the syntax check and all five suites (start green: 247, 17, 57, 79, 19 PASS on HEAD; automation ends at 267). If #45 or #47 has reached the base branch by then, rebase first and run again; the patch applied cleanly to the #45 tip.
- **Mirror**: `README.md` "Running Automated Tests"
- **Validate**: `for f in bin/kingpin-launch-check bin/kingpin-wait tests/test-automation.sh; do bash -n "$f"; done && for t in tests/test-*.sh; do bash "$t" || exit 1; done`

---

## Validation

```bash
# Syntax (shellcheck is not installed)
for f in bin/kingpin-launch-check bin/kingpin-wait tests/test-automation.sh; do bash -n "$f"; done

# Tests (all five suites; each prints its own ALL ... PASSED line)
for t in tests/test-*.sh; do bash "$t" || break; done

# Reproduction: red on HEAD (11 FAIL lines, about 1 m 45 s), green after the fix
bash tests/test-automation.sh 2>&1 | grep -E "^FAIL: t21|ALL AUTOMATION TESTS PASSED"
```

## End-to-End Verification

Real tmux on a scratch socket and a scratch `KINGPIN_HOME`, with no touch of the user's tmux or `~/.kingpin`. Test 21 already runs this flow inside the suite; this is the manual spot check:

1. `T=$(mktemp -d); export KINGPIN_HOME=$T/kp TMUX_TMPDIR=$T/tmux TREEHOUSE_ROOT=$T/pool KINGPIN_SKIP_GUARD=1`, a throwaway git repo with an `origin`, `kingpin init demo $T/proj --harness agy`, and a fake harness `printf '#!/usr/bin/env bash\nexit 1\n' > $T/dead; chmod +x $T/dead`.
2. `KINGPIN_AGY=$T/dead kingpin spawn demo --issue 246 --id e2e-dead`. Expect `OK: spawned`; `kingpin list` shows `(pending)`.
3. Wait past the grace period (`export KINGPIN_STATUS_GRACE=3; sleep 4`), then `kingpin wait --once`. Expect `e2e-dead exited` from the first pass, and on the next pass (after `kingpin ack e2e-dead`) `e2e-dead status`; `kingpin list` shows `failed: no status: e2e-dead (agy) exited, tmux window gone; never reported a status (...)`.
4. Slow start: spawn with a harness `sleep 600` and the same grace; after `sleep 4`, `kingpin wait --once` prints nothing and `kingpin list` shows `(pending)`.
5. `kingpin done e2e-dead` succeeds without `--force`; `kingpin list` no longer shows it. Kill the scratch tmux server and remove `$T`.

## Risks

| Risk | Mitigation |
|------|------------|
| A live worker is marked failed because tmux cannot be reached from where `kingpin wait` runs (a gone window and an unreachable server fail alike) | The helper requires `tmux list-sessions` to succeed first and records nothing otherwise; Test 21 covers it with a failing `tmux` shim. In scope. |
| A worker that is alive, stopped and quiet gets `failed:` while a human is about to answer it | The line is an ordinary last status: any later line from the worker wins in `list`, `wait`, `run` and the `done` slot guard. The window must also be silent for the whole grace period. In scope; see Open Question 1. |
| Idle detection uses `#{window_activity}`; a real harness TUI that redraws while idle (a clock, a spinner) never looks silent | It then fails safe: the old `quiet` event is all that fires. Test 21 proves the logic on `cat` and a printing loop, not on the real TUIs. Out of scope to probe real claude, agy and opencode idle screens while planning (it needs live harness sessions); flagged for the owner. |
| Merge conflicts with #45 and #47 in `bin/kingpin-wait` and at the end of `tests/test-automation.sh` | The patch adds one hunk inside `check_task` and leaves the header comment alone; it applies cleanly on the #45 tip and the suite passes there. Test numbering and the README paragraph position may need a hand merge. In scope: re-run Task 4 after any rebase. |
| `kingpin-wait` runs the helper for every empty-status task on every 2 s pass | The `[ -s "$dir/status" ] ||` guard skips tasks that have reported; only freshly spawned tasks pay one process and one `list-sessions` call. In scope. |
| A worker that wrote only the informational `issue:` line and then died is not covered (status is not empty) | The acceptance criteria say "empty"; #45 makes `issue:` lines non-waking, so such a worker still gets `exited` or `quiet`. Out of scope; see Open Question 2. |
| `date -d` is GNU-only | The repo already depends on GNU `sed -i` (`bin/kingpin-spawn:162`) and `stat -c` on the #45 branch; an unparsable `CREATED` makes the helper record nothing. Out of scope to port. |
| `failed:` on a task whose worktree holds nothing, left until the boss runs `kingpin done` | `kingpin-watch` already prints `reported failure`; `kingpin done` works without `--force` (Test 21). Auto-running `done` is not done here; see Open Question 4. |

## Open Questions

1. **A stopped worker whose window is still open (Stop hook fired, status empty, silent for the grace period): `failed:` or only a clearer `quiet`?** The archived dead-agy tasks are this case, and the issue's first criterion says "reported as `exited` or `failed: no status`". Proposed default (implemented in the patch): record `failed: no status: ... stopped and went silent; kingpin peek <id> shows why`. The alternative is to leave `quiet` and add the harness to its text, which would not satisfy `kingpin list` showing the task as failed.
2. **Should a worker whose only status line is the informational `issue:` count as "no status"?** The criteria say "empty". Proposed default: no, keep strict (`issue:` proves the harness ran and the skill started). Treating `issue:` as empty would be a one-line change in the helper's `has_status` and in the `[ -s ]` guard, best done after #45 lands.
3. **Grace period value and name.** The issue gives no number. Proposed default: 30 s, `KINGPIN_STATUS_GRACE`; it is longer than any spawn race (a window appears within seconds) and shorter than the ~90 s in which the observed workers stopped. (The name avoids #45's internal `LAUNCH_GRACE=120`, which is a different thing: how long a `launching` marker hides a missing window.)
4. **Should `kingpin-watch` run `kingpin done` on `failed: no status:` tasks by itself?** Proposed default: no. The orchestrator relays the failure and the boss decides, as for any other `failed:`; the AGENTS.md line says how to release the slot. Note also that `kingpin list` does not derive the failure on its own: it relies on a `kingpin wait` or `watch` pass (always armed while tasks are live, per AGENTS.md rule 5).

## Acceptance Criteria

- [ ] All tasks completed
- [ ] A worker whose process stopped with an empty status past the grace period gets `failed: no status: ...` and a `status` event (Test 21)
- [ ] The line names the task and its harness (Test 21)
- [ ] `kingpin list` shows such a task as failed, not `(pending)` (Test 21)
- [ ] A worker that is only slow to start, or is inside the grace period, is not failed (Test 21)
- [ ] `bash -n` clean and all five suites pass (automation: 267 PASS)
- [ ] README and AGENTS.md describe the behavior
- [ ] Follows existing patterns
