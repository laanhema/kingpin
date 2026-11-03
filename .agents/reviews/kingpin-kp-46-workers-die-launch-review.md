# Code Review: kingpin/kp-46-workers-die-launch

**Scope**: branch `kingpin/kp-46-workers-die-launch` against merge base `b8c2f8e` (default branch `main`), including uncommitted and untracked changes, checked against GitHub issue #46.
**Recommendation**: APPROVE WITH NITS

## Summary

The branch adds `bin/kingpin-launch-check` (new, untracked, mode 755), a five-line call to it from `check_task` in `bin/kingpin-wait`, a 111-line Test 21 in `tests/test-automation.sh`, and one paragraph each in `README.md` and `AGENTS.md`. A worker that stops with an empty `status` file gets one `failed: no status: <task> (<harness>) <cause>; ...` line after a 30 s grace period (`KINGPIN_STATUS_GRACE`), which `kingpin wait`, `kingpin list`, `kingpin run` and `kingpin done` already treat as an ordinary `failed:` status. The design is sound, fails safe when tmux cannot be reached, and every suite is green. One Medium finding (the "stopped and went silent" path does not reuse the working-marker exclusion that the `quiet` event applies) and two Low findings remain. The untracked plan, prototype patch and implementation report were read as context; none contradicts the code. The posted issue comment says the work is "not yet committed", which still holds: the helper is untracked and must be `git add`ed with its executable bit.

Acceptance criteria of issue #46 (no owner comment changes them; the only comment is the implementation summary):

| Criterion | Met | How I know |
|-----------|-----|------------|
| A worker whose process stopped and whose `status` is still empty after a grace period is reported as `exited` or `failed: no status` | Met | Test 21 "kingpin-wait reports the dead worker as a status event" and "the failed line ..." pass; a `kingpin spawn` of a harness that exits at once is reported, and `kingpin run` exits 1 with `FAILED: ... failed: no status:`. Branch tests run on the merge-base code fail (see Validation). |
| The report names the task and its harness | Met | `bin/kingpin-launch-check:86` builds `failed: no status: $id ($harness) ...`; Test 21 asserts `failed: no status: t21-dead (agy) ` and `... t21-idle (opencode) ...`. |
| `kingpin list` shows such a task as failed, not `(pending)` | Met | `bin/kingpin:127-130` prints the last status line of a non-empty file; Test 21 asserts the list row for a hand-made and a really spawned task. This needs a `kingpin wait`/`watch` pass to write the line (see Noted). |
| A worker that is just slow to start is not reported failed within the grace period | Met | Test 21 covers a live window with an empty status and no stop (`t21-slow`, 120 s old), a dead worker younger than the grace period (`t21-young`), and a worker that stopped inside the grace period (`t21-justnow`). |

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority

- **M1** `bin/kingpin-launch-check:70-76` — The "stopped and went silent" path fails a live worker on `#{window_activity}` alone and does not apply the working-marker exclusion that the `quiet` event uses for the same Stop-hook condition (`bin/kingpin-wait:128` `Waiting for N background agent|Background agent` for claude, `:136` and `:144` `esc to cancel|Interrupt` for agy and opencode). **Why:** the Stop hook fires while background agents still run (that is why `quiet` skips them), so a worker that stopped with an empty `status` while its pane waits on background agents and prints nothing for 30 s is recorded as `failed: no status: ... stopped and went silent`. I confirmed in a scratch tmux server that a window printing `Waiting for 1 background agent` with a 120 s old `stopped` file and an empty status is failed by the helper (exit 0, line appended). Whether a real harness TUI stays silent in that state is not verified (no live harness sessions here). The damage is limited: the next line the worker writes wins in `list`, `wait` and `run`, but `AGENTS.md` offers `kingpin done` on `failed:`, which kills the window. **Fix:** in that branch, capture the pane tail (`tmux capture-pane -pt "$tmux_target" -S -30`) and `exit 1` when it shows the same markers `check_task` excludes for `quiet`, ideally by moving the per-harness test into one shared function that both scripts call, so the two cannot drift.

### Suggestions (Low)

- **L1** `bin/kingpin-launch-check:2-3` — The header says `kingpin-wait` calls the helper "for every task on every pass", but the call is guarded by `[ -s "$dir/status" ] ||` (`bin/kingpin-wait:55`), so it runs only for tasks whose status file is empty. **Why:** a reader of the helper alone overestimates its cost and its reach; the plan's Task 2 asks the header to state the call accurately. **Fix:** reword to "for every task whose `status` file is empty, on every pass".
- **L2** `bin/kingpin-launch-check` (untracked) — The helper is a new file, executable in the working tree, and it is the only script the changed `bin/kingpin-wait` and Test 21 depend on. **Why:** if it is committed without `git add` of the mode, or left out of the commit, `kingpin-wait` silently ignores it (`>/dev/null 2>&1 || true`) and the fix disappears without any error. **Fix:** stage it with the rest of the change and confirm `git ls-files -s bin/kingpin-launch-check` shows mode `100755`.

**Noted, not a finding**:
- `kingpin list` stays read-only and shows the failed line only after a `kingpin wait` or `watch` pass wrote it; `AGENTS.md` rule 5 keeps one `bin/kingpin-wait` armed while tasks are live, and the plan's Open Question 4 documents this. The incident in the issue had `kingpin-wait` running.
- A worker whose only status line is `issue:` is not covered (plan Open Question 2, default kept; issue says "empty").
- A stopped, alive, silent worker is recorded as `failed:` (plan Open Question 1, default kept); a real TUI that redraws while idle fails safe (only `quiet` fires). The plan flags that real claude, agy and opencode idle screens were not probed.
- `date -d` is GNU-only; the repo already relies on GNU tools (`sed -i`), and an unparsable `CREATED` records nothing.
- The `kingpin-wait` header comment does not mention the launch check; the plan leaves it alone on purpose because #45 and #47 rewrite it.
- `tests/test-automation.sh` and `tests/test-acceptance.sh` temporarily overwrite `bin/kingpin-send` in the working tree and restore it from a backup (existing behavior); a mid-run `git diff` shows it modified, and it is clean after the run.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash project, no build step. `bash -n bin/kingpin-launch-check bin/kingpin-wait tests/test-automation.sh` is clean (host). |
| Warnings | N/A | No warnings gate; no CI directory. |
| Lint | SKIPPED | `shellcheck` is not installed on the host and the repo has no lint step or CI workflow. |
| Tests | PASS | `for t in tests/test-*.sh; do bash "$t"; done`, host, private tmux socket per suite: automation 267 PASS / 0 FAIL (Test 21: 20 of 20), report 17, harnesses 57, worker-settings 79, acceptance 19; 0 FAIL, 0 skipped. Red check: see below. |
| UI verification | N/A | No UI change. |

Red check (the branch's `tests/test-automation.sh` copied into a throwaway `git worktree` of the merge base, whose `bin/` has no fix): 11 FAIL, 256 PASS, `AUTOMATION TESTS FAILED` (the dead worker is only `exited`, `list` shows `(pending)`, nothing is recorded, `kingpin run` reaches its 60 s timeout). With the branch code the same file gives 267 PASS, 0 FAIL, so Test 21 does detect the bug. The worktree was removed afterwards.

## What's Good

- The helper's decision order is careful: unreachable tmux records nothing (`list-sessions` is checked first), an empty or unparsable `CREATED` cannot pass the age check (the `date -d ""` midnight trap is guarded), a live window with no Stop is never failed, and the append is re-checked against a second caller.
- Reusing the ordinary `failed:` status means `list`, `run`, `done`, the slot guard and `watch` need no change, and a later worker line still wins.
- The wiring in `kingpin-wait` is one guarded line that costs no process for a worker that has reported, and keeps stdout out of the event channel.
- Test 21 covers each criterion plus the edge cases (dead pane under `remain-on-exit`, silent versus printing windows, tmux shim that fails, a real `spawn` then `done`, `kingpin run`), and the docs match the behavior (grace period, env var, `peek`, `done`).

## Recommendation

Merge after considering M1 (cheap to close by reusing the `quiet` markers) and staging the new helper with its executable bit (L2). No Critical or High finding; all four acceptance criteria are met.
