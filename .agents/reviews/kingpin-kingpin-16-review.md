# Code Review: kingpin/kingpin-16

**Scope**: branch `kingpin/kingpin-16` vs merge base 64180ce (main), including uncommitted and untracked changes; issue #16
**Recommendation**: APPROVE WITH NITS

## Summary

The change gives spawned tasks one slug for task ID, branch and tmux window (`kp-<n>-<slug>` for `--issue`, `kp-<slug>` for `--text`), adds `lib/slug.mjs`, `bin/kingpin-rename` (called from `kingpin-wait`) and Test 17. Read in full: `bin/kingpin-spawn`, `bin/kingpin-rename`, `bin/kingpin-wait`, `lib/slug.mjs`, the test block, the README row, plus the plan and implementation report (context only). All five test scripts pass on the host; only two Low nits found.

Acceptance criteria (issue #16, owner comment of 2026-11-02 read):
- Clean lowercase alphanumeric slug from issue title or text: met (`lib/slug.mjs`; Test 17 slug checks, `kingpin-spawn:102-114`).
- Task ID, branch and window share the slug format: met at spawn (Test 17 checks ID, `BRANCH`, window name, worktree branch). After the `--text` rename the window differs from the task ID and branch by design; see "Noted".
- `TMUX_TARGET` records the slugged window name: met (`kingpin-spawn:201`, rewritten by `kingpin-rename:46-49`; asserted in Test 17).
- Automated tests verify slug generation and downstream command routing: met (24 checks; `kingpin send` and `kingpin done` on the slugged and renamed windows).

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-rename:39` — `gh issue view` runs with no timeout, synchronously inside `check_task` of `kingpin-wait` (and likewise at `bin/kingpin-spawn:104`). **Why:** a hung `gh` call (network stall) blocks every fleet wake-up event for as long as it hangs, since `kingpin-wait` is the orchestrator's only event source. **Fix:** wrap both calls in `timeout 10` (guarded with `command -v timeout`), so a stall degrades to the existing `kp-<n>` / id-derived fallback.
- **L2** `lib/slug.mjs:31` — when the first non-stop word exceeds 24 chars, the fallback takes `words[0]`, which can be a stop word (`"the supercalifragilisticexpialidocious thing"` gives `the`). **Why:** a useless slug such as `kp-the`; cosmetic only. **Fix:** fall back to the first non-stop word, truncated to 24 chars (`words.find(w => !STOP_WORDS.has(w)) ?? words[0]`).

**Noted, not a finding**: (a) The issue asks for the slug to be used "uniformly", but a `--text` task keeps its first-name task ID and branch after the window and `TMUX_TARGET` are renamed; the owner comment states this as the plan's default for the open question, and renaming the branch or task folder under a running worker is unsafe. Criterion 2 is "met, pending owner decision" on that point. (b) `--text` IDs are now `kp-<slug>` instead of timestamped; a stale unmerged remote branch of the same name from an earlier `done --force` could be reused by `treehouse get -b`. Not reproduced; same exposure `--issue` tasks already had.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | none configured; `bash -n` on the three scripts and `node --check lib/slug.mjs` pass (host) |
| Warnings | N/A | no warnings gate; shellcheck is not installed |
| Lint | N/A | none configured |
| Tests | PASS | host: `tests/test-automation.sh` ALL PASSED (includes Test 17), `test-harnesses.sh`, `test-worker-settings.sh`, `test-acceptance.sh`, `test-report.sh` all pass; no skipped tests seen |
| UI verification | N/A | no UI change |

## What's Good

- Failure handling is degrade-not-abort: a `gh` failure or empty slug gives `kp-<n>`, never a failed spawn.
- `kingpin-rename` is idempotent with the marker written last, so a failed rename retries; the window is renamed by ID, so it is safe against the earlier window-ID work.
- `--id` still overrides with no `gh` call, and text collisions get `-2`, `-3`.
- Test 17 covers the full path: spawn, send, done, gh failure, collision, rename, second-call no-op.

## Recommendation

Merge-ready; L1 and L2 are optional hardening. `/fix-findings .agents/reviews/kingpin-kingpin-16-review.md` if wanted.
