# Plan: Make `kingpin land` say when a fix pass runs first

## Summary

`bin/kingpin-land` sends `/fix-findings` and exits when the review verdict is `APPROVE WITH NITS` or `NEEDS CHANGES`; the only hint is `review verdict is <verdict>; sending /fix-findings`. Fix: (1) reword every outcome line so the operator can tell what happens next: the fix path says a fix pass runs first and that landing continues after the `fixed:` event; the clean path says landing is starting; (2) make that line the last line the command prints, because `bin/kingpin-listen:148` echoes only the last line of `kingpin-land` output to the dossier (today that is `OK: sent to <tmux target>` from `kingpin-send`); (3) add `kingpin approve` as an alias of `kingpin land` (the issue's recommended "option 1 plus a clearly named alias"), documented in `--help`, `README.md`, `AGENTS.md`, and covered by a test. `kingpin land` keeps working, so `bin/kingpin-watch`, `worker/preamble.md` and the dossier button need no change.

## User Story

As the operator (boss)
I want `kingpin land` to tell me when it starts a fix pass instead of landing
So that I do not mistake a fix-pass dispatch for a landing, or wait for a merge that has not started.

## Metadata

| Field | Value |
|-------|-------|
| Type | ENHANCEMENT |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-land`, `bin/kingpin`, `README.md`, `AGENTS.md`, `tests/test-automation.sh` |
| GitHub Issue | #30 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| `tests/test-automation.sh`, `test-acceptance.sh`, `test-harnesses.sh`, `test-worker-settings.sh` on HEAD | all green (`ALL ... PASSED`) |
| Tests asserting current `kingpin-land:` wording | none (grep of `tests/` finds none) |
| `bin/kingpin-listen:141-148` | reply is `Approval received. $(... | tail -n 1)`; test at `tests/test-automation.sh:861` only matches the prefix `Approval received` |
| `kingpin-send` stdout | `OK: sent to <target>` (`bin/kingpin-send:37`); would be the last line unless silenced |
| Blockers | #10 and #17 (named in the issue notes) are merged and closed |

## Patterns to Follow

### Output lines
```
// SOURCE: bin/kingpin-land:79-80
echo "kingpin-land: task $id review verdict is $verdict; sending /fix-findings"
touch "$task_dir/landing_in_progress"
```

### Dispatch in bin/kingpin
```
// SOURCE: bin/kingpin:64-66
  land)
    exec "$KP_BIN/kingpin-land" "$@"
    ;;
```

### Tests
```
// SOURCE: tests/test-automation.sh:513-516
"$KP_BIN/kingpin" land t7-nits >/dev/null
[ -f "$t7_dir/landing_in_progress" ] && pass "landing_in_progress set on APPROVE WITH NITS" || fail "landing_in_progress missing"
```

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-land` | UPDATE | explicit output for each outcome, final line is the outcome, `kingpin-send` stdout silenced |
| `bin/kingpin` | UPDATE | `approve` alias in the dispatch, usage comment and `--help` |
| `README.md` | UPDATE | command table row: alias and the fix-pass behaviour |
| `AGENTS.md` | UPDATE | note `kingpin approve` alias and that `land` may run the fix pass first |
| `tests/test-automation.sh` | UPDATE | Test 14: both output paths, the last-line rule, the alias, `--help` |

## Tasks

### Task 1: Explicit outcome lines in `bin/kingpin-land`

- **File**: `bin/kingpin-land`
- **Action**: UPDATE
- **Implement**: Keep control flow unchanged. Messages (each is one `echo`, printed once, immediately before the `kingpin-send` call, and `kingpin-send ... >/dev/null` so it is the final stdout line):
  - fix path (`APPROVE WITH NITS` / `NEEDS CHANGES`): `kingpin-land: task $id review has findings ($verdict): running the fix pass first (/fix-findings); landing continues after the worker reports fixed: (run kingpin land again then, unless kingpin watch does it)`
  - re-review path (`fixed: high=N>0`): `... fix pass left $high High/Critical finding(s): requesting a re-review first (/review); landing continues after the re-review reports ready:` 
  - fixed clean: print `kingpin-land: task $id fix pass completed cleanly; starting landing` (replaces "proceeding to landing"; keep it before the lock logic, so a queued task prints the queue line last).
  - clean verdict dispatch: `kingpin-land: task $id review is clean ($verdict); starting landing: sending /issue-flow-done $issue` (and the no-issue `/create-pr-merge` variant). For the fixed-clean path the verdict is unset, so use `after the fix pass`.
  - queued: unchanged text.
- **Mirror**: `bin/kingpin-land:79`
- **Validate**: `bash -n bin/kingpin-land && bash tests/test-automation.sh`

### Task 2: `approve` alias in `bin/kingpin`

- **File**: `bin/kingpin`
- **Action**: UPDATE
- **Implement**: `land|approve)` in the case; add `kingpin approve <task-id>` to the usage comment; in `usage()` change the `land` line to `land      Land a ready worker (runs the fix pass first when the review has findings); alias: approve`.
- **Mirror**: `bin/kingpin:64-66`
- **Validate**: `bin/kingpin --help | grep approve`

### Task 3: Docs

- **File**: `README.md`, `AGENTS.md`
- **Action**: UPDATE
- **Implement**: README command table: `kingpin land` row gains "alias `kingpin approve`; when the review has findings it runs `/fix-findings` first and lands after the `fixed:` event". AGENTS.md rule 4/supervise list: one clause that `bin/kingpin approve` is the same command as `bin/kingpin land`, and that `land` can start the fix pass first (so the `fixed:` step runs it again). Do not change the existing `kingpin land` references.
- **Validate**: `grep -n approve README.md AGENTS.md`

### Task 4: Tests

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: add "Test 14" before the final summary, following Test 7's setup (tmux window `cat`, task.env, status). Cases: (a) `APPROVE WITH NITS` -> `kingpin land` output contains `fix pass` and `fixed:`, last stdout line contains `fix pass`, no landing lock; (b) `APPROVE` -> output contains `starting landing`, last line is not `OK: sent`, lock taken; (c) `fixed: high=0` -> `starting landing`; (d) `kingpin approve <id>` behaves like land (APPROVE case) and `kingpin land` still does; (e) `kingpin --help` lists `approve`.
- **Mirror**: `tests/test-automation.sh:496-607`
- **Validate**: `bash tests/test-automation.sh`

## Validation

```bash
bash -n bin/kingpin bin/kingpin-land
bash tests/test-automation.sh
bash tests/test-acceptance.sh
bash tests/test-harnesses.sh
bash tests/test-worker-settings.sh
```
No type check or lint is configured (`shellcheck` is not installed).

## End-to-End Verification

Run Test 14 (it drives the real `bin/kingpin` against a private tmux server and a fake task dir). The new assertions fail on HEAD (`starting landing` and the `approve` command do not exist there): confirm by running them against `git stash`-free HEAD copy via `git show HEAD:bin/kingpin-land` into a scratch dir if wanted.

## Risks

| Risk | Mitigation |
|------|------------|
| Dossier reply (`kingpin-listen`) uses the last output line | Silence `kingpin-send` stdout so the outcome line is last; Test 14 asserts it. In scope |
| Alias drifts from `land` | It is one `case` arm, no second code path. In scope |
| Renaming `land` itself | Out of scope; `AGENTS.md`, `kingpin-watch`, `worker/preamble.md` keep `land` |

## Open Questions

- Whether to add the alias at all: the issue recommends option 1 plus an alias and its AC makes alias coverage conditional. Default: add `kingpin approve` (cheap, one case arm); name matches the issue's own example.

## Acceptance Criteria

- [ ] Fix path output states a fix pass runs first and landing continues after `fixed:`
- [ ] Clean path output states landing is starting
- [ ] `kingpin approve` works, in `--help`, `AGENTS.md`, `README.md`, and tests; `kingpin land` still works
- [ ] Existing tests pass; Test 14 covers both output paths
