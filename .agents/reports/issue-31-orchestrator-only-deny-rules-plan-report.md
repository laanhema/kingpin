# Implementation Report: issue 31 — Orchestrator-only tool deny rules

**Status**: COMPLETE
**Plan**: `.agents/plans/completed/issue-31-orchestrator-only-deny-rules-plan.md`
**Branch**: `kingpin/kingpin-31` (uncommitted)

## Changes
- `.claude/settings.json`: removed from git (it carried the Edit/Write/NotebookEdit/Agent deny rules every worker worktree inherited).
- `.gitignore`: ignores `.claude/settings.local.json`.
- `bin/kingpin-guard` (new): `install` / `check` `[--dir <checkout>]`; merges the deny list into the main checkout's `.claude/settings.local.json`, idempotent, refuses malformed JSON and linked worktrees.
- `bin/kingpin`: `guard` subcommand. `bin/kingpin-init`: installs the guard (opt out with `KINGPIN_SKIP_GUARD=1`). `bin/kingpin-lock`: `acquire` warns when the guard is inactive.
- `AGENTS.md`, `README.md`: where the guard lives, how to set it up on a fresh clone.
- `tests/test-worker-settings.sh` (new): tracked tree has no deny rules; guard install/merge/idempotence/refusals; a spawned Claude worker's effective settings (worktree settings files + the `--settings` file in `launch.sh`) deny none of the four tools; init/lock wiring. `tests/test-automation.sh` sets `KINGPIN_SKIP_GUARD=1`.

## Validation
| Check | Result |
|---|---|
| `bash -n` on changed scripts | PASS |
| tests/test-worker-settings.sh | PASS (43 checks) |
| tests/test-automation.sh | PASS (118) |
| tests/test-harnesses.sh | PASS (51) |
| tests/test-acceptance.sh | PASS (20) |

Running the suites in parallel makes test-automation fail (test-acceptance temporarily rewrites `bin/kingpin-send`); run them one at a time.

## Deviations
None. The orchestrator-side deny rules of the old tracked file no longer exist in this repo, so existing clones need `kingpin guard install` once (lock acquire warns).
