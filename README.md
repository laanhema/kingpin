# Kingpin

<p align="center">
  <img src="assets/kingpin.jpg" alt="Kingpin" width="700">
</p>

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in parallel git worktrees, isolates dependencies, prevents git pollution, serializes landing queues, and hands each task to you as a visual review dossier.

Kingpin supports **Claude Code**, **Antigravity CLI (agy)**, **OpenCode**, and **Pi**.

## The Ranks

The fleet runs on a four-rank fiction that lives in conversation. The **kingpin** is the user, who owns the jobs and the final word. The **underboss** is the orchestrator session: it plans jobs, sends out capos, reads dossiers, lands work and never touches code. A **caporegime** (capo) is one spawned worker running one job end to end in its own worktree. A **soldier** is a subagent a capo sends out under the label `Soldier: <job>`.

The voice stays in the room. Commits, PRs, issues, code, status fields, review reports and dossiers stay neutral and machine-readable.

## Prerequisites

Ensure the following tools are installed on your host:

- `git` (2.30+)
- `tmux`
- `treehouse` (git worktree pool manager)
- `node` (18+; Pi needs Node 22.19+)
- At least one worker harness:
  - `claude` (Claude Code)
  - `agy` (Google Antigravity CLI)
  - `opencode` (OpenCode CLI)
  - `pi` (Pi coding agent: `npm i -g @earendil-works/pi-coding-agent`)

A Pi worker needs a model login done by hand: run `pi`, then `/login`, then `/model`. Kingpin does not provision credentials; it passes `PI_PROVIDER` and `PI_MODEL` from the project env only when they are set.

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

Kingpin detects the git repository and writes `~/.kingpin/projects/my-repo.env` automatically. It also installs the orchestrator tool guard (`kingpin guard install`): a `PreToolUse` hook in the untracked `.claude/settings.local.json` of the Kingpin checkout denies `Edit`, `Write`, `NotebookEdit` and `Agent` when the session's working directory is the main checkout of any git repository, not only the Kingpin checkout, so only the orchestrator session is restricted and a linked worktree keeps full tooling. The hook judges the session's working directory because Claude Code also loads that file for its linked worktrees (see [Worker permissions](#worker-permissions)).

The same install writes the orchestrator contract, so an orchestrator session reads its job description without any worker seeing it. The text is tracked once, as `orchestrator/contract.md`, and generated into `~/.kingpin/orchestrator.md` plus three untracked copies in the Kingpin checkout: `.claude/rules/kingpin-orchestrator.md`, `.agents/rules/kingpin.md`, and the `instructions` entry of `.opencode/opencode.json`. Only `kingpin guard install` writes them: `kingpin spawn` and `kingpin sync` never refresh a copy, so a checkout that upgrades across a contract change needs one `kingpin init` or `kingpin guard install`. `kingpin guard check` names a stale copy; `kingpin list` and `kingpin wait` print its warning through `kingpin guard warn`, which `KINGPIN_SKIP_GUARD=1` silences; `kingpin lock acquire` runs `kingpin guard check` itself, so it warns even with that variable set.

You can pin a harness for the project:

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

`kingpin lock acquire` finds the harness in this order: `--harness <name>` on `acquire`, the `KINGPIN_HARNESS` environment variable, the command name or argv of the session process (`claude`, `agy`, `opencode`, `pi`, including the `@earendil-works/pi-coding-agent` npm path), then the calling agent's own marker (`CLAUDECODE=1`, `OPENCODE=1`). A session that matches none records nothing. `acquire` and `release` are serialized by a sibling `orchestrator.lock.mutex`, so sessions that start together get one `lock: acquired` and the rest exit 1 naming the holder, and the lock file is renamed into place whole, so `status`, `check` and `harness` never read a half-written file. `kingpin lock release` drops only the calling session's record and refuses, naming the holder, while another live session holds the lock; the record is ignored once the holder process is gone. Project files written by older versions of `kingpin init` contain `HARNESS=claude`, which counts as set; delete that line to let the lock holder decide.

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
- Automatically triggers `kingpin land` for workers in `auto` mode when they report `ready:`, and continues a landing after `fixed:` only when that line reports `high=0`; a `fixed:` line with High findings still open is sent back for `/review` first.
- Automatically triggers `kingpin done` when workers report `merged:`, releasing worktrees back to the treehouse pool.
- Notifies when tasks in `review` mode are ready for inspection or need input.
- Advances a project's landing queue whose holder released or is gone.
- Re-arms a review task's dossier listener that died, so a reviewer's clicks always reach a session someone reads.
- Lands a clean review verdict while AFK is armed, so a fleet you step away from does not wait on a click. A findings verdict still runs the fix pass first, and the clean landing that follows carries the same note; a `needs-input:`, `cleanup-refused:` or `failed:` task waits for you.

Only one supervisor runs at a time. A second `kingpin watch` refuses to start and names the running pid (recorded in `~/.kingpin/supervisor.pid`), and a pidfile left by a supervisor that died is reclaimed by the next one. `kingpin list` prints `Supervisor: running (pid 12345, since 14:03)` or `Supervisor: none - run kingpin watch`, and `kingpin lock acquire` warns when none is running. `kingpin watch --once` runs a single pass without claiming the pidfile; `kingpin wait` is the one-shot primitive underneath, for scripts that want to read fleet events themselves.

`kingpin afk on [--ttl <duration>]` arms auto-landing for this session, `kingpin afk off` disarms it, and `kingpin afk status` reports it. The default TTL is 8 hours (`--ttl 90m`, `8h` or `1h30m` change it). The arm is session-scoped at `~/.kingpin/afk`, it reads as off once the TTL passes or the session pid is gone, `kingpin lock release` clears it, and `kingpin list` prints `AFK: on until 16:40 (pid 12345)` only while it is live. While armed, a clean review verdict is landed through `kingpin land` and the task status gains `approved: auto (afk)`; findings still run the fix pass, and questions, refused cleanups and failures wait for a human.

## CLI Command Reference

| Command | Description |
|---|---|
| `kingpin init` | Auto-configures a project from current directory or path. [Details](docs/cli.md#kingpin-init) |
| `kingpin run` | Single command that spawns, monitors, and completes a task. [Details](docs/cli.md#kingpin-run) |
| `kingpin watch` | The fleet's one supervisor: a continuous supervision and auto-landing loop. [Details](docs/cli.md#kingpin-watch) |
| `kingpin afk` | Arms session-scoped auto-landing while you are away: a clean review verdict is landed through `kingpin land` and gains `approved: auto (afk)`, while findings run the fix pass and questions, refused cleanups and failures wait. Default TTL 8h, cleared by `kingpin lock release`. [Details](docs/cli.md#kingpin-afk) |
| `kingpin spawn` | Starts a worker on a background tmux window and records its tmux window ID (`TMUX_WINDOW_ID` in `task.env`), so renaming a worker window or moving it to another session is safe; `task.env` files without it fall back to `TMUX_TARGET`. With no tmux client it uses the target it was given, the attached session, or refuses when several sessions are unattached, instead of creating a `kingpin` session silently. [Details](docs/cli.md#kingpin-spawn) |
| `kingpin list` | Displays active fleet tasks and states in the terminal: a `STATE` column (`WAITING`, `SILENT`, `Unseen: N`) and a `SESSION` column naming the tmux session each worker's window lives in, plus a `Supervisor: running (pid <n>, since <HH:MM>)` or `Supervisor: none - run kingpin watch` line; `--all` (or `-a`) also shows finished (archived) tasks. A finished task's leftover dossier link is never listed as live. [Details](docs/cli.md#kingpin-list) |
| `kingpin send` | Types the text literally into a worker window, then presses Enter. [Details](docs/cli.md#kingpin-send) |
| `kingpin peek` | Read-only view of a worker: prints the last 20 non-empty lines of its tmux pane (`--lines N` changes the count), scrollback included. [Details](docs/cli.md#kingpin-peek) |
| `kingpin sync` | Fast-forwards the main checkout from its upstream branch with `git pull --ff-only`, so the orchestrator never runs raw git against project files. A tracked change blocks it; an untracked file, such as a `.lavish/` handover page, does not, unless the incoming tree would overwrite it, which is refused with every path named and nothing changed. [Details](docs/cli.md#kingpin-sync) |
| `kingpin listen` | Keeps a Lavish listener attached to a task's review dossier (`report.html`): opens the dossier once, then polls it and routes what the reviewer does. [Details](docs/cli.md#kingpin-listen) |
| `kingpin wait` | Prints one `<task-id> <reason>` line (`status`, `quiet` or `exited`) per fleet event that needs action. [Details](docs/cli.md#kingpin-wait) |
| `kingpin ack` | Marks a task's events as seen, so `kingpin wait` reports only newer ones; `--through <line>` sets the seen cursor to that line instead of the file's length, for a caller that dispatches a batch one line at a time (`kingpin-watch`). [Details](docs/cli.md#kingpin-ack) |
| `kingpin land` | Serializes project landing and triggers merge. [Details](docs/cli.md#kingpin-land) |
| `kingpin done` | Verifies merge, kills the task's tmux window, releases the worktree lease, deletes the worker's local branch with `git branch -D` and, once the merge check passes, that branch on `origin`, advances the queue, and archives the task record to `~/.kingpin/archive/<task-id>`, or the next free `<task-id>.<n>` when that name is taken, leaving a link at the old task path so an open dossier keeps resolving, and closing its Lavish session with one final reply. [Details](docs/cli.md#kingpin-done) |
| `kingpin lock` | Enforces a single active orchestrator session and records its harness for `kingpin spawn`. [Details](docs/cli.md#kingpin-lock) |
| `kingpin guard` | `kingpin guard [install\|check\|warn]` | Installs or verifies the orchestrator-only tool guard, a `PreToolUse` hook in `.claude/settings.local.json` (untracked), and the orchestrator contract described under [Initialize your project](#1-initialize-your-project-run-once-inside-any-git-repository); `install` also removes the deny rules that older versions wrote there, which leaked into workers, and keeps its three main-checkout contract excludes in a `# kingpin guard` … `# end kingpin guard` block of `.git/info/exclude`, which it rewrites on every run (adopting a loose line an older version appended), so that block is the only part of the file `install` rewrites; it may also append a plain `.claude/settings.local.json` line outside the block when the project does not already ignore that file; `--dir` points the command at another checkout instead of the one `bin/kingpin-guard` lives in; `check` names a stale contract copy; `warn` prints a stderr warning when the guard or the contract is missing or stale; `kingpin guard hook <orchestrator\|worker>` is the hook entry point; `list` and `wait` run it at startup, and `lock acquire` prints the same warning. |
| `kingpin scope` | Names the instruction files a harness really loads for a worker: `files` prints `<kind>\t<path>` per source (`discovery`, a file the harness finds; `configured`, an `instructions` entry of the worktree's config, JSONC included; `ignored`, a rules file the harness skips; `global`, loaded from the user's config directory); `doctor --harness pi` reports the Pi binary, credentials, skills and extension in one command. [Details](docs/cli.md#kingpin-scope) |
| `kingpin report` | Dossier helper for workers. [Details](docs/cli.md#kingpin-report) |
| `kingpin curate` | Aggregates critique files from finished worker tasks and runs one curator in the skills checkout: default `~/.claude/skills`, `KINGPIN_SKILLS_DIR` overrides it, and the curator command is `KINGPIN_CURATOR_CMD`, else `KINGPIN_CLAUDE`, else `claude`, so an agy- or OpenCode-only host must set both. The curator commits on `curator/<date>`, opens a PR, and reports `ready:` for review; `kingpin land curator` merges it. `--dry-run` lists the batch, `--auto` is the daily idle-fleet trigger `kingpin watch` and `kingpin done` run, `--mark-applied <pr-url>` records the applied batch, and `--land` merges and archives. [Details](docs/cli.md#kingpin-curate) |

Every command in the table exits 0 and prints its usage on `--help` (or `-h`), and an unknown flag exits non-zero: `kingpin curate --help` prints usage without launching a curator, and `kingpin run --help` prints `spawn`'s usage without starting a worker. `kingpin <command> --help` is the fastest way to see one command's flags.

## Fleet Overview & Visual Review Dossiers

Kingpin is CLI-first for fleet monitoring and visual-first for code review. For any live task whose folder holds a `report.html`, whatever its mode or status, `kingpin list` prints the dossier line directly below the task row: the recorded Lavish session URL, or the `lavish-axi <path>` command when none is recorded. It carries `(listening: pid <n>)` while that task's listener runs; finished and archived rows show no dossier line. When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. The full overview, including terminal monitoring, review dossiers and the noir dossier template, is in [docs/fleet-overview.md](docs/fleet-overview.md).

The prose gate covers markdown as well as the dossier. `kingpin report check --prose-only <file>.md` applies the same `unslop` rule list to a review report under `.agents/reviews/` before it is handed back, and to an issue or pull-request body written to a `.md` file before `gh ... --body-file` files it. Fenced and indented code, inline code spans and HTML comments are ignored; `<!-- unslop:ignore -->` is the single escape.

## Worker permissions

A worker runs in its own leased worktree with every tool. `worker/hooks.json` adds a `PreToolUse` hook (`kingpin guard hook worker`) for `Edit`, `Write` and `NotebookEdit`: it allows files inside the worker's worktree and its task folder (`~/.kingpin/tasks/<id>/`, where it writes `status`, `question.md` and `report.html`), and denies every other path, including the main checkout. The full permission model, including why workers used to lose tools and how to unblock one, is in [docs/worker-permissions.md](docs/worker-permissions.md).

## Multi-Harness Architecture

Each supported harness uses native configuration and hook mechanisms without dirtying repository tracking. `bin/kingpin-scope` (`kingpin scope files`) lists the instruction files a harness really loads for a worktree, and `kingpin scope check` exits 1 naming the file when one of them carries the contract; `kingpin spawn` runs it before it opens a window. The per-harness wiring and the worktree exclude rules are in [docs/harnesses.md](docs/harnesses.md).

## Running Automated Tests

Run the lint and the full test suite from the repository root: [docs/testing.md](docs/testing.md).
