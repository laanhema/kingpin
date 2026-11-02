# Plan: Prevent workers from adopting orchestrator role when working on kingpin repo

## Summary

When background workers are spawned on the `kingpin` repository itself, harness agents (`agy`, `claude`, `opencode`) discover and load `AGENTS.md` in the workspace root as ambient rules or system instructions. Because `AGENTS.md` defines the orchestrator/underboss persona and hard rule 1 ("Never edit, write, or touch project code directly"), workers mistake themselves for the orchestrator, refuse to make code changes, and attempt to run orchestration commands. We will add an explicit scope guard at the top of `AGENTS.md` stating it applies exclusively to the root orchestrator and must be ignored by background workers in leased worktrees, update `worker/preamble.md` to explicitly instruct workers that they are background code workers who must ignore root `AGENTS.md`, ensure `bin/kingpin-spawn` substitutes `{{WORKTREE}}`, and add verification in `tests/test-harnesses.sh` to ensure all harnesses (`claude`, `agy`, `opencode`) deliver these instructions cleanly.

## User Story

As a developer using Kingpin on its own codebase
I want background workers spawned on the kingpin repo to know they are code workers and ignore root orchestrator rules
So that workers implement tasks directly without role confusion or refusing to edit code

## Metadata

| Field | Value |
|---|---|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `AGENTS.md`, `worker/preamble.md`, `bin/kingpin-spawn`, `tests/test-harnesses.sh` |
| GitHub Issue | #20 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Patterns to Follow

### Preamble Template Variables
```bash
// SOURCE: bin/kingpin-spawn:166-167
sed -e "s|{{TASK_ID}}|$id|g" -e "s|{{TASK_DIR}}|$task_dir|g" -e "s|{{MODE}}|$mode|g" \
  "$KP_ROOT/worker/preamble.md" > "$task_dir/preamble.md"
```

### Harness Rules & Instructions Injection
```bash
// SOURCE: bin/kingpin-spawn:191-228
# claude: --append-system-prompt-file '$task_dir/preamble.md'
# agy: cp "$task_dir/preamble.md" "$worktree/.agents/rules/kingpin.md"
# opencode: config.json instructions: ["$task_dir/preamble.md"]
```

### Harness Verification Test Pattern
```bash
// SOURCE: tests/test-harnesses.sh:58-62
"$KP_BIN/kingpin-spawn" demo --issue 101 --id task-claude --harness claude >/dev/null
[ -f "$KINGPIN_HOME/tasks/task-claude/task.env" ] && pass "task-claude task.env created" || fail "missing task.env"
```

---

## Files to Change

| File | Action | Purpose |
|---|---|---|
| `AGENTS.md` | UPDATE | Add prominent top scope guard restricting file to root orchestrator only and directing workers in leased worktrees to ignore it |
| `worker/preamble.md` | UPDATE | Explicitly instruct worker that it is a background code worker in a leased worktree and must ignore root `AGENTS.md` |
| `bin/kingpin-spawn` | UPDATE | Add `{{WORKTREE}}` substitution to `sed` when compiling `preamble.md` |
| `tests/test-harnesses.sh` | UPDATE | Add test assertions for scope guard and preamble worker instructions across claude, agy, and opencode spawns |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Add Scope Guard to AGENTS.md
- **File**: `AGENTS.md`
- **Action**: UPDATE
- **Implement**: Add a prominent blockquote / alert at the very top of `AGENTS.md` clarifying that the orchestrator contract applies exclusively to the root orchestrator session and does NOT apply to background workers in leased worktrees (`~/.treehouse/...`). Direct background workers to ignore the file and implement tasks directly.
- **Mirror**: `AGENTS.md:1-14`
- **Validate**: `grep -qi "scope guard" AGENTS.md && grep -qi "leased worktree" AGENTS.md`

### Task 2: Update worker/preamble.md Instructions
- **File**: `worker/preamble.md`
- **Action**: UPDATE
- **Implement**: Add explicit instructions stating that the worker is a background code worker in a leased worktree (`{{WORKTREE}}` or `~/.treehouse/...`), NOT the orchestrator, and that any root orchestrator instructions (`AGENTS.md`) in the worktree must be ignored in favor of directly implementing the task. Emphasize that workers must make code changes directly and never adopt the underboss persona or refuse edits.
- **Mirror**: `worker/preamble.md:1-7`
- **Validate**: `grep -qi "background code worker" worker/preamble.md && grep -qi "AGENTS.md" worker/preamble.md`

### Task 3: Substitute WORKTREE in bin/kingpin-spawn
- **File**: `bin/kingpin-spawn`
- **Action**: UPDATE
- **Implement**: Include `-e "s|{{WORKTREE}}|$worktree|g"` in the `sed` command that renders `$KP_ROOT/worker/preamble.md` into `$task_dir/preamble.md`.
- **Mirror**: `bin/kingpin-spawn:166-167`
- **Validate**: `grep -q "{{WORKTREE}}" bin/kingpin-spawn`

### Task 4: Add Worker Role Separation Tests to test-harnesses.sh
- **File**: `tests/test-harnesses.sh`
- **Action**: UPDATE
- **Implement**: Add verification checks ensuring `AGENTS.md` contains the scope guard, `worker/preamble.md` contains the worker role instruction, and spawning tasks with `claude`, `agy`, and `opencode` properly instantiates worktree rules/instructions with the worker role guidance and without role confusion.
- **Mirror**: `tests/test-harnesses.sh:56-149`
- **Validate**: `bash tests/test-harnesses.sh`

### Task 5: Run Full Test Suite
- **File**: `tests/test-acceptance.sh`, `tests/test-automation.sh`, `tests/test-harnesses.sh`
- **Action**: CHECK
- **Implement**: Run all Kingpin test scripts to guarantee no regressions in multi-harness spawning, automation, or acceptance suites.
- **Mirror**: `tests/test-acceptance.sh`
- **Validate**: `bash tests/test-harnesses.sh && bash tests/test-automation.sh && bash tests/test-acceptance.sh`

---

## Validation

```bash
# Type check / Build (N/A for bash / shell repo, syntax check instead)
bash -n bin/kingpin bin/kingpin-spawn bin/kingpin-wait bin/kingpin-done

# Lint
# shellcheck if installed, or bash -n

# Tests
bash tests/test-harnesses.sh
bash tests/test-automation.sh
bash tests/test-acceptance.sh

# Reproduction: red on the unfixed code, green after the fix
! grep -qi "scope guard" AGENTS.md && ! grep -qi "background code worker" worker/preamble.md
```

## End-to-End Verification

1. Verify `AGENTS.md` has the scope guard:
   `grep -qi "scope guard" AGENTS.md`
2. Verify `worker/preamble.md` instructs workers they are background workers and to ignore `AGENTS.md`:
   `grep -qi "background code worker" worker/preamble.md`
3. Run `bin/kingpin-spawn` in a test environment and verify the generated `$task_dir/preamble.md` and `.agents/rules/kingpin.md` (for agy) explicitly instruct the worker not to adopt orchestrator role.
4. Execute `bash tests/test-harnesses.sh`, `bash tests/test-automation.sh`, and `bash tests/test-acceptance.sh` and ensure all tests exit with status code 0.

## Risks

| Risk | Mitigation |
|---|---|
| Orchestrator session itself might misinterpret the scope guard | The scope guard explicitly specifies it applies to orchestrator outside worktrees and only workers inside leased worktrees (`~/.treehouse/...`) should ignore it |
| Harness agents might prioritize root `AGENTS.md` over preamble | Preamble is loaded with higher precedence (system prompt in Claude, `.agents/rules/kingpin.md` in AGY, `instructions` in OpenCode) and explicitly tells the model to override and ignore `AGENTS.md` |

## Acceptance Criteria

- [ ] `AGENTS.md` includes an explicit scope guard at the top stating it applies exclusively to the root orchestrator session and does NOT apply to background workers in leased worktrees (`~/.treehouse/...`).
- [ ] `worker/preamble.md` explicitly instructs workers that they are background code workers in a leased worktree, not the orchestrator, and that any root orchestrator instructions (`AGENTS.md`) in the worktree must be ignored in favor of directly implementing the task.
- [ ] Spawning a worker on the `kingpin` repo with `agy`, `claude`, or `opencode` results in the worker immediately proceeding with implementation without role confusion.
- [ ] All tests in `tests/test-harnesses.sh`, `tests/test-automation.sh`, and `tests/test-acceptance.sh` pass.
