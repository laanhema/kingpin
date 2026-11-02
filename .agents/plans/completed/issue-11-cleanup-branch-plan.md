# Plan: issue #11 cleanup of renamed task branches and remote branches

Path: quick (Complexity Small). Prime focus: backend (shell).

- In `bin/kingpin-done`, read the worktree's current branch (`symbolic-ref`) before the worktree is returned; fall back to `BRANCH` from `task.env` (detached HEAD, missing worktree).
- Set `merge_verified=1` only when the existing `merge-base --is-ancestor` check ran and passed.
- Delete local branches (used + recorded), never the default branch. Delete the remote branch only when `merge_verified=1`; a missing remote branch or failed push is not an error.
- Tests: Test 16 in `tests/test-automation.sh` (bare remote, linked worktrees, `treehouse` stub).
