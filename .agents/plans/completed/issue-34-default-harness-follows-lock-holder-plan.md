# Plan: Default worker harness follows the orchestrator lock holder

## Summary

`kingpin lock acquire` detects which agent harness (claude, agy, opencode) holds the session and stores it on line 2 of `orchestrator.lock`. A new `kingpin lock harness` subcommand prints it while the holder pid is alive. `kingpin-spawn` resolves the harness as `--harness` > project `HARNESS` (only if explicitly set) > lock holder's harness > `DEFAULT_HARNESS` > `claude`. `kingpin-init` stops writing `HARNESS=claude` unless `--harness` is given, so "explicitly set" is meaningful. `kingpin lock status` shows the harness.

## Metadata

| Field | Value |
|-------|-------|
| Type | ENHANCEMENT |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-lock`, `bin/kingpin-spawn`, `bin/kingpin-init`, `bin/kingpin`, tests, `AGENTS.md`, `README.md` |
| GitHub Issue | #34 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Detection (documented in the lock script header and README)

1. `--harness <name>` flag on `lock acquire`, then `KINGPIN_HARNESS` env var (validated: claude|agy|opencode, else error).
2. The resolved session pid's command name (`ps -o comm=`, then its argv) matching `claude*`, `agy*`, `opencode*`.
3. Fallback env markers of the calling agent: `CLAUDECODE=1` -> claude, `OPENCODE=1` -> opencode.
4. Nothing matched (including codex/pi/grok/kimi holders): record nothing.

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-lock` | UPDATE | parse `--harness`, detect, write line 2, `status` shows it, add `harness` subcommand (empty when free/stale/none) |
| `bin/kingpin-spawn` | UPDATE | new precedence |
| `bin/kingpin-init` | UPDATE | write `HARNESS` only when `--harness` is passed |
| `tests/test-automation.sh` | UPDATE | lock harness detection/override/release/stale, init without `--harness` |
| `tests/test-harnesses.sh` | UPDATE | spawn precedence |
| `AGENTS.md`, `README.md` | UPDATE | wording |

## Tasks

1. `bin/kingpin-lock`: add flag parsing, `detect_harness`, lock line 2, status, `harness` subcommand. Validate: `bash tests/test-automation.sh`.
2. `bin/kingpin-spawn`: query `kingpin-lock harness`, apply precedence. Validate: `bash tests/test-harnesses.sh`.
3. `bin/kingpin-init`: optional harness. Validate: `bash tests/test-automation.sh`.
4. Tests, then docs.

## Validation

```bash
bash -n bin/kingpin-lock bin/kingpin-spawn bin/kingpin-init
bash tests/test-automation.sh
bash tests/test-harnesses.sh
bash tests/test-acceptance.sh
```
(No type checker or linter exists in the repo; shellcheck is not installed.)

## End-to-End Verification

Run `bin/kingpin lock acquire --harness agy` against a scratch `KINGPIN_HOME`, then `kingpin lock status` (shows `(agy)`), then `kingpin-spawn` against a scratch project with a fake agent and check `task.env` says `HARNESS=agy`; release and confirm the next spawn falls back to `claude`. Covered by the new tests.

## Risks

| Risk | Mitigation |
|------|------------|
| Existing project env files say `HARNESS=claude` (old init default) and keep beating the lock holder | Cannot be told apart from an explicit choice; document it (in scope: docs only) |
| Test shells run inside Claude Code (`CLAUDECODE=1`) and leak into detection | Tests unset `CLAUDECODE`/`OPENCODE`/`KINGPIN_HARNESS` |
| Old readers of the lock file read only line 1 | pid stays on line 1 |

## Acceptance Criteria

- [ ] All tasks completed
- [ ] Existing and new tests pass
- [ ] Docs updated
