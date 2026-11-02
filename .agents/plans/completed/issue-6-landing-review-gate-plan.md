# Plan: Landing Review Gate Verdict Parsing, Fix Findings Flow, and Re-Review Loop

## Summary

This plan fixes the Kingpin landing review gate in `bin/kingpin-land`, `bin/kingpin-watch`, and `bin/kingpin-board` so that review verdicts containing spaces (`APPROVE WITH NITS`, `NEEDS CHANGES`) are parsed in full up to ` report=` rather than truncated at the first space. It ensures that tasks with findings have their relative report paths resolved against their leased worktree and are sent `/fix-findings <report>` before joining the landing queue. When a worker completes a fix pass and reports `fixed: high=<n> report=<path>`, Kingpin checks the high finding count: if High or Critical findings were fixed (`high > 0`), it sends `/review` for a re-review pass before landing; if the fix pass was clean (`high == 0`), it automatically advances to the project landing lock and `/issue-flow-done` without requiring a manual second `kingpin land` in either review or auto mode. In `bin/kingpin-watch`, `landing_sent` is decoupled from initial ready detection and set only upon merge dispatch, and worker preamble and AGENTS orchestrator rules are updated to document the new `fixed:` lifecycle.

## User Story

As the Kingpin orchestrator (and fleet supervisor)
I want `kingpin-land` to read the complete review verdict, dispatch `/fix-findings` with worktree-resolved report paths, trigger re-review on High/Critical fixes, and automatically advance to `/issue-flow-done`
So that tasks with review findings are cleanly resolved and verified without landing premature changes or requiring manual second-step landing interventions.

## Metadata

| Field | Value |
|---|---|
| Type | BUG_FIX |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-land`, `bin/kingpin-watch`, `bin/kingpin-board`, `worker/preamble.md`, `AGENTS.md`, `tests/test-automation.sh` |
| GitHub Issue | #6 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Patterns to Follow

### Naming

Standard Kingpin script root and environment variable resolution:

```bash
// SOURCE: bin/kingpin-land:8-10
KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}
KP_BIN=$(cd "$(dirname "$0")" && pwd)
```

Task environment property loading:

```bash
// SOURCE: bin/kingpin-land:20-22
project=$(sed -n 's/^PROJECT=//p' "$env_file" 2>/dev/null || true)
issue=$(sed -n 's/^ISSUE=//p' "$env_file" 2>/dev/null || true)
[ -n "$project" ] || project="default"
```

### Error Handling

Validation of task directory and task environment:

```bash
// SOURCE: bin/kingpin-land:14-18
task_dir="$KP_HOME/tasks/$id"
[ -d "$task_dir" ] || { echo "kingpin-land: task $id not found: $task_dir" >&2; exit 1; }

env_file="$task_dir/task.env"
[ -f "$env_file" ] || { echo "kingpin-land: task.env missing in $task_dir" >&2; exit 1; }
```

Lock acquisition and queue serialization:

```bash
// SOURCE: bin/kingpin-land:54-64
if [ -f "$project_landing_lock" ]; then
  holder=$(cat "$project_landing_lock" 2>/dev/null || true)
  if [ "$holder" != "$id" ] && [ -d "$KP_HOME/tasks/$holder" ]; then
    echo "kingpin-land: project $project is already landing $holder; queuing $id"
    grep -qx "$id" "$queue_file" 2>/dev/null || echo "$id" >> "$queue_file"
    exit 0
  fi
fi

# Acquire landing lock for this project
echo "$id" > "$project_landing_lock"
```

### Tests

Assertion pattern with isolated test directories:

```bash
// SOURCE: tests/test-automation.sh:17-19
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0
```

Mock status updates and command overrides:

```bash
// SOURCE: tests/test-automation.sh:72-86
echo "ready: branch=kingpin/task-auto-1 review=APPROVE report=none" >> "$KINGPIN_HOME/tasks/task-auto-1/status"
```

---

## Files to Change

| File | Action | Purpose |
|---|---|---|
| `bin/kingpin-land` | UPDATE | Parse review verdicts up to ` report=`, resolve relative report paths against worktree, manage `landing_in_progress` and `landing_sent` markers, and handle `fixed:` status lines with re-review or lock advancement |
| `bin/kingpin-watch` | UPDATE | Avoid premature `landing_sent` creation on `ready:`, handle `fixed:` status events by delegating to `kingpin-land`, and auto-continue `ready:` events in review mode when `landing_in_progress` is set |
| `bin/kingpin-board` | UPDATE | Map `fixed:` status lines to board state `"fixing"` with description |
| `worker/preamble.md` | UPDATE | Document `fixed: high=<n> report=<review report path>` in worker status reporting events |
| `AGENTS.md` | UPDATE | Document handling of `fixed:` status events and automatic landing continuation in the orchestrator supervision protocol |
| `tests/test-automation.sh` | UPDATE | Add Test 7 verifying verdict parsing, report path resolution, fix-findings dispatch, high-finding re-review, and auto-continuation in both review and auto modes |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Update `bin/kingpin-land` verdict parsing, worktree report path resolution, and state markers

- **File**: `bin/kingpin-land`
- **Action**: UPDATE
- **Implement**:
  - Extract the review verdict and report using regex matching that captures the entire verdict up to ` report=`:
    ```bash
    verdict=""
    report=""
    if [[ $last_status =~ review=(.*)[[:space:]]+report=([^[:space:]]*) ]]; then
      verdict="${BASH_REMATCH[1]}"
      report="${BASH_REMATCH[2]}"
    elif [[ $last_status =~ review=([^ ]+( [^ ]+)*) ]]; then
      verdict="${BASH_REMATCH[1]}"
    fi
    if [ -z "$report" ] && [[ $last_status =~ report=([^[:space:]]+) ]]; then
      report="${BASH_REMATCH[1]}"
    fi
    verdict=$(echo "$verdict" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    report=$(echo "$report" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    ```
  - Read `worktree=$(sed -n 's/^WORKTREE=//p' "$env_file" 2>/dev/null || true)` from `$env_file`.
  - When `report` is non-empty and not `none`, resolve it relative to `$worktree` if it does not begin with `/`:
    ```bash
    resolved_report=""
    if [ -n "$report" ] && [ "$report" != "none" ]; then
      if [[ "$report" != /* ]] && [ -n "$worktree" ]; then
        resolved_report="$worktree/$report"
      else
        resolved_report="$report"
      fi
    fi
    ```
  - On `APPROVE WITH NITS`, `NEEDS CHANGES`, `NEEDS_CHANGES`, or `NEEDS-CHANGES`:
    - Touch `$task_dir/landing_in_progress` to remember that landing has been authorized/initiated.
    - If `$resolved_report` is non-empty, send `/fix-findings $resolved_report`, otherwise `/fix-findings`.
    - Exit 0 without acquiring the project landing lock.
  - When landing actually proceeds (verdict is `APPROVE` or `fixed:` with clean findings):
    - After acquiring the project landing lock, touch `$task_dir/landing_sent`.
- **Mirror**: `bin/kingpin-land:27-46`
- **Validate**: `./tests/test-automation.sh`

### Task 2: Implement `fixed:` status handling and re-review dispatch in `bin/kingpin-land`

- **File**: `bin/kingpin-land`
- **Action**: UPDATE
- **Implement**:
  - Add handling when `last_status` starts with `fixed:`:
    ```bash
    if [[ $last_status =~ ^fixed: ]]; then
      high=0
      if [[ $last_status =~ high=([0-9]+) ]]; then
        high="${BASH_REMATCH[1]}"
      fi
      if [ "$high" -gt 0 ]; then
        echo "kingpin-land: task $id fixed $high High/Critical finding(s); requesting re-review"
        if [ -n "$issue" ]; then
          "$KP_BIN/kingpin-send" "$id" "/review --issue $issue"
        else
          "$KP_BIN/kingpin-send" "$id" "/review"
        fi
        exit 0
      fi
      echo "kingpin-land: task $id fix pass completed cleanly; proceeding to landing"
    fi
    ```
  - Ensure that when `high == 0`, execution falls through to acquire the project landing lock, set `$task_dir/landing_sent`, and dispatch `/issue-flow-done $issue` (or `/create-pr-merge`).
- **Mirror**: `bin/kingpin-land:48-79`
- **Validate**: `./tests/test-automation.sh`

### Task 3: Update `bin/kingpin-watch` auto-landing supervision and fix-pass continuation

- **File**: `bin/kingpin-watch`
- **Action**: UPDATE
- **Implement**:
  - In `process_task_event`, update the `ready:*)` case:
    - In `auto` mode: invoke `"$KP_BIN/kingpin-land" "$id"` when `[ ! -f "$task_dir/landing_sent" ]` without pre-touching `landing_sent` (allowing `kingpin-land` to create `landing_sent` upon actual lock acquisition and merge dispatch).
    - In `review` mode: if `[ -f "$task_dir/landing_in_progress" ]` and `[ ! -f "$task_dir/landing_sent" ]`, auto-continue landing by running `"$KP_BIN/kingpin-land" "$id"`; otherwise log that the task is ready for review.
  - Add `fixed:*)` case:
    - If `[ "$mode" = "auto" ]` or `[ -f "$task_dir/landing_in_progress" ]`, log continuation and invoke `"$KP_BIN/kingpin-land" "$id"`.
- **Mirror**: `bin/kingpin-watch:50-74`
- **Validate**: `./tests/test-automation.sh`

### Task 4: Map `fixed:` status lines to `"fixing"` state in `bin/kingpin-board`

- **File**: `bin/kingpin-board`
- **Action**: UPDATE
- **Implement**:
  - In `derive_task_state`, add a check for `last_line.startswith("fixed:")`:
    ```python
    if last_line.startswith("fixed:"):
        return "fixing", f"Fix pass: {last_line[len('fixed:'):].strip()}"
    ```
- **Mirror**: `bin/kingpin-board:60-70`
- **Validate**: `./tests/test-acceptance.sh`

### Task 5: Document `fixed:` event in `worker/preamble.md` and orchestrator contract in `AGENTS.md`

- **File**: `worker/preamble.md`
- **Action**: UPDATE
- **Implement**:
  - Add to the status event list in `worker/preamble.md`:
    `- fixed: high=<n> report=<review report path> when /fix-findings finished.`
- **Mirror**: `worker/preamble.md:7-14`
- **Validate**: `grep -q "fixed: high=" worker/preamble.md`

### Task 6: Document event handling in `AGENTS.md`

- **File**: `AGENTS.md`
- **Action**: UPDATE
- **Implement**:
  - Update the orchestrator supervision section in `AGENTS.md` to document:
    - On `ready:` in review mode: if `landing_in_progress` is set, run `bin/kingpin land <task-id>` to continue landing; otherwise provide the review dossier link and wait for approval.
    - On `fixed:`: run `bin/kingpin land <task-id>` to continue landing.
- **Mirror**: `AGENTS.md:44-50`
- **Validate**: `grep -q "landing_in_progress" AGENTS.md`

### Task 7: Add Test 7 in `tests/test-automation.sh` for landing review gate and re-review lifecycle

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**:
  - Add `=== Test 7: Landing review gate verdict parsing, fix-findings, and re-review ===`:
    1. Unit tests verifying regex parsing of `APPROVE`, `APPROVE WITH NITS`, and `NEEDS CHANGES` up to ` report=`.
    2. Verification that `APPROVE WITH NITS` and `NEEDS CHANGES` resolve relative report paths against `$worktree` and dispatch `/fix-findings <resolved_path>` via `kingpin-send`.
    3. Verification that when worker reports `fixed: high=1 report=...`, `kingpin-land` sends `/review` (or `/review --issue <n>`).
    4. Verification that when worker reports `fixed: high=0 report=...`, `kingpin-watch` and `kingpin-land` advance to the project queue and send `/issue-flow-done` without a manual second `kingpin land`, in both review mode (with `landing_in_progress`) and auto mode.
    5. Verification that `APPROVE` with no findings goes straight to the landing queue as before.
- **Mirror**: `tests/test-automation.sh:60-105`
- **Validate**: `./tests/test-automation.sh`

---

## Validation

```bash
# Type check / Build (shell/python - no compiler required)
bash -n bin/kingpin-land bin/kingpin-watch bin/kingpin-wait bin/kingpin-send bin/kingpin-ack bin/kingpin-done
python3 -m py_compile bin/kingpin-board

# Automation test suite (including Test 7)
./tests/test-automation.sh

# Acceptance test suite (multi-worker parallel concurrency and landing queue)
./tests/test-acceptance.sh

# Multi-harness isolation test suite
./tests/test-harnesses.sh

# Reproduction command (BUG_FIX): red on unfixed code, green after fix
bash -c '
tmp_kp=$(mktemp -d)
mkdir -p "$tmp_kp/tasks/repro-1"
cat > "$tmp_kp/tasks/repro-1/task.env" << "EOF"
TASK_ID=repro-1
PROJECT=demo
MODE=review
WORKTREE=/tmp
EOF
echo "ready: branch=feat review=APPROVE WITH NITS report=.agents/reviews/r1.md" > "$tmp_kp/tasks/repro-1/status"
output=$(KINGPIN_HOME="$tmp_kp" ./bin/kingpin-land repro-1 2>&1 || true)
rm -rf "$tmp_kp"
echo "$output" | grep -q "verdict is APPROVE WITH NITS; sending /fix-findings" || {
  echo "BUG REPRODUCED: kingpin-land did not send /fix-findings for APPROVE WITH NITS. Output was: $output"
  exit 1
}
'
```

## End-to-End Verification

1. Start with clean git working tree and verified test baseline: `./tests/test-automation.sh` passing.
2. Run reproduction command on current codebase: exits 1 demonstrating that `APPROVE WITH NITS` fails to trigger `/fix-findings`.
3. Apply changes across `bin/kingpin-land`, `bin/kingpin-watch`, `bin/kingpin-board`, `worker/preamble.md`, `AGENTS.md`, and `tests/test-automation.sh`.
4. Re-run reproduction command: exits 0 demonstrating that `APPROVE WITH NITS` properly extracts the full verdict, resolves the report against the worktree, sets `landing_in_progress`, and sends `/fix-findings`.
5. Execute `./tests/test-automation.sh`: all 7 test groups pass, including new Test 7 covering all 5 issue acceptance criteria.
6. Execute `./tests/test-acceptance.sh`: all parallel worker concurrency and serial landing queue tests pass.
7. Execute `./tests/test-harnesses.sh`: multi-harness contract tests pass.

## Risks

| Risk | Mitigation | Scope |
|---|---|---|
| Compatibility with legacy status lines using `NEEDS_CHANGES` or single-token verdicts | Handle both new multiline/spaced verdicts (`APPROVE WITH NITS`, `NEEDS CHANGES`) and legacy underscores (`NEEDS_CHANGES`, `NEEDS-CHANGES`) in `bin/kingpin-land` case matching | IN-SCOPE |
| Concurrent tasks reporting `fixed:` while another task occupies the project landing lock | Rely on `project.landing_queue` serialization in `bin/kingpin-land`; if lock is held, task ID is queued in `$queue_file` and picked up by `kingpin-done` | IN-SCOPE |
| Missing or non-numeric `high=` count in `fixed:` status line | Default `high=0` when `high=([0-9]+)` match is absent, preventing unhandled regex failures | IN-SCOPE |
| Re-review loop encountering repeated High/Critical findings | Re-review limits and escalation to human intervention are governed by `/do` and `/review` contracts (3 rounds max) rather than indefinite looping in `kingpin-land` | OUT-OF-SCOPE |

## Open Questions

- **Re-review invocation format**: When `high > 0`, what exact command should be sent to the worker window?
  - *Proposed Default*: Send `"/review --issue $issue"` if `ISSUE` is defined in `task.env`, otherwise send `"/review"`. This adheres to `/review` skill syntax and ensures the worker re-reviews against the original issue context.
- **Marker lifecycle**: When should `landing_in_progress` be removed?
  - *Proposed Default*: `landing_in_progress` is retained while the task is landing (including through fix-findings and re-review) so that subsequent `ready:` or `fixed:` events continue automatically. When the task merges, `kingpin-done` cleans up the entire task directory (`~/.kingpin/tasks/<id>`), cleanly clearing all marker files.

## Acceptance Criteria

- [ ] The verdict is parsed as the whole value up to ` report=` (`APPROVE`, `APPROVE WITH NITS`, `NEEDS CHANGES`) (verify: unit test with each value)
- [ ] `APPROVE WITH NITS` and `NEEDS CHANGES` send `/fix-findings <report path>` first, with a relative report path resolved against the task's worktree (verify: test)
- [ ] When the fix pass fixed a High or Critical finding, the worker re-reviews before landing (verify: test with a fake worker that reports a fixed High finding)
- [ ] After a successful fix pass, landing continues to the project queue and `/issue-flow-done` without a manual second `kingpin land`, in both review and auto mode (verify: test)
- [ ] `APPROVE` with no findings goes straight to the landing queue as today (verify: existing tests pass)
- [ ] Type check and lint validation commands pass without syntax errors
- [ ] Full automated test suite `./tests/test-automation.sh`, `./tests/test-acceptance.sh`, and `./tests/test-harnesses.sh` passes cleanly
