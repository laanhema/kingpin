# Plan: Fix Session Lock Recording and Session Lifecycle in Kingpin

## Summary

Fix `bin/kingpin-lock` so that acquiring the orchestrator session lock records a long-lived session process PID (detecting agent harnesses such as `claude`, `agy`, `opencode` in process ancestry, or the caller's parent process `$PPID` for long-lived scripts/shells, or an explicit PID / `KINGPIN_LOCK_PID`), instead of `$$` (the short-lived script's own PID). When a holder process is active, subsequent `acquire` and `check` invocations fail non-zero naming the holder PID, while `status` correctly reports the lock as held. When the holder process terminates, the lock is recognized as stale and can be reclaimed by another session without manual release. Update `AGENTS.md` to run `bin/kingpin lock acquire` on startup and remain read-only if acquisition fails. Add automated test coverage in `tests/test-automation.sh` verifying the full lock lifecycle with a long-lived parent process, collision rejection, process exit auto-freeing, and re-acquisition.

## User Story

As a Kingpin orchestrator session or developer
I want the orchestrator session lock to hold for the duration of my live session and reject concurrent orchestrators
So that multiple orchestrator sessions cannot accidentally drive the same fleet concurrently.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-lock`, `AGENTS.md`, `tests/test-automation.sh` |
| GitHub Issue | #5 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-lock` | UPDATE | Replace `$$` with session PID resolution (checking explicit PID argument / `KINGPIN_LOCK_PID`, detecting harness ancestry for `claude`/`agy`/`opencode`, or falling back to `$PPID`); guard `check` and `acquire` to reject concurrent live holders and allow re-claim when stale or self-held |
| `AGENTS.md` | UPDATE | Change startup instruction from `bin/kingpin lock check` to `bin/kingpin lock acquire`, staying read-only when acquire fails |
| `tests/test-automation.sh` | UPDATE | Add Test 6 verifying session lock lifecycle: free state, acquisition by long-lived parent, collision rejection on second acquire and check, auto-freeing upon holder process termination, and re-acquisition |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Update `bin/kingpin-lock` to resolve and record session PID

- **File**: `bin/kingpin-lock`
- **Action**: UPDATE
- **Implement**:
  - Add helper function `is_harness_pid` to check if a process is a known agent harness (`claude`, `agy`, `opencode`, `codex`, `pi`, `grok`, `kimi`, or node running harness).
  - Add helper function `resolve_session_pid` to resolve the owning session PID:
    1. If `KINGPIN_LOCK_PID` is set and numeric, use it.
    2. If an optional second argument (e.g. `kingpin-lock acquire <pid>`) is provided and numeric, use it.
    3. Check candidate 1 (`$PPID`): if it is a harness, return it.
    4. Check candidate 2 (parent of `$PPID` via `ps -o ppid= -p "$PPID"`): if it is a harness, return it.
    5. Fall back to `$PPID` (the parent shell/process invoking the command).
  - In `acquire`:
    - Resolve `target_pid=$(resolve_session_pid "$@")`.
    - If `$LOCK_FILE` exists and contains a live PID distinct from `target_pid` (`[ "$pid" != "$target_pid" ] && kill -0 "$pid"`), output error to stderr and exit 1:
      `error: another live kingpin orchestrator session holds the lock (pid $pid)`
    - Write `target_pid` to `$LOCK_FILE` and echo `lock: acquired (pid $target_pid)`.
  - In `check`:
    - Keep as a read-only probe.
    - Resolve `target_pid=$(resolve_session_pid "$@")`.
    - If `$LOCK_FILE` exists and contains a live PID distinct from `target_pid`, output error to stderr and exit 1:
      `error: another live kingpin orchestrator session holds the lock (pid $pid)`
    - Otherwise exit 0 with `lock: verified`.
  - In `status`:
    - Keep reporting `lock: free`, `lock: held by pid $pid`, or `lock: stale`.
- **Mirror**: `bin/kingpin-lock:12-51`
- **Validate**: `bash -n bin/kingpin-lock`

### Task 2: Update `AGENTS.md` startup contract

- **File**: `AGENTS.md`
- **Action**: UPDATE
- **Implement**:
  - Update rule 3 to instruct the orchestrator underboss to acquire the session lock on startup:
    `Acquire the session lock on startup: bin/kingpin lock acquire. If locked by another session (acquire fails), operate read-only.`
- **Mirror**: `AGENTS.md:23-24`
- **Validate**: `git diff AGENTS.md`

### Task 3: Add automated tests for lock lifecycle in `tests/test-automation.sh`

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**:
  - Add `=== Test 6: kingpin lock lifecycle ===`:
    1. Verify initial status: `"$KP_BIN/kingpin" lock status` reports `lock: free`.
    2. Spawn a long-lived parent background process running `"$KP_BIN/kingpin" lock acquire` followed by `sleep 30`. Record `holder_pid=$!`.
    3. Verify `"$KP_BIN/kingpin" lock status` reports `lock: held by pid $holder_pid`.
    4. Verify second `acquire` from a different process fails with exit code 1 and contains `error: another live kingpin orchestrator session holds the lock (pid $holder_pid)`.
    5. Verify `"$KP_BIN/kingpin" lock check` from another process fails with exit code 1 and contains `error: another live kingpin orchestrator session holds the lock (pid $holder_pid)`.
    6. Kill the holder process (`kill -9 "$holder_pid"`).
    7. Verify `"$KP_BIN/kingpin" lock status` reports `lock: stale`.
    8. Verify new `acquire` succeeds over the stale lock.
    9. Verify `"$KP_BIN/kingpin" lock release` removes the lock and status reports `lock: free`.
- **Mirror**: `tests/test-automation.sh:145-169`
- **Validate**: `bash tests/test-automation.sh`

### Task 4: Run full validation suite

- **File**: `tests/test-acceptance.sh`, `tests/test-automation.sh`, `tests/test-harnesses.sh`
- **Action**: CHECK
- **Implement**:
  - Run `bash tests/test-acceptance.sh`
  - Run `bash tests/test-automation.sh`
  - Run `bash tests/test-harnesses.sh`
  - Verify all tests pass cleanly.
- **Mirror**: `tests/test-acceptance.sh:1`
- **Validate**: `bash tests/test-acceptance.sh && bash tests/test-automation.sh && bash tests/test-harnesses.sh`

---

## Validation

```bash
# Syntax check
bash -n bin/kingpin-lock tests/test-automation.sh

# Reproduction command (BUG_FIX): red on unfixed code (prints "lock: stale"), green after fix (prints "lock: held by pid ...")
( "$KP_ROOT/bin/kingpin" lock acquire && "$KP_ROOT/bin/kingpin" lock status )

# Full test suites
bash tests/test-automation.sh
bash tests/test-harnesses.sh
bash tests/test-acceptance.sh
```

## End-to-End Verification

1. In a shell, run:
   ```bash
   ( bin/kingpin lock acquire && bin/kingpin lock status && sleep 1 ) &
   pid=$!
   wait $pid
   ```
   Expected output:
   `lock: acquired (pid ...)`
   `lock: held by pid ...`
2. Run `bin/kingpin lock status`:
   Expected output: `lock: stale` (since the parent subshell has now exited).
3. Run `bin/kingpin lock acquire`:
   Expected output: `lock: acquired (pid ...)` (successfully reclaims stale lock).
4. Run `bin/kingpin lock release`:
   Expected output: `lock: released`.

## Risks

| Risk | Mitigation |
|------|------------|
| Parent PID detection in subshell / test environment differs from interactive harness session | Helper `resolve_session_pid` explicitly inspects harness identity in `$PPID` and grandparent PPID before falling back to `$PPID`, and supports `KINGPIN_LOCK_PID` or explicit PID argument for deterministic testing and overrides |
| Stale lock prevents legitimate session from starting | `acquire` explicitly checks if the recorded PID is alive via `kill -0`; dead PIDs are overwritten automatically |

## Acceptance Criteria

- [ ] `bin/kingpin-lock acquire` records a live session PID rather than `$$`
- [ ] `kingpin lock status` reports `lock: held by pid <pid>` while the session lives
- [ ] A second `acquire` while the holder lives exits 1 and names the holder PID
- [ ] A second `check` while another holder lives exits 1 and names the holder PID
- [ ] Terminating the holder process frees the lock (status becomes `stale`) and allows re-acquisition without manual intervention
- [ ] `AGENTS.md` acquires the lock on startup and stays read-only when acquire fails
- [ ] All test suites (`test-automation.sh`, `test-harnesses.sh`, `test-acceptance.sh`) pass
