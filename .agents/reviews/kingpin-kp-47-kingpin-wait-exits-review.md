# Code Review: kingpin/kp-47-kingpin-wait-exits

**Scope**: branch kingpin/kp-47-kingpin-wait-exits vs main (uncommitted changes; issue #47)
**Recommendation**: APPROVE (no findings)

## Summary

kingpin-wait now exits 0 silently on a plain timeout; --once with no events keeps exit 1; bad args exit 2; unusable fleet dir exits 1, each with a message. Acceptance criteria: (1) met, exit 0 and empty output, tested in Test 6b; (2) met, bad arg, bad --timeout and unusable dir tested, and I ran the missing-dir and missing-value cases by hand; (3) met, --once still exits 1 and tests 6 stay green; (4) met, usage text, script header, bin/kingpin header and AGENTS.md updated. The only other caller, kingpin-watch, uses `|| true`, so it is unaffected.

## Issues Found

### Critical
None
### High Priority
None
### Medium Priority
None
### Suggestions (Low)
None

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | shell project |
| Warnings | NONE | |
| Lint | N/A | none configured |
| Tests | PASS | `bash tests/test-automation.sh` ALL AUTOMATION TESTS PASSED on host |
| UI verification | N/A | no UI |

## What's Good

Minimal change, --once contract preserved, error paths tested.

## Recommendation

Ready to land.
