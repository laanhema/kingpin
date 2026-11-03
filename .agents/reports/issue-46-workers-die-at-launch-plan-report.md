# Implementation Report

**Plan**: `.agents/plans/completed/issue-46-workers-die-at-launch-plan.md`
**Branch**: `kingpin/kp-46-workers-die-launch`
**Status**: COMPLETE

## Summary

A worker that stops without ever writing a status line is now recorded as `failed: no status: <task> (<harness>) <cause>; never reported a status (<N>s since ...)` by `kingpin wait`. A new helper, `bin/kingpin-launch-check <task-dir>`, decides and appends the line. `kingpin-wait` calls it at the top of `check_task`, only while the task's `status` file is empty. "Stopped" means the tmux window is gone or its panes are dead, or the Stop hook has fired and the window has printed nothing for the grace period. The grace period is 30 s, or `KINGPIN_STATUS_GRACE` seconds. A live window with no stop is never failed. Because the line is an ordinary `failed:` status, it produces a `status` event, `kingpin list` shows it instead of `(pending)`, `kingpin run` exits 1 with `FAILED`, and `kingpin done` releases the slot without `--force`. The prototype patch supplied the helper, the wiring and Test 21 (20 assertions); the README and AGENTS.md were documented by hand.

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 0 | Prototype patch applied (test hunk first for the red run, then the rest) | `bin/kingpin-launch-check`, `bin/kingpin-wait`, `tests/test-automation.sh` | PASS |
| 1 | Reproduce red, then green (Test 21) | `tests/test-automation.sh` | PASS |
| 2 | Review patched code for placement and comments | `bin/kingpin-launch-check`, `bin/kingpin-wait` | PASS |
| 3 | Document in README and AGENTS | `README.md`, `AGENTS.md` | PASS |
| 4 | Full validation (syntax and all five suites) | `tests/test-*.sh` | PASS |

## Validation Results

| Check | Result | Command / environment |
|-------|--------|-----------------------|
| Type check / build | N/A (bash project, no build step) | n/a |
| Syntax | PASS | `for f in bin/kingpin-launch-check bin/kingpin-wait tests/test-automation.sh; do bash -n "$f"; done` — host |
| Lint | N/A (`shellcheck` is not installed, no CI lint) | n/a |
| Tests | PASS (439 passed: automation 267, report 17, harnesses 57, worker-settings 79, acceptance 19; 0 FAIL) | `for t in tests/test-*.sh; do bash "$t"; done` — host, private tmux socket per suite |
| Reproduction | PASS | red: `git apply --include=tests/test-automation.sh <patch>` then `bash tests/test-automation.sh`: 11 `FAIL: t21`, 256 PASS (the dead worker is only `exited`, `list` shows `(pending)`, `kingpin run` hit its 60 s timeout, rc=124). Green: after the rest of the patch, `bash tests/test-automation.sh`: `ALL AUTOMATION TESTS PASSED`, 267 PASS, 0 FAIL — host |
| Task 3 grep | PASS | `grep -c "failed: no status" README.md AGENTS.md` gives 1 and 1 |
| Helper usage | PASS | `bash bin/kingpin-launch-check --help 2>&1 \| grep -q usage`; `test -x bin/kingpin-launch-check` |
| E2E: dead harness, spawn, wait, list, done | PASS | scratch `KINGPIN_HOME`, `TMUX_TMPDIR`, `TREEHOUSE_ROOT`, private tmux socket, fake harness `exit 1`, `KINGPIN_STATUS_GRACE=3` |
| E2E: slow start left alone | PASS | same scratch setup, fake harness `sleep 600`: `kingpin wait --once` prints nothing for it, `kingpin list` shows `(pending)` |

E2E observations (see Deviations): spawn showed `(pending)`; after the grace period `kingpin wait --once` printed `e2e-dead status`; `kingpin list` showed `failed: no status: e2e-dead (agy) exited, tmux window gone; never reported a status (4s since launch)`; `kingpin done e2e-dead` returned 0 without `--force`, and the task no longer appeared in `kingpin list`. Variant with a pass inside the grace period: `e2e-dead2 exited` first (list still `(pending)`), then `e2e-dead2 status` after the grace period.

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `bin/kingpin-launch-check` | CREATE (mode 755) | +89 |
| `bin/kingpin-wait` | UPDATE | +5 |
| `tests/test-automation.sh` | UPDATE (Test 21) | +111 |
| `README.md` | UPDATE | +2 |
| `AGENTS.md` | UPDATE | +1 |

## Deviations from Plan

- E2E step 3 in the plan expects `e2e-dead exited` from the first `kingpin wait --once` after the grace period. When the grace period is already over at the first pass, `check_task` appends the failed line first and reports `status`, and the `exited` event is never emitted for that task (the status check runs before the liveness check). This matches Test 21 and the plan's "Events" semantics, which is `exited` while the pass is inside the grace period and `status` once it is over. The `exited`-then-`status` sequence was verified with a pass inside the grace period (variant run above). No code change.
- The patch applied cleanly to HEAD (`b8c2f8e`); no tasks were re-implemented by hand.
- No stories file exists under `.agents/stories/`, so no PRD phase was updated.
- Open questions: the plan's defaults were adopted as instructed (record `failed:` for a stopped-and-silent live window; grace 30 s via `KINGPIN_STATUS_GRACE`; `issue:`-only workers not covered; no auto-cleanup).

## Tests Written

| Test File | Test Cases |
|-----------|------------|
| `tests/test-automation.sh` (Test 21, 20 assertions) | dead window plus old `CREATED` gives a `status` event; the line names task and harness; the cause is "tmux window gone"; `kingpin list` shows failed, not `(pending)`; no repeat event after `kingpin ack`; the line is written once; a worker inside the grace period is not failed; a live worker with no stop is not failed; `KINGPIN_STATUS_GRACE=1` shortens the period; a short grace still leaves a live worker alone; a worker with a status line is not rewritten; a stopped worker with a silent window is failed with a peek hint; a stopped worker whose window still prints is not failed; a worker that stopped inside the grace period is not failed; a dead pane under `remain-on-exit` is failed; an unreachable tmux records nothing; a real `kingpin spawn` of a harness that exits at once is reported, shown failed, and released by `kingpin done` without `--force`; `kingpin run` exits 1 with `FAILED: ... failed: no status:` |
