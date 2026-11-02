# Code Review: kingpin/kingpin-40

**Scope**: branch `kingpin/kingpin-40` (uncommitted changes vs `main`), issue #40
**Recommendation**: APPROVE WITH NITS

## Summary

The change replaces the orchestrator guard's `permissions.deny` rules, which Claude Code also loads for the main checkout's linked worktrees and so stripped `Edit`/`Write`/`NotebookEdit`/`Agent` from every worker, with a `PreToolUse` hook that denies only in the main checkout, and adds a worker hook that allows edits only inside the worker's worktree and task folder. The review ran in the implementing session (no subagent tool), so it is not independent. Plan and implementation-report artifacts were not produced for the same reason.

Acceptance criteria:
- AC1 cause identified and written down: met. README "Worker permissions" and AGENTS.md record the cause and a reproduction; reproduced in a throwaway repo (guard file present: no tools in main or worktree; file moved away: tools present; worker-side allow rule does not restore them).
- AC2 spawn launches workers with an explicit permission configuration allowing edits in the worktree, checked by a test: met. `worker/hooks.json` PreToolUse hook, `KINGPIN_ROOT` exported by `bin/kingpin-spawn`; `tests/test-worker-settings.sh` Test 3 and 3b (the main checkout's settings file is now part of the effective settings checked).
- AC3 edits outside the worktree stay denied, checked by a test: met. Test 3b covers the main checkout, `/etc`, `..` traversal, symlink escape, another task folder, NotebookEdit and the real `hooks.json` command. A real `claude -p` run denied an outside Write and allowed an inside one, in default and auto permission mode.
- AC4 README/AGENTS.md explain what a worker may edit and how to unblock one: met (README "Worker permissions", AGENTS.md "Orchestrator Tool Guard").

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
- **M1** `worker/hooks.json:7` — The guard hooks fail open: Claude Code only blocks on exit status 2, so a crashed hook (node missing, `bin/kingpin-guard` missing, e.g. on a checkout without the file) or an unset `KINGPIN_ROOT` lets the edit through. **Why:** The old deny rules were fail-closed; now an outside edit (worker) or any edit (orchestrator) goes through whenever the hook cannot run, while AC3 says edits outside the worktree stay denied. **Fix:** Wrap both commands so any non-zero status becomes a deny, e.g. `"$KINGPIN_ROOT/bin/kingpin-guard" hook worker || exit 2` with an explicit `exit 2` when `KINGPIN_ROOT` is unset (worker), and the same `|| exit 2` in the hook command that `kingpin guard install` writes (`bin/kingpin-guard:55`). Add a test that runs the command with a missing script.

### Suggestions (Low)
- **L1** `bin/kingpin:45` — The `kingpin --help` line still says the guard installs "tool deny rules". **Why:** Misleads readers: the guard is a hook now and deny rules are what leaked. **Fix:** Reword to `Install or verify the orchestrator-only tool guard (PreToolUse hook)`.
- **L2** `bin/kingpin-lock:189` — The comment "The deny rules are untracked, so a clone that pulled their removal has none" describes the old design. **Why:** Stale comment next to the warn logic that now also catches legacy deny rules. **Fix:** Reword: the guard file is untracked, so a fresh clone or a clone with legacy deny rules fails `check`.
- **L3** `tests/test-worker-settings.sh:2` — The file header still says the deny rules for Edit, Write, NotebookEdit and Agent live in the untracked file. **Why:** Stale description of what the test verifies. **Fix:** Describe the hook-based guard, the leak check on the main checkout's settings file, and the worker edit boundary.

**Noted, not a finding**: the live `/home/lauri/github/kingpin/.claude/settings.local.json` still holds the legacy deny rules; after landing, run `kingpin guard install` there (it migrates them, and `kingpin list`/`lock acquire` warn until then). Bash is not sandboxed by the worker hook (scoped out by the issue). OpenCode and Antigravity workers do not use this settings file.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n` on the changed scripts, `node --check lib/guard-hook.mjs`, `worker/hooks.json` parses; host |
| Warnings | N/A | shell project |
| Lint | N/A | no linter configured |
| Tests | PASS | `tests/test-worker-settings.sh` (76 PASS), `tests/test-harnesses.sh`, `tests/test-automation.sh`, `tests/test-acceptance.sh`; none skipped; host |
| UI verification | N/A | no UI change |

## What's Good

The hook resolves symlinks of the nearest existing ancestor, so a link out of the worktree cannot smuggle a write. `guard install` is idempotent, migrates the legacy rules, and keeps unrelated deny rules and hooks. The test now covers the real leak path (the main checkout's settings file).

## Recommendation

Fix M1 (fail closed) and the three stale-wording nits with `/fix-findings`, then land.
