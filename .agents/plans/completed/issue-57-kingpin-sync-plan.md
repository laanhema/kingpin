# Plan: Add kingpin sync

## Summary

Add `bin/kingpin-sync`, modelled on `bin/kingpin-peek`, and register it in `bin/kingpin`. It runs in the current directory's repo, refuses in a linked worktree, a dirty tree, a missing upstream, or a non-fast-forward, and otherwise runs `git pull --ff-only`, printing old and new short SHAs plus the commits pulled (or `already up to date`). AGENTS.md tells the orchestrator to use it instead of raw git; README.md documents it. Tests go in `tests/test-automation.sh` as Test 21 with temp git repos.

## User Story

As the orchestrator
I want to fast-forward the main checkout with a kingpin command
So that I never run raw git against project files

## Metadata

| Field | Value |
|-------|-------|
| Type | NEW_CAPABILITY |
| Complexity | LOW |
| Systems Affected | bin/, tests/, AGENTS.md, README.md |
| GitHub Issue | #57 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

## Environment Findings

| Probe | Result |
|-------|--------|
| `bash tests/test-automation.sh` on HEAD | ALL AUTOMATION TESTS PASSED (green baseline) |
| Forward references to #57 | none in source/docs |

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-sync` | CREATE | The command |
| `bin/kingpin` | UPDATE | Header usage, help text, `sync)` case |
| `tests/test-automation.sh` | UPDATE | Test 21 |
| `AGENTS.md` | UPDATE | Tell the orchestrator to use `kingpin sync` |
| `README.md` | UPDATE | Command table row and usage example |

## Tasks

### Task 1: Create bin/kingpin-sync

- **File**: `bin/kingpin-sync`
- **Action**: CREATE (chmod +x)
- **Implement**: Header comment, `usage()`, arg loop (`-h|--help` exit 0, any other argument: message + usage + exit 2). `die()` prints `kingpin-sync: <msg>` to stderr, exit 1. Checks in order: inside a git work tree; `--git-dir` equals `--git-common-dir` (absolute) else refuse "linked worktree"; on a branch (not detached HEAD); upstream configured (`git rev-parse --abbrev-ref @{upstream}`) else refuse; `git status --porcelain` non-empty means refuse "working tree is dirty"; record old HEAD; run `git pull --ff-only` (output to stderr on failure, exit 1 with "cannot fast-forward"); new HEAD; equal means print `already up to date`; else print `synced <branch>: <old7>..<new7>` then `git log --oneline old..new`. Never merge, rebase, reset.
- **Mirror**: `bin/kingpin-peek:11-53` (arg loop, usage/exit codes); `bin/kingpin-guard:60-65` (main-checkout test)
- **Validate**: `bash -n bin/kingpin-sync`

### Task 2: Register in bin/kingpin

- **File**: `bin/kingpin`
- **Action**: UPDATE
- **Implement**: Header line `kingpin sync`, help line `sync      Fast-forward the main checkout from its upstream (never merges or discards)`, `sync)` case exec'ing `kingpin-sync`.
- **Mirror**: `bin/kingpin:11,34,87-89` (peek entries)
- **Validate**: `bash -n bin/kingpin && bin/kingpin sync --help`

### Task 3: Tests

- **File**: `tests/test-automation.sh`
- **Action**: UPDATE
- **Implement**: Test 21 after Test 20, before the final summary: bare origin, main clone, second clone to push commits. Cases: up to date; success with commits pulled (prints old/new SHAs and subjects, HEAD moves); dirty tracked file refused and untouched; untracked file refused; ignored file not dirty; non-fast-forward (local commit plus remote commit) refused and HEAD unchanged; linked worktree refused; no upstream refused; `--help` exit 0; unknown arg exit 2.
- **Mirror**: `tests/test-automation.sh:1666-1740` (t20 style, pass/fail helpers)
- **Validate**: `bash tests/test-automation.sh`

### Task 4: Docs

- **File**: `AGENTS.md`, `README.md`
- **Action**: UPDATE
- **Implement**: AGENTS.md Hard Rule 1: to pick up merged changes in the main checkout run `kingpin sync` (fast-forward only); bash stays for kingpin commands only. README: command table row and a usage example near the peek example. Grep for other command lists.
- **Mirror**: `README.md:103-104,132-150`; `AGENTS.md:26`
- **Validate**: `grep -n "kingpin sync" AGENTS.md README.md`

## Validation

```bash
bash -n bin/kingpin-sync bin/kingpin tests/test-automation.sh
bash tests/test-automation.sh
bash tests/test-report.sh
bash tests/test-worker-settings.sh
```

## End-to-End Verification

In a scratch dir, make a bare origin, two clones, push a commit from clone B, run `bin/kingpin sync` in clone A: expect old/new SHAs and the commit line, then `already up to date` on a second run. Run it in a `git worktree add` copy: expect exit 1 and a "linked worktree" message. Covered by Test 21.

## Risks

| Risk | Mitigation |
|------|------------|
| `git pull` may prompt or merge via config (`pull.rebase`) | Use `--ff-only`, which overrides pull.rebase/merge; in scope |
| Hung fetch prompting credentials | Set `GIT_TERMINAL_PROMPT=0`; in scope |
| Stash/autostash config | Dirty tree is refused first; `--no-autostash` passed; in scope |
| Submodules | Out of scope |

## Acceptance Criteria

- [ ] All tasks completed
- [ ] `kingpin sync` refuses in linked worktree, dirty tree, non-ff, no upstream; exits non-zero
- [ ] Success prints old/new short SHAs and commits, or `already up to date`
- [ ] Registered in header, help, dispatcher; `--help` works
- [ ] Tests added and pass
- [ ] AGENTS.md and README.md updated
