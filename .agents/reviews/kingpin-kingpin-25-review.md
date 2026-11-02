# Code Review: kingpin/kingpin-25

**Scope**: branch `kingpin/kingpin-25` against `main`, including uncommitted and untracked work (issue #25)
**Recommendation**: APPROVE WITH NITS

## Summary

Reviewed `lib/report-diffs.mjs`, `bin/kingpin-report`, the `report` dispatch in `bin/kingpin`, the `{{KP_ROOT}}` substitution in `bin/kingpin-spawn`, the new preamble section, `tests/test-report.sh` and the README row. This review ran in the implementer's own session (no subagent tool), so it is not independent of the implementation. The helper works: the generated section rendered 5/5 diffs in Chrome, and all five test suites pass. `check` has one correctness weakness (M1).

Acceptance criteria:
- **`worker/preamble.md` includes the verified Pierre snippet with `oldFile`/`newFile`**: met (`worker/preamble.md`, section "Diffs in `report.html`"; the shape matches `lavish-axi playbook code`; it also warns that `patch:` renders nothing).
- **Workers have a standard, reliable pattern or helper**: met by `kingpin report diffs`; the preamble points to it with an absolute path through `{{KP_ROOT}}`, which I confirmed substitutes with the same `sed` as the other placeholders.
- **Dossiers reliably render visible diffs on initial load without blank containers**: met when the helper is used (static fallback is visible immediately, and Pierre replaces it; verified in Chrome). It depends on the worker running the gate; see L1 and M1.

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
- **M1** `lib/report-diffs.mjs:148` — `check` tests the whole page text outside `<pre>` and JSON data, not the script code. **Why:** prose such as "replaced the old patch: approach" fails a good report (reproduced, rc=1), and a page whose only mention is prose such as `<p>FileDiff oldFile newFile</p>` passes (reproduced, rc=0) even though nothing renders, which is the blank-diff case the gate exists to catch. **Fix:** build `code` from the contents of `<script>` elements without the `application/json` type, and run the `FileDiff`, `patch:` and `oldFile`/`newFile` tests on that; add a test case for each reproduced input.

### Suggestions (Low)
- **L1** `worker/preamble.md:48` — the check is only an instruction to the worker; nothing in the orchestrator runs it when a worker reports `ready:`. **Why:** a worker that skips it can still land a blank dossier, so criterion 3 depends on compliance. **Fix:** have `bin/kingpin-listen` (or `kingpin-land`) run `kingpin-report check` on `report.html` for `ready:` and warn when it fails, or file a follow-up issue.
- **L2** `README.md:177` — the new `tests/test-report.sh` is missing from the README's test-suite list. **Fix:** add `./tests/test-report.sh` with a one-line comment.
- **L3** `lib/report-diffs.mjs:159` — the empty-container regex uses `\bkp-diff\b`, which also matches `kp-diff-file`/`kp-diff-title`, so a hand-written empty `kp-diff-title` div would be reported as an empty diff container. **Fix:** match the class as a whole token, `(?:^|\s)kp-diff(?:\s|$)`.

**Noted, not a finding**: the JSON data block holds the full old and new text of every changed file, so a dossier is roughly three times the size of the changed files (JSON, fallback, and Pierre output); acceptable for the diff sizes of a task.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | bash/node project; `bash -n` on `bin/kingpin`, `bin/kingpin-report`, `bin/kingpin-spawn` and `node --check lib/report-diffs.mjs` PASS (host) |
| Warnings | N/A | none configured |
| Lint | N/A | no linter configured (shellcheck not installed) |
| Tests | PASS | `tests/test-report.sh` (14 assertions), `test-harnesses.sh`, `test-worker-settings.sh`, `test-automation.sh`, `test-acceptance.sh` all PASS on the host; none skipped |
| UI verification | PASS | generated fragment opened in Chrome via `chrome-devtools-axi`: 5 of 5 containers hold a rendered Pierre diff and the fallback hid itself |

## What's Good

- It fixes the cause: the generator is the only place that builds the `FileDiff` call, and the gate names the exact mistake in its error message.
- The static fallback means a failed esm.sh load still shows the diff.
- File text cannot break the page: `<` is escaped in the JSON, and the test covers a `</script>` inside a changed file.
- Renames, untracked files and binary files are handled.

## Recommendation

Merge after fixing M1 (and ideally L1 to L3) with `/fix-findings .agents/reviews/kingpin-kingpin-25-review.md`.
