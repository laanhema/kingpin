# Code Review: kingpin/kingpin-8

**Scope**: branch `kingpin/kingpin-8`
**Recommendation**: APPROVE WITH NITS

## Summary

Reviewed branch `kingpin/kingpin-8` implementing narrow git `info/exclude` configurations for `agy` and `opencode` workers to resolve issue #8. The changes replace whole-directory exclusions (`.agents` and `.opencode`) with exact file exclusions for Kingpin-injected files, and add an automated migration step in `bin/kingpin-spawn` that cleans up legacy broad exclusion lines on worker spawn. All three acceptance criteria from issue #8 are met and verified by new regression tests in `tests/test-harnesses.sh`.

- [x] Spawning an agy worker excludes only the files kingpin writes (`.agents/rules/kingpin.md`, `.agents/hooks.json`), not the whole `.agents/` folder: Met. Verified in `tests/test-harnesses.sh` Test 2 asserting exact file exclusions, clean status, and untracked `.agents/reviews/x.md` detected in `git status`.
- [x] The same holds for opencode and `.opencode/`: Met. Verified in `tests/test-harnesses.sh` Test 3 asserting exact injected config/plugin files in `info/exclude`, clean status, and untracked `.opencode/notes.txt` detected in `git status`.
- [x] The existing broad `.agents` and `.opencode` lines that earlier spawns added are removed or migrated: Met. `migrate_legacy_excludes` in `bin/kingpin-spawn` automatically strips legacy lines on worker spawn, verified by pre-seeding `.agents\n.opencode\n` in `tests/test-harnesses.sh`.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `README.md:143` — Clarify that Kingpin excludes specific injected `.opencode` files rather than `.opencode/*`. **Why:** Shorthand `.opencode/*` in `README.md` suggests all files directly in `.opencode/` are excluded, whereas `bin/kingpin-spawn` specifically excludes only `.opencode/config.json`, `.opencode/plugins/package.json`, and `.opencode/plugins/kingpin-stop.js`, intentionally allowing other user files (e.g. `notes.txt`) under `.opencode/` to be tracked. **Fix:** Update `README.md` line 143 to list the specific files or state "injected `.opencode` files".

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n bin/* tests/*.sh` on host; syntax clean |
| Warnings | NONE | Zero warnings emitted during syntax checks and test suite executions |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host |
| Tests | PASS | `tests/test-harnesses.sh` (6/6 passed); `tests/test-acceptance.sh` (15/15 passed); `tests/test-automation.sh` (5/5 passed) |
| UI verification | N/A | CLI orchestrator; no web or graphical UI components |

## What's Good

- Minimal and targeted fix that cleanly prevents git pollution while enabling agent review reports and plans to be tracked across checkouts.
- Automated backward-compatible migration via `migrate_legacy_excludes` cleans legacy exclusions in `info/exclude` without requiring manual intervention.
- Strong test coverage in `tests/test-harnesses.sh` asserting both exclusion of injected files and git tracking of newly created user artifacts.

## Recommendation

Approve with nits. Proceed with merging `kingpin/kingpin-8`; the minor documentation precision note in L1 can be adjusted during routine cleanup.
