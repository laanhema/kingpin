# Kingpin

Kingpin is a multi-worker fleet orchestrator for AI coding agents. It runs tasks in
parallel git worktrees, leases one worktree per task, serializes landing, and hands
each task back as a visual review dossier. This file describes the repository.

## Layout

| Path | What it holds |
|---|---|
| `bin/` | One executable per command (`kingpin-spawn`, `kingpin-guard`, `kingpin-wait`, `kingpin-brief`, ...), plus `bin/kingpin`, the dispatcher that maps `kingpin <cmd>` to them |
| `lib/` | Shared helpers: `status.sh` (the status-file protocol, the `seen`/`seen_line` dispatch cursor with the reader that notices a file rewritten under it, the live-versus-archived task path readers, and the state token `kingpin list` and `kingpin brief` share: `kp_task_state`), `tmux.sh`, `browser.sh` (the browser-daemon table, its working-directory ownership rule, the process-tree stop and the size formatter), `landing.sh`, `mutex.sh` (the mutex sequence, plus the non-blocking `kp_mutex_try` the auto-curate gate uses), `curator.sh` (the automatic daily curator gate, applied-critique marker and trigger), `supervisor.sh` (the fleet supervisor's pidfile), `afk.sh` (the session-scoped AFK state), `queue.sh` (the issue-queue runner's state under `$KINGPIN_HOME/queue/`, which only `kingpin brief` reads), `session.sh` (the session-pid detection), `exclude.sh` (the per-worktree exclude file a spawn points at, and the guard-owned block of the main checkout's exclude file), `portable.sh` (the GNU-then-BSD clock and file-mtime readers), `duration.sh` (the one duration parser the `--since` and `--ttl` flags share, units `s`, `m`, `h` and `d`, and the short formatter `kingpin stats` prints: `3h12m`, `48m`), `gitdir.sh` (the git-dir, common-dir and git-path readers the linked-worktree checks use, which read the plain `git rev-parse` form so they work on git 2.30), and the node helpers `*.mjs` (`guard-hook`, `slug`, `report-diffs`, `codex-trust`, ...) |
| `lib/tmux.sh` | The fleet's tmux socket (`KINGPIN_TMUX_SOCKET`, default `kingpin`), the one `kp_tmux` helper every command reaches tmux through (a name takes `-L`, a value holding a `/` takes `-S`), `kp_tmux_resolve_target`, the one place a new worker's socket and session are resolved (issue #191), the exact session check (`kp_tmux_has_session`) and the one prefix resolver (`kp_tmux_resolve_session`, which only a user-typed target such as `--tmux-session` uses), the spellers `kp_tmux_label`/`kp_tmux_attach_cmd` every message and attach hint uses, the two socket-health readers (`kp_tmux_socket_reachable`, whether a server answers, and `kp_tmux_socket_warn_line`, the one stderr line a dead server prints for the tasks on it), and the one window resolver: finds a task's window by name first and by the recorded id second, decides whether the harness really runs in it (`harness.pid` against the pane pid), records a new id, and is the only place that creates or respawns a window |
| `lib/mux.sh` | The one terminal contract every command calls (issue #144): selects the backend from `KINGPIN_MUX` or from the task record's `MUX=` line, and delegates every verb (find, capture, send, activity, rename, kill, ensure-session, create, record-id) to `lib/tmux.sh` or to the Herdr backend. The tmux delegations are today's `kp_tmux`/`kp_window_*` calls unchanged, and the Herdr file is loaded only when a record or `KINGPIN_MUX` selects it |
| `lib/mux-herdr.sh` | The Herdr backend of `lib/mux.sh`: the one place the `herdr` binary is reached, session resolution (`KINGPIN_HERDR_SESSION`, then the inherited `HERDR_SESSION`), the label-first pane resolver with its pane-id fallback, and the verbs written against herdr 0.9.3 (`pane read` prints plain text, `pane list`/`pane get` print JSON). It refuses to create a terminal until the spawn path is migrated (issue #144 phase E) |
| `lib/launch.sh` | The worker preamble and the per-harness `launch.sh` generator, shared by `kingpin-spawn` and `kingpin-restore`, so a restored worker gets the preamble and harness wiring a spawned one does |
| `worker/` | `preamble.md`, the text a spawned worker receives, `curator-preamble.md`, the contract the curator worker receives, `hooks.json`, its Claude Code settings, and `pi/kingpin-harness.ts`, the Pi extension a spawn loads with `-e` |
| `orchestrator/contract.md` | The orchestrator contract. `kingpin guard install` copies it into the main checkout's untracked instruction sources; no harness loads this tracked file directly |
| `tests/` | One shell suite per feature, with shared setup in `tests/lib.sh`, including the `kp_wait_until` and `kp_holds_for` waits |
| `docs/` | The long-form pages `README.md` links to: per-command usage, flags and exit codes (`cli.md`), fleet overview, worker permissions, harness wiring, and testing |
| `assets/` | Images for `README.md` |

## Validation

```bash
# bash -n, shellcheck, node --check over lib/*.mjs, the CI-matrix and suite-table checks,
# the fixed-sleep-before-an-assertion check, the unguarded-`$?` check, the README/docs
# CLI-reference check in both directions, the path:line citation check, and the tracked
# .agents artifact check
./tests/lint.sh

# One suite at a time (two suites briefly swap bin/kingpin-send)
./tests/test-<suite>.sh
```

## Rules and their checks

A rule that only a person keeps is one that goes stale; each rule below names what keeps it, and the last row names the review that catches the shapes no check can see.

| Rule | Enforced by |
|---|---|
| `bin/*`, `lib/*.sh` and `tests/*.sh` parse and pass shellcheck 0.11.0, and `lib/*.mjs` parses | `tests/lint.sh` |
| every `tests/test-*.sh` is a leg of the CI matrix | `tests/lint.sh` |
| every `tests/test-*.sh` has a row in `docs/testing.md` and every row names a suite that exists | `tests/lint.sh` |
| a suite waits with `kp_wait_until` or `kp_holds_for`, never a fixed `sleep` before an assertion | `tests/lint.sh` |
| a test script captures a status with `kp_run`, never on a `NAME=$?` assignment after an unguarded command while errexit is on | `tests/lint.sh` |
| every parsed flag and `KINGPIN_*` variable is documented, and every one a page shows reaches `docs/cli.md` | `tests/readme-cli-reference.sh` |
| no page the citation check reads (`README.md`, `AGENTS.md`, `docs/*.md`, `orchestrator/contract.md`, `worker/*.md`) cites a source file by line number | `tests/doc-citations.sh` |
| nothing under `.agents/` is tracked | `tests/lint.sh` |
| `tmux` is reached only through `lib/tmux.sh` and `herdr` only through `lib/mux-herdr.sh` | the static checks in `tests/test-tmux-isolation.sh` and `tests/test-mux.sh` |
| a tmux session is matched exactly: a session check goes through `kp_tmux_has_session`, never a raw `has-session`, and only a user-typed target (`--tmux-session` or `KINGPIN_TMUX_SESSION`, for a spawn or the curator) accepts a prefix, through `kp_tmux_resolve_session` | the static check in `tests/test-tmux-isolation.sh` for the raw `has-session`, and review for the prefix resolver |
| a dossier or handover page passes the prose, layout and palette `check` | `bin/kingpin-report check` |
| a message or marker that reports a step is written only after the step's status is checked | review |
| a test never silences a status it claims to check with `\|\| true` (reviews of #5, #75), and never runs an unbounded `wait` that hangs instead of failing (reviews of #99, #145) | review |

## Lavish Artifacts

Every page we hand over is prose first: any page written from the `assets/lavish/worker-dossier/` templates (a worker's `report.html` or a handover page), and any plan or comparison page you open with `lavish-axi`, always gets an unslop pass before it is served.

- Start a handover artifact from the handover template, not a blank page: copy `assets/lavish/worker-dossier/handover.html` into the artifact's folder (`.lavish/`), swap the content, and keep the chrome. `assets/lavish/worker-dossier/DESIGN.md` sits beside it and records the rules the look depends on, including how to trim it into a review summary. A worker's review dossier, and the curator's, start from `assets/lavish/worker-dossier/template.html` instead: copy it to the task folder as `report.html`, keep its chrome, and read the same `DESIGN.md`. `tests/test-worker-dossier-template.sh` fails when the folder loses a file, when a section a page is read for goes missing, when a decision form loses its handler, when a page stops passing `check`, or when `worker/preamble.md` or `worker/curator-preamble.md` stops pointing at the worker template. The noir dossier template (`assets/lavish/noir-dossier/`, tested by `tests/test-noir-template.sh`) stays in the repo for a future look but is not the default for anything.
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
so no harness binary is needed. The fleet's tmux target is a socket plus a session
resolved by `lib/tmux.sh`: `kingpin` (`tmux -L kingpin`) unless `KINGPIN_TMUX_SOCKET`
or `TMUX_SOCKET` in `config.env` says otherwise, or the caller's own socket path when a
spawn runs inside tmux. `lib/tmux.sh` is still the one place a command reaches tmux: a
raw `tmux` call in `bin/` or `lib/` reads the default server, which may not be the one a
record names. Commands reach a worker terminal through `lib/mux.sh`, which picks
`lib/tmux.sh` or `lib/mux-herdr.sh` from the task record (issue #144), and `herdr` is
reached only inside `lib/mux-herdr.sh`. The `test-tmux-isolation.sh` static check fails on
`tmux` in command position there (the start of a line or of a `$(...)`, or after `;`, `&&`,
`||`, `|` or `!`) outside `lib/tmux.sh`, and `tests/test-mux.sh` runs the same check for
`herdr` outside `lib/mux-herdr.sh`; a comment or a message that only mentions the word
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
  so a pi spawn records no injected path and needs no exclude file. A codex spawn injects
  one path per fleet skill, a link at `<worktree>/.codex/skills/<name>`, and nothing at
  `.codex/` as a whole: a project's own skill at that name is left in place and named. A
  config the project already tracks
  (`.opencode/opencode.json`) cannot be excluded, so the spawn refuses it instead of
  rewriting it.

## Harness wiring

| Harness | Worker preamble | Turn end |
|---|---|---|
| Claude Code | `--append-system-prompt-file <task>/preamble.md` | `worker/hooks.json` `Stop` hook |
| agy | `<worktree>/.agents/rules/kingpin.md`, which needs `trigger: always_on` frontmatter | `<worktree>/.agents/hooks.json` |
| OpenCode | `instructions` entry in `<worktree>/.opencode/opencode.json` | `<worktree>/.opencode/plugins/kingpin-stop.js` |
| Pi | `--append-system-prompt <task>/preamble.md` | `-e <checkout>/worker/pi/kingpin-harness.ts`, which runs `bin/kingpin-stop` on `agent_settled` |
| Codex | `-c model_instructions_file <task>/preamble.md`, and one link per fleet skill at `<worktree>/.codex/skills/<name>` so `$<skill>` expands | the `notify` program `<task>/notify.sh`, which runs `bin/kingpin-stop` |

An instruction file a harness silently ignores is a bug, not a preference:
`bin/kingpin-scope` exists to name the files a harness really loads.

## Supervision

`bin/kingpin-watch` is the fleet's one supervisor. It dispatches each unprocessed status
line once, runs the cleanup on `merged:`, and re-arms a dossier listener that died.
The listener opens a review dossier once and records its Lavish session URL in the task's
`dossier.url`; `kingpin list` prints that URL, and the orchestrator hands it over instead of
running `lavish-axi` on the page again.

A tmux server that dies leaves every worker window gone or back as a plain shell, and tmux
window ids restart at `@0`, so a recorded id can name another task's window. `kingpin list`
marks those tasks `DEAD` and prints the `kingpin restore` hint, and it names the socket that
is gone on stderr, with the attach command; `kingpin wait` prints the same warning once per
server per process, and `KINGPIN_SKIP_SOCKET_WARN=1` silences both. `kingpin restore`
recreates or reclaims each live task's window from its own worktree and branch, relaunches
the recorded harness with a resume brief, and repairs the recorded id. Every reader resolves
a window through `lib/tmux.sh`, so a stale id is never typed into.

The supervisor owns the tmux server's lifecycle, and no systemd unit or timer does: the
socket is data, not configuration (each record names its own `TMUX_SOCKET`, a fleet can hold
records on more than one server, and the same fleet runs on the operator's default server on
one host), so a unit would name one socket and, on the operator-server configuration, would
be a second owner for a server that is not the fleet's. On every sweep, before the wait pass,
`kingpin-watch` checks each socket a live task record names; when one no longer answers it
runs `kingpin restore` for the tasks on that socket, which recreates the session and with it
the server, and re-arms the windows. The one case it cannot cover is a supervisor that was
itself running inside the server that died, so `kingpin watch` is started outside the
workers' server; on the operator-server configuration that server belongs to whatever
started it (a systemd `tmux.service`, or the operator's own tmux), and the next sweep
restores the windows once it is back. A `kingpin spawn` that had to start the server itself
says so in its `OK:` line.

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

## Worker placement

A spawn's or curator's tmux target is resolved, never guessed, in one place
(`kp_tmux_resolve_target` in `lib/tmux.sh`, issues #152 and #191). A named session wins first:
`--tmux-session <name>`, then `KINGPIN_TMUX_SESSION`, then `TMUX_SESSION` in
`$KINGPIN_HOME/config.env`, resolved on the chosen socket, and it must already exist, so a typo is
refused rather than starting a second silent session. A user-typed target (`--tmux-session` or
`KINGPIN_TMUX_SESSION`) may be an unambiguous prefix, and the resolved name is recorded; a
`TMUX_SESSION` from the config file is matched exactly, so a `kingpin-workers` session is never
taken for `kingpin` (issues #181 and #191). With no name, a spawn started inside tmux
follows the caller's own session and socket, so a worker lands beside the orchestrator. A named
socket suppresses that caller default only, because the caller's session lives on another server:
`KINGPIN_TMUX_SOCKET` or `TMUX_SOCKET` in the config does not hide a configured `TMUX_SESSION`,
and a configured session missing from the chosen socket is refused with both sources named.
Outside tmux, or with a socket named, the one attached session on that server is used, then the
only session it holds; several unattached sessions, or more than one attached session, are refused
with every candidate named. Only a server with no session at all gets the `kingpin` fallback, and
the command says on stderr that it created one. A socket is a `-L` name, or a socket path when the
value holds a `/`, which is how the caller's own server is recorded; every message and attach hint
spells it through `kp_tmux_label`/`kp_tmux_attach_cmd`. The resolution runs before the worktree
lease, so a refusal costs no worktree and leaves no task record, and the `OK:` line names the
chosen session and where it came from.
`kingpin list` prints it in a `SESSION` column read from the live window through the record's
socket, so a window moved to another session is reported where it really is.

Sharing the operator's own server has a price: `tmux kill-server` there ends every worker on it,
and `kingpin watch` and `kingpin restore` recreate the session and re-arm the windows from their
records, including through a recorded socket path. That trade was chosen on purpose in #191, so a
later reader does not undo it; `KINGPIN_TMUX_SOCKET=kingpin` keeps the isolation of #142.

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
