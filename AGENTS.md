# Kingpin

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in
parallel git worktrees, leases one worktree per task, serializes landing, and hands
each task back as a visual review dossier. This file describes the repository.

## Layout

| Path | What it holds |
|---|---|
| `bin/` | One executable per command (`kingpin-spawn`, `kingpin-guard`, `kingpin-wait`, ...), plus `bin/kingpin`, the dispatcher that maps `kingpin <cmd>` to them |
| `lib/` | Shared helpers: `status.sh` (the status-file protocol, sourced by the scripts), `landing.sh`, and the node helpers `*.mjs` (`guard-hook`, `slug`, `report-diffs`, ...) |
| `worker/` | `preamble.md`, the text a spawned worker receives, and `hooks.json`, its Claude Code settings |
| `orchestrator/contract.md` | The orchestrator contract. `kingpin guard install` copies it into the main checkout's untracked instruction sources; no harness loads this tracked file directly |
| `tests/` | One shell suite per feature, with shared setup in `tests/lib.sh` |
| `assets/` | Images for `README.md` |

## Validation

```bash
# bash -n, shellcheck, and the CI-matrix check
./tests/lint.sh

# One suite at a time (two suites briefly swap bin/kingpin-send)
./tests/test-<suite>.sh
```

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every
PR. `./tests/lint.sh` fails when a suite has no leg, so add both together.

`tests/lint.sh` needs shellcheck 0.11.0, the version CI pins
(`pip install shellcheck-py==0.11.0.1`). Disable a rule only with a
`# shellcheck disable=SCnnnn # reason` line, or in `.shellcheckrc` with a comment.

The suites need `git`, `tmux`, `node`, `treehouse` and a git identity; they set their
own identity, run a private tmux server on a temporary socket, and use fake agents,
so no harness binary is needed.

## Conventions

- Every script starts with `set -euo pipefail`, defines `die() { echo "<script>: $*" >&2; exit 1; }`,
  and takes `KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)` and `KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}`.
- User-facing success lines start with `OK:`; failures go to stderr through `die`.
- Test suites define `pass`/`fail` from `tests/lib.sh` and print `ALL <LABEL> TESTS PASSED`
  through `kp_test_finish`.
- Harness-specific files a command writes into a worktree (`.opencode/*`, `.agents/rules/*`,
  `.agents/hooks.json`) are added to that worktree's `.git/info/exclude`, never to the
  tracked `.gitignore`, so a user's own files in those directories stay visible.

## Harness wiring

| Harness | Worker preamble | Turn end |
|---|---|---|
| Claude Code | `--append-system-prompt-file <task>/preamble.md` | `worker/hooks.json` `Stop` hook |
| agy | `<worktree>/.agents/rules/kingpin.md`, which needs `trigger: always_on` frontmatter | `<worktree>/.agents/hooks.json` |
| OpenCode | `instructions` entry in `<worktree>/.opencode/opencode.json` | `<worktree>/.opencode/plugins/kingpin-stop.js` |

An instruction file a harness silently ignores is a bug, not a preference:
`bin/kingpin-scope` exists to name the files a harness really loads.

## Orchestrating from this repository

The person running the fleet (the orchestrator) works in the main checkout with the
contract installed by `kingpin guard install`; a spawned worker in a leased worktree
gets `worker/preamble.md` instead. The two never share a file, so neither has to
argue with the other. If you are a worker, follow the preamble you were given.

A fresh clone has neither the guard nor the contract: run `kingpin init` (or
`kingpin guard install`) in the main checkout once.
