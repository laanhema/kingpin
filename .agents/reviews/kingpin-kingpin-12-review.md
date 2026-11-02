# Code Review: kingpin/kingpin-12

**Scope**: branch `kingpin/kingpin-12` vs merge base 9f863da (all changes uncommitted), checked against issue #12
**Recommendation**: APPROVE WITH NITS

## Summary

`bin/kingpin-send` now sends text with `send-keys -l --`, sleeps `KINGPIN_SEND_DELAY` (default 0.2s), then sends Enter in a separate call. Tests and docs follow, and the two stub-restoring tests no longer discard uncommitted edits. Untracked plan and report under `.agents/` were read as context only. No correctness problems found.

Acceptance criteria:
- Text via `send-keys -l`, then Enter in a separate call after a pause: met. `bin/kingpin-send:34-36`. Test 12 (`tests/test-automation.sh:1034-1072`) sends `Escape` and `C-c` to a `cat` pane and reads them back as lines. I ran the suite and it passes.
- Multi-line or long message arrives intact (verify: 2,000-character message): met. Test 12 asserts the 2,000-char line arrives intact. I also checked a 4-line message with a blank line in a private tmux socket against a `cat` pane, and all lines arrived in order.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-send:14` — the usage error still says `kingpin-send <task-id> <keys>`, and the header comment at `bin/kingpin-send:2` still says "text or keys", while the change renamed the argument to `<text>` everywhere else (header line 4, `bin/kingpin:12`, README). **Why:** the message contradicts the new literal-text contract. **Fix:** change to `usage: kingpin-send <task-id> <text>` and "Send text into a kingpin task's tmux window."
- **L2** `tests/test-automation.sh:1057-1070` — Test 12 has no multi-line case, though the criterion title says "multi-line or long message". **Why:** newline handling under `-l` is only verified by hand here. **Fix:** add a case sending `$'a\nb'` and assert both lines reach the pane.

**Noted, not a finding**: the fixed 0.2s pause is a heuristic for TUI paste handling (overridable via `KINGPIN_SEND_DELAY`). The issue itself specifies "a short pause".

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n` on the changed scripts, per the implementation report (pure bash); host |
| Warnings | N/A | no warnings gate; shellcheck not installed |
| Lint | SKIPPED | shellcheck not installed on the host |
| Tests | PASS | `bash tests/test-automation.sh` (includes Test 12, 5 new assertions), `test-acceptance.sh`, `test-harnesses.sh`, `test-worker-settings.sh` all pass; host, private tmux socket; nothing reported skipped. Red-before-fix run taken from the implementation report, not re-run. |
| UI verification | N/A | no UI change |

## What's Good

- Uses `-l --`, so text starting with a dash is also safe, and Test 12 covers it.
- Restoring the stub from a backup copy fixes a real hazard: `git checkout` discarded uncommitted edits to the script under test.
- The delay is configurable and the tests use a short delay.

## Recommendation

Merge after optionally fixing L1 (one-line usage text) and L2. Run `/fix-findings .agents/reviews/kingpin-kingpin-12-review.md`.
