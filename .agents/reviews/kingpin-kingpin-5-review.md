# Code Review: kingpin/kingpin-5

**Scope**: branch `kingpin/kingpin-5` (issue #5)
**Recommendation**: APPROVE WITH NITS

## Summary

Reviewed branch `kingpin/kingpin-5` implementing GitHub issue #5 ("Session lock never holds because it records the lock script's own PID"), including uncommitted changes in `bin/kingpin-lock`, `AGENTS.md`, and `tests/test-automation.sh`. The implementation replaces the short-lived `$$` script PID with ancestry-aware session PID resolution detecting known agent harnesses (`claude`, `agy`, `opencode`) and caller shells (`$PPID`), updates orchestrator startup in `AGENTS.md` to acquire the lock and operate read-only on failure, and adds an automated lifecycle test suite verifying free state, holder retention, collision rejection, stale recovery, and release. All acceptance criteria from issue #5 are met.

- **Criterion 1 (Hold lock for orchestrator session life):** Met — `resolve_session_pid` records the live harness PID or caller parent process PID ($PPID), verified by `tests/test-automation.sh` (Test 6) with a background process holding the lock.
- **Criterion 2 (Second acquire exits non-zero and names holder):** Met — Subsequent `acquire` calls while the holder lives fail with exit status 1 and output `error: another live kingpin orchestrator session holds the lock (pid $pid)`, verified by Test 6.
- **Criterion 3 (Auto-freeing on process termination):** Met — When the recorded holder PID terminates, `kill -0 "$pid"` fails, causing `status` to report `lock: stale` and allowing immediate re-acquisition without manual intervention, verified by Test 6.
- **Criterion 4 (AGENTS.md startup lock acquisition):** Met — `AGENTS.md:24` updated Rule 3 to run `bin/kingpin lock acquire` on startup and operate read-only if acquisition fails.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
- **M1** `bin/kingpin-lock:24` — Loose `*pi*` wildcard in harness argument matching matches any command line containing substring `pi` (including the project name `kingpin` itself). **Why:** Non-harness parent processes (such as IDE servers or custom runners with paths containing `kingpin`, `api`, or `pipeline` in their argument list) are misidentified as agent harnesses, causing the lock to latch onto long-lived ambient daemons rather than the orchestrator session, which defeats session isolation and automatic stale-lock cleanup. **Fix:** Restrict harness detection to exact tokens or word boundaries (e.g. `(^|[ /])(claude|agy|opencode|codex|pi|grok|kimi)(-[^ ]*)?([ ]|$)` or matching exact command names in `comm` and bounded words in `args`).

### Suggestions (Low)
- **L1** `tests/test-automation.sh:189` — Collision rejection assertions mask subshell exit codes with `|| true` without explicitly verifying that `acquire` or `check` exited non-zero. **Why:** If a regression caused concurrent invocations to print the error message while still returning exit code 0, the test would pass false positive. **Fix:** Capture the subshell exit code explicitly (e.g. `rc=0; ("$KP_BIN/kingpin" lock acquire) >/dev/null 2>&1 || rc=$?`) and assert `[ "$rc" -ne 0 ]` alongside the stderr string match.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash codebase; syntax validated via `bash -n bin/kingpin-lock tests/test-automation.sh` |
| Warnings | NONE | No warnings emitted during syntax checks or test suites |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host |
| Tests | PASS | `bash tests/test-automation.sh && bash tests/test-harnesses.sh && bash tests/test-acceptance.sh` (all suites passed: Test 6 lifecycle passed, multi-harness passed, parallel acceptance passed; 0 failed, 0 skipped) |
| UI verification | N/A | CLI orchestration tooling; no user-facing UI changes |

## What's Good

- Solves the core lifecycle defect cleanly by capturing ambient session PID rather than the ephemeral script PID `$$`.
- Preserves idempotency for re-entrant calls from the same session holder while strictly rejecting concurrent third-party sessions.
- Comprehensive end-to-end automated test coverage in Test 6 testing the full lifecycle across free, held, collision, stale, re-acquired, and released states.
- Clean and non-disruptive integration with existing `AGENTS.md` orchestrator guidelines.

## Recommendation

APPROVE WITH NITS. All acceptance criteria are fully met and verified by automated tests. Findings M1 and L1 are non-blocking improvements that can be resolved via `/fix-findings .agents/reviews/kingpin-kingpin-5-review.md M1 L1` or during branch finalization.
