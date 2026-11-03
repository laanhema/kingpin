# CLI Command Reference

[Back to the README](../README.md).

## kingpin init

**Usage:** `kingpin init [name] [path] [--harness <name>] [--setup "<cmd>"]`

**Flags:** `--harness <name>`, `--setup "<cmd>"`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD`

`--setup` records the project's `SETUP_CMD`, which `kingpin spawn` runs in each new worktree before the harness launches (its output goes to the task's `setup.log`), and is the mechanism behind the "isolates dependencies" claim in the [README](../README.md).

## kingpin run

**Usage:** `kingpin run <proj> (--issue <n> | --text <req>) [--mode auto|review] [--id <task-id>] [--harness <name>]`

**Flags:** `--issue <n>`, `--text <req>`, `--mode review|auto`, `--id <task-id>`, `--harness <name>`

- `--issue`: an existing GitHub issue: the worker runs /issue-flow (review) or /do (auto)
- `--text`: a free-text request: the worker runs /create-issue first, then the same
- `--mode`: review (default) stops at a ready branch for the review; auto merges when green
- `--id`: task id; defaults to kp-<n>-<slug> (issue title) or kp-<slug> (request)
- `--harness`: worker harness: claude, agy, or opencode (overrides the project and the lock)

**Environment:** `KINGPIN_HOME` (its own); the `kingpin spawn` it runs reads the rest, listed under [kingpin spawn](#kingpin-spawn).

### Review mode

In `review` mode it exits 0 when the worker reports `ready:` and prints the dossier path. A worker blocked on a human (`needs-input:`, or the Stop hook's `waiting:` line) ends it with exit 0 too, printing where the question is.

### A window gone before a terminal line

A worker that reported a status line and whose window is gone before a terminal line ends it with exit 1 naming `exited` and the last status: the supervisor records the dead window in `seen_exited` and `run` stops on that marker. In `auto` mode that includes a `ready:` worker whose window died, because only the worker can finish the landing.

### Terminal status lines

`merged:`, `failed:` and `cleanup-refused:` keep the exits they had.

## kingpin watch

**Usage:** `kingpin watch [--once] [--interval <sec>]`

**Flags:** `--once`, `--interval <sec>`

**Environment:** `KINGPIN_HOME`, `KINGPIN_LAVISH`

### Each cycle

Each cycle also advances a project's landing queue whose holder released or is gone, so an ownerless queue recovers on its own, and re-arms a review task's dossier listener that died (missing or dead `listener.pid`) unless the reviewer ended the session, the task finished, a landing is under way, the task runs in `auto` mode, or its last worker event is not `ready:`/`fixed:`.

### `--interval`

`--interval` takes a whole number of seconds, at least 1 and at most nine digits; anything else exits 2, and a `kingpin wait` that fails is retried after one warning on stderr and a two-second pause, so an unusable fleet directory cannot spin the loop.

### The pidfile

It claims `~/.kingpin/supervisor.pid`, refuses a second copy with the running pid named, reclaims a pidfile left by a dead supervisor, and `--once` runs one pass without claiming it (that is the path `kingpin run` and the tests use). `kingpin wait` is the primitive it drives.

## kingpin spawn

**Usage:** `kingpin spawn <proj> (--issue <n> | --text <req>) [--mode review|auto] [--id <task-id>] [--harness <name>]`

**Flags:** `--issue <n>`, `--text <req>`, `--mode review|auto`, `--id <task-id>`, `--harness <name>`

- `--issue`: an existing GitHub issue: the worker runs /issue-flow (review) or /do (auto)
- `--text`: a free-text request: the worker runs /create-issue first, then the same
- `--mode`: review (default) stops at a ready branch for the review; auto merges when green
- `--id`: task id; defaults to kp-<n>-<slug> (issue title) or kp-<slug> (request)
- `--harness`: worker harness: claude, agy, or opencode (overrides the project and the lock)

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_AGY`, `KINGPIN_OPENCODE`, `KINGPIN_GH`; the `kingpin scope check` it runs reads `KINGPIN_ALLOW_GLOBAL_CONTRACT`.

### Window names

The window is pinned with `automatic-rename off` and `allow-rename off`, so ambient tmux settings and worker child commands cannot rename it; only `kingpin-wait` renames it.

### Task ID, branch and window

The task ID, branch (`kingpin/<id>`) and window share one slug: `kp-<n>-<slug>` from the issue title for `--issue`, `kp-<slug>` from the request for `--text` (`--id` overrides).

### `--text` tasks

For `--text`, `kingpin-wait` renames the window and `TMUX_TARGET` to `kp-<n>-<slug>` once the worker reports its issue; the task ID and branch keep the first name.

## kingpin list

**Usage:** `kingpin list [--all|-a]`

**Flags:** `--all`, `-a`

**Environment:** `KINGPIN_HOME`

`kingpin status` is the same command under its older name.

## kingpin send

**Usage:** `kingpin send <task-id> "<text>"`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SEND_DELAY`

## kingpin peek

**Usage:** `kingpin peek <task-id> [--lines N]`

**Flags:** `--lines N`

**Environment:** `KINGPIN_HOME`

### Finding the pane

It finds the pane from the recorded window ID (`TMUX_WINDOW_ID`), so it works after the window is renamed or moved, and falls back to `TMUX_TARGET` for older `task.env` files.

### Read-only

It sends no keys and changes no state. Exits 1 for an unknown task or a window that is gone, 2 for a bad argument.

### Why a worker is stuck

Use it to see why a worker is stuck (an unsubmitted pasted message, a usage-limit banner, a permission prompt).

## kingpin sync

**Usage:** `kingpin sync`

### Running it

Run it in the main checkout; it prints the old and new short SHAs plus the commits pulled, or `already up to date`.

### What it never does

It never merges, rebases, resets or stashes.

### Exit codes

Exits 1 with a message on stderr in a linked worktree, on a dirty tree (any `git status --porcelain` output; ignored files do not count), with a detached HEAD or no upstream, or when a fast-forward is not possible; 2 for an argument.

## kingpin listen

**Usage:** `kingpin listen <task-id> [--once] [--background]`

**Flags:** `--once`, `--background`

**Environment:** `KINGPIN_HOME`, `KINGPIN_LAVISH`

### Approve & Land

**Approve & Land** runs `kingpin land` and, once the gate accepts the line, appends an `approved:` note to the task's `status`; a task whose last worker event is not `ready:` or `fixed:` (or whose verdict `kingpin land` refuses) is answered with its current state, and records no approval.

### Request Changes

**Request Changes** appends the text to `feedback.md` plus a `feedback:` note, and both notes wake `kingpin wait`.

### An unreadable poll

A poll whose prompts the parser cannot read is parked as `unparsed-poll-*.txt` in the task directory and its `prompt:` values are still forwarded as feedback; a `feedback:` note that names a parked response means the poll could not be parsed, and the raw response is in that file.

### Background and one-shot listeners

`--background` starts one detached listener per task (concurrent launches start only one; pid in `listener.pid`, output in `listener.log`) and returns at once; `kingpin watch` starts it when a review-mode worker reports `ready:`. `--once` stops after one poll.

### Without Lavish

Without `lavish-axi` (or `KINGPIN_LAVISH`) it prints a note on stderr and exits 0.

### Exit codes and cleanup

Exits 1 for an unknown task or one without `report.html`, 2 for a bad argument. `kingpin done` stops the listener.

## kingpin wait

**Usage:** `kingpin wait [--timeout <sec>] [--once]`

**Flags:** `--timeout <sec>`, `--once`

**Environment:** `KINGPIN_HOME`

### Exit codes

Exits 0 on events and on a plain timeout (nothing printed); `--once` with no events exits 1; 2 for a bad argument.

### See also

See [Fleet Overview](fleet-overview.md#fleet-overview--visual-review-dossiers).

## kingpin ack

**Usage:** `kingpin ack <task-id>... | --all | --through <line>`

**Flags:** `--all`, `--through <line>`

**Environment:** `KINGPIN_HOME`

The cursor never moves backwards and is clamped to the file.

## kingpin land

**Usage:** `kingpin land <task-id>` (alias: `kingpin approve <task-id>`)

**Environment:** `KINGPIN_HOME`

### The review gate

The review gate fails closed: it reads `review=` from the worker's last `ready:` line whatever the field order, and only `APPROVE` lands.

### Fix passes

`APPROVE WITH NITS` and `NEEDS CHANGES` (any case; `NEEDS_CHANGES` and `NEEDS-CHANGES` too) run `/fix-findings` first and say so; landing continues after the worker reports `fixed:`.

### Unreadable verdicts

An unrecognized verdict, a line with no `review=` field (or an empty or repeated one), a `fixed:` line without a numeric `high=<n>`, or a `fixed:` line whose `review=` is not `APPROVE` prints the line it could not parse and exits 1 without taking the landing lock. When the review is clean it says that landing is starting.

### The project lane

The project lane is claimed atomically, so two concurrent runs for different tasks cannot both dispatch.

### A send failure

A `kingpin-send` failure (a dead worker window, for example) clears `landing_sent`, releases the project landing lock and exits 1, so the lane advances instead of wedging; if the release itself cannot take the lane's mutex it says so on stderr and names `kingpin done <id> --force`.

### Queued landings

A queued landing is skipped when the task is gone, archived, finished or already dispatched.

## kingpin done

**Usage:** `kingpin done <task-id> [--force]`

**Flags:** `--force`

**Environment:** `KINGPIN_HOME`, `KINGPIN_LAVISH`

### Single-flight cleanup

Cleanup is single-flight per task: a second run while one is in progress says so and exits 0, so two concurrent runs call `treehouse return` once and archive once.

### A refused cleanup

A failed `treehouse return` refuses the cleanup, names the worktree and treehouse's reason in the `cleanup-refused:` line, and leaves the record in `tasks/` instead of archiving a task whose lease is gone.

### The lease-lost marker

The supervisor still retries a refused cleanup, but a task whose lease was lost carries a `lease-lost` marker in its task directory, so every retry re-reports that refusal with no network call and no external command until the owner runs `kingpin done <task-id> --force`, which bypasses the marker and re-attempts the full cleanup.

### Default-branch resolution and the merge check

The merge check resolves the default branch from the remote's `HEAD` (a read-only `git ls-remote --symref`, when the remote is reachable), then `origin/HEAD`, then `origin/master`, then `origin/main`, then the checkout's own `HEAD`, and a failed `git fetch` is reported on stderr rather than read as an unmerged commit: cleanup still succeeds when the last-known refs prove the merge, and the refusal names the fetch failure when they cannot.

### Queue handoff

The handoff to the next queued task skips entries that can no longer land (gone, archived, finished or already dispatched) and lands the next live one.

### The worktree guard

Refuses, even with `--force`, when another unfinished task records the same worktree.

### Status lines and the listener

A refusal is recorded as a `cleanup-refused:` status line only for a finished task (`merged:`, `failed:`); a worker that may still be live keeps its last status (for example `needs-input:`), and the reason goes to stderr. `done` also stops the task's dossier listener, and `kingpin ack` of an archived task is a no-op that exits 0 with a note.

## kingpin lock

**Usage:** `kingpin lock [status|check|acquire [--harness <name>]|release|harness] [pid]`

**Flags:** `--harness <name>`; `[pid]` is a positional argument

**Environment:** `KINGPIN_HOME`, `KINGPIN_HARNESS`, `KINGPIN_LOCK_PID`

`acquire` also warns on stderr when no fleet supervisor is running. A numeric `[pid]` overrides the detected session pid, as does `KINGPIN_LOCK_PID`.

## kingpin guard

**Usage:** `kingpin guard [install|check|warn] [--dir <kingpin-checkout>]`

**Flags:** `--dir <kingpin-checkout>`

**Subcommand:** `kingpin guard hook <orchestrator|worker>` is the hook entry point.

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD`; `KINGPIN_TASK_DIR` and `KINGPIN_WORKTREE` are read by the `guard hook worker` entry point (`lib/guard-hook.mjs`).

## kingpin scope

**Usage:** `kingpin scope files|check --harness <claude|agy|opencode> --worktree <dir> [--preamble <file>]`

**Flags:** `--harness <claude|agy|opencode>`, `--worktree <dir>`, `--preamble <file>`

**Environment:** `KINGPIN_ALLOW_GLOBAL_CONTRACT`

### `check`

`check` exits 1 naming the file when any source carries the orchestrator contract, including a global file in your own config directory (`KINGPIN_ALLOW_GLOBAL_CONTRACT=1` downgrades that one to a warning), and, for OpenCode and agy, when the preamble is not among the sources the harness loads (Claude Code gets it through `--append-system-prompt-file`, which `check` does not verify); nothing is edited.

### Before a spawn

`kingpin spawn` runs `check` before it opens a window.

## kingpin report

**Usage:** `kingpin report diffs [--repo <dir>] [--base <ref>]` / `kingpin report check [--prose-only] <report.html>`

**Flags:** `--repo <dir>`, `--base <ref>`, `--prose-only`

### `diffs`

`diffs` prints the HTML for the file-diff section (every committed, uncommitted and untracked change, each with a static fallback and a `@pierre/diffs` call that passes `oldFile`/`newFile`).

### `check` and the layout pass

`check` exits 1 when a dossier would show blank diffs (`patch:` used, `FileDiff` without `oldFile`/`newFile`, or an empty diff container), and runs a layout pass over a full page: it fails, naming the line, on a `<pre>` or inline `code` with no wrap rule, an `<img>` with no `max-width` rule, a table whose cells have no wrap rule, a grid/flex layout with no `min-width: 0` or `minmax(0, ...)` guard, and a `src`/`href`/`url()` that is an absolute path or climbs out with `..`.

### The prose pass

It also runs a prose pass over the page: it fails with `file:line` and the offending line on the mechanical slice of the `unslop` skill (em dash, "testament to", "it's not just", "delve", "seamless", "in order to", "let me know", "I hope this helps"), ignoring code, diff output, script/style bodies and attributes. `<!-- unslop:ignore -->` on a line is the single escape.

### `--prose-only`

`--prose-only` runs everything but the diff section (the layout and prose passes), for an artifact with no diff section.

### Required before `ready:`

The worker preamble and `AGENTS.md` require both the pass and the check before `ready:` and before an orchestrator artifact is served.

## kingpin curate

**Usage:** `kingpin curate [--dry-run]`

**Flags:** `--dry-run`

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_CURATOR_CMD`, `KINGPIN_SKILLS_DIR`

### Trust and `--help`

It records trust for that directory with the same helper `kingpin spawn` uses, so the first run on an untrusted host shows no folder-trust dialog; `--help` prints usage without launching anything, and an unknown flag exits 2.

### Reaping a dead curator

A curator window whose panes have all exited is reaped instead of reported as `already active`, so a failed launch cannot block the next run.

### Consumed critiques

A critique applied by a successful run is stamped beside the file (`critique.consumed`) and is not collected again, including after `kingpin done` archives the task; a critique rewritten while the curator is running is left pending, so the next run collects the new bytes. A failed, reaped or non-zero run leaves every critique pending.

### `--dry-run`

`--dry-run` writes no file and leaves the previous run's `curator-input.txt`, `batch-critiques.txt` and `launch.sh` byte-identical.

### Serialized runs

Concurrent runs are serialized, so one curator is published and launched at a time.

## Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `KINGPIN_HOME` | every fleet command | Fleet state directory (default `~/.kingpin`): `tasks/`, `archive/`, `projects/`, `locks/`, `supervisor.pid` and `config.env`. |
| `KINGPIN_HARNESS` | `bin/kingpin-lock:104` | Harness recorded by `lock acquire` when `--harness` is omitted (before the command-name and agent-marker detection). |
| `KINGPIN_CLAUDE` | `bin/kingpin-spawn:32` | Command `spawn` launches for the `claude` harness (default `claude`). |
| `KINGPIN_AGY` | `bin/kingpin-spawn:33` | Command `spawn` launches for the `agy` harness (default `agy`). |
| `KINGPIN_OPENCODE` | `bin/kingpin-spawn:34` | Command `spawn` launches for the `opencode` harness (default `opencode`). |
| `KINGPIN_GH` | `bin/kingpin-spawn:35` | `gh` command `spawn` uses to read an issue title for the task slug (default `gh`). |
| `KINGPIN_SEND_DELAY` | `bin/kingpin-send:60` | Seconds between the literal text and the Enter key (default `0.2`). |
| `KINGPIN_CURATOR_CMD` | `bin/kingpin-curate:14` | Command `curate` launches the curator with; falls back to `KINGPIN_CLAUDE`, then `claude`. |
| `KINGPIN_SKILLS_DIR` | `bin/kingpin-curate:13` | Skills directory the curator works in (default `~/.claude/skills`). |
| `KINGPIN_LAVISH` | `bin/kingpin-listen:58` | `lavish-axi` command the listener drives (default `lavish-axi`). |
| `KINGPIN_STATUS_GRACE` | `bin/kingpin-launch-check:44` | Seconds a worker may stay silent before `wait`/`watch`/`run` record `failed: no status:` (default `30`). |
| `KINGPIN_ALLOW_GLOBAL_CONTRACT` | `bin/kingpin-scope` | `1` downgrades a contract found in a global instruction file to a warning instead of a refusal. |
| `KINGPIN_SKIP_GUARD` | `bin/kingpin-guard:54`, `bin/kingpin-init:82` | `1` skips the guard install and warning; set by the test suites and scripted setups. |
| `KINGPIN_LOCK_PID` | `bin/kingpin-lock:161` | A whole-number pid `lock acquire` records as the session pid instead of detecting one; the test suites use it. |
| `KINGPIN_TASK_DIR` | `bin/kingpin-stop:31`, `worker/hooks.json:19` | Set by `kingpin spawn` to the task folder (`~/.kingpin/tasks/<id>`) so the Stop hook can write `status`. Not for hand-setting. |
| `KINGPIN_ROOT` | `worker/hooks.json:9-19`, `bin/kingpin-spawn:329` | Set by `kingpin spawn` to the Kingpin checkout, so a hook finds `bin/kingpin-stop` even after the worker `cd`s elsewhere. Not for hand-setting. |
| `KINGPIN_WORKTREE` | `lib/guard-hook.mjs:109,153` | Set by `kingpin spawn` to the leased worktree; the worker's `PreToolUse` hook allows edits only inside it and the task folder. Not for hand-setting. |

## Internal helpers

Two scripts in `bin/` are not `kingpin` subcommands. `kingpin wait` calls them as it scans tasks (`kingpin-launch-check` for a task with an empty `status`, `kingpin-rename` when a task has new status lines); run them by hand only to debug.

- `bin/kingpin-launch-check <task-dir>`: finds a worker that died at launch (its `status` file is still empty). Once the task is older than the grace period (`KINGPIN_STATUS_GRACE`, 30 seconds, counted from the last stop or from launch) and its tmux window or pane is gone, or the Stop hook fired and the window stayed silent without a working marker, it appends and prints `failed: no status: ...`. Exits 0 when it recorded that line, 1 when it recorded nothing, 2 for a bad argument.
- `bin/kingpin-rename <task-id>`: renames the tmux window and `TMUX_TARGET` of a `--text` task to `kp-<n>-<slug>` once the worker has reported `issue: #<n>`. The task ID, folder, branch and worktree keep their first name. It is idempotent (a `renamed` marker in the task folder) and a no-op for tasks that already have an issue or no `issue:` line.
