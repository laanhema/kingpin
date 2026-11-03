# Plan: kingpin-wait exits 0 on a plain timeout

## Summary

`bin/kingpin-wait` exits 1 with no output on a plain timeout, which harnesses report as a crash. A plain timeout (no `--once`) will exit 0 and print nothing. `--once` with no events keeps exiting 1 (scripts and tests rely on it). Bad arguments keep exit 2; an unusable fleet directory exits non-zero with an explicit message. Usage text, header comment, AGENTS.md and tests are updated.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | bin/kingpin-wait, AGENTS.md, tests/test-automation.sh |
| GitHub Issue | #47 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| bin/kingpin-watch:118 (`--once ... \|\| true`), :138 (`--timeout ... \|\| true`) | tolerate any exit code; no change needed |
| bin/kingpin:69 `wait` | `exec`s kingpin-wait, so the exit code passes through; no change needed |
| README.md | does not document wait semantics beyond the guard row; only a one-line mention if absent |

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-wait` | UPDATE | timeout exit 0; validate --timeout; explicit fleet-dir error; usage + header |
| `bin/kingpin` | UPDATE | header/usage line for wait documents exit codes |
| `AGENTS.md` | UPDATE | rule 5 / supervision: timeout behavior |
| `tests/test-automation.sh` | UPDATE | tests next to Test 6 |

## Tasks

### Task 1: Fix exit codes in kingpin-wait
- **File**: `bin/kingpin-wait`
- **Action**: UPDATE
- **Implement**: both timeout exits (elapsed >= TIMEOUT, step <= 0) become `exit 0`; `--once` no-events keeps `exit 1`; reject non-numeric `--timeout` with exit 2 and message; replace bare `mkdir -p` with `mkdir -p ... 2>/dev/null || { echo "kingpin-wait: cannot create fleet directory $tasks_dir" >&2; exit 1; }` and a readability check; update header comment and `-h` text.
- **Mirror**: existing arg parsing in the same file
- **Validate**: `bash -n bin/kingpin-wait`

### Task 2: Docs
- **File**: `AGENTS.md`, `bin/kingpin`
- **Action**: UPDATE
- **Implement**: describe: events found exit 0 with lines; timeout exit 0 and empty; `--once` without events exit 1; errors non-zero with message.
- **Validate**: `bash -n bin/kingpin`

### Task 3: Tests
- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: after Test 6 add checks for timeout (exit 0, empty stdout/stderr), --once exit 1, bad argument, bad timeout, unreadable fleet dir (KINGPIN_HOME with a file in place of tasks dir).
- **Mirror**: Test 6 pass/fail style
- **Validate**: `bash tests/test-automation.sh`

## Validation

```bash
bash -n bin/kingpin-wait bin/kingpin tests/test-automation.sh
bash tests/test-automation.sh
bash tests/test-harnesses.sh
```

## End-to-End Verification

`KINGPIN_HOME=$(mktemp -d) bin/kingpin-wait --timeout 1; echo $?` prints nothing and 0 (red on HEAD: 1). `--once` prints 1. `--bogus` prints a message and 2.

## Risks

| Risk | Mitigation |
|------|------------|
| Callers distinguishing timeout by exit 1 | only watch/tests use it; both use `\|\| true` or `--once` (in scope: verified) |

## Acceptance Criteria

- [ ] Timeout exits 0, no output
- [ ] Errors exit non-zero with message
- [ ] --once still exits 1; existing tests green
- [ ] Usage and AGENTS.md updated
