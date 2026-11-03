# Plan: Make the Test 4 guard check independent of the host checkout

## Summary

`tests/test-worker-settings.sh:203` runs `(cd "$T/proj" && "$KP_BIN/kingpin" guard check ...)` and expects a failure. `kingpin-guard` ignores the working directory and defaults `--dir` to its own checkout (`bin/kingpin-guard:34`, `KP_ROOT` at `bin/kingpin-guard:19`), and `$KP_BIN` is the real checkout's `bin/`. On a checkout that carries the guard (the orchestrator's main checkout) the check passes and the suite prints `FAIL: proj wrapper check saw a guard it should not`; in a leased worktree the guard refuses to run (linked worktree), so workers always saw a pass. The fix is one line: pass `--dir "$T/proj"` so the check reads the fixture, drop the meaningless `cd`, and give the line a `pass` branch like its neighbours. A prototype patch is saved and was verified in a scratch clone of the repo with the guard installed and with it removed. An audit of the other four suites found no host-state read or write; the findings are listed below so the PR can quote them.

## User Story

As a Kingpin maintainer running the suites in the orchestrator's main checkout
I want `tests/test-worker-settings.sh` to pass whether or not a guard is installed there
So that the suite's result does not depend on the checkout it runs in, and workers' "all tests pass" reports are trustworthy.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `tests/test-worker-settings.sh` |
| GitHub Issue | #60 |
| PRD Phase | N/A |
| Prototype Patch | `.agents/plans/issue-60-guard-test-host-checkout-prototype.patch` |

All `file:line` citations below are lines of HEAD (d290271) before the patch.

---

## Environment Findings

| Probe | Result |
|-------|--------|
| Worktree has a guard file (`.claude/settings.local.json`) | Absent; `kingpin-guard install` refuses a linked worktree (`bin/kingpin-guard:60-64`), so the failure cannot be reproduced here |
| Reproduction on HEAD: scratch `git clone` of this branch in `/tmp`, `bin/kingpin-guard install`, `bash tests/test-worker-settings.sh` | `FAIL: proj wrapper check saw a guard it should not`, `WORKER SETTINGS TESTS FAILED` |
| Same clone, guard file removed | `ALL WORKER SETTINGS TESTS PASSED` |
| Patch applied to the clone, guard installed | `PASS: proj wrapper check fails without a guard`, `ALL WORKER SETTINGS TESTS PASSED` |
| Patch applied to the clone, guard removed | Same, all pass |
| Other suites in the clone with a guard installed (`test-report`, `test-harnesses`, `test-automation`, `test-acceptance`) | All four pass; clone `git status` clean afterwards (so the suites did not write into it); `md5sum` of `~/.kingpin/orchestrator.lock` and `~/.kingpin/config.env` unchanged across `test-automation` |
| Clone and scratch worktree | Deleted after the probes; `git worktree list` shows no leftovers |

Green baseline in a worktree (no guard): `test-worker-settings.sh` passes (the line prints nothing in that branch today).

---

## Patterns to Follow

### Passing the fixture explicitly
```bash
# SOURCE: tests/test-worker-settings.sh:136
"$KP_BIN/kingpin-guard" check --dir "$T/proj" >/dev/null && pass "main checkout guard is active" || fail "main checkout guard inactive"
```

### Negative check with both outcomes reported
```bash
# SOURCE: tests/test-worker-settings.sh:91
"$KP_BIN/kingpin-guard" check --dir "$T/kp-checkout" >/dev/null 2>&1 && fail "check passed with legacy deny rules" || pass "check rejects legacy deny rules"
```

### Host-isolation env block (the suites' shared pattern)
```bash
# SOURCE: tests/test-worker-settings.sh:7-16
unset TMUX CLAUDECODE OPENCODE KINGPIN_HARNESS
T=$(mktemp -d)
export KINGPIN_HOME=$T/kp
export KINGPIN_SKIP_GUARD=1
export TREEHOUSE_ROOT=$T/pool
export CLAUDE_CONFIG_DIR=$T/cfg
```

---

## Host-State Audit of the Other Suites

Checked by reading each suite and by running all of them in a scratch clone with the guard installed (see Environment Findings).

| Suite | Host-state reads/writes | Verdict |
|-------|------------------------|---------|
| `tests/test-worker-settings.sh` | Line 203 reads the real checkout's guard (the bug). Line 157 reads only `$T/proj`'s settings. Lines 62-64 read `$KP_ROOT` tracked files and ignore rules on purpose (assert a repo property). Line 129 copies the host's untracked-unignored files into the fixture (harmless). Lines 204-218 use `$T/proj/bin/*` copies (their `KP_ROOT` is the fixture) or `--dir`. | Fix line 203 only |
| `tests/test-automation.sh` | Exports `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD=1`, `TREEHOUSE_ROOT`, `CLAUDE_CONFIG_DIR`, `GEMINI_CONFIG_DIR` (lines 8-12), `KINGPIN_SKILLS_DIR` (525, 1184). `kingpin init` (64, 70, 520) would call `kingpin-guard install` on the real checkout (`bin/kingpin-init:80-87`) but `KINGPIN_SKIP_GUARD=1` skips it. Lock tests use `KINGPIN_HOME/orchestrator.lock` (396, 431). It also temporarily overwrites `$KP_BIN/kingpin-send` in the real checkout (95-103) and restores it at 110 and in the `cleanup` trap (restore added in the review fix). | No read leak; the `KINGPIN_SKIP_GUARD=1` export is load-bearing. Write-in-place of a tracked script is a robustness risk; out of scope, list in the PR |
| `tests/test-harnesses.sh` | Same isolation exports (6-12); `kingpin-lock acquire` at 189 uses `KINGPIN_LOCK_PID=$$` and the temp `KINGPIN_HOME`. Reads `$KP_ROOT/AGENTS.md` and `worker/preamble.md` (243-246) on purpose (content assertions). | Clean |
| `tests/test-acceptance.sh` | Same isolation exports (6-11); real `treehouse` runs under `TREEHOUSE_ROOT`. It temporarily overwrites `$KP_BIN/kingpin-send` in the real checkout (115-124) and restores it in the `cleanup` trap (36) and at 170. | No read leak. Write-in-place of a tracked script is a robustness risk; out of scope, list in the PR |
| `tests/test-report.sh` | Temp repo only; no `~/.kingpin`, no guard. | Clean |

No `~/.kingpin` file, lock or guard is read from the real checkout by any other suite, so no further fix is needed.

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `tests/test-worker-settings.sh` | UPDATE | Line 203: check the fixture with `--dir "$T/proj"`; patch covers it fully |
| `.agents/plans/issue-60-guard-test-host-checkout-prototype.patch` | (input) | Prototype of the change above |

---

## Tasks

The `/implement` run applies the patch first (Metadata names it); there is no apply task.

### Task 1: Verify the patched line and its comment

- **File**: `tests/test-worker-settings.sh`
- **Action**: CHECK
- **Implement**: Confirm the patch replaced the `cd ... && ... && fail` line with `"$KP_BIN/kingpin" guard check --dir "$T/proj" ... && fail ... || pass ...` and added a two-line comment saying why `--dir` is needed. Keep the comment (it is the only record of why `cd` does not work). Do not touch lines 204-218.
- **Mirror**: `tests/test-worker-settings.sh:91`
- **Validate**: `bash -n tests/test-worker-settings.sh && grep -n 'guard check --dir "\$T/proj"' tests/test-worker-settings.sh`

### Task 2: Prove the fix in a main checkout with the guard installed, and without

- **File**: `tests/test-worker-settings.sh`
- **Action**: CHECK
- **Implement**: A linked worktree cannot hold a guard, so use a scratch clone in `/tmp` (the main-checkout case). Run the script below. It must print `FAIL: proj wrapper check saw a guard it should not` for the first run on HEAD's version of the test and `ALL WORKER SETTINGS TESTS PASSED` twice for the patched version.
- **Mirror**: Environment Findings table
- **Validate**:
```bash
WT=$PWD S=$(mktemp -d)
git clone -q "$WT" "$S/main" && cd "$S/main" && git checkout -q "$(git -C "$WT" rev-parse HEAD)"
bin/kingpin-guard install >/dev/null
git show HEAD:tests/test-worker-settings.sh > tests/test-worker-settings.sh       # HEAD's unpatched test
bash tests/test-worker-settings.sh 2>&1 | grep -E 'FAIL|ALL WORKER'               # red: FAIL: proj wrapper check ...
cp "$WT/tests/test-worker-settings.sh" tests/test-worker-settings.sh               # the patched test
bash tests/test-worker-settings.sh 2>&1 | grep -E 'FAIL|wrapper check|ALL WORKER'  # green, guard installed
rm -f .claude/settings.local.json
bash tests/test-worker-settings.sh 2>&1 | grep -E 'FAIL|wrapper check|ALL WORKER'  # green, no guard
cd "$WT" && rm -rf "$S"
```

### Task 3: Run the whole suite in the worktree

- **File**: `tests/`
- **Action**: CHECK
- **Implement**: Run all five suites in the leased worktree (no guard) to confirm start-green, stay-green.
- **Mirror**: `README.md:187-206`
- **Validate**: `for t in tests/test-*.sh; do bash "$t" 2>&1 | grep -E 'FAIL|ALL .*PASSED'; done`

---

## Validation

```bash
# Build / type check: none (bash scripts)
bash -n tests/test-worker-settings.sh

# Lint: none configured in this repo at HEAD (issue #61 adds shellcheck CI separately)

# Tests
for t in tests/test-*.sh; do bash "$t"; done

# Reproduction: red on HEAD, green after the fix, in a main-checkout clone with the guard installed (Task 2)
```

## End-to-End Verification

1. `git clone` the branch to a scratch dir; `bin/kingpin-guard install` there (a real main checkout, so the guard is accepted).
2. Run the unpatched `tests/test-worker-settings.sh`: expect `FAIL: proj wrapper check saw a guard it should not` and exit 1. Already observed on HEAD.
3. Copy the patched test in and run it: expect `PASS: proj wrapper check fails without a guard` and `ALL WORKER SETTINGS TESTS PASSED`. Already observed with the patch.
4. Remove `.claude/settings.local.json` in the clone and rerun: same result. Already observed.
5. Delete the clone. Run `git status --short` in the worktree: only the intended test change remains.

## Risks

| Risk | Mitigation |
|------|------------|
| Guard cannot be installed in the leased worktree, so the red run must happen elsewhere | Use a scratch clone in `/tmp` (main checkout); never install a guard into a linked worktree. In scope |
| `A && fail || pass` runs `pass` if `fail` returns non-zero | `fail` is `echo` plus an assignment (always 0), same idiom as line 91. Out of scope |
| A future test again calls `"$KP_BIN/kingpin" guard ...` without `--dir` | Out of scope as a lint; the audit shows no other call. Optionally mention in the PR that `KINGPIN_SKIP_GUARD=1` plus `--dir` is the pattern |
| `test-acceptance.sh` and `test-automation.sh` rewrite `$KP_BIN/kingpin-send` in the real checkout during the run (restored by trap) | Not a read leak; flag in the PR, no change here |
| Suite 1 lines 62-64 and 129 read the real checkout | Intentional (repo-property assertions, fixture seed). Out of scope |

## Open Questions

- Should the check use the fixture wrapper `"$T/proj/bin/kingpin" guard check` (its `KP_ROOT` is the fixture) instead of `--dir`? Proposed default: `--dir "$T/proj"` as the issue's first acceptance criterion says; both check the fixture.
- Should the audit's non-leak observation (`test-acceptance.sh` and `test-automation.sh` overwriting `$KP_BIN/kingpin-send`) become its own issue? Proposed default: only mention it in the PR, no follow-up filed.
- The issue says to test "with and without the guard installed in the host checkout"; in a leased worktree the guard cannot exist, so this plan uses a scratch clone as the host. Proposed default: accept the clone as a faithful stand-in (it reproduced the exact failure).

## Acceptance Criteria

- [ ] `tests/test-worker-settings.sh` line 203 checks the fixture via `--dir "$T/proj"`
- [ ] `bash tests/test-worker-settings.sh` passes in a main-checkout clone with and without the guard installed
- [ ] All five suites pass in the leased worktree
- [ ] The audit table above (or its summary) is in the PR description; no other leak found or fixed
- [ ] Follows existing patterns (`tests/test-worker-settings.sh:91`)
