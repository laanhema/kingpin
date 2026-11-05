# Kingpin

<p align="center">
  <img src="assets/kingpin.jpg" alt="Kingpin" width="700">
</p>

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in parallel git worktrees, isolates dependencies, prevents git pollution, serializes landing queues, and hands each task to you as a visual review dossier.

Kingpin supports **Claude Code**, **Antigravity CLI (agy)**, **OpenCode**, **Pi**, and **Codex** (OpenAI Codex CLI).

## The Ranks

The fleet runs on a four-rank fiction that lives in conversation. The **kingpin** is the user, who owns the jobs and the final word. The **underboss** is the orchestrator session: it plans jobs, sends out capos, reads dossiers, lands work and never touches code. A **caporegime** (capo) is one spawned worker running one job end to end in its own worktree. A **soldier** is a subagent a capo sends out under the label `Soldier: <job>`.

The voice stays in the room. Commits, PRs, issues, code, status fields, review reports and dossiers stay neutral and machine-readable.

## Prerequisites

Ensure the following tools are installed on your host:

- `git` (2.30+)
- `tmux` (required today: `kingpin spawn` still creates tmux workers) or `herdr` (adapter in place; worker creation lands with issue #144 phase E)
- `treehouse` (git worktree pool manager)
- `node` (18+; Pi needs Node 22.19+)
- At least one worker harness:
  - `claude` (Claude Code)
  - `agy` (Google Antigravity CLI)
  - `opencode` (OpenCode CLI)
  - `pi` (Pi coding agent: `npm i -g @earendil-works/pi-coding-agent`)
  - `codex` (OpenAI Codex CLI, 0.166.0)

A Pi worker needs a model login done by hand: run `pi`, then `/login`, then `/model`. Kingpin does not provision credentials; it passes `PI_PROVIDER` and `PI_MODEL` from the project env only when they are set. A codex worker needs `codex login` done by hand for the same reason: Kingpin stores no credentials and pins no provider or model, so the worker runs on whatever account your own `codex` is logged into. `kingpin scope doctor --harness codex` prints the binary, what `codex login status` reports, the config store and the skills directory before you spawn.

Optional:
- **`lavish-axi` (HIGHLY RECOMMENDED):** per-task review dossiers and their interactive actions. Kingpin hands every task back as a visual dossier, and this is what renders it.
- `shellcheck` (contributors only, for `./tests/lint.sh`; `pip install shellcheck-py==0.11.0.1` into a venv, which is the version CI pins, or your package manager at shellcheck 0.11.0)

## Quick Start (Two Commands)

Add Kingpin to your `PATH`:

```bash
export PATH="/path/to/kingpin/bin:$PATH"
```

Replace `/path/to/kingpin` with the directory you cloned Kingpin into.

### 1. Initialize your project (run once inside any git repository)

```bash
cd /path/to/my-repo
kingpin init
```

Kingpin detects the git repository, writes `~/.kingpin/projects/my-repo.env`, and installs the orchestrator tool guard (`kingpin guard install`), which keeps an orchestrator session in the checkout from editing code while a linked worktree keeps every tool (see [Worker permissions](#worker-permissions)).

The same install writes the orchestrator contract, tracked once as `orchestrator/contract.md`, so an orchestrator session reads its job description without any worker seeing it. Only `kingpin guard install` or `kingpin init` refreshes a copy, so a checkout that upgrades across a contract change runs one. `kingpin guard check` names a stale copy, and what the hook denies and what `install` writes is in [`kingpin guard`](docs/cli.md#kingpin-guard).

You can pin a harness for the project:

```bash
kingpin init --harness agy
```

Without `--harness`, no `HARNESS` is written and the project follows the default harness below.

### Which harness a worker uses

`kingpin spawn` follows `--harness <name>`, then the project's `HARNESS`, then the harness the orchestrator lock recorded, then `DEFAULT_HARNESS` in `~/.kingpin/config.env`, then `claude`; `kingpin lock acquire` records the orchestrator's own harness, so a worker matches the session you are in. The full order, how `acquire` detects a harness and the lock's refusals are in [`kingpin spawn`](docs/cli.md#kingpin-spawn) and [`kingpin lock`](docs/cli.md#kingpin-lock).

### 2. Run a task to completion in one command

```bash
# Auto mode: spawns, monitors, auto-lands when green, merges, and cleans up
kingpin run my-repo --issue 42 --mode auto

# Review mode: spawns, monitors, and stops at ready with your review report link
kingpin run my-repo --text "refactor authentication service" --harness agy
```

## Automated Fleet Supervision (`kingpin watch`)

`kingpin watch` is the fleet's supervisor: one process per fleet, started once and left running, in the background or in a separate terminal:

```bash
kingpin watch >> ~/.kingpin/supervisor.log 2>&1 &
```

It loops, so it keeps handling events after it handles one; there is nothing to restart each turn. It:
- Automatically triggers `kingpin land` for workers in `auto` mode when they report `ready:`, and continues a landing after `fixed:` only when the review gate allows it. [`kingpin land`](docs/cli.md#fix-passes) has the gate and the fix pass.
- Automatically triggers `kingpin done` when workers report `merged:`, releasing worktrees back to the treehouse pool.
- Notifies when tasks in `review` mode are ready for inspection or need input.
- Advances a project's landing queue whose holder released or is gone.
- Re-arms a review task's dossier listener that died, so a reviewer's clicks always reach a session someone reads.
- Lands a clean review verdict while AFK is armed, so a fleet you step away from does not wait on a click. A findings verdict still runs the fix pass first, and the clean landing that follows carries the same note; a `needs-input:`, `cleanup-refused:` or `failed:` task waits for you. [`kingpin afk`](docs/cli.md#kingpin-afk) has the exact rule.

Only one supervisor runs at a time. A second `kingpin watch` refuses to start and names the running pid, and `kingpin lock acquire` warns when none is running. `kingpin list` prints `Supervisor: running (pid 12345, since 14:03)` or `Supervisor: none - run kingpin watch`. [`kingpin watch`](docs/cli.md#kingpin-watch) has the pidfile, `--once` and the interval rules.

`kingpin afk on [--ttl <duration>]` arms auto-landing for this session, `kingpin afk off` disarms it, and `kingpin afk status` reports it. The default TTL is 8 hours, and `--ttl` changes it; the arm reads as off once the TTL passes or the session pid is gone. [`kingpin afk`](docs/cli.md#kingpin-afk) has the status note and the thresholds.

## CLI Command Reference

| Command | Description |
|---|---|
| `kingpin init` | Auto-configures a project from current directory or path. [Details](docs/cli.md#kingpin-init) |
| `kingpin run` | Single command that spawns, monitors, and completes a task. [Details](docs/cli.md#kingpin-run) |
| `kingpin watch` | The fleet's one supervisor: a continuous supervision and auto-landing loop. [Details](docs/cli.md#kingpin-watch) |
| `kingpin afk` | Arms session-scoped auto-landing while you are away: a clean review verdict lands, and anything that needs a human waits. Default TTL 8h. [Details](docs/cli.md#kingpin-afk) |
| `kingpin spawn` | Starts a worker in a background tmux window on the fleet's own server, in a leased worktree; the session is resolved, never guessed. [Details](docs/cli.md#kingpin-spawn) |
| `kingpin list` | Displays the live fleet: each task's state, session and window, the browser daemons it holds, its dossier link, and whether the supervisor is running; `--all` (or `-a`) also shows finished tasks. [Details](docs/cli.md#kingpin-list) |
| `kingpin send` | Types the text literally into a worker's window, then presses Enter. [Details](docs/cli.md#kingpin-send) |
| `kingpin peek` | Read-only view of a worker's terminal: the last 20 non-empty lines of its pane, scrollback included (`--lines N` changes the count). [Details](docs/cli.md#kingpin-peek) |
| `kingpin sync` | Fast-forwards the main checkout from its upstream branch with `git pull --ff-only`, so the orchestrator never runs raw git against project files. It refuses rather than discarding, and names every untracked path it refuses to overwrite. [Details](docs/cli.md#kingpin-sync) |
| `kingpin listen` | Keeps a Lavish listener attached to a task's review dossier (`report.html`): opens the dossier once, then polls it and routes what the reviewer does. [Details](docs/cli.md#kingpin-listen) |
| `kingpin wait` | Prints one `<task-id> <reason>` line per fleet event that needs action. [Details](docs/cli.md#kingpin-wait) |
| `kingpin ack` | Marks a task's events as seen, so `kingpin wait` reports only newer ones. [Details](docs/cli.md#kingpin-ack) |
| `kingpin land` | Serializes project landing and triggers merge. [Details](docs/cli.md#kingpin-land) |
| `kingpin done` | Verifies the merge, then cleans up the task's window, browser daemons and worktree lease, deletes its branches, closes the issue it names, and archives the record. [Details](docs/cli.md#kingpin-done) |
| `kingpin restore` | Brings every live task's window back after a tmux server restart, in its own worktree and on its own branch. [Details](docs/cli.md#kingpin-restore) |
| `kingpin lock` | Enforces a single active orchestrator session and records its harness for `kingpin spawn`. [Details](docs/cli.md#kingpin-lock) |
| `kingpin guard` | Installs or verifies the orchestrator-only tool guard and the orchestrator contract in the main checkout. [Details](docs/cli.md#kingpin-guard) |
| `kingpin scope` | Names the instruction files a harness really loads for a worker, and checks a harness's readiness. [Details](docs/cli.md#kingpin-scope) |
| `kingpin report` | Dossier helper for workers. [Details](docs/cli.md#kingpin-report) |
| `kingpin curate` | Runs one curator over the critiques of finished tasks and hands the result back as a review PR. [Details](docs/cli.md#kingpin-curate) |

Every command prints its usage on `--help` and exits 0, an unknown flag exits non-zero, and [`docs/cli.md`](docs/cli.md#conventions) is the reference for flags, refusals and exit codes.

## Fleet Overview & Visual Review Dossiers

Kingpin is CLI-first for fleet monitoring and visual-first for code review. For any live task whose folder holds a `report.html`, whatever its mode or status, `kingpin list` prints the dossier line directly below the task row: the recorded Lavish session URL, or the `lavish-axi <path>` command when none is recorded. It carries `(listening: pid <n>)` while that task's listener runs; finished and archived rows show no dossier line. When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. The full overview, including terminal monitoring, review dossiers and the noir dossier template, is in [docs/fleet-overview.md](docs/fleet-overview.md).

The prose gate covers markdown as well as the dossier. `kingpin report check --prose-only <file>.md` applies the same `unslop` rule list to a review report under `.agents/reviews/` before it is handed back, and to an issue or pull-request body written to a `.md` file before `gh ... --body-file` files it. Fenced and indented code, inline code spans and HTML comments are ignored; `<!-- unslop:ignore -->` is the single escape.

## Worker permissions

A worker runs in its own leased worktree with every tool. `worker/hooks.json` adds a `PreToolUse` hook (`kingpin guard hook worker`) for `Edit`, `Write` and `NotebookEdit`: it allows files inside the worker's worktree and its task folder (`~/.kingpin/tasks/<id>/`, where it writes `status`, `question.md` and `report.html`), and denies every other path, including the main checkout. The full permission model, including why workers used to lose tools and how to unblock one, is in [docs/worker-permissions.md](docs/worker-permissions.md).

## Multi-Harness Architecture

Each supported harness uses native configuration and hook mechanisms without dirtying repository tracking. `bin/kingpin-scope` (`kingpin scope files`) lists the instruction files a harness really loads for a worktree, and `kingpin scope check` exits 1 naming the file when one of them carries the contract; `kingpin spawn` runs it before it opens a window. The per-harness wiring and the worktree exclude rules are in [docs/harnesses.md](docs/harnesses.md).

## Running Automated Tests

Run the lint and the full test suite from the repository root: [docs/testing.md](docs/testing.md).
