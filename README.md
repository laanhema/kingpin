# Kingpin

<p align="center">
  <img src="assets/kingpin.jpg" alt="Kingpin" width="700">
</p>

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in parallel git worktrees, isolates dependencies, prevents git pollution, serializes landing queues, and hands each task to you as a visual review dossier.

Kingpin supports **Claude Code**, **Antigravity CLI (agy)**, and **OpenCode**.

---

## Prerequisites

Ensure the following tools are installed on your host:

- `git` (2.30+)
- `tmux`
- `treehouse` (git worktree pool manager)
- `node` (18+)
- At least one worker harness:
  - `claude` (Claude Code)
  - `agy` (Google Antigravity CLI)
  - `opencode` (OpenCode CLI)

Optional:
- `lavish-axi` (for per-task review dossiers and their interactive actions)
- `shellcheck` (contributors only, for `./tests/lint.sh`; `pip install shellcheck-py==0.11.0.1` into a venv, which is the version CI pins, or your package manager at shellcheck 0.11.0)

---

## Quick Start (Two Commands)

Add Kingpin to your `PATH`:

```bash
export PATH="/home/lauri/github/kingpin/bin:$PATH"
```

### 1. Initialize your project (run once inside any git repository)

```bash
cd /path/to/my-repo
kingpin init
```

Kingpin detects the git repository and writes `~/.kingpin/projects/my-repo.env` automatically. It also installs the orchestrator tool guard (`kingpin guard install`): a `PreToolUse` hook in the untracked `.claude/settings.local.json` of the Kingpin checkout denies `Edit`, `Write`, `NotebookEdit` and `Agent` when the session runs in the main checkout, so only the orchestrator session is restricted and leased workers keep full tooling (see [Worker permissions](#worker-permissions)). You can pin a harness for the project:

```bash
kingpin init --harness agy
```

Without `--harness`, no `HARNESS` is written and the project follows the default harness below.

### Which harness a worker uses

`kingpin spawn` picks the first of these that is set:

1. `--harness <name>` on the command
2. `HARNESS` in the project's `~/.kingpin/projects/<name>.env` (only when set explicitly, e.g. by `kingpin init --harness`)
3. the harness of the orchestrator session that holds the lock (`kingpin lock acquire` records it; `kingpin lock status` shows it)
4. `DEFAULT_HARNESS` in `~/.kingpin/config.env`
5. `claude`

`kingpin lock acquire` finds the harness in this order: `--harness <name>` on `acquire`, the `KINGPIN_HARNESS` environment variable, the command name of the session process (`claude`, `agy`, `opencode`), then the calling agent's own marker (`CLAUDECODE=1`, `OPENCODE=1`). A session that matches none records nothing. The record is dropped by `kingpin lock release` and ignored once the holder process is gone. Project files written by older versions of `kingpin init` contain `HARNESS=claude`, which counts as set; delete that line to let the lock holder decide.

### 2. Run a task to completion in one command

```bash
# Auto mode: spawns, monitors, auto-lands when green, merges, and cleans up
kingpin run my-repo --issue 42 --mode auto

# Review mode: spawns, monitors, and stops at ready with your review report link
kingpin run my-repo --text "refactor authentication service" --harness agy
```

---

## Automated Fleet Supervision (`kingpin watch`)

When running multiple workers simultaneously, start the fleet supervisor in the background or in a separate terminal:

```bash
kingpin watch
```

`kingpin watch` automates the entire lifecycle:
- Automatically triggers `kingpin land` for workers in `auto` mode when they report `ready:`.
- Automatically triggers `kingpin done` when workers report `merged:`, releasing worktrees back to the treehouse pool.
- Notifies when tasks in `review` mode are ready for inspection or need input.

---

## CLI Command Reference

| Command | Usage | Description |
|---|---|---|
| `kingpin init` | `kingpin init [name] [path] [--harness <name>]` | Auto-configures a project from current directory or path. |
| `kingpin run` | `kingpin run <proj> (--issue <n> \| --text <req>) [--mode auto\|review]` | Single command that spawns, monitors, and completes a task. |
| `kingpin watch` | `kingpin watch [--once] [--interval <sec>]` | Continuous supervision and auto-landing loop. |
| `kingpin spawn` | `kingpin spawn <proj> (--issue <n> \| --text <req>) [--harness <name>]` | Starts a worker on a background tmux window and records its tmux window ID (`TMUX_WINDOW_ID` in `task.env`), so renaming a worker window or moving it to another session is safe; `task.env` files without it fall back to `TMUX_TARGET`. The window is pinned with `automatic-rename off` and `allow-rename off`, so ambient tmux settings and worker child commands cannot rename it; only `kingpin-wait` renames it. The task ID, branch (`kingpin/<id>`) and window share one slug: `kp-<n>-<slug>` from the issue title for `--issue`, `kp-<slug>` from the request for `--text` (`--id` overrides). For `--text`, `kingpin-wait` renames the window and `TMUX_TARGET` to `kp-<n>-<slug>` once the worker reports its issue; the task ID and branch keep the first name. |
| `kingpin list` | `kingpin list [--all]` | Displays active fleet tasks and states in the terminal; `--all` also shows finished (archived) tasks. |
| `kingpin send` | `kingpin send <task-id> "<text>"` | Types the text literally into a worker window, then presses Enter. |
| `kingpin peek` | `kingpin peek <task-id> [--lines N]` | Read-only view of a worker: prints the last 20 non-empty lines of its tmux pane (`--lines N` changes the count), scrollback included. It finds the pane from the recorded window ID (`TMUX_WINDOW_ID`), so it works after the window is renamed or moved, and falls back to `TMUX_TARGET` for older `task.env` files. It sends no keys and changes no state. Exits 1 for an unknown task or a window that is gone, 2 for a bad argument. Use it to see why a worker is stuck (an unsubmitted pasted message, a usage-limit banner, a permission prompt). |
| `kingpin sync` | `kingpin sync` | Fast-forwards the main checkout from its upstream branch with `git pull --ff-only`, so the orchestrator never runs raw git against project files. Run it in the main checkout; it prints the old and new short SHAs plus the commits pulled, or `already up to date`. It never merges, rebases, resets or stashes. Exits 1 with a message on stderr in a linked worktree, on a dirty tree (any `git status --porcelain` output; ignored files do not count), with a detached HEAD or no upstream, or when a fast-forward is not possible; 2 for an argument. |
| `kingpin listen` | `kingpin listen <task-id> [--once] [--background]` | Keeps a Lavish listener attached to a task's review dossier (`report.html`): opens the dossier once, then polls it and routes what the reviewer does. **Approve & Land** runs `kingpin land` and appends an `approved:` note to the task's `status`; **Request Changes** appends the text to `feedback.md` plus a `feedback:` note, and both notes wake `kingpin wait`. `--background` starts one detached listener per task (concurrent launches start only one; pid in `listener.pid`, output in `listener.log`) and returns at once; `kingpin watch` starts it when a review-mode worker reports `ready:`. `--once` stops after one poll. Without `lavish-axi` (or `KINGPIN_LAVISH`) it prints a note on stderr and exits 0. Exits 1 for an unknown task or one without `report.html`, 2 for a bad argument. `kingpin done` stops the listener. |
| `kingpin wait` | `kingpin wait [--timeout <sec>] [--once]` | Prints one `<task-id> <reason>` line (`status`, `quiet` or `exited`) per fleet event that needs action. Exits 0 on events and on a plain timeout (nothing printed); `--once` with no events exits 1; 2 for a bad argument. See [Fleet Overview](#fleet-overview--visual-review-dossiers). |
| `kingpin ack` | `kingpin ack <task-id>... \| --all` | Marks a task's events as seen, so `kingpin wait` reports only newer ones. |
| `kingpin land` | `kingpin land <task-id>` (alias: `kingpin approve <task-id>`) | Serializes project landing and triggers merge. When the review verdict has findings (`APPROVE WITH NITS`, `NEEDS CHANGES`) it runs `/fix-findings` first and says so; landing continues after the worker reports `fixed:`. When the review is clean it says that landing is starting. |
| `kingpin done` | `kingpin done <task-id> [--force]` | Verifies merge, releases worktree lease, advances the queue, and archives the task record to `~/.kingpin/archive/<task-id>`. Refuses, even with `--force`, when another unfinished task records the same worktree. A refusal is recorded as a `cleanup-refused:` status line only for a finished task (`merged:`, `failed:`); a worker that may still be live keeps its last status (for example `needs-input:`), and the reason goes to stderr. `done` also stops the task's dossier listener, and `kingpin ack` of an archived task is a no-op that exits 0 with a note. |
| `kingpin lock` | `kingpin lock [status\|check\|acquire [--harness <name>]\|release\|harness]` | Enforces a single active orchestrator session and records its harness for `kingpin spawn`. |
| `kingpin guard` | `kingpin guard [install\|check\|warn]` | Installs or verifies the orchestrator-only tool guard, a `PreToolUse` hook in `.claude/settings.local.json` (untracked); `install` also removes the deny rules that older versions wrote there, which leaked into workers; `warn` prints a stderr warning when the guard is missing or stale; `kingpin guard hook <orchestrator\|worker>` is the hook entry point; `list` and `wait` run it at startup, and `lock acquire` prints the same warning. |
| `kingpin report` | `kingpin report diffs [--repo <dir>] [--base <ref>]` / `kingpin report check <report.html>` | Dossier helper for workers. `diffs` prints the HTML for the file-diff section (every committed, uncommitted and untracked change, each with a static fallback and a `@pierre/diffs` call that passes `oldFile`/`newFile`). `check` exits 1 when a dossier would show blank diffs (`patch:` used, `FileDiff` without `oldFile`/`newFile`, or an empty diff container). The worker preamble tells workers to run `check` before reporting `ready:`. |
| `kingpin curate` | `kingpin curate` | Aggregates critique files from finished worker tasks. |

### Internal helpers

Two scripts in `bin/` are not `kingpin` subcommands. `kingpin wait` calls them as it scans tasks (`kingpin-launch-check` for a task with an empty `status`, `kingpin-rename` when a task has new status lines); run them by hand only to debug.

- `bin/kingpin-launch-check <task-dir>`: finds a worker that died at launch (its `status` file is still empty). Once the task is older than the grace period (`KINGPIN_STATUS_GRACE`, 30 seconds, counted from the last stop or from launch) and its tmux window or pane is gone, or the Stop hook fired and the window stayed silent without a working marker, it appends and prints `failed: no status: ...`. Exits 0 when it recorded that line, 1 when it recorded nothing, 2 for a bad argument.
- `bin/kingpin-rename <task-id>`: renames the tmux window and `TMUX_TARGET` of a `--text` task to `kp-<n>-<slug>` once the worker has reported `issue: #<n>`. The task ID, folder, branch and worktree keep their first name. It is idempotent (a `renamed` marker in the task folder) and a no-op for tasks that already have an issue or no `issue:` line.

---

## Fleet Overview & Visual Review Dossiers

Kingpin is CLI-first for fleet monitoring and visual-first for code review:

### 1. Terminal Fleet Overview (`kingpin list`)

Monitor all active workers, leased worktrees, and current statuses:

```bash
kingpin list
```

When a task finishes in `review` mode, `kingpin list` displays its review dossier link directly below the task row.

`kingpin wait` wakes the orchestrator only for events that need action: a new status line other than the informational `issue:` line, a worker that stopped (`quiet`), or a window that is gone (`exited`). A worker whose last acknowledged status is `needs-input:` is not reported `quiet` again until its status or pane activity changes, and a task that `kingpin spawn` is still launching (its `launching` marker is fresh) is not reported `exited`.

A worker that stops without ever writing a status line (a harness that died at launch) is marked `failed: no status: <task> (<harness>) ...` by `kingpin wait`, and so by `kingpin watch` and `kingpin run`; `kingpin list` then shows that line instead of `(pending)`. "Stopped" means the tmux window or pane is gone, or the Stop hook fired and the window stayed silent for the grace period without showing a working marker (such as a wait on background agents). The grace period is 30 seconds from launch (or from the last stop), and `KINGPIN_STATUS_GRACE` sets it in seconds. A worker that is only slow to start is left alone. `kingpin peek <task-id>` shows the pane while the window is open, and `kingpin done <task-id>` releases the worktree.

To see why a worker is quiet or stuck, look at the tail of its pane without touching it:

```bash
kingpin peek <task-id>              # last 20 non-empty lines
kingpin peek <task-id> --lines 50   # more context
```

To pick up merged changes in the main checkout, fast-forward it without raw git:

```bash
kingpin sync    # old..new short SHAs and the commits pulled, or "already up to date"
```

Finished tasks are archived by `kingpin done` and hidden from `kingpin list`; run `kingpin list --all` to include them. `kingpin curate` still collects skill critiques from archived tasks.

### 2. Task Review Dossiers (`lavish-axi`)

When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. Open it with Lavish:

```bash
lavish-axi ~/.kingpin/tasks/<task-id>/report.html
```

Review the changes and click **Approve & Land** on the dossier or run:

```bash
kingpin land <task-id>
```


---

## Worker permissions

**What a Claude Code worker may edit.** A worker runs in its own leased worktree with every tool. `worker/hooks.json` adds a `PreToolUse` hook (`kingpin guard hook worker`) for `Edit`, `Write` and `NotebookEdit`: it allows files inside the worker's worktree and its task folder (`~/.kingpin/tasks/<id>/`, where it writes `status`, `question.md` and `report.html`), and denies every other path, including the main checkout. The hook decides before the permission prompt or the auto-mode classifier, so these edits need no human approval. It does not sandbox `Bash`. The worktree it allows is pinned by `KINGPIN_WORKTREE` (set by the launch script) or by `WORKTREE=` in the task's `task.env`, never by the session's working directory, so a worker that `cd`s to the main checkout gains nothing and one that `cd`s to its task folder keeps its worktree. Both hooks fail closed: if `kingpin-guard` cannot run (for example `KINGPIN_ROOT` is unset), or the decision cannot be made (a payload it cannot read, a worker tool call with no file path, a worker with no resolvable worktree, or an orchestrator session whose working directory cannot be resolved to a git worktree), the edit is denied. The orchestrator hook decides on the session's checkout rather than the target, so a path-less call such as `Agent` is still allowed from a linked worktree.

**Why workers used to lose `Edit`, `Write` and `Agent` (issue #40).** Claude Code loads the main checkout's `.claude/settings.local.json` for its linked worktrees. The orchestrator guard used to be `permissions.deny` rules for `Edit`, `Write`, `NotebookEdit` and `Agent` in that file, so every worker started without those tools, and fell back to `Bash` heredocs that the auto-mode classifier sometimes denied. A deny rule beats any allow rule, so a worker cannot override it. To reproduce: in a throwaway repo, put those four deny rules in `.claude/settings.local.json` of the main checkout, add a linked worktree with `git worktree add`, and run `claude -p "List your tools"` in the worktree; the four tools are missing, and they come back when the file is moved away. The guard is now a hook that denies only when the session runs in the main checkout, or when it cannot resolve the session's directory to a git worktree (fail closed).

**Unblocking a worker.**
- *No `Edit`/`Write`/`Agent` tool:* run `kingpin guard check` in the main checkout. If it reports stale deny rules, run `kingpin guard install` (it removes them) and respawn the worker; a running session keeps the tool list it started with.
- *A `Bash` command denied as "dangerous":* the worker stops with `needs-input`. Approve the command in the worker's tmux window, or add a Bash permission rule with `/permissions`. Workers should edit with `Edit`/`Write`, which the hook allows.
- *An edit denied for being outside the worktree:* the path belongs to the main checkout or another place. Put that change in a task of its own.

## Multi-Harness Architecture

Each supported harness uses native configuration and hook mechanisms without dirtying repository tracking:

- **Claude Code**: Workspace trust in `~/.claude.json`. System prompt via `--append-system-prompt-file`. Turn end via `worker/hooks.json`.
- **Antigravity CLI**: Workspace trust in `~/.gemini/antigravity-cli/settings.json`. Rules in `.agents/rules/kingpin.md`. Turn end via `.agents/hooks.json`.
- **OpenCode**: Autonomous permissions in `.opencode/config.json`. Instructions in `.opencode/config.json`. Turn end via `.opencode/plugins/kingpin-stop.js`.

Kingpin-injected worktree configuration files (`.agents/rules/kingpin.md`, `.agents/hooks.json`, `.opencode/config.json`, `.opencode/plugins/package.json`, and `.opencode/plugins/kingpin-stop.js`) are added to `.git/info/exclude` in each leased worktree to guarantee zero uncommitted git pollution without hiding user-created artifacts in those directories.

`.gitignore` ignores `.agents/plans/`, `.agents/reports/` and `.agents/reviews/`. They hold local working artifacts (plans, implementation reports, reviews and prototype patches) that agents write while they work, so they are not tracked. Other files under `.agents/`, such as a PRD, stay trackable.

---

## Running Automated Tests

Run the lint and the full test suite from the repository root:

```bash
# Lint: bash -n + shellcheck over bin/*, lib/*.sh and tests/*.sh (config in .shellcheckrc),
# plus a check that every tests/test-*.sh is a leg of the CI matrix
./tests/lint.sh

# Every suite, one after the other
for s in tests/test-*.sh; do "./$s" || break; done
```

The suites, one file per feature (shared setup is in `tests/lib.sh`: private tmux server, scratch repo, helpers):

| Suite | Covers |
|---|---|
| `test-lifecycle.sh` | `init`, `list`, `watch` auto-lifecycle, `run`, tmux session targeting |
| `test-wait.sh` | `wait` and `ack`: blocking, wake filtering, exit codes |
| `test-lock.sh` | `lock`: lifecycle, collisions, stale locks, recorded harness |
| `test-curate.sh` | `curate` |
| `test-land.sh` | `land`: review-gate verdicts, fix pass, re-review, output wording |
| `test-done.sh` | `done`: refused cleanup, archive, slot guard, branch cleanup |
| `test-listen.sh` | `listen`: dossier opening, live listener, prompt routing |
| `test-send-peek.sh` | `send` and `peek` |
| `test-spawn.sh` | `spawn`: window ID tracking, descriptive slugs, pinned window names |
| `test-sync.sh` | `sync` |
| `test-launch-check.sh` | `kingpin-launch-check`: workers that die at launch |
| `test-status.sh` | `lib/status.sh`, the shared status protocol |
| `test-report.sh` | `report`: generated diffs are renderable, blank-diff reports are rejected |
| `test-harnesses.sh` | Multi-harness contract and isolation |
| `test-worker-settings.sh` | Orchestrator tool guard and worker edit boundary |
| `test-acceptance.sh` | 3-worker parallel concurrency and serial landing |

Run one suite with `./tests/test-<name>.sh`. Run suites one at a time in a checkout: `test-lifecycle.sh` and `test-acceptance.sh` briefly replace `bin/kingpin-send` with a stub (restored on exit), so a second suite that sends keys to a worker during that window hits the stub and fails. CI legs do not clash, since each runs in its own checkout.

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every PR and push to `main`. The suites need `git`, `tmux`, `node`, `treehouse` and a git identity (the suites set one themselves). They use fake agents, so no harness binary is required. A new suite needs a matrix leg; `./tests/lint.sh` fails until it has one.
