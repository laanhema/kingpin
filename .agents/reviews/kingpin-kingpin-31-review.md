# Code Review: kingpin/kingpin-31

**Scope**: branch `kingpin/kingpin-31` (issue #31), merge base `c28c41f` (= `origin/main`), committed work none; all changes uncommitted, including untracked `bin/kingpin-guard` and `tests/test-worker-settings.sh`
**Recommendation**: APPROVE WITH NITS

## Summary

The change untracks `.claude/settings.json` (the Edit/Write/NotebookEdit/Agent deny rules), git-ignores `.claude/settings.local.json`, adds `bin/kingpin-guard` (install/check, merge, idempotent, refuses linked worktrees), wires it into `kingpin guard`, `kingpin init` and `kingpin lock acquire`, documents it in `AGENTS.md`/`README.md`, and adds `tests/test-worker-settings.sh`. The design is sound: workers are launched with only `worker/hooks.json` (a Stop hook, no permissions) and no tracked settings file now exists, so a leased worktree receives no deny rules. Untracked plan/report files under `.agents/` were read as context only.

Acceptance criteria (issue #31, no comments):
- **A leased worker worktree does not contain deny rules** - Met. `git ls-files .claude` is empty after the change, `bin/kingpin-spawn:191` passes only `worker/hooks.json`, and `tests/test-worker-settings.sh` Test 3 spawns a worker and checks its worktree, the `--settings` file and the worktree settings files (I ran it: all PASS). The test copies this repo's tree into the project, so it would fail against the old tracked file.
- **Orchestrator in the main checkout still has the tools denied** - Met once `kingpin guard install` has run (`bin/kingpin-guard:55-76`, merged and idempotent, tested). It is not met on an existing clone until then; see the note below.
- **Location and setup documented, init covers a fresh clone** - Met. `AGENTS.md:39-46`, `README.md:46,93,159-160`, `bin/kingpin-init:76-85`, and the `lock acquire` warning at `bin/kingpin-lock:98-100`.
- **A test verifies a spawned worker's effective settings allow Edit, Write and Agent** - Met, as the absence of any deny rule in every settings source the launch uses (not a positive allow, which Claude does not need).
- **Existing tests pass** - Met. See Validation: one flaky failure in `test-automation.sh` (listener log timing, outside this change) on the first run; it passed on re-run.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-guard:63` - `install` prints `OK: orchestrator guard installed` and exits 0 when the existing `.claude/settings.local.json` parses as JSON but is not an object with an object `permissions` (reproduced: `[]` and `{"permissions":"x"}` leave the file without the rules; `null` throws a Node stack trace instead of the tool's `malformed JSON` error). **Why:** a false "OK" for a security guard; the subsequent `check` (and the `lock acquire` warning) does catch it, so impact is limited to a hand-corrupted file. **Fix:** after parsing, reject (exit 1 with a `kingpin-guard:` message) when `cfg` is not a plain object or `cfg.permissions` exists and is not a plain object.
- **L2** `bin/kingpin-lock:99` - on an existing clone that pulls this change, the deleted tracked file leaves the orchestrator unguarded until the operator runs `kingpin guard install`; the only signal is a stderr warning at `lock acquire`. **Why:** the guard silently lapses for one session if the warning is missed; documented in `AGENTS.md:42`, so this is a hardening nit. **Fix:** optional: make `kingpin list`/`kingpin-wait` startup repeat the warning, or have `lock acquire` auto-run `kingpin-guard install` when run from the main checkout.

**Noted, not a finding**: `tests/test-automation.sh` failed two assertions on the first run (`unparsed prompts not logged`, `no resend reply`, `grep: .../task-lavish-raw/listener.log: No such file`); a re-run passed all. This is a timing race in the #17 listener test (Test 11), not touched by this change. The implementation report says `test-worker-settings.sh` has 27 checks; the run shows 23 `PASS` lines (cosmetic).

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Shell project; `bash -n` on `bin/kingpin`, `bin/kingpin-guard`, `bin/kingpin-init`, `bin/kingpin-lock`: all OK |
| Warnings | N/A | `shellcheck` not installed on the host |
| Lint | N/A | No lint command in `AGENTS.md`/README |
| Tests | PASS | Run one at a time on the host: `test-worker-settings.sh` PASS (23 PASS lines, ALL PASSED); `test-harnesses.sh` PASS (51); `test-acceptance.sh` PASS (20); `test-automation.sh` first run 116 PASS / 2 FAIL (flaky listener-log race, see above), re-run ALL PASSED. No skipped tests. |
| UI verification | N/A | No UI change |

## What's Good

- The guard refuses a linked worktree, so it cannot be installed into a worker checkout, and falls back to `.git/info/exclude` if the ignore rule is missing.
- Install merges into existing settings, dedupes, writes atomically (tmp + rename), and refuses malformed JSON.
- The worker-settings test is a real regression test: it spawns a worker from a copy of this tree and fails if a tracked deny file returns.
- `KINGPIN_SKIP_GUARD` keeps test suites from touching the real checkout.

## Recommendation

Merge-ready after optional nits L1 and L2. The caller should run `bin/kingpin guard install` once in the main Kingpin checkout after landing.
