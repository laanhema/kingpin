# Code Review: kingpin/kingpin-17

**Scope**: branch `kingpin/kingpin-17` (issue #17)
**Recommendation**: NEEDS CHANGES

## Summary

Reviewed branch `kingpin/kingpin-17` implementing GitHub issue #17 ("Automatically open Lavish review dossiers and maintain background live listeners"), including uncommitted changes in `bin/kingpin-listen` (new file), `bin/kingpin-watch`, `bin/kingpin-done`, `bin/kingpin`, `worker/preamble.md`, `AGENTS.md`, and `tests/test-automation.sh`. The implementation creates a background listener daemon that automatically opens review dossiers via `lavish-axi`, polls for user actions and feedback, routes approvals to `kingpin-land`, routes feedback and change requests to `feedback.md` and `status`, cleans up processes on `kingpin-done`, displays listener state in `kingpin list`, and adds full lifecycle tests in `test-automation.sh`.

Acceptance criteria verification against GitHub issue #17:
- **Criterion 1 (Auto-open dossier on ready in review mode):** Met — `bin/kingpin-watch:61-64` invokes `bin/kingpin-listen "$id" --background` upon detecting `ready:` in review mode, which executes `lavish-axi "$task_dir/report.html"` once (guarded by `$task_dir/lavish_opened`).
- **Criterion 2 (Background live listener armed & connected):** Met — `bin/kingpin-listen:62-75` maintains background polling via `lavish-axi poll`, records PID in `$task_dir/listener.pid`, `bin/kingpin:120-126` displays active PID in `kingpin list`, and `bin/kingpin-done:54-73` terminates the listener and ends the Lavish session.
- **Criterion 3 (Route clicks & feedback to orchestrator):** Partially met (see Finding H1) — while `Approve & Land` and basic feedback route to `status` and `feedback.md`, an unanchored regex match on `approve` in `bin/kingpin-listen:189` misidentifies negative review comments or change requests containing the word "approve" as approvals, triggering unintended landings.

## Issues Found

### Critical
None

### High Priority
- **H1** `bin/kingpin-listen:189` — Substring match on `approve` misidentifies negative review feedback or change requests as approvals. **Why:** Review feedback containing phrases like "Request Changes: do not approve yet", "cannot approve until tests pass", or "disapproved" matches `grep -qiE '(kingpin[[:space:]]+land|approve)'`, causing `kingpin-listen` to log `approved: by user via lavish dossier` to `$task_dir/status` and trigger `kingpin-land` to land unapproved code. **Fix:** Check for `Request Changes:` or negative terms before checking for approval, and anchor approval matching to explicit commands or CTA patterns (e.g. `^[[:space:]]*(kingpin[[:space:]]+land|approve([[:space:]]*&[[:space:]]*land)?)\b`).

### Medium Priority
None

### Suggestions (Low)
- **L1** `bin/kingpin-listen:163` — `extract_prompt` raw text fallback can return empty prompt JSON payloads (e.g. `{"prompts": []}`) as feedback text. **Why:** When `jq` or `node` successfully parses valid JSON but finds no prompt entries, `extract_prompt` falls through to the raw text heuristic at line 163, treating the JSON payload itself as user feedback. **Fix:** Explicitly return 1 from `extract_prompt` if structured JSON parsing was attempted and produced no prompt text.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | PASS | `bash -n bin/* tests/*.sh` on host; zero syntax errors |
| Warnings | NONE | Zero warnings emitted during syntax checks or test suites |
| Lint | PASS | `bash -n bin/* tests/*.sh` on host |
| Tests | PASS | `./tests/test-automation.sh` (10/10 passed, including new Test 10); `./tests/test-acceptance.sh` (passed); `./tests/test-harnesses.sh` (7/7 passed) |
| UI verification | N/A | Backend orchestrator scripts and CLI listener; Lavish Editor integration verified via mock harness in Test 10 |

## What's Good

- Elegant design separating background polling into `bin/kingpin-listen` with PID tracking and sentinel files (`lavish_opened`) preventing duplicate browser tabs.
- Full process lifecycle management in `bin/kingpin-done` with multi-step termination (`SIGTERM`, wait loop, `SIGKILL` fallback) and session cleanup via `lavish-axi end`.
- Clean terminal UX in `bin/kingpin list` surfacing active background listener PIDs.
- Thorough and robust automated end-to-end testing in `tests/test-automation.sh` (Test 10) covering dossier opening, listener arming, approval routing, feedback routing, and cleanup.

## Recommendation

NEEDS CHANGES. Address Finding H1 in `bin/kingpin-listen:189` to anchor approval pattern matching and prevent negative review feedback from falsely triggering automatic landing.
