# Kingpin

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in
parallel git worktrees, leases one worktree per task, serializes landing, and hands
each task back as a visual review dossier. This file describes the repository.

## Layout

| Path | What it holds |
|---|---|
| `bin/` | One executable per command (`kingpin-spawn`, `kingpin-guard`, `kingpin-wait`, ...), plus `bin/kingpin`, the dispatcher that maps `kingpin <cmd>` to them |
| `lib/` | Shared helpers: `status.sh` (the status-file protocol and the live-versus-archived task path readers, sourced by the scripts), `landing.sh`, `mutex.sh` (the mutex sequence shared by the landing lane and `kingpin-lock`), `supervisor.sh` (the fleet supervisor's pidfile, sourced by `kingpin-watch`, `kingpin-lock` and `kingpin list`), `exclude.sh` (the per-worktree exclude file a spawn points at, and the guard-owned block of the main checkout's exclude file, sourced by `kingpin-spawn`, `kingpin-done` and `kingpin-guard`), `portable.sh` (the GNU-then-BSD clock and file-mtime readers), and the node helpers `*.mjs` (`guard-hook`, `slug`, `report-diffs`, ...) |
| `worker/` | `preamble.md`, the text a spawned worker receives, and `hooks.json`, its Claude Code settings |
| `orchestrator/contract.md` | The orchestrator contract. `kingpin guard install` copies it into the main checkout's untracked instruction sources; no harness loads this tracked file directly |
| `tests/` | One shell suite per feature, with shared setup in `tests/lib.sh` |
| `docs/` | The long-form pages `README.md` links to: per-command usage, flags and exit codes (`cli.md`), fleet overview, worker permissions, harness wiring, and testing |
| `assets/` | Images for `README.md` |

## Validation

```bash
# bash -n, shellcheck, node --check over lib/*.mjs, the CI-matrix check, the README/docs
# CLI-reference check, and the tracked .agents artifact check
./tests/lint.sh

# One suite at a time (two suites briefly swap bin/kingpin-send)
./tests/test-<suite>.sh
```

## Lavish Artifacts

Every page we hand over is prose first: a worker's `report.html` dossier, and a plan or comparison page you open with `lavish-axi`, gets an unslop pass before it is served.

- Start a handover artifact from the noir dossier template, not a blank page: copy `assets/lavish/noir-dossier/template.html` and its `kingpin.jpg` into the artifact's folder (`.lavish/`), swap the content, and keep the chrome. `assets/lavish/noir-dossier/DESIGN.md` sits beside the page and records the rules the look depends on; `tests/test-noir-template.sh` fails when the folder loses a file, when a `src`/`href` is absolute or climbs out of the folder, when a diff block loses its static fallback, or when the page stops passing `check`. This template is for the pages you hand the boss, not for worker review dossiers, which keep their own layout.
- Run the `unslop` skill over the page, then `bin/kingpin-report check <file>`. A page with no diff section takes `--prose-only`.
- `check` fails with `<file>:<line>:` and the offending line for the mechanical tells: em dash, "testament to", "it's not just", "delve", "seamless", "in order to", "let me know", "I hope this helps". Fix the line, or put `<!-- unslop:ignore -->` on it when the word is genuinely wanted.
- The same `check` runs a layout pass over a full page (`*.html` with an `<html>` element) and names the line for a `<pre>` or inline `<code>` with no wrap rule, an `<img>` with no `max-width` rule, a table whose cells have no wrap rule, a grid/flex layout with no `min-width: 0` or `minmax(0, ...)` guard, and a `src`/`href`/`url()` that is an absolute path or climbs out with `..`. The block a worker dossier must carry is in `worker/preamble.md`, and `assets/lavish/noir-dossier/template.html` carries it too.
- Code blocks, diff output, script and style bodies and HTML attributes are ignored, and style judgement stays with the skill: title-case display headings or a deliberate noir voice in a hand-built page are not slop.
- `worker/preamble.md` carries the same requirement for workers, and `bin/kingpin-watch` warns when a dossier fails the check.

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every
PR. `./tests/lint.sh` fails when a suite has no leg, so add both together.

`tests/lint.sh` needs shellcheck 0.11.0, the version CI pins
(`pip install shellcheck-py==0.11.0.1`), and `node` for the `node --check` pass over
`lib/*.mjs`. Disable a rule only with a
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
  `.agents/hooks.json`) are hidden by a Kingpin-owned exclude file,
  `$KP_HOME/tasks/<id>/exclude`, which the worktree reads through a worktree-scoped
  `core.excludesFile` (`lib/exclude.sh`); never through the main checkout's
  `.git/info/exclude`, which belongs to the user and is shared by every linked worktree,
  and never through the tracked `.gitignore`. The only part of that file `kingpin guard
  install` rewrites is the `# kingpin guard` … `# end kingpin guard` block it holds its
  main-checkout contract copies in, and it may also append a plain
  `.claude/settings.local.json` line outside that block when the project does not already
  ignore the file. `kingpin spawn` names every other Kingpin-shaped line there and skips
  the block. Enabling git's `extensions.worktreeConfig`
  is the one repository-config line a spawn writes. `kingpin done` clears the pointer, the
  files that spawn recorded as injected and the task's exclude file. A config the project
  already tracks
  (`.opencode/opencode.json`) cannot be excluded, so the spawn refuses it instead of
  rewriting it.

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
