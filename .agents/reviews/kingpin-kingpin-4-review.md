# Code Review: kingpin/kingpin-4

**Scope**: branch `kingpin/kingpin-4` (vs merge base `bb11cf7` including uncommitted changes, issue #4)
**Recommendation**: APPROVE

## Summary

Reviewed all changes implementing event-driven orchestrator wakes and explicit acknowledgment across `bin/kingpin`, `bin/kingpin-ack`, `bin/kingpin-wait`, `bin/kingpin-watch`, `bin/kingpin-done`, `AGENTS.md`, and `tests/test-automation.sh`. The implementation is robust, adheres to repository patterns, and cleanly satisfies all acceptance criteria.

Acceptance criteria verification:
- `bin/kingpin-wait` without `--once` blocks until at least one task event exists and prints one `<task-id> <reason>` line per event, then exits 0: **MET** (verified by automated Test 6 and live execution waking in ~28ms on status append).
- An event is printed once: after the orchestrator handles it (for example with a `kingpin ack <task-id>` command or by advancing `seen`), the next `kingpin-wait` run does not print it again: **MET** (verified by Test 6 and live execution checking status, quiet, and exited suppression after `kingpin ack`).
- `AGENTS.md` tells the orchestrator to keep one background `kingpin-wait` running whenever a task is live, to re-arm it after handling each event, and never to run two at once: **MET** (verified in `AGENTS.md` Hard Rule 5 and Supervise instructions).
- `AGENTS.md` lets the orchestrator read files under `~/.kingpin/tasks/<id>/` (status, question.md, report.html), not only run `kingpin` commands: **MET** (verified in `AGENTS.md` Hard Rule 1).

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
| Build / Type Check | N/A | Bash scripts; syntax validated via `bash -n bin/* tests/*` on host |
| Warnings | NONE | No warnings emitted during syntax checks or test runs |
| Lint | PASS | `bash -n bin/* tests/*` on host |
| Tests | PASS | `./tests/test-acceptance.sh && ./tests/test-automation.sh && ./tests/test-harnesses.sh` all passed on host (acceptance tests: 3 concurrent workers and serialized landing passed; automation tests: tests 1-6 passed; harness tests: tests 1-6 passed; occasional timing jitter in pre-existing test-acceptance.sh sleep 2 observed on base commit as well) |
| UI verification | N/A | CLI and orchestration backend changes; no web UI modifications |

## What's Good

- `bin/kingpin-wait` combines bounded `inotifywait` with periodic 2-second fallback polling, ensuring sub-50ms reaction to status/stopped filesystem modifications while guaranteeing reliable detection of external window death within 2 seconds even if filesystem watchers miss an event.
- Event deduplication and acknowledgment via `bin/kingpin-ack` cleanly centralizes seen counter advancement, stopped timestamps, and `seen_exited` markers across CLI entrypoints, eliminating duplicated inline tracking in `bin/kingpin-watch`.
- `bin/kingpin-done` automatically invokes `kingpin-ack` upon closing task windows to prevent expected teardowns from being misclassified as worker crashes.
- Comprehensive end-to-end test coverage added to `tests/test-automation.sh` covering idle wait blocking, sub-5-second wake latency, output matching, `kingpin ack`, and suppression of status, quiet, and exited events.

## Recommendation

Ready to merge. Changes can be committed and landed.
