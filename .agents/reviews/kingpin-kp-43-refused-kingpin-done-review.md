# Code Review: kingpin/kp-43-refused-kingpin-done

**Scope**: branch `kingpin/kp-43-refused-kingpin-done` vs merge base `ede5059` (main), including uncommitted changes (nothing is committed yet), checked against issue #43
**Recommendation**: APPROVE WITH NITS

## Summary

Reviewed `bin/kingpin-done`, `bin/kingpin-ack`, Test 19 in `tests/test-automation.sh`, and the README row, plus the callers (`kingpin-watch`, `kingpin-wait`, `kingpin-land`, `kingpin run`) that read the status line. The change is small and correct. The untracked plan and implementation report agree with the code.

Acceptance criteria (issue #43, owner comment 2026-11-03 adds no changes):
- Refused `done` on a live worker keeps its last status: met. Test 19(a) holds `needs-input:`, runs `done`, and checks the last status line and `kingpin list`. Test 19 is red on the pre-fix `bin/` per the report.
- Refusal on a finished task still reports `cleanup-refused:`: met. Test 19(b) asserts it, and the existing refusal tests in Tests 1-18 still pass.
- `done` stops the dossier listener: met. Test 19(b) checks that the pid is gone, `listener.pid` is removed, and `list` no longer shows `listening`.
- `ack` on an archived task exits 0 with a note: met. Test 19(c), and an unknown id still exits 1.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-done:83` — The `grep -vE '^(approved|feedback):'` filter that skips the listener's notes has no test. **Why:** Test 19 never puts an `approved:` or `feedback:` line after `merged:`, so removing the filter leaves the suite green. The filter is the only thing that stops `merged:` then `approved:` from being treated as a live worker. **Fix:** Add a case to Test 19 where the status file is `merged: ...` followed by `approved: by user via lavish dossier`, then assert that a refused `done` still appends `cleanup-refused:`.

**Noted, not a finding**: the slot guard (`bin/kingpin-done:~113`) still reads `other_last` with a plain `tail -n 1`, so it does not skip listener notes. That is the existing behaviour, untouched by this change. A refusal of a live worker is now only on stderr (no status event), which is what criterion 1 asks for.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | Bash project, no build step. `bash -n` was run by the implementer. |
| Warnings | N/A | No compiler. |
| Lint | N/A | No linter configured in the project rules. |
| Tests | PASS | `bash tests/test-automation.sh` (host): ALL AUTOMATION TESTS PASSED, Test 19 all PASS. `test-report.sh`, `test-harnesses.sh`, `test-worker-settings.sh` and `test-acceptance.sh` each exited 0. No skipped tests observed. |
| UI verification | N/A | No UI change. |

## What's Good

- The listener-stop code is one shared `stop_listener`, used by both the success and refusal paths, rather than being duplicated.
- Test 19 also covers the opposite case: a refusal on a live `ready:` worker leaves its listener running.
- The README row describes the new behaviour accurately, including the stderr-only reason.

## Recommendation

Ready to land. The one Low nit (L1) is optional: add the missing test case for the `approved:`/`feedback:` filter.
