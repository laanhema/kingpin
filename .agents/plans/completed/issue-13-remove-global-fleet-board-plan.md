# Plan: Remove the global fleet board

## Summary

Delete `bin/kingpin-board`, the `board` subcommand in `bin/kingpin`, the three board calls in `bin/kingpin-watch`, and board mentions in README. Tests that checked board HTML are changed to check `kingpin list` output. No `lib/` helper is board-only (`report-diffs.mjs`, `lavish-prompts.mjs` serve report/listen). Per-task `report.html` stays.

## Metadata

| Field | Value |
|-------|-------|
| Type | REFACTOR |
| Complexity | LOW |
| Systems Affected | bin/, tests/, README.md |
| GitHub Issue | #13 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-board` | DELETE | board renderer |
| `bin/kingpin` | UPDATE | drop usage header, help line, `board)` case |
| `bin/kingpin-watch` | UPDATE | drop board calls and comments |
| `tests/test-acceptance.sh` | UPDATE | check `kingpin list` instead |
| `tests/test-harnesses.sh` | UPDATE | check `kingpin list` harness column instead |
| `README.md` | UPDATE | remove board command row, section, lavish wording |

## Tasks

### Task 1: Delete board script and subcommand
- **File**: `bin/kingpin-board`, `bin/kingpin`
- **Action**: UPDATE
- **Implement**: `git rm bin/kingpin-board`; remove lines 9, 37 and the `board)` case in `bin/kingpin`.
- **Mirror**: neighbouring cases in `bin/kingpin`
- **Validate**: `bash -n bin/kingpin && bin/kingpin --help | grep -ci board` (expect 0)

### Task 2: Strip board from watch
- **File**: `bin/kingpin-watch`
- **Action**: UPDATE
- **Implement**: remove the three `kingpin-board` calls, the "Initial board refresh" comment, and header comment items 1 and 4 (renumber).
- **Mirror**: n/a
- **Validate**: `bash -n bin/kingpin-watch && ! grep -i board bin/kingpin-watch`

### Task 3: Update tests
- **File**: `tests/test-acceptance.sh`, `tests/test-harnesses.sh`
- **Action**: UPDATE
- **Implement**: replace board checks with `kingpin list` output checks (task ids; harness names), inspecting how list prints the harness first.
- **Mirror**: existing pass/fail helpers
- **Validate**: `bash tests/test-acceptance.sh && bash tests/test-harnesses.sh`

### Task 4: README
- **File**: `README.md`
- **Action**: UPDATE
- **Implement**: remove the `kingpin board` row, section 3, and reword the optional `lavish-axi` line to per-task review dossiers.
- **Validate**: `! grep -i "fleet board\|kingpin board" README.md`

## Validation

```bash
for f in bin/kingpin bin/kingpin-watch tests/test-*.sh; do bash -n $f; done
for t in tests/test-*.sh; do bash $t; done
grep -rniI "kingpin-board\|board.html\|fleet board" --exclude-dir=.git --exclude-dir=.agents .
```

## End-to-End Verification

`bin/kingpin --help` shows no `board`; `bin/kingpin board` errors as unknown command; test suites pass.

## Risks

| Risk | Mitigation |
|------|------------|
| `kingpin list` may not print harness | check its output; assert on what it prints, else drop that check (in scope) |
| `.agents/rules/kingpin.md` / preamble `report.html` hits | per-task report, keep |

## Acceptance Criteria

- [ ] All tasks completed
- [ ] `kingpin --help` has no board; no `kingpin-board` call remains
- [ ] All test suites pass
- [ ] README/AGENTS.md mention no fleet board
