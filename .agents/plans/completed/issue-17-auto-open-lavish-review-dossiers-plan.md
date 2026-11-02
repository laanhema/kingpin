# Plan: Automatically Open Lavish Review Dossiers and Maintain Background Live Listeners

## Summary

This plan resolves GitHub issue #17 by automating the visual review workflow for Kingpin tasks that enter `ready:` in `review` mode. Currently, `bin/kingpin-watch` only prints a terminal reminder (`lavish-axi ~/.kingpin/tasks/<task-id>/report.html`), requiring the user to run it manually. Furthermore, because no listener runs `lavish-axi poll`, the Lavish Editor UI shows "Agent is not listening" and action buttons (`Approve & Land`, `Request Changes`) fail to reach the orchestrator. We introduce a dedicated listener utility `bin/kingpin-listen` (and `kingpin listen` CLI subcommand) that opens the review dossier in the browser (if not already opened) and maintains an active background `lavish-axi poll` process with PID tracking in `$task_dir/listener.pid`. When user prompts arrive from the Lavish Editor UI, the listener parses them: `Approve & Land` (matching `kingpin land`) logs `approved:` to `$task_dir/status`, sends a confirmation receipt via `lavish-axi reply`, and triggers `kingpin-land <task-id>`; user feedback or `Request Changes` writes the full feedback to `$task_dir/feedback.md`, logs `feedback: <summary>` to `$task_dir/status` to wake `kingpin-wait`, and replies to Lavish. `bin/kingpin-watch` automatically arms this listener upon detecting `ready:` in review mode, `bin/kingpin-done` ensures clean termination of the listener process and session on task completion, `bin/kingpin list` displays listener activity status, and comprehensive test coverage is added to `tests/test-automation.sh`.

## User Story

As the Kingpin orchestrator (and fleet supervisor)
I want review dossiers to open in the browser automatically and maintain an active background Lavish listener when workers report `ready:`
So that reviewers see connected/listening status in the Lavish Editor UI and can trigger `Approve & Land` or submit feedback directly into the orchestrator without manual CLI commands.

## Metadata

| Field | Value |
|---|---|
| Type | ENHANCEMENT |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-listen` (new), `bin/kingpin-watch`, `bin/kingpin-done`, `bin/kingpin`, `worker/preamble.md`, `AGENTS.md`, `tests/test-automation.sh` |
| GitHub Issue | #17 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Patterns to Follow

### Naming

Standard Kingpin script root and environment variable resolution:

```bash
// SOURCE: bin/kingpin-watch:13-16
KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}
KP_BIN="$KP_ROOT/bin"
```

Command override pattern with graceful defaults:

```bash
// SOURCE: bin/kingpin-spawn:22-24
CLAUDE_CMD=${KINGPIN_CLAUDE:-claude}
AGY_CMD=${KINGPIN_AGY:-agy}
OPENCODE_CMD=${KINGPIN_OPENCODE:-opencode}
```

### Error Handling

Task directory validation and missing dependency tolerance:

```bash
// SOURCE: bin/kingpin-land:14-18
task_dir="$KP_HOME/tasks/$id"
[ -d "$task_dir" ] || { echo "kingpin-land: task $id not found: $task_dir" >&2; exit 1; }

env_file="$task_dir/task.env"
[ -f "$env_file" ] || { echo "kingpin-land: task.env missing in $task_dir" >&2; exit 1; }
```

Process liveness checking and graceful process cleanup:

```bash
// SOURCE: bin/kingpin-done:50-52
tmux_target=${TMUX_TARGET:-kingpin:$id}
tmux kill-window -t "$tmux_target" 2>/dev/null || true
"$KP_BIN/kingpin-ack" "$id" >/dev/null 2>&1 || true
```

### Tests

Isolated assertion style and mock status transitions:

```bash
// SOURCE: tests/test-automation.sh:17-19
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0
```

```bash
// SOURCE: tests/test-automation.sh:71-73
# Mock ready status
echo "ready: branch=kingpin/task-auto-1 review=APPROVE report=none" >> "$KINGPIN_HOME/tasks/task-auto-1/status"
```

---

## Files to Change

| File | Action | Purpose |
|---|---|---|
| `bin/kingpin-listen` | CREATE | Implements background polling for review dossiers, opens browser, parses feedback, routes `Approve & Land` to `kingpin-land`, routes feedback to `status` and `feedback.md`, and replies via Lavish |
| `bin/kingpin-watch` | UPDATE | Auto-launches `bin/kingpin-listen "$id" --background` on `ready:` in review mode; handles `approved:*` and `feedback:*` status events |
| `bin/kingpin-done` | UPDATE | Terminates background listener process, removes `listener.pid`, and ends Lavish session on cleanup |
| `bin/kingpin` | UPDATE | Adds `listen` subcommand to CLI router; updates `kingpin list` to show active listener status |
| `worker/preamble.md` | UPDATE | Clarifies `Request Changes` button behavior in review dossiers (`window.lavish?.queuePrompt?.('Request Changes: ...')`) |
| `AGENTS.md` | UPDATE | Documents automated dossier launching, background listener lifecycle, and `approved:` / `feedback:` status line handling |
| `tests/test-automation.sh` | UPDATE | Adds automated end-to-end verification covering dossier launch, background poller arming, approval routing, feedback routing, and cleanup |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Create `bin/kingpin-listen`

- **File**: `bin/kingpin-listen`
- **Action**: CREATE
- **Implement**: Create executable script `bin/kingpin-listen <task-id> [--once] [--background]`
  1. Resolve `KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}` and `KP_BIN=$(cd "$(dirname "$0")" && pwd)`.
  2. Validate `$task_dir="$KP_HOME/tasks/$id"` and check that `$task_dir/report.html` exists.
  3. Resolve `LAVISH_CMD=${KINGPIN_LAVISH:-lavish-axi}`. If `command -v "$LAVISH_CMD"` is not found, log a notice and exit 0 (graceful fallback).
  4. If `--background` is passed:
     - Check if `$task_dir/listener.pid` already exists with a running process (`kill -0 "$pid" 2>/dev/null`). If so, exit 0.
     - Otherwise, launch `"$KP_BIN/kingpin-listen" "$id" > "$task_dir/listener.log" 2>&1 &` and write `$!` to `$task_dir/listener.pid`.
     - Exit 0.
  5. In the foreground listener process:
     - Record current PID `$$` into `$task_dir/listener.pid`.
     - Register `trap 'rm -f "$task_dir/listener.pid"' EXIT INT TERM`.
     - Open review dossier in browser if not already opened:
       ```bash
       if [ ! -f "$task_dir/lavish_opened" ]; then
         "$LAVISH_CMD" "$task_dir/report.html" >/dev/null 2>&1 || true
         touch "$task_dir/lavish_opened"
       fi
       ```
     - Enter poll loop:
       - Run `poll_out=$("$LAVISH_CMD" poll "$task_dir/report.html" --owner "kingpin:$id" 2>/dev/null || true)`.
       - If session ended or browser permanently disconnected (`status: ended` or `session_ended`), exit loop.
       - If feedback received:
         - Extract prompts text.
         - If prompt contains `kingpin land` or matches `approve`:
           - Append `approved: by user via lavish dossier` to `$task_dir/status`.
           - Post reply: `"$LAVISH_CMD" reply "$task_dir/report.html" --agent-reply "Approval received. Landing initiated for task $id." >/dev/null 2>&1 || true`.
           - Trigger landing: `"$KP_BIN/kingpin-land" "$id" >/dev/null 2>&1 || true`.
           - Exit or continue based on `--once`.
         - Else (user feedback or `Request Changes`):
           - Write prompt to `$task_dir/feedback.md`.
           - Append `feedback: <first-line-summary>` to `$task_dir/status`.
           - Post reply: `"$LAVISH_CMD" reply "$task_dir/report.html" --agent-reply "Feedback received. Forwarded to orchestrator." >/dev/null 2>&1 || true`.
           - If `--once` passed, exit 0; otherwise continue loop to keep listening.
- **Mirror**: `bin/kingpin-land:8-25`
- **Validate**: `chmod +x bin/kingpin-listen && [ -x bin/kingpin-listen ]`

### Task 2: Update `bin/kingpin-watch` to Auto-Open and Arm Listener

- **File**: `bin/kingpin-watch`
- **Action**: UPDATE
- **Implement**:
  1. In `process_task_event`, locate `ready:*)` under `elif [ "$mode" = "review" ]; then`.
  2. If `landing_in_progress` is not set:
     - Print the review notice: `echo "[kingpin-watch] $id is ready for review (lavish-axi $task_dir/report.html)"`.
     - If `[ -f "$task_dir/report.html" ]`, invoke `"$KP_BIN/kingpin-listen" "$id" --background || true`.
  3. Add case arms to `process_task_event`:
     - `approved:*)`:
       ```bash
       echo "[kingpin-watch] $id was approved via review dossier; initiating landing..."
       "$KP_BIN/kingpin-land" "$id" || true
       ```
     - `feedback:*|changes-requested:*)`:
       ```bash
       echo "[kingpin-watch] $id received review feedback: $last_status"
       ```
- **Mirror**: `bin/kingpin-watch:50-65`
- **Validate**: `grep -q "kingpin-listen" bin/kingpin-watch && grep -q "approved:" bin/kingpin-watch`

### Task 3: Update `bin/kingpin-done` for Listener Cleanup

- **File**: `bin/kingpin-done`
- **Action**: UPDATE
- **Implement**:
  1. In cleanup section of `bin/kingpin-done`, check for `$task_dir/listener.pid`.
  2. If present:
     - Read PID, check if running (`kill -0 "$lpid" 2>/dev/null`), and kill it (`kill "$lpid" 2>/dev/null || true`).
     - Remove `$task_dir/listener.pid`.
  3. End the lavish session:
     ```bash
     LAVISH_CMD=${KINGPIN_LAVISH:-lavish-axi}
     if command -v "$LAVISH_CMD" >/dev/null 2>&1 && [ -f "$task_dir/report.html" ]; then
       "$LAVISH_CMD" end "$task_dir/report.html" >/dev/null 2>&1 || true
     fi
     ```
- **Mirror**: `bin/kingpin-done:49-53`
- **Validate**: `grep -q "listener.pid" bin/kingpin-done`

### Task 4: Update `bin/kingpin` Router and List View

- **File**: `bin/kingpin`
- **Action**: UPDATE
- **Implement**:
  1. Add `listen` subcommand to the `kingpin` router:
     ```bash
     listen)
       exec "$KP_BIN/kingpin-listen" "$@"
       ;;
     ```
  2. In `kingpin list`, after printing `↳ Review: lavish-axi $d/report.html`:
     - Check if `$d/listener.pid` exists and process is alive.
     - If running, display ` (listening: pid <pid>)`.
  3. Update usage output to include `listen` command.
- **Mirror**: `bin/kingpin:72-87`
- **Validate**: `grep -q "kingpin-listen" bin/kingpin && grep -q "listener" bin/kingpin`

### Task 5: Update `worker/preamble.md` and `AGENTS.md` Documentation

- **File**: `worker/preamble.md`, `AGENTS.md`
- **Action**: UPDATE
- **Implement**:
  1. In `worker/preamble.md` line 25: clarify that the action bar includes 'Approve & Land' CTA (`kingpin land {{TASK_ID}}`) and 'Request Changes' button (triggering `window.lavish?.queuePrompt?.('Request Changes: ...')`).
  2. In `AGENTS.md`: update rule 4 and "How to Handle Requests" to document that when tasks report `ready:` in review mode, Kingpin automatically launches `lavish-axi <report.html>` and maintains a background `lavish-axi poll` listener. Document that `approved:` status events automatically advance to `kingpin land`, and `feedback:` status events alert the orchestrator.
- **Mirror**: `worker/preamble.md:25`, `AGENTS.md:50-55`
- **Validate**: `grep -q "approved:" AGENTS.md && grep -q "Request Changes" worker/preamble.md`

### Task 6: Add Verification Tests in `tests/test-automation.sh`

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: Add `Test 10: Lavish review dossier auto-opening, live listener, and prompt routing`:
  1. Create a mock `lavish-axi` binary that logs invocations and simulates `poll` / `reply` / `end`.
  2. Configure `export KINGPIN_LAVISH=$T/mock-lavish`.
  3. Set up a task in review mode with a mock `report.html`.
  4. Emit `ready:` status.
  5. Run `kingpin-watch --once`:
     - Assert `mock-lavish <report.html>` was invoked (dossier opened).
     - Assert `listener.pid` was created and process is running.
  6. Simulate `Approve & Land` feedback:
     - Assert `approved:` status was appended.
     - Assert `kingpin-land` was triggered.
     - Assert confirmation reply was sent to Lavish.
  7. Simulate user feedback:
     - Assert `feedback.md` was created with the feedback text.
     - Assert `feedback:` status was appended.
  8. Run `kingpin-done`:
     - Assert listener process was killed.
     - Assert `listener.pid` was removed.
     - Assert `mock-lavish end` was invoked.
- **Mirror**: `tests/test-automation.sh:58-86`
- **Validate**: `./tests/test-automation.sh`

---

## Validation

```bash
# Type check / Build (bash scripts & project syntax)
bash -n bin/kingpin bin/kingpin-listen bin/kingpin-watch bin/kingpin-done bin/kingpin-land

# Full automation test suite
./tests/test-automation.sh

# Multi-harness contract test
./tests/test-harnesses.sh
```

## End-to-End Verification

1. Run syntax check across all modified shell scripts:
   `bash -n bin/kingpin bin/kingpin-listen bin/kingpin-watch bin/kingpin-done`
2. Run full test suite `./tests/test-automation.sh` to ensure all existing automation tests (Tests 1–9) and new Lavish listener tests (Test 10) pass cleanly.
3. Test manual CLI invocations:
   - Run `bin/kingpin listen --help` to confirm usage display.
   - Run `bin/kingpin list` to confirm clean formatting without errors.

## Risks

| Risk | Mitigation | In/Out of Scope |
|---|---|---|
| `lavish-axi` is not installed on some host environments | `bin/kingpin-listen` checks `command -v "$LAVISH_CMD"` and exits 0 gracefully with a clear notice if absent; `kingpin-watch` proceeds without crashing | In Scope |
| Multiple `kingpin-watch` cycles could spawn redundant listeners | PID file `$task_dir/listener.pid` with `kill -0` liveness check ensures strictly one background listener per task | In Scope |
| Repeated browser tab launches on every watch interval | `$task_dir/lavish_opened` sentinel flag guarantees the browser dossier is opened exactly once per review cycle | In Scope |
| Lingering background listener processes after task merge or teardown | `bin/kingpin-done` explicitly reads `listener.pid`, kills the process, and calls `lavish-axi end` | In Scope |
| Accidental execution in headless CI environments opening GUI browsers | Mock `KINGPIN_LAVISH` override is used in tests and respects `--no-open` or mock execution | In Scope |

## Open Questions

- **Relaying feedback directly to worker vs orchestrator only**: When user feedback / `Request Changes` is received via Lavish, should `kingpin-listen` immediately forward the text into the worker's tmux window via `kingpin send <task-id> "<feedback>"`, or only route it to the orchestrator via `$task_dir/status` and `$task_dir/feedback.md`?
  - *Proposed Default*: Route to orchestrator first via `$task_dir/status` (and `$task_dir/feedback.md`) so `kingpin-wait` wakes the orchestrator. In `mode=auto` or when orchestrator handles the event, it dispatches to the worker via `kingpin-send`. This preserves the orchestrator contract where workers never accept unsupervised instructions directly.

## Acceptance Criteria

- [ ] When a task enters `ready:` in review mode, `kingpin-watch` launches `lavish-axi <report.html>` to open the browser automatically.
- [ ] A background `lavish-axi poll <report.html>` process is armed so the Lavish web UI displays connected/listening.
- [ ] Button clicks (`Approve & Land`, `Request Changes`) and user feedback typed in Lavish route directly to the orchestrator.
- [ ] Listener lifecycle is tracked via `$task_dir/listener.pid` and cleaned up on `kingpin-done`.
- [ ] All unit and automation tests in `./tests/test-automation.sh` pass.
