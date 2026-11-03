# Multi-Harness Architecture

[Back to the README](../README.md).

Each supported harness uses native configuration and hook mechanisms without dirtying repository tracking:

- **Claude Code**: Workspace trust in `~/.claude.json`. System prompt via `--append-system-prompt-file`. Turn end via `worker/hooks.json`, whose Stop command runs `bin/kingpin-stop`.
- **Antigravity CLI**: Workspace trust in `~/.gemini/antigravity-cli/settings.json`. Rules in `.agents/rules/kingpin.md`, which needs a `trigger: always_on` frontmatter: agy skips a rules file without one, without a word. Turn end via `.agents/hooks.json`, whose Stop command runs `bin/kingpin-stop`.
- **OpenCode**: Autonomous permissions via `--auto`. Instructions in `.opencode/opencode.json`: OpenCode reads `opencode.json` or `.opencode/opencode.json`. Turn end via `.opencode/plugins/kingpin-stop.js`, which calls `bin/kingpin-stop`.
- **Pi**: No worktree file and no trust prompt. The preamble arrives through `--append-system-prompt <task>/preamble.md`, and `-e <checkout>/worker/pi/kingpin-harness.ts` loads the extension from the checkout by absolute path. On `resources_discover` it bridges `KINGPIN_SKILLS_DIR` (default `~/.claude/skills`), so the fleet's `/skill:<name>` commands resolve; on `project_trust` it answers yes for the leased worktree only (resolved realpaths) and never remembers the answer; on `agent_settled` it runs `bin/kingpin-stop`, the same Stop hook the other three use. Pi has no subagent tool, so a delegating skill's steps run inline in the worker.
- **The orchestrator contract** (issue #96): tracked as `orchestrator/contract.md` and installed only in the main checkout, into `~/.kingpin/orchestrator.md`, `.claude/rules/kingpin-orchestrator.md` and `.agents/rules/kingpin.md`, with `.opencode/opencode.json` pointing at `~/.kingpin/orchestrator.md`. A spawned worker gets `worker/preamble.md` and none of these files.

`bin/kingpin-scope` (`kingpin scope files`) lists the instruction files a harness really loads for a worktree, and `kingpin scope check` exits 1 naming the file when one of them carries the contract; `kingpin spawn` runs it before it opens a window. `kingpin scope doctor --harness pi` adds the Pi readiness probe: binary, credentials, skills directory and extension.

### Fleet skills on Pi: support matrix

Pi has no subagent tool, so a skill that delegates runs its steps inline in the worker and loses the
context isolation a subagent would give it. The skills' own no-subagent branches state that. The
`State` column separates what has actually been run on Pi from what is only expected to work: a row
is `measured` only when a real Pi session ran that skill through a real model, and the evidence names
the command.

Provider and model for every measured row: `openrouter` / `anthropic/claude-sonnet-4.5`, Pi 1.5.0.
The raw runs are in the Phase 0 spike (`spike.md`, "H2/H1 re-verification"), with the transcript kept
in the task folder.

| Skill | Delegates? | State | Evidence or what is missing |
|---|---|---|---|
| `prime` | no | measured | `pi --provider openrouter --model anthropic/claude-sonnet-4.5 --approve -e worker/pi/kingpin-harness.ts -p "/skill:prime 93"` in a scratch clone: exit 0, Phases 2 to 4 completed, full project and issue context produced. |
| `plan` | no | unmeasured | Needs a spawned or hand-driven worker with a plan request; no run yet. |
| `create-issue` | no | unmeasured | Needs a GitHub-writing session and a throwaway issue; not run. |
| `issue-flow` | yes: plan, implement, review | unmeasured | Runs inline; the review is not independent, which the skill states. No run on Pi yet. |
| `do` | yes: plan, implement, review, fix | unmeasured | Runs inline; the pi preamble tells the worker to continue instead of asking whether to continue without subagents. No run on Pi yet. |
| `review` | yes: parallel batches | unmeasured | Batches run one after another instead of in parallel. No run on Pi yet. |
| `fix-findings` | yes: the fix pass | unmeasured | Phases 2 to 5 run inline. No run on Pi yet. |
| `issue-flow-done` | no | unmeasured | Needs a merged PR and a board write; not run. |
| `create-pr-merge` | no | unmeasured | Needs a real branch and PR; not run. |

The fleet-level end-to-end (a spawned pi worker on a real issue, followed by `kingpin wait`, a
mid-run `kingpin send`, `kingpin land` and `kingpin done`) is not covered by the table either: it
needs an orchestrator session. `measured` above means the skill itself ran to completion on Pi; it
does not mean the fleet drove it.

Kingpin-injected worktree configuration files (`.agents/rules/kingpin.md`, `.agents/hooks.json`, `.opencode/opencode.json`, `.opencode/plugins/package.json`, and `.opencode/plugins/kingpin-stop.js`) stay out of `git status` in a leased worktree through an exclude file Kingpin owns (`~/.kingpin/tasks/<task-id>/exclude`), which that worktree reads through a worktree-scoped `core.excludesFile` (`lib/exclude.sh`). The file the worktree would otherwise inherit is mirrored into the task's file, because the worktree-scoped setting replaces it; a configured ignore file that exists but cannot be read refuses the spawn instead of dropping your rules without a word. The main checkout's `.git/info/exclude` is your file: a linked worktree shares the common dir, so a spawn that appended to it changed your repository on every task and deleted lines it never wrote, and it never writes it now. The only part of it `kingpin guard install` rewrites is the `# kingpin guard` … `# end kingpin guard` block that it writes for its three main-checkout contract copies: the install rewrites the block on every run, and it adopts a loose copy an older version left in the file instead of adding a second line, so one install silences the warning. It may also append a plain `.claude/settings.local.json` line outside the block, when your project does not already ignore that file. `kingpin spawn` names every Kingpin-shaped line outside that block (a broad `.agents/` or `.opencode/` one, or an unmaintained exact path such as `.agents/hooks.json` or the `.opencode/plugins/*` pair) and leaves it for you to remove; it skips the block. The worktree-scoped setting needs git's `extensions.worktreeConfig` flag, which `kingpin spawn` sets once in the project repository; the flag changes no ignore rule by itself. `kingpin done` removes the pointer, the harness files that spawn injected and the task's exclude file, so a pool slot goes back clean for the next lease. Pi contributes no injected file at all: its extension is loaded from the checkout by absolute path and writes nothing into the worktree, so a pi spawn records no injected path and creates no exclude file. Your own `.agents/` and `.opencode/` files stay visible in `git status`, because no broad line is written for you.

`.gitignore` ignores `.agents/plans/`, `.agents/reports/` and `.agents/reviews/`. They hold local working artifacts (plans, implementation reports, reviews and prototype patches) that agents write while they work, so they are not tracked. Other files under `.agents/`, such as a PRD, stay trackable. An ignore rule never untracks a path that is already in the index, so `./tests/lint.sh` fails on any tracked path under those three directories; the remedy it prints is `git rm --cached <path>`, which leaves the file on disk and ignored.
