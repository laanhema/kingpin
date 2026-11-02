# Code Review: kingpin/kingpin-19

**Scope**: branch `kingpin/kingpin-19` (vs `main` merge base, including uncommitted changes)
**Recommendation**: NEEDS CHANGES

## Summary

Reviewed changes on branch `kingpin/kingpin-19` addressing Issue #19. The changes configure isolated tmux environments in `tests/test-acceptance.sh`, `tests/test-automation.sh`, and `tests/test-harnesses.sh` by defining unique `TEST_SOCKET` identifiers under `TMUX_TMPDIR="$T/tmux-tmp"` and inserting a `$T/bin/tmux` wrapper at the front of `PATH`. However, all three test scripts introduce an ambient check (`"$REAL_TMUX" -L default has-session -t kingpin`) that directly violates Acceptance Criterion 2 ("never modifies, inspects, or kills sessions on the ambient default tmux server") and causes false-positive test failures whenever Kingpin is running ambiently on the host outside of tmux.

### Acceptance Criteria Verification

- [x] **All test scripts in `tests/` operate on an isolated private tmux socket (`tmux -L kingpin-test-...` or a temporary socket directory) with an independent socket name** — Met. All three test scripts (`tests/test-acceptance.sh:23-32`, `tests/test-automation.sh:25-34`, `tests/test-harnesses.sh:25-34`) set unique `TEST_SOCKET` variables (`kingpin-test-<suite>-$$`) and route tmux commands through `$T/bin/tmux`.
- [ ] **Running `./tests/test-*.sh` never modifies, inspects, or kills sessions on the ambient default tmux server** — Unmet / Deviates. Lines `tests/test-acceptance.sh:93`, `tests/test-automation.sh:60`, and `tests/test-harnesses.sh:48` inspect the ambient default tmux server using `"$REAL_TMUX" -L default has-session -t kingpin 2>/dev/null`. If an ambient `kingpin` session is active (the default when running Kingpin outside tmux), the check triggers `fail "kingpin session leaked onto default tmux socket"`, causing false-positive test suite failures.
- [x] **Test cleanup cleanly destroys only its own private test socket and temporary socket files** — Met. All three test suites register `cleanup()` via `trap cleanup EXIT` executing `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server` and removing `$T`.

## Issues Found

### Critical
None

### High Priority
- **H1** `tests/test-automation.sh:60` — Ambient default tmux server is inspected with has-session, causing false test failure if an ambient kingpin session exists. **Why:** Acceptance Criterion 2 specifies that running tests never modifies, inspects, or kills sessions on the ambient default tmux server; executing `"$REAL_TMUX" -L default has-session -t kingpin` inspects the default server and causes false failures when Kingpin is running ambiently on the host outside tmux. **Fix:** Remove the `"$REAL_TMUX" -L default has-session` check from `tests/test-acceptance.sh:93`, `tests/test-automation.sh:60`, and `tests/test-harnesses.sh:48`, relying on the preceding `#{socket_path}` assertion which already proves tmux operations are isolated to the private test socket.

### Medium Priority
None

### Suggestions (Low)
- **L1** `tests/test-automation.sh:378` — Redundant explicit kill-server calls before script exit. **Why:** `tests/test-acceptance.sh:172`, `tests/test-automation.sh:378`, and `tests/test-harnesses.sh:220` explicitly invoke `"$REAL_TMUX" -L "$TEST_SOCKET" kill-server` immediately before exit, duplicating the `cleanup()` trap already registered on `EXIT`. **Fix:** Remove the redundant `kill-server` invocations before exit and rely solely on the `EXIT` cleanup trap.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash project |
| Warnings | NONE | `bash -n bin/* tests/*.sh` reported 0 syntax warnings/errors |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host |
| Tests | PASS | `./tests/test-harnesses.sh`, `./tests/test-automation.sh`, `./tests/test-acceptance.sh` all passed on host |
| UI verification | N/A | CLI/testing infrastructure |

## What's Good

- Generating a lightweight `$T/bin/tmux` wrapper prepended to `PATH` cleanly intercepts `tmux` invocations across bash scripts, child subshells, and Python `subprocess.run` calls without modifying any core project binaries in `bin/`.
- `export TMUX_TMPDIR="$T/tmux-tmp"` ensures all socket files and temporary tmux state stay strictly inside `$T`, avoiding any leakage into `/tmp/tmux-<uid>/`.
- The `cleanup()` EXIT trap in `test-acceptance.sh` reliably restores `bin/kingpin-send` even if the test aborts prematurely during the landing simulation.

## Recommendation

Address finding H1 by removing the default socket `has-session` check across all three test scripts (`tests/test-acceptance.sh:93`, `tests/test-automation.sh:60`, and `tests/test-harnesses.sh:48`). Then run `/fix-findings .agents/reviews/kingpin-kingpin-19-review.md H1 L1`.
