# Implementation Report

**Plan**: `.agents/plans/completed/issue-16-descriptive-title-slugs-plan.md`
**Branch**: `kingpin/kingpin-16`
**Status**: COMPLETE

## Summary

Task ID, git branch and tmux window of a spawned task now share a descriptive slug: `kp-<n>-<slug>` for `--issue <n>` (slug from the issue title via `gh issue view`) and `kp-<slug>` for `--text` (with `-2`, `-3`... on collision). Slug generation lives in `lib/slug.mjs`. For `--text` tasks, `kingpin-wait` calls the new `bin/kingpin-rename` when a task has new status lines; once the worker's `issue: #<n>` line exists it renames the tmux window (by window ID) and rewrites `TMUX_TARGET`, leaving the task ID and branch alone. `--id` still overrides and calls no `gh`; a `gh` failure degrades to `kp-<n>`.

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 1 | Slug generator | `lib/slug.mjs` | PASS |
| 2 | Generate unified ID, `GH_CMD`, header | `bin/kingpin-spawn` | PASS |
| 3 | Rename helper | `bin/kingpin-rename` | PASS |
| 4 | Trigger rename from wait | `bin/kingpin-wait` | PASS |
| 5 | Test 17 | `tests/test-automation.sh` | PASS |
| 6 | README spawn row | `README.md` | PASS |

## Validation Results

| Check | Result | Command / environment |
|-------|--------|-----------------------|
| Type check | N/A | none configured; `bash -n bin/kingpin-spawn bin/kingpin-rename bin/kingpin-wait tests/test-automation.sh && node --check lib/slug.mjs` PASS — host |
| Lint | N/A | none configured (shellcheck not installed) |
| Tests | PASS (384 PASS lines, 0 FAIL) | `bash tests/test-automation.sh` 211 (baseline 187, +24 t17), `test-harnesses.sh` 57, `test-worker-settings.sh` 79, `test-acceptance.sh` 20, `test-report.sh` 17 — host, private tmux socket |
| E2E 1-3 (issue spawn, text spawn + rename, `done --force`) | PASS | covered by Test 17 with a stub `gh` (`KINGPIN_GH`) |
| E2E 4 real-gh smoke | PASS | `gh issue view 16 --json title -q .title \| xargs node lib/slug.mjs` -> `unify-task-id` |

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `lib/slug.mjs` | CREATE | +32 |
| `bin/kingpin-rename` | CREATE | +55 |
| `bin/kingpin-spawn` | UPDATE | +18/-3 |
| `bin/kingpin-wait` | UPDATE | +2 |
| `tests/test-automation.sh` | UPDATE | +73 |
| `README.md` | UPDATE | +1/-1 |

## Deviations from Plan

- `bin/kingpin-rename` rewrites `TMUX_TARGET` and writes the marker even when the window is already gone (the tmux rename is skipped), so the retry does not loop forever on a dead window.
- `bin/kingpin-rename` also exits silently if the computed name is not a valid ID shape.
- The slug cap in `slug.mjs` stops at the first word that would push past 24 chars (rather than skipping to a shorter later word).
- Test 17 asserts `kingpin done` closed the slugged window and removed the task folder; archive contents are covered by existing tests.

## Tests Written

| Test File | Test Cases |
|-----------|------------|
| `tests/test-automation.sh` (Test 17, 24 checks) | slug unit checks (long title, punctuation-only, accents, length/shape); issue spawn ID/BRANCH/TMUX_TARGET/window/worktree branch; `kingpin send` and `done` on the slugged task; `gh` failure fallback; text spawn and `-2` collision; rename after `issue:` line (window, TMUX_TARGET, unchanged window ID/branch/folder, marker, send, idempotence); `--id` override with no `gh` call |
