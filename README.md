# Kingpin

<p align="center">
  <img src="assets/kingpin.jpg" alt="Kingpin" width="700">
</p>

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in parallel git worktrees, isolates dependencies, prevents git pollution, serializes landing queues, and serves a live dark-mode fleet board.

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
- `lavish-axi` (for real-time fleet board serving and interactive actions)

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

Kingpin detects the git repository and writes `~/.kingpin/projects/my-repo.env` automatically. You can specify a default harness:

```bash
kingpin init --harness agy
```

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
| `kingpin spawn` | `kingpin spawn <proj> (--issue <n> \| --text <req>) [--harness <name>]` | Starts a worker on a background tmux window. |
| `kingpin board` | `kingpin board [--out <path>]` | Renders the live fleet status HTML board. |
| `kingpin list` | `kingpin list` | Displays active fleet tasks and states in the terminal. |
| `kingpin send` | `kingpin send <task-id> "<keys>"` | Sends input or answers to a worker window. |
| `kingpin land` | `kingpin land <task-id>` | Serializes project landing and triggers merge. |
| `kingpin done` | `kingpin done <task-id> [--force]` | Verifies merge, releases worktree lease, and advances queue. |
| `kingpin lock` | `kingpin lock check` | Enforces single active orchestrator session. |
| `kingpin curate` | `kingpin curate` | Aggregates critique files from finished worker tasks. |

---

## Fleet Overview & Visual Review Dossiers

Kingpin is CLI-first for fleet monitoring and visual-first for code review:

### 1. Terminal Fleet Overview (`kingpin list`)

Monitor all active workers, leased worktrees, and current statuses:

```bash
kingpin list
```

When a task finishes in `review` mode, `kingpin list` displays its review dossier link directly below the task row.

### 2. Task Review Dossiers (`lavish-axi`)

When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. Open it with Lavish:

```bash
lavish-axi ~/.kingpin/tasks/<task-id>/report.html
```

Review the changes and click **Approve & Land** on the dossier or run:

```bash
kingpin land <task-id>
```

### 3. Optional Fleet Board (`kingpin board`)

To generate a static HTML overview of all fleet tasks:

```bash
kingpin board
```

---

## Multi-Harness Architecture

Each supported harness uses native configuration and hook mechanisms without dirtying repository tracking:

- **Claude Code**: Workspace trust in `~/.claude.json`. System prompt via `--append-system-prompt-file`. Turn end via `worker/hooks.json`.
- **Antigravity CLI**: Workspace trust in `~/.gemini/antigravity-cli/settings.json`. Rules in `.agents/rules/kingpin.md`. Turn end via `.agents/hooks.json`.
- **OpenCode**: Autonomous permissions in `.opencode/config.json`. Instructions in `.opencode/config.json`. Turn end via `.opencode/plugins/kingpin-stop.js`.

Worktree configuration directories (`.agents`, `.opencode`) are added to `.git/info/exclude` in each leased worktree to guarantee zero uncommitted git pollution.

---

## Running Automated Tests

Run the full test suite from the repository root:

```bash
# Automation suite: unified CLI, init, watch, and run
./tests/test-automation.sh

# Multi-harness contract and isolation test
./tests/test-harnesses.sh

# 3-worker parallel concurrency and serial landing acceptance test
./tests/test-acceptance.sh
```
