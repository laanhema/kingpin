# Kingpin

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

## Setup

### 1. Add Kingpin to your PATH

```bash
export PATH="/home/lauri/github/kingpin/bin:$PATH"
```

### 2. Configure a Project

Create a configuration file at `~/.kingpin/projects/<project>.env`.

For example, `~/.kingpin/projects/my-app.env`:

```bash
# Path to the primary git clone
PROJECT_PATH=/home/lauri/github/my-app

# Default worker harness (claude | agy | opencode)
HARNESS=claude

# Optional setup command run inside leased worktrees before launch
SETUP_CMD="npm install"
```

---

## How to Run Kingpin

Kingpin can be run by an AI orchestrator session or directly from your terminal.

### Step 1. Acquire the Orchestrator Lock

Ensure only one orchestrator session modifies the fleet:

```bash
kingpin-lock check
```

### Step 2. Spawn Workers

Spawn tasks using GitHub issues or free-text requests. Specify `--harness` to override the project default.

```bash
# Spawn a Claude Code worker on an issue (review mode)
kingpin-spawn my-app --issue 42

# Spawn an Antigravity worker on a text request
kingpin-spawn my-app --text "refactor authentication middleware" --harness agy

# Spawn an OpenCode worker in auto-merge mode
kingpin-spawn my-app --issue 10 --harness opencode --mode auto
```

Each worker receives:
- A dedicated, leased git worktree managed by `treehouse`.
- An isolated branch `kingpin/<task-id>`.
- Pre-registered workspace trust.
- Injected system instructions and turn-end Stop hooks.
- A dedicated tmux window inside the `kingpin` session.

### Step 3. Monitor the Fleet Board

Generate and update the fleet board:

```bash
kingpin-board
```

The board is saved at `~/.kingpin/board.html`. Open it in any browser or serve it with Lavish:

```bash
lavish-axi poll ~/.kingpin/board.html
```

The board displays:
- Active tasks, branches, and assigned harnesses.
- Live task states (running, quiet, needs-input, ready, merged, failed).
- Expandable terminal previews.
- Interactive buttons for landing, answering input prompts, or requesting changes.

### Step 4. Watch for Updates

Run the event watcher to listen for status changes, quiet states, or exits:

```bash
# Wait for the next fleet event (blocking)
kingpin-wait

# Non-blocking single check
kingpin-wait --once
```

Outputs one line per event: `<task-id> <reason>` (e.g. `my-app-42 status` or `my-app-42 quiet`).

### Step 5. Interact with Workers

If a worker reports `needs-input:` or you want to steer it:

```bash
kingpin-send <task-id> "Use option B and proceed"
```

### Step 6. Land and Clean Up

When a worker reports `ready:`, its review report is available at `~/.kingpin/tasks/<task-id>/report.html`.

Initiate landing:

```bash
kingpin-land <task-id>
```

`kingpin-land` enforces project serialization. If another task is already landing on `my-app`, this task enters `~/.kingpin/projects/my-app.landing_queue` until the active merge completes.

When the worker finishes merging (`merged:`), clean up:

```bash
kingpin-done <task-id>
```

`kingpin-done` asserts the branch is merged into `main`, returns the worktree lease to the treehouse pool, deletes the local task branch, and triggers the next queued task.

---

## Command Reference

| Command | Usage | Description |
|---|---|---|
| `kingpin-spawn` | `kingpin-spawn <proj> (--issue <n> \| --text <req>) [--harness <name>] [--mode review\|auto]` | Leases worktree, configures trust, and launches worker. |
| `kingpin-wait` | `kingpin-wait [--timeout <sec>] [--once]` | Inotifywait watcher for status changes and qualified quiet workers. |
| `kingpin-board` | `kingpin-board [--out <path>]` | Renders the fleet status HTML board. |
| `kingpin-send` | `kingpin-send <task-id> "<keys>"` | Sends input keys to a worker's tmux window. |
| `kingpin-land` | `kingpin-land <task-id>` | Starts or queues serialized landing for a project. |
| `kingpin-done` | `kingpin-done <task-id>` | Verifies merge, releases worktree, and advances queue. |
| `kingpin-lock` | `kingpin-lock check` | Enforces single active orchestrator session. |
| `kingpin-curate` | `kingpin-curate` | Aggregates critique files from finished worker tasks. |

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
# Multi-harness contract and isolation test
./tests/test-harnesses.sh

# 3-worker parallel concurrency and serial landing acceptance test
./tests/test-acceptance.sh
```
