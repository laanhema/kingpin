# Plan: Curator archives skill critiques only after success and handles quotes safely

## Summary

Fix `bin/kingpin-curate` so that skill critiques are archived only after the curator finishes successfully and writes a success result file (`$KINGPIN_HOME/curator-result`). Pass the curator prompt through a file (`prompt.txt`) and launch script instead of inline in tmux arguments, ensuring that critiques containing single quotes, double quotes, and `$()` reach the curator verbatim without shell parsing errors or command substitution. Maintain `kingpin curate --dry-run` to inspect pending critiques without modifying files. Support pending critique discovery in both `$KINGPIN_HOME/tasks` and `$KINGPIN_HOME/archive` so recovered runs can be curated. Add automated test coverage in `tests/test-automation.sh` verifying dry-run, fake curator failure keeping critiques pending, quote and command substitution preservation verbatim, and successful curation archiving.

## User Story

As a Kingpin orchestrator operator
I want `bin/kingpin-curate` to safely pass arbitrary critique text to the curator and only archive critiques upon verified curator success
So that worker skill critiques are never lost or corrupted by special characters.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | Small |
| Systems Affected | `bin/kingpin-curate`, `tests/test-automation.sh` |
| GitHub Issue | #7 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-curate` | UPDATE | Pass prompt via file and launch script, check for `$KINGPIN_HOME/curator-result` and successful exit before archiving batch critiques, preserve special characters, and scan tasks and archive directories |
| `tests/test-automation.sh` | UPDATE | Add Test 8 verifying `kingpin curate`: dry-run, fake curator failure leaving critiques pending, quote/subshell preservation verbatim, and fake curator success archiving critiques |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Update `bin/kingpin-curate` to pass prompt via file and archive on verified success

- **File**: `bin/kingpin-curate`
- **Action**: UPDATE
- **Implement**:
  - Support `SKILLS_DIR="${KINGPIN_SKILLS_DIR:-$HOME/.claude/skills}"` and `CLAUDE_CMD="${KINGPIN_CURATOR_CMD:-${KINGPIN_CLAUDE:-claude}}"`.
  - Scan for pending critiques across `$KP_HOME/tasks` and `$KP_HOME/archive`, de-duplicating task directories.
  - Maintain dry-run behavior (`--dry-run`) listing pending critiques without modifications.
  - Set up a curator directory `$KP_HOME/curator`.
  - Write the curator prompt safely to `$KP_HOME/curator/prompt.txt` using file streaming (`cat`) rather than shell interpolation, preserving single quotes, double quotes, and `$()` verbatim. Instruct the curator to write its result to `$KP_HOME/curator-result`.
  - Record the batch critique file paths in `$KP_HOME/curator/batch-critiques.txt`.
  - Clear any pre-existing `$KP_HOME/curator-result`.
  - Generate `$KP_HOME/curator/launch.sh` that launches the curator with `"$(cat "$PROMPT_FILE")"`, captures exit code, verifies `$RESULT_FILE` is non-empty upon exit 0, and archives each critique in the batch to `.applied.<timestamp>`. If curator fails or result file is missing, leave critiques pending.
  - Launch tmux window running `$KP_HOME/curator/launch.sh`.
- **Mirror**: `bin/kingpin-spawn:188-192`
- **Validate**: `bash -n bin/kingpin-curate`

### Task 2: Add automated tests for curator robustness in `tests/test-automation.sh`

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**:
  - Add Test 8 for `kingpin curate`:
    - Set up a test tasks directory with multiple pending critiques, including tricky text: single quotes (`'`), double quotes (`"`), and command substitution (`$(echo subshell)`).
    - Test `kingpin curate --dry-run`: verify exit 0, output lists pending critiques, and critique files remain unchanged.
    - Test failing fake curator: configure fake curator that fails (or writes no result), run `kingpin curate`, wait for window exit, verify critique files remain pending.
    - Test quote preservation: verify that the fake curator received quotes and `$()` verbatim.
    - Test succeeding fake curator: configure fake curator that writes `$KINGPIN_HOME/curator-result` and exits 0, run `kingpin curate`, wait for window exit, verify critique files are archived to `critique.applied.*`.
- **Mirror**: `tests/test-automation.sh:255-300`
- **Validate**: `./tests/test-automation.sh`

### Task 3: Recover lost critiques from `~/.kingpin/archive/sandbox-slug`

- **File**: `~/.kingpin/archive/sandbox-slug/critique`
- **Action**: CREATE / RESTORE
- **Implement**:
  - Copy `~/.kingpin/archive/sandbox-slug/critique.applied.1793637765` to `~/.kingpin/archive/sandbox-slug/critique`.
- **Validate**: `test -f ~/.kingpin/archive/sandbox-slug/critique`

---

## Validation

```bash
# Syntax check
bash -n bin/kingpin-curate

# Full automated test suite
./tests/test-automation.sh

# Reproduction: verify dry-run shows pending critiques without crashing on quotes
./bin/kingpin curate --dry-run
```

## End-to-End Verification

1. Run `./tests/test-automation.sh` and ensure all test suites pass, including the new Test 8 covering curator lifecycle.
2. Run `./bin/kingpin curate --dry-run` on real fleet tasks and verify it lists pending critiques safely without modifying any files.

## Risks

| Risk | Mitigation |
|------|------------|
| Tmux session kingpin not active when curate is invoked | Auto-create session if missing (`tmux has-session -t kingpin 2>/dev/null || tmux new-session -d -s kingpin -n home`) matching existing behavior |
| Curator process fails after partially editing skills | Critiques remain pending so operator can review skills or re-run curator |

## Acceptance Criteria

- [ ] Critiques are archived only after the curator writes a success result (for example a `curator-result` file listing each applied edit) (verify: test with a fake curator that fails leaves every critique pending)
- [ ] A critique containing single quotes, double quotes, and `$()` reaches the curator verbatim (verify: test)
- [ ] The curator prompt is passed through a file, not inline on the command line
- [ ] `kingpin curate --dry-run` lists pending critiques without changing them (verify: existing behavior kept)
