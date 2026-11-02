# Plan: Unify Task ID, git branch, and window name with descriptive title slugs

## Summary

`kingpin-spawn` names a task `<project>-<n>` or `<project>-<MMDD-HHMMSS>`, and that one string is the task folder, the git branch (`kingpin/<id>`), and the tmux window name. This plan replaces the default with `kp-<n>-<slug>` for `--issue <n>` (slug from the issue title, read with `gh issue view`) and `kp-<slug>` for `--text` (slug from the request). Slug generation lives in one new Node CLI, `lib/slug.mjs`, so the spawn script and a new `bin/kingpin-rename` helper share it. For `--text`, the issue number is unknown at spawn; once the worker appends `issue: #<n> <url>` to `status`, `kingpin-wait` calls `kingpin-rename`, which renames the tmux window (by its recorded window ID, so nothing else breaks) to `kp-<n>-<slug>` and rewrites `TMUX_TARGET`. The task ID and branch of a `--text` task are not renamed (see Open Questions: the worker holds the task folder path and the branch while it runs). An explicit `--id` keeps working and skips slug generation, so the existing tests do not change.

## User Story

As the orchestrator operator
I want task IDs, git branches and tmux windows to carry a short descriptive slug
So that I can tell what a worker is doing from `kingpin list`, `git branch` and `tmux list-windows` without looking up an issue number

## Metadata

| Field | Value |
|-------|-------|
| Type | ENHANCEMENT |
| Complexity | MEDIUM |
| Systems Affected | `bin/kingpin-spawn`, `bin/kingpin-wait`, new `bin/kingpin-rename`, new `lib/slug.mjs`, `bin/kingpin` (usage comment only if needed), `tests/test-automation.sh`, `README.md` |
| GitHub Issue | #16 |
| PRD Phase | N/A |
| Prototype Patch | N/A (the slug function was probed in a scratch dir, see Environment Findings; the change is small bash) |

## Environment Findings

| Probe | Result |
|-------|--------|
| Baseline on HEAD (`kingpin/kingpin-16`, clean tree) | green; PASS counts: `test-harnesses.sh` 57, `test-automation.sh` 187, `test-report.sh` 17, `test-worker-settings.sh` 79, `test-acceptance.sh` 20 (no FAIL lines asserted beyond the scripts' own exit status) |
| Lint / typecheck | none configured; shellcheck not installed; use `bash -n <script>` and `node --check lib/slug.mjs` |
| tmux isolation | tests wrap `tmux` with a private socket (`tests/test-automation.sh:22-37`); a new test must use the same wrapper, not the user's server |
| Existing tests and `--id` | every `kingpin-spawn` call in `tests/*.sh` passes `--id` (`grep -n spawn tests/*.sh`), so keeping `--id` authoritative (no slugging, no `gh`) leaves them untouched |
| `gh` | installed (`/usr/bin/gh`); `gh issue view 16 --json title -q .title` works from inside a clone and fails outside a git repo ("not a git repository"), so the call must run with `PROJECT_PATH` as cwd |
| Slug probe (scratch `/tmp/kp16-probe/slug.mjs`: lowercase, drop stop words, first 3 words, max 24 chars) | `"Unify Task ID, git branch, and window name with descriptive title slugs"` -> `unify-task-id`; `"Wake the orchestrator when a worker's status changes"` -> `wake-orchestrator-worker`; `"refactor authentication service"` -> `refactor-authentication`; `"!!!"` -> empty. Defect found: `"Überprüfung der API"` -> `u-berpru-fung` because non-alphanumerics were replaced before combining marks were removed; the real implementation strips `\p{M}` right after `normalize("NFKD")` (-> `uberprufung`) |
| Forward references to #16 | `grep` of source, docs and prior plans: none. Related finished work: #9 (`.agents/plans/completed/issue-9-track-worker-windows-by-id-plan.md`) made every reader use `TMUX_WINDOW_ID`, which is what makes a window rename safe |
| Readers of the task ID / branch / window name | `bin/kingpin:188` parses the ID from spawn's output with `spawned \([a-z0-9-]*\) ` (a `kp-4-wait-wakeup` ID matches); `bin/kingpin-done:99-126,160` use `BRANCH` and `TMUX_WINDOW_ID`; `bin/kingpin-board:56,124,173` use `TMUX_WINDOW_ID`/`TMUX_TARGET`/`BRANCH` with fallbacks; `bin/kingpin-land:21-33` reads `ISSUE` or the `issue:` status line; the preamble gets `{{TASK_ID}}`/`{{TASK_DIR}}` substituted (`bin/kingpin-spawn:171`) |

## Patterns to Follow

### Naming

```bash
# SOURCE: bin/kingpin-spawn:98-101
if [ -z "$id" ]; then
  if [ -n "$issue" ]; then id=$project-$issue; else id=$project-$(date +%m%d-%H%M%S); fi
fi
[[ $id =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "task id must be lowercase letters, digits, and dashes: $id"
```

The ID check stays; the generated IDs (`kp-4-wait-wakeup`) pass it.

### Command overrides and failure handling

```bash
# SOURCE: bin/kingpin-spawn:26-28
CLAUDE_CMD=${KINGPIN_CLAUDE:-claude}
AGY_CMD=${KINGPIN_AGY:-agy}
OPENCODE_CMD=${KINGPIN_OPENCODE:-opencode}
# SOURCE: bin/kingpin-spawn:30
die() { echo "kingpin-spawn: $*" >&2; exit 1; }
```

Add `GH_CMD=${KINGPIN_GH:-gh}` the same way so tests can stub `gh` (the repo's tests stub tools through PATH wrappers or env overrides, e.g. `KINGPIN_AGY`).

### Node CLI helper in lib/

```js
// SOURCE: lib/claude-trust.mjs:1-12
// Mark one directory as trusted ...
// Usage: node claude-trust.mjs <directory>
import fs from "node:fs";
...
const target = fs.realpathSync(process.argv[2] ?? "");
```

`lib/slug.mjs` follows this shape: header comment with usage, `process.argv`, prints the result, called from bash as `node "$KP_ROOT/lib/slug.mjs" "<text>"`.

### Window ID is the stable handle; TMUX_TARGET is the human-readable name

```bash
# SOURCE: bin/kingpin-spawn:307-310
# Record the window ID (@N): unlike the name in TMUX_TARGET, it survives a
# rename or a move to another session.
window_id=$(tmux new-window -d -P -F '#{window_id}' -t "$target_session:" -n "$id" -c "$worktree" "$task_dir/launch.sh")
printf 'TMUX_WINDOW_ID=%s\n' "$window_id" >> "$task_dir/task.env"
```

### Tests

```bash
# SOURCE: tests/test-automation.sh:159-164
spawn_out_outside=$(TMUX='' "$KP_BIN/kingpin" spawn demo-auto --issue 203 --id task-target-outside --mode review)
echo "$spawn_out_outside" | grep -q "tmux kingpin:task-target-outside" && pass "spawn logged kingpin target when TMUX is empty" || fail "spawn did not log kingpin target"
grep -q "^TMUX_TARGET=kingpin:task-target-outside$" "$KINGPIN_HOME/tasks/task-target-outside/task.env" && pass "..." || fail "..."
tmux list-windows -t kingpin -F '#{window_name}' | grep -qx "task-target-outside" && pass "..." || fail "..."
```

Numbered `# Test N` blocks with `pass`/`fail` helpers; the last block is Test 16 (`tests/test-automation.sh:1282`), so the new block is Test 17, placed before the final `if [ "$FAILED" -eq 0 ]` summary.

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `lib/slug.mjs` | CREATE | `node lib/slug.mjs "<text>"` prints a lowercase alphanumeric slug of 2-3 words, empty when the text has no usable word |
| `bin/kingpin-spawn` | UPDATE | generate `kp-<n>-<slug>` / `kp-<slug>` when `--id` is absent; `GH_CMD`; header comment |
| `bin/kingpin-rename` | CREATE | idempotent: for a `--text` task whose status has `issue: #<n> ...`, rename the tmux window to `kp-<n>-<slug>` and rewrite `TMUX_TARGET` |
| `bin/kingpin-wait` | UPDATE | call `kingpin-rename <id>` (best effort) when a task has new status lines |
| `tests/test-automation.sh` | UPDATE | Test 17: slug unit checks, spawn ID/branch/window/`TMUX_TARGET` for both modes, rename after the `issue:` line, `--id` override |
| `README.md` | UPDATE | `kingpin spawn` row: describe the ID format; mention the rename |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Slug generator

- **File**: `lib/slug.mjs`
- **Action**: CREATE
- **Implement**: read `process.argv.slice(2).join(" ")`; `normalize("NFKD")`, strip `\p{M}` (combining marks), lowercase, replace every run of non `[a-z0-9]` with a space, split, drop stop words (`a an the of to for and or in on with from by is are be it its as at that this when how into via`), keep the first 3 words, join with `-`, and stop adding words once the slug would exceed 24 characters. If every word was a stop word, fall back to the first raw word cut to 24 characters. Print the slug (possibly empty) and exit 0.
- **Mirror**: `lib/claude-trust.mjs:1-12` (header comment with usage, argv handling)
- **Validate**: `node --check lib/slug.mjs && [ "$(node lib/slug.mjs 'Unify Task ID, git branch, and window name with descriptive title slugs')" = unify-task-id ] && [ "$(node lib/slug.mjs 'Überprüfung der API')" = uberprufung-der-api ] && [ -z "$(node lib/slug.mjs '!!!')" ]`

### Task 2: Generate the unified ID in kingpin-spawn

- **File**: `bin/kingpin-spawn` (lines 10, 26-28, 98-101)
- **Action**: UPDATE
- **Implement**:
  - Header: `--id` default becomes `kp-<n>-<slug>` (issue) or `kp-<slug>` (text); add `KINGPIN_GH` to the "Command overrides" line.
  - Add `GH_CMD=${KINGPIN_GH:-gh}` next to the other `*_CMD` lines.
  - Replace the default-ID block. Only when `$id` is empty:
    - issue mode: `title=$(cd "$PROJECT_PATH" && $GH_CMD issue view "$issue" --json title -q .title 2>/dev/null || true)`; `slug=$(node "$KP_ROOT/lib/slug.mjs" "$title")`; `id=kp-$issue${slug:+-$slug}` (a failed `gh` call or an empty slug degrades to `kp-<n>`, never aborts the spawn). Use `${GH_CMD%% *}` for the `command -v` check only if `gh` is added to the tool list; do not make `gh` mandatory (offline spawns must still work), so leave it out of the `for tool in ...` loop.
    - text mode: `slug=$(node "$KP_ROOT/lib/slug.mjs" "$text")`; `id=kp-${slug:-task}`; if `$KP_HOME/tasks/$id` already exists, append `-2`, `-3`, ... until free (two live text tasks with the same opening words must not collide). Issue mode keeps the existing "task already exists" die.
  - Keep the `[[ $id =~ ... ]]` validation and the rest of the script unchanged: `branch=kingpin/$id`, the tmux window name `-n "$id"`, and `TMUX_TARGET=$target_session:$id` already derive from `$id`, which is what makes the three names uniform.
- **Mirror**: `bin/kingpin-spawn:98-101`, `:26-28`
- **Validate**: `bash -n bin/kingpin-spawn`

### Task 3: kingpin-rename helper

- **File**: `bin/kingpin-rename`
- **Action**: CREATE (chmod +x)
- **Implement**: `Usage: kingpin-rename <task-id>`. Exit 0 silently unless all hold: the task dir and `task.env` exist, `ISSUE=` in `task.env` is empty (the `--text` flow), no `$task_dir/renamed` marker exists, and `status` has a line matching `^issue: #[0-9]+` (take the first, as `bin/kingpin-land:31-32` does). Then: read `PROJECT_PATH`, `TMUX_TARGET`, `TMUX_WINDOW_ID` with `sed -n 's/^KEY=//p'`; fetch the title (`cd $PROJECT_PATH && ${KINGPIN_GH:-gh} issue view <n> --json title -q .title`, failure tolerated); `slug=$(node $KP_ROOT/lib/slug.mjs "$title")`, falling back to `${id#kp-}` (the text slug already in the task ID); `new=kp-<n>${slug:+-$slug}`. Rename with `tmux rename-window -t "${TMUX_WINDOW_ID:-$TMUX_TARGET}" "$new"` (skip when the window is gone). Rewrite the `TMUX_TARGET=` line of `task.env` to `<session>:<new>` through a temp file and `mv` (task.env is `source`d by `kingpin-done`, so keep every other line byte-identical). Write the marker `renamed` (contains `$new`) last, so a failed rename retries on the next event. Never touch the task folder, the branch, or the worktree.
- **Mirror**: `bin/kingpin-land:21-33` (reading `task.env` and the `issue:` line), `bin/kingpin-send:23-40` (target resolution)
- **Validate**: `bash -n bin/kingpin-rename`

### Task 4: Trigger the rename from kingpin-wait

- **File**: `bin/kingpin-wait` (the "New status lines" branch of `check_task`, line 72)
- **Action**: UPDATE
- **Implement**: before `echo "$id status"`, add `"$(dirname "$0")/kingpin-rename" "$id" >/dev/null 2>&1 || true`. `kingpin-wait` is already the one process the orchestrator and `kingpin-watch` both run while tasks are live, and a new `issue:` line is a new status line, so the rename needs no new poller. The call is idempotent (marker) and never changes the wait output.
- **Mirror**: `bin/kingpin-wait:35` (`"$(dirname "$0")/kingpin-guard" warn || true`)
- **Validate**: `bash -n bin/kingpin-wait`

### Task 5: Tests

- **File**: `tests/test-automation.sh` (new "Test 17" block before the final summary)
- **Action**: UPDATE
- **Implement**: in a `t17_` namespace, with a `gh` stub script (`$T/t17-gh`, printing `Wait for worker wakeup events` for `issue view`) selected through `KINGPIN_GH`, and `KINGPIN_AGY=$T/fake-worker` as in Test 5:
  1. Slug unit checks: `node lib/slug.mjs` on the issue title above -> `unify-task-id`; punctuation-only -> empty; accents folded; result matches `^[a-z0-9]+(-[a-z0-9]+)*$` and is at most 24 chars.
  2. Issue spawn without `--id`: `kingpin spawn demo-auto --issue 301` prints `spawned kp-301-wait-worker-wakeup` (the exact slug the stub title yields); `task.env` has `BRANCH=kingpin/kp-301-...` and `TMUX_TARGET=kingpin:kp-301-...`; `tmux list-windows -F '#{window_name}'` contains that name; `git -C <worktree> branch --show-current` equals `kingpin/kp-301-...`.
  3. Downstream routing: `kingpin send kp-301-... "echo t17-ok"` prints `OK: sent to kingpin:kp-301-...`.
  4. `gh` failing (stub exits 1): spawn `--issue 302` falls back to `kp-302`.
  5. Text spawn without `--id`: `--text "refactor authentication service"` gives `kp-refactor-authentication`; a second identical spawn gives `kp-refactor-authentication-2` (no collision).
  6. Rename: append `issue: #303 https://example/303` to that task's `status`, run `kingpin-wait --once`; the window name becomes `kp-303-<stub slug>`, `TMUX_TARGET` is rewritten, `TMUX_WINDOW_ID`, `BRANCH` and the task folder name are unchanged, `renamed` marker exists, `kingpin send` to the task ID still reaches the window, and a second `kingpin-wait --once`/`kingpin-rename` is a no-op.
  7. `--id explicit-id` still wins and calls no `gh` (stub that writes a marker file; assert it is absent).
  Clean up with `kingpin done <id> --force` per task, like Test 5.
- **Mirror**: `tests/test-automation.sh:159-188` (spawn, `task.env` greps, window list, send, done), `tests/test-automation.sh:1282-1300` (Test 16 helper layout)
- **Validate**: `bash tests/test-automation.sh 2>&1 | tail -5` shows `ALL AUTOMATION TESTS PASSED`; the new `PASS: t17...` lines appear

### Task 6: README

- **File**: `README.md` (the `kingpin spawn` row, line 100)
- **Action**: UPDATE
- **Implement**: add to the spawn description: the task ID, branch (`kingpin/<id>`) and window share a slug, `kp-<n>-<slug>` from the issue title for `--issue` and `kp-<slug>` from the request for `--text`; `--id` overrides; for `--text`, the window is renamed to `kp-<n>-<slug>` once the worker reports its issue (the task ID and branch keep the first name). Keep the row style.
- **Mirror**: `README.md:100`
- **Validate**: `grep -n "kp-<" README.md`

---

## Validation

```bash
# Syntax (no build/typecheck/lint exists; shellcheck is not installed)
bash -n bin/kingpin-spawn bin/kingpin-rename bin/kingpin-wait && node --check lib/slug.mjs

# Tests (baseline on HEAD: harnesses 57, automation 187, report 17, worker-settings 79, acceptance 20 PASS lines)
bash tests/test-automation.sh
bash tests/test-harnesses.sh
bash tests/test-worker-settings.sh
bash tests/test-acceptance.sh
bash tests/test-report.sh
```

## End-to-End Verification

Run in a scratch `KINGPIN_HOME` with the private tmux socket and a stub `gh` exactly as Test 17 does (never the user's `~/.kingpin` or tmux server):

1. `kingpin spawn demo --issue 301` with a stub `gh` titled "Wait for worker wakeup events": output says `spawned kp-301-wait-worker-wakeup`; `git branch --show-current` in the worktree prints `kingpin/kp-301-wait-worker-wakeup`; `tmux list-windows` shows the same name; `task.env` has `TMUX_TARGET=<session>:kp-301-wait-worker-wakeup`.
2. `kingpin spawn demo --text "refactor authentication service"`: ID, branch, window are `kp-refactor-authentication`. Append `issue: #303 <url>` to its `status`, run `kingpin-wait --once`: the window is now `kp-303-<slug>`, `TMUX_TARGET` follows, `kingpin send <id> "echo ok"` still works, the task folder and branch keep the first name.
3. `kingpin done <id> --force` for each: window gone, task archived, branch deleted.
4. Real-gh smoke check (one call, read-only, reason: prove the real `gh issue view --json title` output shape): `cd <this repo> && gh issue view 16 --json title -q .title | xargs node lib/slug.mjs` prints `unify-task-id`.

## Risks

| Risk | Mitigation | Scope |
|------|------------|-------|
| `--text` task keeps its first ID and branch, so the three names agree in format but not in content after the issue is known | Renaming the task folder or branch under a live worker breaks `KINGPIN_TASK_DIR`, the preamble paths (`{{TASK_DIR}}`), the orchestrator's `kingpin-wait` seen counters, the listener, and the branch the skills may already have pushed. Rename only the window (safe since #9 tracks windows by ID). Recorded as an Open Question. | in scope (window), out of scope (ID/branch) |
| IDs no longer carry the project name, so two projects with issue #4 in one `KINGPIN_HOME` collide (task dir already exists) | The existing "task already exists" die names the path; `--id` overrides. The issue explicitly asks for `kp-<n>-<slug>`. Open Question, no code change by default. | flag only |
| `gh` unavailable, offline, or unauthenticated at spawn | Falls back to `kp-<n>`; never aborts the spawn. | in scope |
| Issue title yields an empty or odd slug (non-Latin script, only stop words) | Empty slug -> `kp-<n>` / `kp-task`; stop-word-only text falls back to the first raw word. | in scope |
| A second `kingpin spawn` for an issue whose first task is still live | Unchanged: the existing "task ... already exists" die. A finished task is archived (`kingpin-done`), so its ID is free again. | in scope (unchanged) |
| `kingpin-wait` gains a side effect | The call is best effort, silent, idempotent through the `renamed` marker, and only fires on new status lines; wait output is unchanged. | in scope |
| `task.env` is `source`d by `kingpin-done` | The rewrite keeps every other line byte-identical and the new value is `[a-z0-9:-]` only. | in scope |
| Slug quality depends on a hand-written stop-word list | Cap at 3 words/24 chars and cover the cases in the unit test; tuning the list is cosmetic. | flag only |

## Open Questions

- **Does "auto-rename the window and task target" also mean renaming the task ID and branch for `--text` tasks?** The issue says to use the slug "uniformly across Task ID, git branch name, and tmux window name", but only names the window and `TMUX_TARGET` for the rename. Proposed default: rename only the window and `TMUX_TARGET` (above); the first `kp-<textslug>` stays as ID and branch. A full rename would need the worker to be paused or told a new `KINGPIN_TASK_DIR`, and would invalidate IDs the orchestrator is already tracking. If the owner wants it, it is a follow-up issue.
- **Should the project name stay in the ID?** The issue prescribes `kp-<n>-<slug>`. Proposed default: follow the issue; on a cross-project collision the spawn fails clearly and `--id` resolves it.
- **Slug length and stop words.** The issue says 2-3 words. Proposed default: up to 3 words, 24 characters, the stop-word list in Task 1 (an internal choice that changes no acceptance criterion).

## Acceptance Criteria

- [ ] `kingpin-spawn` without `--id` yields `kp-<n>-<slug>` (issue) or `kp-<slug>` (text), lowercase alphanumeric with dashes
- [ ] Task ID, branch (`kingpin/<id>`) and tmux window name are the same string at spawn
- [ ] `TMUX_TARGET` records the slugged window name, and is rewritten when a `--text` task's window is renamed after `issue:`
- [ ] Tests cover slug generation, downstream routing (`kingpin send`, `kingpin done`) and the rename
- [ ] `--id` still overrides; `gh` failure does not break spawning
- [ ] All tasks completed
- [ ] `bash -n` / `node --check` pass
- [ ] All five test scripts pass (baseline counts above)
- [ ] Follows existing patterns
