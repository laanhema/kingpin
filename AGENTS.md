# Kingpin

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in
parallel git worktrees, leases one worktree per task, serializes landing, and hands
each task back as a visual review dossier. This file describes the repository.

## Layout

| Path | What it holds |
|---|---|
| `bin/` | One executable per command (`kingpin-spawn`, `kingpin-guard`, `kingpin-wait`, ...), plus `bin/kingpin`, the dispatcher that maps `kingpin <cmd>` to them |
| `lib/` | Shared helpers: `status.sh` (the status-file protocol and the live-versus-archived task path readers, sourced by the scripts), `tmux.sh` (the fleet's tmux socket and the one `kp_tmux` helper every command reaches tmux through, sourced by every window reader), `landing.sh`, `mutex.sh` (the mutex sequence shared by the landing lane and `kingpin-lock`, plus the non-blocking `kp_mutex_try` the auto-curate gate uses), `curator.sh` (the automatic daily curator gate, applied-critique marker and trigger, sourced by `kingpin-curate`, `kingpin-watch` and `kingpin-done`), `supervisor.sh` (the fleet supervisor's pidfile, sourced by `kingpin-watch`, `kingpin-lock` and `kingpin list`), `afk.sh` (the session-scoped AFK state, sourced by `kingpin-afk`, `kingpin-watch`, `kingpin-lock` and `kingpin list`), `session.sh` (the session-pid detection `kingpin-lock` and `kingpin-afk` share), `exclude.sh` (the per-worktree exclude file a spawn points at, and the guard-owned block of the main checkout's exclude file, sourced by `kingpin-spawn`, `kingpin-done` and `kingpin-guard`), `portable.sh` (the GNU-then-BSD clock and file-mtime readers), `gitdir.sh` (the git-dir, common-dir and git-path readers the linked-worktree checks use, which read the plain `git rev-parse` form so they work on git 2.30, sourced by `kingpin-spawn`, `kingpin-sync`, `kingpin-guard` and the suites), and the node helpers `*.mjs` (`guard-hook`, `slug`, `report-diffs`, ...) |
| `worker/` | `preamble.md`, the text a spawned worker receives, `curator-preamble.md`, the contract the curator worker receives, `hooks.json`, its Claude Code settings, and `pi/kingpin-harness.ts`, the Pi extension a spawn loads with `-e` |
| `orchestrator/contract.md` | The orchestrator contract. `kingpin guard install` copies it into the main checkout's untracked instruction sources; no harness loads this tracked file directly |
| `tests/` | One shell suite per feature, with shared setup in `tests/lib.sh` |
| `docs/` | The long-form pages `README.md` links to: per-command usage, flags and exit codes (`cli.md`), fleet overview, worker permissions, harness wiring, and testing |
| `assets/` | Images for `README.md` |

## Validation

```bash
# bash -n, shellcheck, node --check over lib/*.mjs, the CI-matrix check, the README/docs
# CLI-reference check in both directions, and the tracked .agents artifact check
./tests/lint.sh

# One suite at a time (two suites briefly swap bin/kingpin-send)
./tests/test-<suite>.sh
```

## Lavish Artifacts

Every page we hand over is prose first: a worker's `report.html` dossier, and a plan or comparison page you open with `lavish-axi`, gets an unslop pass before it is served.

- Start a handover artifact from the noir dossier template, not a blank page: copy `assets/lavish/noir-dossier/template.html` and its `kingpin.jpg` into the artifact's folder (`.lavish/`), swap the content, and keep the chrome. `assets/lavish/noir-dossier/DESIGN.md` sits beside the page and records the rules the look depends on; `tests/test-noir-template.sh` fails when the folder loses a file, when a `src`/`href` is absolute or climbs out of the folder, when a diff block loses its static fallback, or when the page stops passing `check`. This template is for the pages you hand the boss, not for worker review dossiers, which keep their own layout.
- Run the `unslop` skill over the page, then `bin/kingpin-report check <file>`. A page with no diff section takes `--prose-only`.
- `check` fails with `<file>:<line>:` and the offending line for the mechanical tells: em dash, "testament to", "it's not just", "delve", "seamless", "in order to", "let me know", "I hope this helps". Fix the line, or put `<!-- unslop:ignore -->` on it when the word is genuinely wanted.
- The same `check` runs a layout pass over a full page (`*.html` with an `<html>` element) and names the line for a `<pre>` or inline `<code>` with no wrap rule, an `<img>` with no `max-width` rule, a table whose cells have no wrap rule, a grid/flex layout with no `min-width: 0` or `minmax(0, ...)` guard, a `src`/`href`/`url()` that is an absolute path or climbs out with `..`, and an `<html>` element with no `data-lavish-annotate` attribute, because Lavish otherwise opens the page in annotation mode; an explicit `"on"` passes. The block a worker dossier must carry is in `worker/preamble.md`, and `assets/lavish/noir-dossier/template.html` carries it too.
- `check` also walks every `<style>` block by brace depth. A declaration at the top level of a block, outside any selector, fails with its line, because the browser's recovery drops the rule that follows it. After parsing, a page that claims `color-scheme: dark` must carry a parsed `background` on `body`, `html` or `:root`. The palette rule is presence only: a gradient, a `var(...)` value and an inline style all count, and a page that claims no dark palette is not asked to paint one.
- Code blocks, diff output, script and style bodies and HTML attributes are ignored, and style judgement stays with the skill: title-case display headings or a deliberate noir voice in a hand-built page are not slop.
- The prose pass reads markdown too, selected by the `.md` or `.markdown` extension: fenced blocks (backtick and tilde, nested fences included), indented code blocks, inline code spans and HTML comments are ignored, and a markdown file skips the diff-section checks because it carries no diff section. Run `bin/kingpin-report check --prose-only <file>.md` on a review report under `.agents/reviews/` before it is handed back, and on an issue or pull-request body written to a `.md` file before `gh issue create --body-file` or `gh pr create --body-file` files it.
- `worker/preamble.md` carries the same requirement for workers, and `bin/kingpin-watch` warns when a dossier fails the check.

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every
PR. `./tests/lint.sh` fails when a suite has no leg, so add both together.

`tests/lint.sh` needs shellcheck 0.11.0, the version CI pins
(`pip install shellcheck-py==0.11.0.1`), and `node` for the `node --check` pass over
`lib/*.mjs`. Disable a rule only with a
`# shellcheck disable=SCnnnn # reason` line, or in `.shellcheckrc` with a comment.

The suites need `git`, `tmux`, `node`, `treehouse` and a git identity; they set their
own identity, run a private tmux server on a temporary socket, and use fake agents,
so no harness binary is needed. The fleet's own tmux socket is `kingpin` (`tmux -L
kingpin`, overridable with `KINGPIN_TMUX_SOCKET`), and `lib/tmux.sh` is the one place
a command reaches tmux: a raw `tmux` call in `bin/` or `lib/` reads the default server,
where no worker lives. The `test-tmux-isolation.sh` static check fails on `tmux` in
command position there (the start of a line or of a `$(...)`, or after `;`, `&&`, `||`,
`|` or `!`) outside `lib/tmux.sh`; a comment or a message that only mentions the word
does not match, and the scan always reads the repository's own `bin/` and `lib/`.

## Conventions

- Every script starts with `set -euo pipefail`, defines `die() { echo "<script>: $*" >&2; exit 1; }`,
  and takes `KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)` and `KP_HOME=${KINGPIN_HOME:-$HOME/.kingpin}`.
- User-facing success lines start with `OK:`; failures go to stderr through `die`.
- Test suites define `pass`/`fail` from `tests/lib.sh` and print `ALL <LABEL> TESTS PASSED`
  through `kp_test_finish`.
- `kingpin sync` refuses a tracked change, the only thing that counts as a dirty tree
  (`git status --porcelain --untracked-files=no`). An untracked path, such as a `.lavish/`
  handover page, does not block it and survives the fast-forward. When the incoming tree
  would overwrite one, `git pull --ff-only` aborts before writing anything, and the sync
  reports every such path by name and changes nothing; the fix is to move or remove the
  named path, never to add it to `.git/info/exclude` or `.gitignore`.
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
  files that spawn recorded as injected and the task's exclude file. A spawn also clears
  the harness files an earlier task left in the pooled slot when their content proves
  Kingpin wrote them (`lib/leftover.mjs`), and leaves and names anything else, because the
  slot is the user's checkout (issue #127). Pi is the exception:
  its extension loads from the checkout by absolute path and it writes no worktree file,
  so a pi spawn records no injected path and needs no exclude file. A config the project
  already tracks
  (`.opencode/opencode.json`) cannot be excluded, so the spawn refuses it instead of
  rewriting it.

## Harness wiring

| Harness | Worker preamble | Turn end |
|---|---|---|
| Claude Code | `--append-system-prompt-file <task>/preamble.md` | `worker/hooks.json` `Stop` hook |
| agy | `<worktree>/.agents/rules/kingpin.md`, which needs `trigger: always_on` frontmatter | `<worktree>/.agents/hooks.json` |
| OpenCode | `instructions` entry in `<worktree>/.opencode/opencode.json` | `<worktree>/.opencode/plugins/kingpin-stop.js` |
| Pi | `--append-system-prompt <task>/preamble.md` | `-e <checkout>/worker/pi/kingpin-harness.ts`, which runs `bin/kingpin-stop` on `agent_settled` |

An instruction file a harness silently ignores is a bug, not a preference:
`bin/kingpin-scope` exists to name the files a harness really loads.

## Supervision

`bin/kingpin-watch` is the fleet's one supervisor. It dispatches each unprocessed status
line once, runs the cleanup on `merged:`, and re-arms a dossier listener that died.

`kingpin afk on [--ttl <duration>]` arms session-scoped auto-landing. The state is
`$KINGPIN_HOME/afk` (holder pid, arm epoch, expiry epoch), the default TTL is 8 hours, and
it is never written to a project or global config. While it is armed, `bin/kingpin-watch`
calls `bin/kingpin-land` for a `ready:` line whose verdict `kp_verdict_kind` reads as
clean, then appends `approved: auto (afk)` to the task status. A findings verdict reaches
the same command but only starts the fix pass; its later clean `fixed:` landing carries the
same note, while a pass left with High findings asks for a re-review and carries none. An
unreadable verdict, `needs-input:`, `cleanup-refused:` and `failed:` wait for the operator,
and AFK never calls `kingpin done --force`. The arm reads as off once the TTL passes or the
holder pid is gone, and `kingpin lock release` clears it.

## Orchestrating from this repository

The person running the fleet (the orchestrator) works in the main checkout with the
contract installed by `kingpin guard install`; a spawned worker in a leased worktree
gets `worker/preamble.md` instead. The two never share a file, so neither has to
argue with the other. If you are a worker, follow the preamble you were given.

A task record lives in `~/.kingpin/tasks/<id>` while it runs. `kingpin done` moves it to
`~/.kingpin/archive/<id>`, or the next free `<id>.2`, `<id>.3`, ... when that name is taken,
and leaves a symlink at the old path so an open dossier keeps resolving. `kingpin list --all`
shows the archived rows. An archived task is not live: `kingpin peek` and `kingpin send` exit 1,
`kingpin wait` raises no event, and `kingpin listen` says it is finished. `lib/status.sh` holds
the reader the fleet commands use to tell a live `tasks/<id>` from that link; `peek` and `send`
resolve the tmux window on the socket its record names instead.

A dossier message reaches the capo from `kingpin listen` itself: after `handle_feedback` writes
`feedback.md` and the `feedback:` note, the listener sends the text to the worker as one line that
names the dossier and repeats the review rule (answer there, do not land). The note and the file
stay for the orchestrator, which reviews what the capo did instead of relaying the message. A
`feedback: not forwarded: <reason>` note means the text is recorded but the capo never received it,
because the task was no longer live or its window was gone. One listener owns a task at a time:
`listener.owner` holds its pid, so a second `kingpin listen` prints one line and exits 0.

After the forward, a watcher beside the poll posts one `The capo updated the page; open it to read
the answer` reply when the worker's next status event lands, so the Lavish conversation stops
showing Working; `answer.done` records the answered line so a restart does not repeat it. With no
event within `KINGPIN_LISTEN_ANSWER_TIMEOUT` seconds (default 600) it posts one `still working`
pointer and no more for that prompt. The poll itself runs in its own process group, recorded in
`listener.poll`, and a listener stop or a replacement stops that group, so an orphaned poll cannot
swallow the reviewer's next annotation.

A fresh clone has neither the guard nor the contract: run `kingpin init` (or
`kingpin guard install`) in the main checkout once.
