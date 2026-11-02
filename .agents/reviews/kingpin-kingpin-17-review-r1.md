# Code Review (re-review r1): kingpin/kingpin-17-claude

**Scope**: branch `kingpin/kingpin-17-claude` (issue #17), uncommitted changes against `main`, including the work imported from the earlier `kingpin/kingpin-17` attempt and the fixes made on top of it.
**Recommendation**: APPROVE WITH NITS
**Independence**: not independent. No subagent tool was available, so the author of the fixes reviewed them. Read the verdict with that in mind.

## Prior findings (from `kingpin-kingpin-17-review.md`)

| ID | Status | Notes |
|----|--------|-------|
| H1 | Fixed | Approval is now matched by `classify()` in `lib/lavish-prompts.mjs` on the whole prompt (`kingpin land [<id>]`, `approve [& land]`). "cannot approve…", "do not approve" and any `Request Changes…` are feedback. Test 10 covers it. |
| L1 | Fixed | The raw-text fallback is gone. Only decoded prompts are used, and an empty prompts list yields nothing. |

## Acceptance criteria (issue #17)

1. Auto-open on `ready:` in review mode: met. `kingpin-watch` runs `kingpin-listen --background`, which opens `lavish-axi <report.html>` once (`lavish_opened`). `AGENTS.md` tells an orchestrator that uses only `kingpin-wait` to run `bin/kingpin listen <id> --background`.
2. Background `lavish-axi poll` armed: met. A setsid'd loop polls with `--owner kingpin:<id> --takeover`, writes `listener.pid`, and `kingpin list` shows it. It survives `browser_disconnected` and stops on an ended session or `kingpin-done`.
3. Button clicks and feedback route to the orchestrator: met. Approve & Land runs `kingpin-land`, then logs `approved:`. Everything else goes to `feedback.md` plus a `feedback:` status line, which wakes `kingpin-wait`. The listener replies in Lavish either way.

## Issues Found

### Critical
None

### High
None. The one High risk found during this review, listener notes in `status` bypassing the `kingpin-land` review gate, was fixed in `bin/kingpin-land` and has a regression test (verified red without the fix, green with it).

### Medium
None

### Low
- **L1** `bin/kingpin-listen` `handle_approve` — A repeat Approve click while a fix pass is pending (`landing_in_progress` set, `landing_sent` not yet) runs `kingpin-land` again and re-sends `/fix-findings`. **Fix:** skip with a reply when `landing_in_progress` exists and the worker's last event is not `ready:`/`fixed:`.
- **L2** `bin/kingpin-listen` background launcher — The "already running" check reads `listener.pid`, which the child writes shortly after start. Two launches within ~50 ms (watch and a manual `kingpin listen`) can both start. **Fix:** take an `mkdir` lock before starting.
- **L3** `lib/lavish-prompts.mjs` — The scan fallback only handles the two TOON shapes seen in `lavish-axi` output. A future format change drops prompts silently. **Fix:** have the listener log the raw response to `listener.log` when a poll returns `feedback` status with zero parsed prompts.

## Validation

| Check | Result | Notes |
|-------|--------|-------|
| Syntax | PASS | `bash -n` on `bin/*` shell scripts and `tests/*.sh`; `node --check lib/lavish-prompts.mjs` |
| Automation tests | PASS | `tests/test-automation.sh`, incl. Test 10 (listener lifecycle, approve, feedback, negative approval, cleanup) and the new gate test; run on a private tmux server |
| Acceptance tests | PASS | `tests/test-acceptance.sh` |
| Harness tests | PASS | `tests/test-harnesses.sh` |
| Real-format decode | PASS | `lib/lavish-prompts.mjs` run against the installed `lavish-axi` decoder for both TOON shapes and a session-ended response |
| Live browser | NOT RUN | No browser session was driven; Lavish behaviour is covered by a mock `lavish-axi` and by decoding real-format output |

## Recommendation

APPROVE WITH NITS. No Critical or High findings.
