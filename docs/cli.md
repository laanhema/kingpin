# CLI Command Reference

[Back to the README](../README.md).

## kingpin init

**Usage:** `kingpin init [name] [path] [--harness <name>] [--setup "<cmd>"]`

**Flags:** `--harness <name>`, `--setup "<cmd>"`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD`

`--harness` accepts `claude`, `agy`, `opencode`, `pi` and `codex`; it writes the project's `HARNESS`, which `kingpin spawn` follows. `--setup` records the project's `SETUP_CMD`, which `kingpin spawn` runs in each new worktree before the harness launches (its output goes to the task's `setup.log`), and is the mechanism behind the "isolates dependencies" claim in the [README](../README.md).

## kingpin run

**Usage:** `kingpin run <proj> (--issue <n> | --text <req>) [--mode auto|review] [--id <task-id>] [--harness <name>] [--tmux-session <name>]`

**Flags:** `--issue <n>`, `--text <req>`, `--mode review|auto`, `--id <task-id>`, `--harness <name>`, `--tmux-session <name>`

- `--issue`: an existing GitHub issue: the worker runs /issue-flow (review) or /do (auto)
- `--text`: a free-text request: the worker runs /create-issue first, then the same
- `--mode`: review (default) stops at a ready branch for the review; auto merges when green
- `--id`: task id; defaults to kp-<n>-<slug> (issue title) or kp-<slug> (request)
- `--harness`: worker harness: claude, agy, opencode, pi, or codex (overrides the project and the lock)
- `--tmux-session`: tmux session to place the worker window in when the caller has no tmux client context; `run` forwards it to the `kingpin spawn` it starts (see [Choosing the session](#choosing-the-session))

**Environment:** `KINGPIN_HOME` (its own); the `kingpin spawn` it runs reads the rest, listed under [kingpin spawn](#kingpin-spawn).

### Review mode

In `review` mode it exits 0 when the worker reports `ready:` and prints the dossier line: the Lavish session URL the listener recorded when it opened the page, or the `lavish-axi <path>` command when no URL is recorded yet. A worker blocked on a human (`needs-input:`, or the Stop hook's `waiting:` line) ends it with exit 0 too, printing where the question is.

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

### A tmux server that died

Before the wait pass of every cycle, and in `--once`, the supervisor checks each socket a live task record names. When one no longer answers it logs `the tmux server '<socket>' is not running; restoring <ids>` and runs `kingpin restore` for the tasks on that socket, which recreates the session (and with it the server) and re-arms each window with a resume brief. Curator tasks and tasks whose last status is terminal are skipped, because restore refuses them by name. Running it before the wait pass means a restored window is back before `exited` would be raised for it. A supervisor that was itself running inside the server that died dies with it, so start `kingpin watch` outside the workers' server; see [Who owns the server](#who-owns-the-server).

### `--interval`

`--interval` takes a whole number of seconds, at least 1 and at most nine digits; anything else exits 2, and a `kingpin wait` that fails is retried after one warning on stderr and a two-second pause, so an unusable fleet directory cannot spin the loop.

### The pidfile

It claims `~/.kingpin/supervisor.pid`, refuses a second copy with the running pid named, reclaims a pidfile left by a dead supervisor, and `--once` runs one pass without claiming it (that is the path `kingpin run` and the tests use). `kingpin wait` is the primitive it drives.

## kingpin spawn

**Usage:** `kingpin spawn <proj> (--issue <n> | --text <req>) [--mode review|auto] [--id <task-id>] [--harness <name>] [--tmux-session <name>]`

**Flags:** `--issue <n>`, `--text <req>`, `--mode review|auto`, `--id <task-id>`, `--harness <name>`, `--tmux-session <name>`

- `--issue`: an existing GitHub issue: the worker runs /issue-flow (review) or /do (auto)
- `--text`: a free-text request: the worker runs /create-issue first, then the same
- `--mode`: review (default) stops at a ready branch for the review; auto merges when green
- `--id`: task id; defaults to kp-<n>-<slug> (issue title) or kp-<slug> (request)
- `--harness`: worker harness: claude, agy, opencode, pi, or codex (overrides the project and the lock)
- `--tmux-session`: tmux session on the fleet's own server to place the worker window in; it must already exist (see [Choosing the session](#choosing-the-session))

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_AGY`, `KINGPIN_OPENCODE`, `KINGPIN_PI`, `KINGPIN_CODEX`, `KINGPIN_GH`, `KINGPIN_TMUX_SOCKET`, `KINGPIN_TMUX_SESSION`; the `kingpin scope check` it runs reads `KINGPIN_ALLOW_GLOBAL_CONTRACT`, and a codex spawn also reads `KINGPIN_SKILLS_DIR` and `CODEX_HOME`.

### Where the window lives

Workers run on a tmux server Kingpin owns, not on yours. `kingpin spawn` and `kingpin curate` talk to the socket `kingpin` (`tmux -L kingpin`) and create their windows in a session there (`kingpin` unless the session is named), so nothing they do reaches your own session or the default server: closing your last session, or restarting your tmux server, leaves a running worker alone. The task record carries both facts, `TMUX_SOCKET` for the socket and `TMUX_TARGET` for `<session>:<task-id>`, and every command that reads a worker window takes both from the same record. `KINGPIN_TMUX_SOCKET` names another socket, and `KINGPIN_TMUX_SOCKET=default` is the deliberate way back onto your own server. A `task.env` written before the split carries no `TMUX_SOCKET`: its window really is on the default server, so the readers resolve it there.

A worker's terminal can also be a Herdr pane. The backend is chosen per fleet by `KINGPIN_MUX`: `tmux` (or unset outside a Herdr pane) keeps the tmux server above, `herdr` uses Herdr, and `auto` picks Herdr only when the command itself runs inside a Herdr pane (`HERDR_ENV=1`). A value other than `auto`, `tmux` or `herdr` is refused by name. `KINGPIN_HERDR_SESSION` names the fleet's Herdr session (default `kingpin`, the same name the tmux socket uses); that session must already be running, because `herdr server` is a foreground process the operator owns, and Kingpin neither starts nor supervises it. Inside a Herdr pane the inherited `HERDR_SESSION` is used instead.

The mux belongs to the task record, not to the process, so one fleet can hold a tmux worker and a Herdr worker at once. A record with `MUX=tmux` or no `MUX=` line at all is a tmux task, forever, and a record with `MUX=herdr` names `MUX_SESSION`, `MUX_TARGET` (the pane id) and `MUX_LABEL` (the re-resolution key, because Herdr renumbers a pane that moves across workspaces). There is no migration step: `kingpin send`, `peek`, `done`, `ack`, `curate` and the `stop`, `launch-check` and `rename` helpers read the record and reach the right backend, and so does the curator's window check. An orchestrator running inside a Herdr pane that wants tmux workers sets `KINGPIN_MUX=tmux`. `kingpin spawn` still creates tmux workers in this change, so no task record can name Herdr yet: the commands not migrated with it (`kingpin list`, `wait`, `restore`) never meet a Herdr record, and `kingpin curate` under `KINGPIN_MUX=herdr` refuses with two lines that name the mux and the way back (`KINGPIN_MUX=tmux`): the backend's `herdr: creating a terminal for a task is not wired up yet (issue #144 phase E); run with KINGPIN_MUX=tmux`, then `kingpin-curate: could not launch the curator in herdr --session <name> curator`.

To look at the fleet server by hand, attach from a shell outside tmux with `tmux -L kingpin attach -t kingpin`; from inside your own session, `TMUX= tmux -L kingpin attach -t kingpin` attaches to it instead of switching your client's server. `kingpin list` prints the attach command for each socket the live records name under the task rows, and `kingpin peek <task-id>` reads one pane without attaching.

### Who owns the server

`kingpin watch` does, and no systemd unit or timer does. The socket is data, not configuration: each task record names its own `TMUX_SOCKET`, a fleet can hold records on more than one server during a move between them, and the same fleet may be running on the operator's default server (`KINGPIN_TMUX_SOCKET=default`) on one host and on a server of its own on the next. A unit would have to name one socket, and on the operator-server configuration it would be a second owner for a server that is not the fleet's. So the supervisor owns the lifecycle of whatever socket the records name: on every sweep it checks each socket a live task record names, and when one no longer answers it hands that socket's tasks to `kingpin restore`, which recreates the session (and with it the server) and re-arms each window with a resume brief. The `OK:` line of a `kingpin spawn` that had to start the server itself says so, for example `, started the tmux server on socket 'kingpin' (it was not running)`.

The one thing this cannot cover is a supervisor that was itself running inside the server that died. Start `kingpin watch` outside the workers' server, for example from a plain shell or from a service that restarts it; on the operator-server configuration that is the same server your own session lives on, and its own lifecycle belongs to whatever started it (a systemd `tmux.service`, or your own tmux). When that server is back, the next sweep restores the windows.

### Window names

The window is pinned with `automatic-rename off` and `allow-rename off`, so ambient tmux settings and worker child commands cannot rename it; only `kingpin-wait` renames it.

### Choosing the session

The worker's session on the fleet's own server is resolved, never guessed: `--tmux-session <name>`,
then `KINGPIN_TMUX_SESSION`, then the one session a client is attached to on that server, then the
only session it holds. A named session must already exist, and an unknown name is refused instead
of starting a session for it. Several sessions with no client attached, or more than one attached
session, are refused, with every candidate named and both ways to name a target. Only a server with
no session at all gets a `kingpin` fallback, and one `kingpin-spawn:` note on stderr says the spawn
created it. Your own tmux client is on the operator's server, not the fleet's, so its session is
never used as a target. The resolution runs before the worktree is leased, so a refusal costs no
worktree and leaves no task record. The `OK:` line names the chosen session and where it came from,
for example `session from --tmux-session` or `session the only session on the server`.

### Task ID, branch and window

The task ID, branch (`kingpin/<id>`) and window share one slug: `kp-<n>-<slug>` from the issue title for `--issue`, `kp-<slug>` from the request for `--text` (`--id` overrides).

An `--id` whose task path is the dossier link of an archived task is refused, naming the archive: a finished task keeps that link (see [`kingpin done`](#kingpin-done)), and a spawn must never write its harness files through it into the archive. An archive left without such a link is harmless to reuse.

### A pooled slot's leftover browser

A slot that comes back to the pool can still be driving a browser: a `chrome-devtools-axi` daemon left by the task that leased the slot last keeps its working directory in the worktree. The spawn checks the worktree it has just leased, stops every such daemon with its `chrome-devtools-mcp` child and headless Chrome, and names what went on stderr, for example `kingpin-spawn: stopped 1 browser daemon left in <worktree> by an earlier task (412 MB freed)`. A clean slot prints nothing. The ownership rule is the one `kingpin done` and `kingpin list` use too (`lib/browser.sh`): a daemon counts when its working directory is inside that slot, and a process that is not a bridge daemon is never touched.

### `--text` tasks

For `--text`, `kingpin-wait` renames the window and `TMUX_TARGET` to `kp-<n>-<slug>` once the worker reports its issue; the task ID and branch keep the first name.

### Pi launch

A `pi` spawn writes nothing into the worktree. The launch runs `pi --append-system-prompt <task>/preamble.md -e <checkout>/worker/pi/kingpin-harness.ts` plus the job prompt, so no injected path is recorded and no worktree exclude file is created. The job prompt is the bare `/skill:<name> <args>` line, because Pi expands a skill only when the message starts with its command; the pi worker's preamble carries the sentence that tells it to run every skill step inline, since Pi has no subagent tool. `PI_PROVIDER` and `PI_MODEL` in the project env are passed as `--provider` and `--model`; each flag is passed only when its own key is set, so a host that logged in with the vendor `/login` keeps Pi's default model, and Kingpin runs no auth preflight. Use `kingpin scope doctor --harness pi` for that check. Fleet sends use `/skill:<name>` on pi through `bin/kingpin-spawn` and `bin/kingpin-land`.

### Codex launch

A `codex` spawn writes only per-skill links at `<worktree>/.codex/skills/<name>` and hides them through the task's exclude file; the preamble arrives through `-c model_instructions_file <task>/preamble.md`, so no tracked file is rewritten. The launch runs `codex -C <worktree> -a never -s workspace-write` with `sandbox_workspace_write.exclude_slash_tmp=true`, `sandbox_workspace_write.exclude_tmpdir_env_var=true` and `sandbox_workspace_write.network_access=true`. Its writable roots are the task folder and the worktree's git dir and common git dir: a linked worktree keeps its index and refs in those git dirs, so without them the sandbox leaves the worker unable to stage or commit. The shared common dir is the main checkout's `.git`, so a worker can also write its `config` and `hooks/`; that is the price of a shared object store, stated in `docs/worker-permissions.md`. `TMPDIR` moves to `<task>/tmp` because `/tmp` is denied. When your `$CODEX_HOME` carries a hook set (`[features] hooks = true`, or a `hooks.json` with hooks), the launch adds `--dangerously-bypass-hook-trust`, Codex's own flag, so the "Hooks need review" dialog cannot stall an unattended worker; a host with no hook set is not given the bypass. The job prompt is the bare `$<name> <args>` line, because Codex 0.166 has no slash command for the fleet's skills. `kingpin done` removes the folder-trust entry the spawn seeded, and only what that spawn wrote.

## kingpin list

**Usage:** `kingpin list [--all|-a]`

**Flags:** `--all`, `-a`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_SOCKET_WARN`

`kingpin status` is the same command under its older name.

The `SESSION` column names the tmux session the worker's window lives in. It is read from the live window, so a window moved to another session is reported where it really is, not where it was spawned; a task with no recorded window and no recorded target shows `-`.

A finished task is shown from `archive/` (with `--all`), never from the dossier link `kingpin done` leaves at its old `tasks/` path: that path resolves a review page, it is not a live task. An archived row has no live window left to read, so its `SESSION` shows the session recorded at spawn, or `-` when none was recorded.

The `STATE` column marks `WAITING` (blocked on a human), `SILENT` (a Stop without a report) and `DEAD`: a live task whose window is gone, or whose recorded harness pid (`harness.pid`) is no longer the pane's. A tmux server that died therefore reads as a dead fleet instead of a healthy one, and one `Fleet: <n> live task(s) have no live window; run kingpin restore` line follows the table. `DEAD` combines with `Unseen: N` the way the other states do.

Every live task whose folder holds a `report.html` gets its dossier line printed below its row, whatever the task's mode or status: the Lavish session URL the listener recorded in the task's `dossier.url` when it opened the page, or the `lavish-axi <path>` command when no URL is recorded yet. Hand the URL over instead of running the command, which opens a second tab on the session the listener already opened (issue #146). The line is followed by `(listening: pid <n>)` while that task's listener runs; a finished or archived row gets no dossier line.

Every live row whose window is still alive also gets a `↳ Window:` line naming the socket, session and window that hold the worker, for example `↳ Window: tmux -L kingpin kingpin (@3)`, and the footer prints one attach command per socket the live records actually name, for example `Workers live on the tmux server 'default': tmux attach (kingpin peek <task-id> reads one pane)`; a fleet with no live task names the socket a new spawn would use. The footer reads the records, not your `KINGPIN_TMUX_SOCKET`, so it never points at a server that holds no worker. A worker whose pane is gone gets no line, so the line never points at a session that is empty. A task record from before the split has no socket, so its line reads `tmux kingpin (@n)`: that window is on the default server.

When a live task record names a tmux server that is not running, `kingpin list` prints one warning on stderr naming that server, the tasks whose windows died with it, and the command that attaches once it is back, for example `kingpin: the tmux server 'kingpin' is not running; live tasks kp-1, kp-2 name it and their windows are gone. Attach once it is back: tmux -L kingpin attach; kingpin watch restarts it and runs kingpin restore (or run kingpin restore yourself)`. `kingpin wait` prints the same line once per server per process. Set `KINGPIN_SKIP_SOCKET_WARN=1` to silence it, the same kind of switch `KINGPIN_SKIP_GUARD=1` is for the guard warning.

A live row whose task holds a browser daemon also gets `↳ Browser: 1 daemon, 412 MB (pid 1234)`: the `chrome-devtools-axi` bridge the task started, with its `chrome-devtools-mcp` child and headless Chrome, summed over the whole process tree. Ownership is the daemon's working directory, so only a daemon started from the task folder or the task's worktree is counted (`lib/browser.sh`), and only a process whose argv runs the bridge script counts: a log tail or an editor that merely names it is neither listed nor stopped. A task that drives no browser gets no line, and an archived row never gets one, because `kingpin done` stops the daemons before it archives the task. A daemon left by a task archived before this change still runs, and no Kingpin command lists or stops it: its record is under `~/.kingpin/archive/<task-id>`, which `kingpin list` does not scan, and `kingpin done` only runs for a live task. Stop one by hand: find its pid, check that its working directory is that archive path (`readlink /proc/<pid>/cwd` on Linux, `lsof -a -p <pid> -d cwd -Fn` on macOS), and kill it. Two or more daemons print as `2 daemons` with their pids comma-separated.

## kingpin send

**Usage:** `kingpin send <task-id> "<text>"`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SEND_DELAY`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

The terminal is resolved by `lib/mux.sh`, from the mux the task record names. For a tmux task it is the task's own window name first, then a recorded window ID that still names this task's window, on the socket the record names (`TMUX_SOCKET`): a send after a tmux server restart therefore reaches the task's own window instead of whichever window inherited the stale id, and an id that names another task's window is refused with `tmux window <label> is not alive`. A Herdr task resolves its pane by `MUX_LABEL` first and by the recorded pane id second.

## kingpin peek

**Usage:** `kingpin peek <task-id> [--lines N]`

**Flags:** `--lines N`

**Environment:** `KINGPIN_HOME`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

### Finding the pane

It looks for the task's own window name in the task's session first (`TMUX_TARGET`), because the name is the one key that survives a tmux server restart, where window ids restart at `@0` and a recorded id can name a different task's window. When the name is gone it falls back to the recorded window ID (`TMUX_WINDOW_ID`), which is what keeps a hand-renamed window reachable; an id that names another window is refused rather than typed into. The socket comes from the same record (`TMUX_SOCKET`), so the window is resolved on the server that holds it. The same rule, in `lib/tmux.sh`, is what `send`, `wait`, `ack`, `launch-check`, `stop`, `rename`, `done` and `list` use, and it is why `peek` only needs `list-panes` and `capture-pane`. `send`, `peek`, `ack`, `launch-check`, `stop`, `rename` and `curate` reach it through `lib/mux.sh`, so a task whose record says `MUX=herdr` resolves its pane by `MUX_LABEL` first and its recorded pane id second instead.

### Read-only

It sends no keys and changes no state. Exits 1 for an unknown task or a window that is gone, 2 for a bad argument.

### Why a worker is stuck

Use it to see why a worker is stuck (an unsubmitted pasted message, a usage-limit banner, a permission prompt).

## kingpin sync

**Usage:** `kingpin sync`

### Running it

Run it in the main checkout; it prints the old and new short SHAs plus the commits pulled, or `already up to date`.

### What blocks it

A modified or staged tracked file refuses the sync with `kingpin-sync: working tree is dirty; commit or remove the changes first (nothing was changed)`, and nothing is changed.

An untracked path does not block it, and ignored files do not count either. Handover artifacts belong in `.lavish/`, which is untracked, so a page an open Lavish session is serving survives the fast-forward.

The one exception is an untracked path the incoming commits would overwrite. git refuses that pull before writing anything, and the sync turns that abort into its own line naming every path:

```
kingpin-sync: the incoming commits would overwrite these untracked paths: collide.txt; move or remove them first (nothing was changed)
```

Nothing is half-applied: HEAD, the index and every file keep the state they had before the attempt, so moving or removing the named path lets the next sync complete the same fast-forward.

### What it never does

It never merges, rebases, resets or stashes.

### Exit codes

Exits 1 with a message on stderr on a tracked change, on an untracked path the incoming commits would overwrite (with each path named), in a linked worktree, with a detached HEAD or no upstream, or when a fast-forward is not possible; 2 for an argument.

## kingpin listen

**Usage:** `kingpin listen <task-id> [--once] [--background]`

**Flags:** `--once`, `--background`

**Environment:** `KINGPIN_HOME`, `KINGPIN_LAVISH`, `KINGPIN_LISTEN_ANSWER_TIMEOUT`

### Approve & Land

**Approve & Land** runs `kingpin land` and, once the gate accepts the line, appends an `approved:` note to the task's `status`; a task whose last worker event is not `ready:` or `fixed:` (or whose verdict `kingpin land` refuses) is answered with its current state, and records no approval.

### Request Changes

**Request Changes** appends the text to `feedback.md` and a `feedback:` note, then the listener forwards the text to the worker as one line that names the dossier and repeats the review rule (answer there, do not land); both notes wake `kingpin wait`. When the task is not live or its window is gone, nothing is forwarded and the status gains `feedback: not forwarded: <reason>`, with the text still in `feedback.md`.

### The answer pointer

After a forward, a watcher beside the poll loop clears the dossier's Working state with one `reply`: `The capo updated the page; open it to read the answer`. It posts when the worker's next status event lands (`ready:`, `waiting:`, `fixed:`, `failed:`), and `answer.done` records the answered status line so a listener restart does not post it twice. When no event arrives within `KINGPIN_LISTEN_ANSWER_TIMEOUT` seconds (default 600), it posts one `The capo is still working; the answer will appear on the page.` and never another for that prompt. The answer itself stays in the page; the reply is only a pointer.

### An unreadable poll

A poll whose prompts the parser cannot read is parked as `unparsed-poll-*.txt` in the task directory and its `prompt:` values are still forwarded as feedback; a `feedback:` note that names a parked response means the poll could not be parsed, and the raw response is in that file.

### Background and one-shot listeners

`--background` starts one detached listener per task (concurrent launches start only one; pid in `listener.pid`, output in `listener.log`) and returns at once; `kingpin watch` starts it when a review-mode worker reports `ready:`. `--once` stops after one poll. One listener owns a task at a time: `listener.owner` holds its pid, so a second `kingpin listen` on a live task prints one line and exits 0 without polling. The poll runs in its own process group and its pid is recorded in `listener.poll`; a listener that is stopped, or a replacement that takes over a stale slot, stops that group first, so an orphaned poll cannot own the session and swallow the next annotation.

The first open of the dossier records the Lavish session URL in `dossier.url` and the listener prints it in its `OK: listening on <task-id>; dossier <url>` line, so a foreground start hands over the same URL `kingpin list` does. The file is never rewritten while it holds a URL, so it survives a listener restart; a session the server lost is reopened once and the replacement URL is recorded in its place.

### Without Lavish

Without `lavish-axi` (or `KINGPIN_LAVISH`) it prints a note on stderr and exits 0.

### Exit codes and cleanup

Exits 1 for an unknown task or one without `report.html`, 2 for a bad argument. `kingpin done` stops the listener.

An archived task resolves: `kingpin listen <task-id>` on one prints `OK: task <task-id> is finished` with the archived dossier path and exits 0. A listener that finds its own task archived out from under it (a cleanup whose listener stop missed it) posts one final reply naming the archive and stops polling.

## kingpin wait

**Usage:** `kingpin wait [--timeout <sec>] [--once]`

**Flags:** `--timeout <sec>`, `--once`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_SOCKET_WARN`

### Exit codes

Exits 0 on events and on a plain timeout (nothing printed); `--once` with no events exits 1; 2 for a bad argument.

An archived task raises no event: its leftover dossier link is not a live task, so it cannot wake the orchestrator twice.

### A server that is gone

A live task record that names a tmux server which no longer answers gets one warning on stderr per server, naming it, the tasks whose windows died with it, and the command that attaches once it is back. The warning is printed once per server per process and the check rides every pass, so a server that dies during a long `kingpin wait` is still named. `KINGPIN_SKIP_SOCKET_WARN=1` silences it.

### See also

See [Fleet Overview](fleet-overview.md#fleet-overview--visual-review-dossiers).

## kingpin ack

**Usage:** `kingpin ack <task-id>... | --all | --through <line>`

**Flags:** `--all`, `--through <line>`

**Environment:** `KINGPIN_HOME`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

The cursor never moves backwards and is clamped to the file. An archived task is a no-op that exits 0 with a note, and no cursor is written into the archive.

## kingpin land

**Usage:** `kingpin land <task-id>` (alias: `kingpin approve <task-id>`)

**Environment:** `KINGPIN_HOME`

### An archived task

`kingpin land <task-id>` on a task that already landed resolves its archive, prints `OK: task <task-id> is already finished; nothing to land` and exits 0, so a stale queue entry or a paste of an old id says why instead of claiming the id is unknown. A queued entry for such a task is dropped by the lane with the reason `archived`.

### A curator task

A task whose `task.env` carries `CURATOR=1` is dispatched to `kingpin curate --land` before the review-verdict gate is read. Its work is a PR in the skills checkout, and the human approval that reached `kingpin land curator` is its review gate, so there is no `review=` line to parse.

### The review gate

The review gate fails closed: it reads `review=` from the worker's last `ready:` line whatever the field order, and only `APPROVE` lands.

### Fix passes

`APPROVE WITH NITS` and `NEEDS CHANGES` (any case; `NEEDS_CHANGES` and `NEEDS-CHANGES` too) run `/fix-findings` first and say so; landing continues after the worker reports `fixed:`. That `fixed:` line has to report `high=0`: a line with `high` above zero sends `/review` again and exits 0 without landing, and a later `ready:` starts the next landing.

### Unreadable verdicts

An unrecognized verdict, a line with no `review=` field (or an empty or repeated one), a `fixed:` line without a numeric `high=<n>`, or a `fixed:` line whose `review=` is not `APPROVE` prints the line it could not parse and exits 1 without taking the landing lock. When the review is clean it says that landing is starting.

### The project lane

The project lane is claimed atomically, so two concurrent runs for different tasks cannot both dispatch. A holder whose worker reports `ready:`, `fixed:`, `needs-input:`, `feedback:` or `waiting:` after the landing was sent is released: the id and the reason go to stderr, the task's `landing_sent` marker is cleared so it can land again from the queue or the dossier, and the project's queue advances. A release that cannot run is named on stderr and retried on the next pass.

### A send failure

A `kingpin-send` failure (a dead worker window, for example) clears `landing_sent`, releases the project landing lock and exits 1, so the lane advances instead of wedging; if the release itself cannot take the lane's mutex it says so on stderr and names `kingpin done <id> --force`.

### The landing message

When the task names an issue, the dispatched message is the bare `/issue-flow-done <n>` and nothing else: that skill's input contract asks for exactly one issue number, so a note appended to the command reads as a malformed argument and can stall the landing. The order reaches the worker through the preamble every spawn receives (`worker/preamble.md`): the PR body says `Closes #<n>`, the merge closes the issue, then the worker checks that the issue is closed and its board item is in Done and reports `merged:`. The closing keyword lets the merge close the issue even when the worker dies mid-flow, and the board item is what the keyword cannot vouch for, since an issue the merge closed on its own can leave its item in Ready. The check has to happen before the report because `merged:` is the line the supervisor acts on: the cleanup archives the task and closes the window as soon as it reads that line.

### Queued landings

A queued landing is skipped when the task is gone, archived, finished or already dispatched.

## kingpin done

**Usage:** `kingpin done <task-id> [--force]`

**Flags:** `--force`

**Environment:** `KINGPIN_HOME`, `KINGPIN_LAVISH`, `KINGPIN_SKIP_MERGE_CHECK`, `KINGPIN_GH`

### Single-flight cleanup

Cleanup is single-flight per task: a second run while one is in progress says so and exits 0, so two concurrent runs call `treehouse return` once and archive once.

### A refused cleanup

A failed `treehouse return` refuses the cleanup, names the worktree and treehouse's reason in the `cleanup-refused:` line, and leaves the record in `tasks/` instead of archiving a task whose lease is gone.

### The lease-lost marker

The supervisor still retries a refused cleanup, but a task whose lease was lost carries a `lease-lost` marker in its task directory, so every retry re-reports that refusal with no network call and no external command until the owner runs `kingpin done <task-id> --force`, which bypasses the marker and re-attempts the full cleanup.

### Default-branch resolution and the merge check

The merge check resolves the default branch from the remote's `HEAD` (a read-only `git ls-remote --symref`, when the remote is reachable), then `origin/HEAD`, then `origin/master`, then `origin/main`, then the checkout's own `HEAD`, and a failed `git fetch` is reported on stderr rather than read as an unmerged commit: cleanup still succeeds when the last-known refs prove the merge, and the refusal names the fetch failure when they cannot. `KINGPIN_SKIP_MERGE_CHECK=1` skips the whole check, for a caller that verified the merge itself; the curator's automatic reconcile sets it.

### Queue handoff

The handoff to the next queued task skips entries that can no longer land (gone, archived, finished or already dispatched) and lands the next live one.

### The worktree guard

Refuses, even with `--force`, when another unfinished task records the same worktree.

### Status lines and the listener

A refusal is recorded as a `cleanup-refused:` status line only for a finished task (`merged:`, `failed:`); a worker that may still be live keeps its last status (for example `needs-input:`), and the reason goes to stderr. `done` also stops the task's dossier listener, and `kingpin ack` of an archived task is a no-op that exits 0 with a note.

### The issue a finished task names

A task record that carries `ISSUE` (or, for an older record, a worker's `issue: #<n>` line) gets one more step before the archive. When the merge check passed and `gh` reports the issue `OPEN`, `done` closes it and the `OK:` line says `closed issue #<n> after the merge`; an issue that is already closed is left alone and named `issue #<n> is closed`. A close that fails is reported as `issue #<n> is still open (close it by hand)`, and a state that cannot be read as `issue #<n> state could not be read (check that it is closed)`. The merge check is the permission: a `--force` cleanup or a missing worktree reports `issue #<n> not checked (the merge was not verified)` and never closes anything. A record that names no issue, such as a curator record, gets no readout at all. Every `gh` failure is part of the `OK:` line and never fails the cleanup. `KINGPIN_GH` overrides the command, as it does for `kingpin spawn`, `kingpin rename` and `kingpin curate`.

### The dossier link

After a successful archive, `done` leaves a symlink at `~/.kingpin/tasks/<task-id>` pointing at `~/.kingpin/archive/<task-id>`. A Lavish session, and a link handed to someone in chat, keep resolving `report.html` and the dossier's sibling assets through that path, where before the merge the page went blank. The link is not a live task: every fleet reader treats a symlinked `tasks/` entry as finished (it has no list row, raises no `wait` event, is never dispatched by `watch`, landed, listened to or cleaned again), and `kingpin done` answers a repeat run from it without touching treehouse. Before it ends the session, `done` posts one final reply saying the task landed and where the dossier is archived. The archive itself is never pruned: it is the record.

### What cleanup deletes

The tmux window, on the socket the task record names (`TMUX_SOCKET`; a record from before the split names none, and its window is on the default server), the task's Lavish listener with its pid file, and the browser daemons the task started (see [Browser daemons](#browser-daemons)). The window is resolved the way `peek` resolves it (name first, then a recorded id that still names this task's window), so a stale id after a server restart never kills a stranger's window. The worktree goes back to the treehouse pool as a clean slot, with the spawn's injected files and exclude file cleared. The worker's branches go: the branch it was on and the one recorded in `task.env`, never the default branch. The branch on `origin` is deleted only when the merge check passed, so a `--force` cleanup leaves it in place. The task record moves to `~/.kingpin/archive/<task-id>`, and a taken name gets the next free suffix (`<task-id>.2`, `<task-id>.3`, ...); nothing ever deletes the archive.

### Browser daemons

A worker that drove `chrome-devtools-axi` leaves a bridge daemon and its headless Chrome running after its turn ends, and nothing in the task record names it. Cleanup stops every daemon whose working directory is inside the task folder or the task's worktree, with the whole recorded process tree (SIGTERM first, then SIGKILL after two seconds), before `treehouse return` hands the slot back. The `OK:` line says what went, for example `OK: cleaned up task kp-120 (archived to ~/.kingpin/archive/kp-120; stopped 2 browser daemons (1.4 GB))`; a task that drove no browser keeps the shorter line. The check reads `ps` and each process's working directory (`lib/browser.sh`), so a daemon that belongs to another task is never killed, and neither is a process at the same path that is not a bridge daemon. A curator task (`NO_LEASE=1`) is checked for its task folder only: its recorded worktree is the shared skills checkout, where another session's browser must survive.

### A curator task and the last-task trigger

A curator task carries `NO_LEASE=1`: its worktree is the shared skills checkout, not a leased slot, so cleanup skips the `treehouse return` and the exclude clear (and needs no `--force`) while it keeps the clean-worktree check, the merge verification, branch deletion, the archive and the dossier link. The automatic curator reconcile skips only the merge verification, because `kingpin land curator` already checked the PR state and a `git fetch` in the operator's live skills checkout does not belong in a fleet tick; a hand-run `kingpin done curator` keeps it. After the archive, cleanup gives the auto-curate trigger one chance, so the last task leaving an idle fleet can start the day's curation the same way a supervisor sweep does. That check is non-blocking and cannot fail the cleanup.

## kingpin restore

**Usage:** `kingpin restore [<task-id> ...] [--harness <name>] [--dry-run] [--force]`

**Flags:** `--harness <name>`, `--dry-run`, `--force`

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_AGY`, `KINGPIN_OPENCODE`, `KINGPIN_PI`

Bring live tasks back after the tmux server dies. A window that is gone is created again, a window that came back as a plain shell under the task's name is respawned in place, and either way the window runs in the task's own worktree and on the branch the worktree has checked out. A name that another live task record also resolves to is never respawned: restore refuses it and names the conflict, because the window belongs to that other task. With no task ids it restores every live task under `$KINGPIN_HOME/tasks`, in sorted order.

The recorded harness is relaunched through the same `lib/launch.sh` a spawn uses, so the preamble, the harness wiring and the injected worktree files are the ones this task had. A record that carries a project's `PI_PROVIDER` and `PI_MODEL` (both written at spawn when the project sets them) relaunches `pi` with the same `--provider` and `--model`, so a restored pi worker comes back on its model. `--harness` launches another harness for this run and records it in `task.env` before the preamble is written, so the pi preamble sentence is there too.

### The resume brief

The harness restarts with no conversational memory, so `<task-dir>/resume-prompt.txt` names the task, project, worktree, branch, mode and harness, repeats the last *worker* status line (an `approved:` or `feedback:` note never decides it), and maps that line to one next step: a `ready:` task is told the review stands and not to land, a `fixed:` task checks the PR state for the merge, an open question waits for its answer, and a task whose landing was already sent is told to check whether the merge happened and never to run `kingpin land` again. The brief also repeats the house rules: one literal status line per event, questions through `question.md` and `needs-input:`, and never `kingpin spawn`, `lock`, `land`, `done`, `listen` or `send`. The window's launch script reads that file instead of the original `prompt.txt`, which stays in the task folder for reference.

### Refusals

A task that cannot be brought back is named on stderr as `kingpin-restore: refused <id>: <reason>`, nothing is deleted, and the run exits 1. Refused are:

- a finished task, named with its archive path;
- a missing task record or a `task.env` without `TASK_ID`, `PROJECT`, `WORKTREE` or `TMUX_TARGET`;
- a curator task (`NO_LEASE=1`), which `kingpin curate` owns;
- a task whose last worker event is `merged:`, `cleanup-refused:` or `failed:`, each with the command that finishes or replaces it;
- a missing worktree, a directory that is not a linked worktree, or a detached HEAD;
- a worktree that treehouse no longer reports as `leased`, or one whose lease cannot be verified;
- a window name that another live task record also resolves to, which restore will not reclaim;
- a harness command that is not installed.

The refusal changes nothing, so the record, the worktree and the branch survive for a later run.

### `--force`

`--force` covers the two advisory refusals only: a harness that still looks alive in its window, and a lease that cannot be verified. It never overrides a missing worktree, an archived task or a terminal status line, so no flag turns `restore` into a destructive command.

### `--dry-run`

`--dry-run` prints one `would restore ...` line per task and touches nothing: no window, no launch file, no `task.env` change, and no restore mutex. A task the real run refuses before it writes is refused here too, with the same line, so the plan shows those conflicts as well as the work. It is the way to see what a fleet-wide restore would do.

### One restore at a time

A restore takes `$KINGPIN_HOME/locks/restore.mutex` for the whole run, so two operators cannot both start a harness for one task. A second run names the holder and exits 1. A second restore over a healthy fleet prints `OK: <id> is already live (<session>:<name> (@N))` per task and starts nothing.

### Starting the supervisor again

The supervisor's pidfile died with the tmux server, so start `kingpin watch` again after a restore. Restore does not re-arm a review dossier's listener: that is the supervisor's job.

### Exit codes

Exits 0 when every named task was restored or was already live; 1 when any task was refused or another restore holds the mutex; 2 for a bad argument, including an unknown flag, an invalid task id or an unknown harness name.

## kingpin lock

**Usage:** `kingpin lock [status|check|acquire [--harness <name>]|release|harness] [pid]`

**Flags:** `--harness <name>`; `[pid]` is a positional argument

**Environment:** `KINGPIN_HOME`, `KINGPIN_HARNESS`, `KINGPIN_LOCK_PID`

`--harness` records `claude`, `agy`, `opencode`, `pi` or `codex`; without it, `acquire` detects the harness from the session process (including the `@earendil-works/pi-coding-agent` npm path) or from the calling agent's environment marker. `acquire` also warns on stderr when no fleet supervisor is running, and when the guard or the contract is missing or stale, even with `KINGPIN_SKIP_GUARD=1`, because it calls `kingpin guard check` directly. A numeric `[pid]` overrides the detected session pid, as does `KINGPIN_LOCK_PID`.

## kingpin afk

**Usage:** `kingpin afk [on [--ttl <duration>]|off|status]`

**Flags:** `--ttl <duration>`

**Environment:** `KINGPIN_HOME`

`on` arms auto-landing for this orchestrator session, `off` disarms it, and `status` prints `AFK: on until HH:MM (pid N)` or `AFK: off`. The state is the three-line file `$KINGPIN_HOME/afk` (holder pid, arm epoch, expiry epoch), published whole with a rename, and it is never a project or global setting.

`--ttl` takes one or more `<n><unit>` segments with unit `s`, `m` or `h` (`30m`, `8h`, `1h30m`); the default is `8h`. A bare number, an unknown unit, a zero total, an unknown subcommand or an unknown flag exits 2; a state file that cannot be written exits 1.

The arm reads as off once the expiry passes or the recorded pid is gone, so a session that died cannot leave the fleet landing on its own. `kingpin lock release` removes the file as well.

While armed, `kingpin watch` reacts to a new `ready:` line:

- a clean `APPROVE` verdict goes through `kingpin land` exactly as an operator's `kingpin land` would, and a landing that starts gains `approved: auto (afk)`; a line that only queues behind a busy project lane gains none, because the note records a decision that has completed;
- `APPROVE WITH NITS` and `NEEDS CHANGES` reach the same command, which starts the fix pass and waits for the re-review, so they never merge on that line. A clean `fixed:` landing that follows an AFK-started pass gains the same `approved: auto (afk)` note in `review` and `auto` mode alike, while a `fixed:` line that only queues gains none and drops its marker; a pass that still leaves High findings asks for `/review` and gains none. If the arm is off or expired by the time that `fixed:` line arrives, the landing still continues but gains no note;
- an unreadable verdict, a `needs-input:` question, a `cleanup-refused:` case and a `failed:` task hold for the operator, and nothing is forced.

The dossier listener's `landing_sent` and `approve_pending` markers are checked first, so an approval the listener already took is never landed twice. AFK adds no merge path: the verdict gate and the per-project landing lane are the ones `kingpin land` always uses. The `kingpin report check` warning belongs to `kingpin watch`, not to `kingpin land`: the supervisor runs it on the dossier in its review branch and, while AFK is armed, in the clean branch before it lands. With AFK off or expired, `kingpin watch` behaves exactly as before.

`kingpin list` prints the same `AFK: on until ...` line below the supervisor line only while the arm is live.

## kingpin guard

**Usage:** `kingpin guard [install|check|warn] [--dir <kingpin-checkout>]`

**Flags:** `--dir <kingpin-checkout>`

**Subcommand:** `kingpin guard hook <orchestrator|worker>` is the hook entry point.

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD`; `KINGPIN_TASK_DIR` and `KINGPIN_WORKTREE` are read by the `guard hook worker` entry point (`lib/guard-hook.mjs`).

`install` writes the hook into the checkout `--dir` names and refuses a linked worktree. The `orchestrator` hook denies `Edit`, `Write`, `NotebookEdit` and `Agent` in the main checkout of any repository, where the session's `git rev-parse --git-dir` equals `--git-common-dir`, and allows a linked worktree; a directory it cannot resolve to a git worktree is denied. `warn` is the quiet startup check `kingpin list` and `kingpin wait` run.

## kingpin scope

**Usage:** `kingpin scope files|check --harness <claude|agy|opencode|pi|codex> --worktree <dir> [--preamble <file>]`, `kingpin scope doctor --harness pi [--worktree <dir>] [--provider <name>] [--model <id>]`, and `kingpin scope doctor --harness codex [--worktree <dir>]`

**Flags:** `--harness <claude|agy|opencode|pi|codex>`, `--worktree <dir>`, `--preamble <file>`, `--provider <name>` and `--model <id>` (pi only)

**Environment:** `KINGPIN_PI`, `KINGPIN_CODEX`, `KINGPIN_SKILLS_DIR`, `CODEX_HOME`, `PI_CODING_AGENT_DIR`, `PI_PROVIDER`, `PI_MODEL`, `KINGPIN_WORKTREE` (the Pi extension), `KINGPIN_ALLOW_GLOBAL_CONTRACT`

`files` prints one `<kind>	<path>` line per instruction source that exists: `discovery` (a file the harness finds itself), `configured` (an entry of the worktree's harness config), `ignored` (a rules file the harness skips), `global` (loaded from your config directory in every session).

### `check`

`check` exits 1 naming the file when any source carries the orchestrator contract, including a global file in your own config directory (`KINGPIN_ALLOW_GLOBAL_CONTRACT=1` downgrades that one to a warning), and, for OpenCode and agy, when the preamble is not among the sources the harness loads (Claude Code gets it through `--append-system-prompt-file`, Pi through `--append-system-prompt`, and codex through `-c model_instructions_file`, so `check` does not verify those three). A codex worktree's sources are its `AGENTS.override.md` and `AGENTS.md`, every `<worktree>/.codex/skills/*/SKILL.md`, and, from the user's `${CODEX_HOME:-~/.codex}`, `AGENTS.override.md`, `AGENTS.md`, `hooks.json`, `skills/*/SKILL.md` and `config.toml`; nothing is edited.

### `doctor`

`doctor` is the pi harness readiness view: `pi: <path>`, `credentials: <state>`, `skills: <dir> (<n> skills)` (the count is `SKILL.md` files found recursively, which is what Pi discovers) and `extension: <path>`, then the same source list `files` prints. It reads the command from `KINGPIN_PI` (default `pi`), the skills directory from `KINGPIN_SKILLS_DIR` (default `~/.claude/skills`), Pi's config directory from `PI_CODING_AGENT_DIR` (default `~/.pi/agent`), and the extension from the checkout (`worker/pi/kingpin-harness.ts`).

The provider and model come from `--provider`/`--model`, or from `PI_PROVIDER`/`PI_MODEL` when the flag is absent (the same keys a pi spawn reads), and are passed to `pi auth check --no-refresh --json`, so the probe is local and offline. The credential line has three states: `ready (<provider>, <authType>)`, `not_ready (<reason>)`, and `unverified`. With no provider named the state is genuinely undetermined, so the line also reports what the agent directory holds: `holds credentials` when `<PI_CODING_AGENT_DIR>/auth.json` carries at least one entry, and `holds no credentials` plus the `pi` + `/login` action when it does not (Pi writes an empty `{}` before the first login). `--worktree` defaults to the current directory, and no subcommand with a harness or provider flag reads as `doctor`, so `kingpin scope --harness pi` is the short form.

Exit codes: 0 when the binary, credentials and extension are usable, or the credential state is `unverified`; 1 when the binary is missing, the extension is missing, or `pi auth check` reports `not_ready`; 2 for a bad argument, including `doctor` on a harness other than `pi` or `codex` and `--provider`/`--model` on the codex probe.

For codex, `doctor` prints `codex: <path>`, `credentials: <state>`, `config: <CODEX_HOME>/config.toml (<n> trusted project entries)` when the file exists, `skills: <dir> (<n> skills)`, then the same source list. The command comes from `KINGPIN_CODEX` (default `codex`), the config store from `CODEX_HOME` (default `~/.codex`), and the skills directory from `KINGPIN_SKILLS_DIR` (default `~/.claude/skills`). The credential state is read from the exit status of `codex login status`, never from its wording: exit 0 reads `credentials: ready (codex login status: <line>)`, and a non-zero exit reads `credentials: unverified (codex login status exited <n>: <line>; a provider configured through env keys or a custom provider is not visible here, so this is not proof the worker will fail)`. A logged-out host therefore exits 0; only a missing binary exits 1. The codex probe takes no `--provider` or `--model`: those flags belong to the pi probe, and passing either one with `--harness codex` is refused instead of silently ignored.

### Before a spawn

`kingpin spawn` runs `check` before it opens a window.

## kingpin report

**Usage:** `kingpin report diffs [--repo <dir>] [--base <ref>]` / `kingpin report check [--prose-only] <file>`

**Flags:** `--repo <dir>`, `--base <ref>`, `--prose-only`

### `diffs`

`diffs` prints the HTML for the file-diff section (every committed, uncommitted and untracked change, each with a static fallback and a `@pierre/diffs` call that passes `oldFile`/`newFile`).

### `check` and the layout pass

`check` exits 1 when a dossier would show blank diffs (`patch:` passed as a `FileDiff`/`render` option, which renders nothing; a comment or a string that only mentions it does not fail, `FileDiff` without `oldFile`/`newFile`, or an empty diff container), and runs a layout pass over a full page: it fails, naming the line, on a `<pre>` or inline `code` with no wrap rule, an `<img>` with no `max-width` rule, a table whose cells have no wrap rule, a grid/flex layout with no `min-width: 0` or `minmax(0, ...)` guard, and a `src`/`href`/`url()` that is an absolute path or climbs out with `..`. The same pass requires `data-lavish-annotate="off"` on the page's `<html>` element: Lavish otherwise opens the page in annotation mode, where a stray click adds an annotation card on a page the reader only wanted to read, while an explicit `"on"` is a deliberate choice and passes.

### The stylesheet parse and the palette

Before the layout pass, `check` walks every `<style>` block by brace depth. A declaration at the top level of a block, outside any selector (a bare `color-scheme: dark;` line, for example), is a parse error: the browser drops the rule that follows it, so the check fails naming that line and quoting it. After parsing, a page that claims `color-scheme: dark` must carry a `background` or `background-color` on `body`, `html` or `:root`, from a rule or an inline style, because a transparent body renders white. Presence is the contract, so a gradient, a `var(...)` value or a class on the body all satisfy it. Both passes judge a full page only, like the layout pass.

### The prose pass

It also runs a prose pass over the file: it fails with `file:line` and the offending line on the mechanical slice of the `unslop` skill (em dash, "testament to", "it's not just", "delve", "seamless", "in order to", "let me know", "I hope this helps"). In an HTML page it ignores code, diff output, script/style bodies and attributes. A `.md` or `.markdown` file is read as markdown: fenced blocks (backtick and tilde, nested fences included), indented code blocks, inline code spans and HTML comments are ignored, and the diff-section checks are skipped because a markdown file carries no diff section. `<!-- unslop:ignore -->` on a line is the single escape for both formats.

### `--prose-only`

`--prose-only` runs everything but the diff section (the layout and prose passes), for an artifact with no diff section. A markdown file is treated the same way whether or not the flag is passed.

### Required before `ready:`

The worker preamble and `AGENTS.md` require both the pass and the check before `ready:` and before an orchestrator artifact is served. Markdown answers to the same gate: run `kingpin report check --prose-only <file>.md` on a review report before it is handed back, and on an issue or pull-request body before `gh ... --body-file` files it.

## kingpin curate

**Usage:** `kingpin curate [--dry-run] [--auto] [--mark-applied <pr-url>] [--land]`

**Flags:** `--dry-run`, `--auto`, `--mark-applied <pr-url>`, `--land`

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_CURATOR_CMD`, `KINGPIN_SKILLS_DIR`, `KINGPIN_CURATOR_AUTO`, `KINGPIN_GH`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

`curate` is not harness-neutral. It needs a skills checkout, `KINGPIN_SKILLS_DIR` or the default `~/.claude/skills`, and a missing one dies with `kingpin-curate: skills directory <dir> not found` on a manual run; `--auto` reports one line and exits 0 instead, because a missing checkout must never fail a fleet tick. The curator runs through `KINGPIN_CURATOR_CMD`, then `KINGPIN_CLAUDE`, then `claude`, so a host whose only harness is agy or OpenCode has to set both the directory and the command.

### The branch and the PR

Curation is a pull request, never a write to the default branch of the skills checkout. The curator creates `curator/<YYYY-MM-DD>` from `origin/<default>`, commits only the skill files the batch justifies, pushes, and opens a PR. The applied marker is written at PR-open time, so a pending PR is not applied twice and a merged one stays auditable.

### The curator task record

A real run creates `~/.kingpin/tasks/curator` with `MODE=review`, `CURATOR=1`, `NO_LEASE=1` and `TMUX_SOCKET` naming the fleet server, and launches the curator into the existing `kingpin:curator` window there: the curator is a worker like any other, so its window is `tmux -L kingpin kingpin:curator`, not a window in your own session. The curator reports through the worker protocol: `ready: branch=<branch> review=PENDING report=<task>/report.html pr=<url>` starts a dossier listener, and `kingpin list` shows the row. `PENDING` is deliberate, so a curator can never auto-land: the review dossier's Approve & Land button runs `kingpin land curator`, and its Request Changes button queues the note for the orchestrator, which sends it to the curator window while it is alive (`kingpin send curator "..."`). Otherwise close the PR and run `kingpin curate` again. The task id `curator` is reserved; a `task.env` there without `CURATOR=1` makes the run refuse rather than overwrite a user's task.

### The automatic trigger

`kingpin watch` runs one check as the last step of every sweep, and `kingpin done` runs it after archiving the last task, so no daemon or timer is involved. `--auto` starts a curator only when all of these hold: `KINGPIN_CURATOR_AUTO` is not `0`; the skills directory is a git checkout; no run has been stamped today; no `kingpin:curator` window is alive; at least three critiques are pending; and the fleet is idle (no live task, no live `landing_in_progress` task, an empty `projects/*.landing_queue`, and no live `projects/*.landing` holder). The daily stamp is `$KINGPIN_HOME/curator/last-run`: line 1 the epoch, line 2 the local calendar day. It is written when the window exists, so a failed run still consumes the day and the next calendar day retries; a launch that failed before the window is retried on the next tick.

The trigger never waits: it takes the curator mutex with a single non-blocking attempt and skips when someone else holds it, reads local files only, and always exits 0. A landing in flight is therefore never delayed. The `kingpin:curator` window is settled before any record is reconciled, because `kingpin done` closes a window by its name: an existing live window makes it a no-op that prints one line and claims the day, and a dead pane is reaped and replaced. A live curator task whose last status is terminal is then reconciled through `kingpin done curator`, and a finished curator record's symlink at `tasks/curator` is dropped so the new record is a real directory. A live record that is not terminal, such as a curator waiting for review, holds the idle gate back and is named on stderr with its last status line and PR, so the fleet log says why the day started nothing.

### Consumed critiques and the applied marker

A critique applied by a successful run is stamped beside the file (`critique.consumed`) and is not collected again, including after `kingpin done` archives the task; a critique rewritten while the curator is running is left pending, so the next run collects the new bytes. When the PR opens, the critique is renamed to `critique.applied.<epoch>` and the URL is written beside it as `critique.applied.<epoch>.pr`. A closed-unmerged PR therefore leaves its critiques consumed but auditable by URL: to re-apply them, delete the task's `critique.consumed` and `critique.applied.*` files and run `kingpin curate` again. A failed, reaped or non-zero run before the PR opens leaves every critique pending.

### `--mark-applied <pr-url>`

Marks the published batch applied with the PR URL and exits with the helper's status. It refuses a PR whose base repository is not the skills checkout's origin, or whose head is not the branch the record opened. The curator calls it itself when the PR opens, and the launch wrapper calls it again after the child returns only as a fallback for a harness that exited before that step. It takes no mutex and writes no launch state. Calling it on an already-marked batch prints `OK: marked 0 critique(s)`.

### `--land`

Merges the curator's PR and finishes its record: it resolves `$KINGPIN_HOME/curator/pr`, refuses unless gh reports that PR's base repository as the skills checkout's origin and its head as the branch the record opened, refuses when the skills checkout is on its default branch, merges with `KINGPIN_GH`, verifies the state is `MERGED`, appends `merged: pr=<url>` to the task status, and runs `kingpin done curator`. `--delete-branch` is omitted in a linked worktree, which cannot switch its checkout. `kingpin land curator` dispatches here before its review-verdict gate, because the human approval that reached it is the review gate. A failed merge removes the `landing_sent` marker and leaves the PR open.

### `--dry-run` and serialized runs

`--dry-run` writes no file and leaves the previous run's `curator-input.txt`, `batch-critiques.txt` and `launch.sh` byte-identical. Manual runs are serialized, so one curator is published and launched at a time.

### Trust

It records trust for the skills directory with the same helper `kingpin spawn` uses, so the first run on an untrusted host shows no folder-trust dialog; `--help` prints usage without launching anything, and an unknown flag exits 2.


## Environment variables

| Variable | Effect |
|---|---|
| `KINGPIN_HOME` | Fleet state directory (default `~/.kingpin`): `tasks/`, `archive/`, `projects/`, `locks/`, `supervisor.pid` and `config.env`. |
| `KINGPIN_HARNESS` | Harness recorded by `lock acquire` when `--harness` is omitted (before the command-name and agent-marker detection). |
| `KINGPIN_CLAUDE` | Command `spawn` and `restore` launch for the `claude` harness (default `claude`). |
| `KINGPIN_AGY` | Command `spawn` and `restore` launch for the `agy` harness (default `agy`). |
| `KINGPIN_OPENCODE` | Command `spawn` and `restore` launch for the `opencode` harness (default `opencode`). |
| `KINGPIN_PI` | Command `spawn` and `restore` launch for the `pi` harness (default `pi`); `kingpin scope doctor` probes the same command. |
| `KINGPIN_CODEX` | Command `spawn` and `restore` launch for the `codex` harness (default `codex`); `kingpin scope doctor --harness codex` probes the same command. |
| `KINGPIN_GH` | `gh` command `spawn` uses to read an issue title for the task slug, `curate` uses to create, view and merge the curator's PR, and `done` uses to read and close the issue a finished task names (default `gh`). |
| `KINGPIN_TMUX_SESSION` | tmux session on the fleet's own server that `spawn` places the worker window in when `--tmux-session` is not given. The session must already exist; an unknown name is refused. Unset, the spawn uses the one attached session on the fleet server, then the only one it holds, and refuses when several are unattached or more than one is attached. |
| `KINGPIN_SEND_DELAY` | Seconds between the literal text and the Enter key (default `0.2`). |
| `KINGPIN_MUX` | Multiplexer the fleet creates and reads workers with: `tmux`, `herdr`, or `auto` (default). `auto` selects Herdr only inside a Herdr pane (`HERDR_ENV=1`) and tmux everywhere else; any other value is refused by name. A task record's `MUX=` line, not this variable, decides where an existing task lives. |
| `KINGPIN_HERDR_SESSION` | Name of the fleet's Herdr session (default `kingpin`, the same name the tmux socket uses). The session must already be running: `herdr server` is a foreground process the operator owns, and nothing in Kingpin starts it. Inside a Herdr pane the inherited `HERDR_SESSION` is used instead. |
| `KINGPIN_TMUX_SOCKET` | Name of the tmux server the fleet uses (default `kingpin`, that is `tmux -L kingpin`), so worker windows are not on your own server; `default` puts them back on it. `kingpin spawn` records the name in `task.env` as `TMUX_SOCKET`, and every window reader resolves the record's socket. The test suites point it at their own socket. |
| `KINGPIN_CURATOR_CMD` | Command `curate` launches the curator with; falls back to `KINGPIN_CLAUDE`, then `claude`. |
| `KINGPIN_CURATOR_AUTO` | `0` disables the automatic curator trigger, so `kingpin watch` and `kingpin done` never launch one; unset or any other value leaves it on. The test suites set `0`. |
| `KINGPIN_SKIP_MERGE_CHECK` | `1` skips the merge verification (the ancestor check and its `git fetch`); the curator's automatic reconcile sets it, because `kingpin land curator` already verified the PR state. Not for hand-setting. |
| `KINGPIN_SKILLS_DIR` | Skills directory the curator works in (default `~/.claude/skills`); `kingpin scope` counts its `SKILL.md` files and checks them for the contract, and the Pi extension bridges it into Pi's skill discovery. |
| `KINGPIN_LAVISH` | `lavish-axi` command the listener drives (default `lavish-axi`). |
| `KINGPIN_STATUS_GRACE` | Seconds a worker may stay silent before `wait`/`watch`/`run` record `failed: no status:` (default `30`). |
| `KINGPIN_ALLOW_GLOBAL_CONTRACT` | `1` downgrades a contract found in a global instruction file to a warning instead of a refusal. |
| `KINGPIN_SKIP_GUARD` | `1` silences `kingpin guard warn`, which `kingpin list` and `kingpin wait` call, and the install `kingpin init` runs; it does not silence `kingpin lock acquire`, which runs `kingpin guard check` directly, or a hand-run `kingpin guard install`/`check`. Set by the test suites and scripted setups. |
| `KINGPIN_SKIP_SOCKET_WARN` | `1` silences the warning `kingpin list` and `kingpin wait` print when a live task record names a tmux server that is not running. Set by scripted setups and the suites. |
| `KINGPIN_LOCK_PID` | A whole-number pid `lock acquire` records as the session pid instead of detecting one; the test suites use it. |
| `KINGPIN_TASK_DIR` | Set by `kingpin spawn` to the task folder (`~/.kingpin/tasks/<id>`) so the Stop hook can write `status`. Not for hand-setting. |
| `KINGPIN_ROOT` | Set by `kingpin spawn` to the Kingpin checkout, so a hook finds `bin/kingpin-stop` even after the worker `cd`s elsewhere. Not for hand-setting. |
| `KINGPIN_WORKTREE` | Set by `kingpin spawn` to the leased worktree; the worker's `PreToolUse` hook allows edits only inside it and the task folder, and the Pi extension's `project_trust` answer covers only it. Not for hand-setting. |

`grep -rl KINGPIN_<name> bin lib worker` is the honest reader list, and it cannot tell a reader from a writer (a spawn sets `KINGPIN_TASK_DIR`), which is why this table carries no `Read by` column; each command's section above names the variables it reads.

## Internal helpers

Two scripts in `bin/` are not `kingpin` subcommands. `kingpin wait` calls them as it scans tasks (`kingpin-launch-check` for a task with an empty `status`, `kingpin-rename` when a task has new status lines); run them by hand only to debug.

- `bin/kingpin-launch-check <task-dir>`: finds a worker that died at launch (its `status` file is still empty). Once the task is older than the grace period (`KINGPIN_STATUS_GRACE`, 30 seconds, counted from the last stop or from launch) and its terminal is gone, or the Stop hook fired and the terminal stayed silent without a working marker, it appends and prints `failed: no status: ...`. Exits 0 when it recorded that line, 1 when it recorded nothing, 2 for a bad argument.
- `bin/kingpin-rename <task-id>`: renames the terminal and the record's name of a `--text` task to `kp-<n>-<slug>` once the worker has reported `issue: #<n>` (`TMUX_TARGET` for a tmux task, `MUX_LABEL` for a Herdr one). The task ID, folder, branch and worktree keep their first name. It is idempotent (a `renamed` marker in the task folder) and a no-op for tasks that already have an issue or no `issue:` line.

`bin/kingpin-launch-check`, `bin/kingpin-rename` and the `kingpin-stop` hook read the task's mux with `KINGPIN_MUX` and `KINGPIN_HERDR_SESSION`, like the commands that call them.
