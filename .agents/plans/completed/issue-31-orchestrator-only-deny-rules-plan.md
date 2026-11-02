# Plan: Orchestrator-only tool deny rules (#31)

## Metadata
- Issue: #31 — Orchestrator-only tool deny rules are inherited by worker worktrees
- Path: quick (no Complexity metadata; small shell/docs change)
- Prime focus: none

## Approach
1. Untrack `.claude/settings.json` (`git rm`) and git-ignore `.claude/settings.local.json`, so leased worktrees never receive deny rules.
2. Add `bin/kingpin-guard` (`install` / `check` / `--dir <checkout>`): writes the deny list (`Edit`, `Write`, `NotebookEdit`, `Agent`) into the Kingpin checkout's `.claude/settings.local.json`, merging with existing settings, idempotent. Refuses a linked worktree (a guard there would hit a worker).
3. Wire it in: `kingpin guard` dispatcher entry; `kingpin init` installs it; `kingpin lock acquire` warns when the guard is missing (covers existing clones that pull this change and lose the tracked file).
4. Document in `AGENTS.md` and `README.md`.
5. Test `tests/test-worker-settings.sh`: guard install/merge/idempotence/linked-worktree refusal; the tracked tree carries no deny rules; a spawned Claude worker's effective settings (worktree `.claude/settings*.json` + the `--settings` file in `launch.sh`) deny none of `Edit`, `Write`, `NotebookEdit`, `Agent`; the guard file is git-ignored.

## Validation
- `bash -n` on changed scripts; the four test scripts under `tests/`.
