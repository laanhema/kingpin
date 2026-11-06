# CLI Command Reference

[Back to the README](../README.md).

## Conventions

Every command prints its usage on `--help` (or `-h`) and exits 0, and an unknown flag exits
non-zero. A success line starts with `OK:` on stdout, and a refusal goes to stderr and exits
non-zero. A startup check that only warns still exits 0: `kingpin guard warn`, a
`kingpin listen` without `lavish-axi`, and a `kingpin curate --auto` whose checkout is
missing are the cases, and their sections say which check ran. Where a command has exit codes
of its own, its section below lists them.

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

`merged:`, `failed:` and `cleanup-refused:` keep the exits they had, with one addition for `merged:`: when the checks on the merged pull request were FAILED or PENDING (see [`The checks of the merged pull request`](#the-checks-of-the-merged-pull-request)), `run` prints `kingpin run: <id> merged and cleaned up, but pull request checks FAILED (<url>)` on stderr in place of the `OK:` line, and still exits 0. While AFK is armed it does not run `kingpin done` itself over the supervisor's hold: it prints `kingpin run: <id> merged but pull request checks FAILED (<url>) (afk on); the cleanup is held for the operator: kingpin done <id>` on stderr and exits 1, leaving the task live. A PASSED or UNREADABLE result keeps the `OK:` line.

## kingpin watch

**Usage:** `kingpin watch [--once] [--interval <sec>]`

**Flags:** `--once`, `--interval <sec>`

**Environment:** `KINGPIN_HOME`, `KINGPIN_LAVISH`, `KINGPIN_GH`

### Each cycle

Each cycle also advances a project's landing queue whose holder released or is gone, so an ownerless queue recovers on its own, and re-arms a review task's dossier listener that died (missing or dead `listener.pid`) unless the reviewer ended the session, the task finished, a landing is under way, the task runs in `auto` mode, or its last worker event is not `ready:`/`fixed:`.

It also retires a finished task's dossier. For a finished record that reached that state without `kingpin done` (an archive from before the marker existed, a `failed:` task) it marks the page the same way `kingpin done` does, and for any finished record it ends the Lavish session a reviewer left open on it, once, writing a `dossier.ended` marker so a later sweep makes no second call. A record that is not finished is left alone, including a hand-archived one whose work may still be going. A record that never recorded a `dossier.url`, one that already carries `dossier.ended`, and one with no `report.html` are skipped. `--once` runs the same sweep.

### What a status line dispatches

Every unprocessed status line is dispatched once, in file order, and the task's `seen` cursor advances line by line, so a line a dispatch appends stays pending for the next pass and a supervisor restart resumes at the first undispatched line. A blank line and an `issue:` line advance the cursor without dispatching anything. A `ready:` line starts a landing in `auto` mode; in `review` mode it continues a landing already in progress, or opens the task's dossier listener. `fixed:` continues a landing in `auto` mode or after a fix pass. `merged:` reads the checks of the pull request on the line first (see [`The checks of the merged pull request`](#the-checks-of-the-merged-pull-request)) and then runs `kingpin done` unless the task carries a `done_cleaned` marker; while AFK is armed, a FAILED or PENDING rollup holds the cleanup instead, with a line that names `kingpin done <id>`. `cleanup-refused:` is logged and the cleanup is retried on every cycle. `approved:`, `feedback:`, `checks:`, `needs-input:`, `waiting:` and `failed:` are logged for the operator, and nothing else runs for them. While AFK is armed, a `ready:` or `fixed:` line goes through the AFK path first (see [`kingpin afk`](#kingpin-afk)).

### A status file rewritten under its cursor

The cursor is a line count paired with the text of the handled line, so a file a worker rewrote is noticed rather than silently skipped. The supervisor logs `[kingpin-watch] <id> status file was rewritten under its cursor (<n> line(s), seen <m>); resuming at line <k>` on stderr, moves the cursor to the line it resumes at, and dispatches from the next one. This is the only cursor move that goes backwards, and it is a repair: after it the file reads as intact again, so the line appears once per rewrite.

### A tmux server that died

Before the wait pass of every cycle, and in `--once`, the supervisor checks each socket a live task record names. When one no longer answers it logs `the tmux server '<socket>' is not running; restoring <ids>` and runs `kingpin restore` for the tasks on that socket, which recreates the session (and with it the server) and re-arms each window with a resume brief. Curator tasks and tasks whose last status is terminal are skipped, because restore refuses them by name, and a `MUX=herdr` record is skipped because it is not on a tmux server at all. Running it before the wait pass means a restored window is back before `exited` would be raised for it. A supervisor that was itself running inside the server that died dies with it, so start `kingpin watch` outside the workers' server; see [Who owns the server](#who-owns-the-server).

### `--interval`

`--interval` takes a whole number of seconds, at least 1 and at most nine digits; anything else exits 2, and a `kingpin wait` that fails is retried after one warning on stderr and a two-second pause, so an unusable fleet directory cannot spin the loop.

### The pidfile

It claims `~/.kingpin/supervisor.pid`, refuses a second copy with the running pid named, reclaims a pidfile left by a dead supervisor, and `--once` runs one pass without claiming it (that is the path `kingpin run` and the tests use). `kingpin wait` is the primitive it drives.

### One sweep at a time

The loop and `--once` dispatch events and run the maintenance steps through one shared sweep, holding `$KINGPIN_HOME/locks/watch-sweep.mutex` for the pass. That is what keeps a line to one dispatch when `kingpin run` sweeps beside the supervisor: the second sweep reads the cursor after the first acknowledged the line and finds nothing pending. A sweep that finds the lock held waits a few seconds for it and then skips this pass, naming the holder on stderr. `--once` exits 0 and never refuses; the loop logs the skip and tries again on its next wait, because the line is still un-acked. A live sweep refreshes the mutex file's mtime every 15 seconds while it holds the lock, so a pass that runs past the one-minute staleness rule (a slow `merged:` cleanup, a dossier retirement over a long archive) is not taken for a dead holder. A sweep that dies while holding the lock leaves a stale one, which the next sweep reclaims when its pid is gone or the file is a minute old.

### Running it as a systemd user service

The normal deployment is the `kingpin-watch` user unit shipped with the checkout at `systemd/kingpin-watch.service`. It mirrors `kingpin-queue.service`: `Type=simple`, `Restart=always`, `RestartSec=30` and `WantedBy=default.target`, so a crashed supervisor is back within 30 seconds and starts again after a reboot. Install it from the Kingpin checkout:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/kingpin-watch.service ~/.config/systemd/user/
# edit ExecStart if the checkout is not ~/github/kingpin
systemctl --user daemon-reload
systemctl --user enable --now kingpin-watch
loginctl enable-linger "$USER"
```

`systemctl --user enable --now kingpin-watch` starts the unit now and at every login, and `loginctl enable-linger "$USER"` keeps the user manager, and with it the unit, running after you log out. Without linger a user unit stops when the last session ends. Check the result with `systemctl --user status kingpin-watch`; the `MainPID` it prints is the pid `kingpin list` reports in its `Supervisor: running (pid <n>, since <HH:MM>)` line.

The unit carries a `PATH` that reaches `gh`, `tmux`, `treehouse`, `lavish-axi` and the worker harnesses, because a user unit does not inherit your login shell's `PATH`. Extend `Environment=PATH=` when your harness lives outside the directories it names, and change `ExecStart=` when the checkout is not at `~/github/kingpin`. The unit does not set a tmux socket: the fleet follows the socket each task record and `$KINGPIN_HOME/config.env` name, and the unit never owns that server.

A host without systemd, or a one-off run under a supervisor of your own, still starts the foreground command directly: `kingpin watch`.

### Exit codes

`--once` exits 0 after one pass, and a running supervisor exits 0 on `INT` or `TERM`. It exits 1 when a second copy is already running (naming its pid) or when the pidfile cannot be claimed, and 2 for a bad `--interval`, an unknown argument or an unknown flag.

## kingpin spawn

**Usage:** `kingpin spawn <proj> (--issue <n> | --text <req>) [--mode review|auto] [--id <task-id>] [--harness <name>] [--tmux-session <name>]`

**Flags:** `--issue <n>`, `--text <req>`, `--mode review|auto`, `--id <task-id>`, `--harness <name>`, `--tmux-session <name>`

- `--issue`: an existing GitHub issue: the worker runs /issue-flow (review) or /do (auto)
- `--text`: a free-text request: the worker runs /create-issue first, then the same
- `--mode`: review (default) stops at a ready branch for the review; auto merges when green
- `--id`: task id; defaults to kp-<n>-<slug> (issue title) or kp-<slug> (request)
- `--harness`: worker harness: claude, agy, opencode, pi, or codex (overrides the project and the lock)
- `--tmux-session`: tmux session on the resolved server to place the worker window in; it must already exist (see [Choosing the session](#choosing-the-session))

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_AGY`, `KINGPIN_OPENCODE`, `KINGPIN_PI`, `KINGPIN_CODEX`, `KINGPIN_GH`, `KINGPIN_TMUX_SOCKET`, `KINGPIN_TMUX_SESSION`; `TMUX_SOCKET` and `TMUX_SESSION` in `$KINGPIN_HOME/config.env` are the fleet-wide default for both, read when the matching environment variable is unset. The `kingpin scope check` it runs reads `KINGPIN_ALLOW_GLOBAL_CONTRACT`, and a codex spawn also reads `KINGPIN_SKILLS_DIR` and `CODEX_HOME`.

The task record carries `BASE_SHA`, the commit the branch was leased at, before any worker commit. `kingpin done` compares it with the branch's `HEAD` to tell a branch with work from one without.

### Which harness

The spawn picks the first of these that is set: `--harness <name>`, `HARNESS` in the
project's env file (only when it was set explicitly, as `kingpin init --harness` does), the
harness the orchestrator lock recorded, `DEFAULT_HARNESS` in `$KINGPIN_HOME/config.env`,
then `claude`. `kingpin lock acquire` records the orchestrator's own harness, and
`kingpin lock status` shows it. A project file written by an older `kingpin init` carries
`HARNESS=claude`, which counts as set; delete that line to let the lock holder decide.

### Where the window lives

A worker lands where the fleet says, not always on a server Kingpin owns. A spawn started inside tmux follows the caller's own client, so the worker appears in your session on your server; a spawn started outside tmux uses the fleet server `kingpin` (`tmux -L kingpin`) or whatever socket `TMUX_SOCKET`/`KINGPIN_TMUX_SOCKET` names. `TMUX_SOCKET` is a `-L` name, or a socket path when the value holds a `/`, which is how a caller's own server is recorded. `KINGPIN_TMUX_SOCKET=kingpin`, or `TMUX_SOCKET=kingpin` in `$KINGPIN_HOME/config.env`, keeps workers off your server: that is the isolation of #142, and it is the right setting for a fleet you do not want a `tmux kill-server` to reach. The task record carries both facts, `TMUX_SOCKET` for the socket and `TMUX_TARGET` for `<session>:<task-id>`, and every command that reads a worker window takes both from the same record. A `task.env` written before the split carries no `TMUX_SOCKET`: its window really is on the default server, so the readers resolve it there.

Sharing your server has a price: `tmux kill-server` there ends every worker on it. `kingpin watch` and `kingpin restore` bring the windows back from their records, including through a recorded socket path.

A worker's terminal can also be a Herdr pane. The backend is chosen per fleet by `KINGPIN_MUX`: `tmux` (or unset outside a Herdr pane) keeps the tmux server above, `herdr` uses Herdr, and `auto` picks Herdr only when the command itself runs inside a Herdr pane (`HERDR_ENV=1`). A value other than `auto`, `tmux` or `herdr` is refused by name. `KINGPIN_HERDR_SESSION` names the fleet's Herdr session (default `kingpin`, the same name the tmux socket uses); that session must already be running, because `herdr server` is a foreground process the operator owns, and Kingpin neither starts nor supervises it. Inside a Herdr pane the inherited `HERDR_SESSION` is used instead.

The mux belongs to the task record, not to the process, so one fleet can hold a tmux worker and a Herdr worker at once. A record with `MUX=tmux` or no `MUX=` line at all is a tmux task, forever, and a record with `MUX=herdr` names `MUX_SESSION`, `MUX_TARGET` (the pane id) and `MUX_LABEL` (the re-resolution key, because Herdr renumbers a pane that moves across workspaces). There is no migration step: `kingpin send`, `peek`, `done`, `ack`, `curate`, `list`, `wait` and `brief` read the record and reach the right backend, and so do the `stop`, `launch-check` and `rename` helpers and the curator's window check. An orchestrator running inside a Herdr pane that wants tmux workers sets `KINGPIN_MUX=tmux`. `kingpin spawn` still creates tmux workers in this change, so it refuses a Herdr fleet by name before it resolves a target or leases a worktree: `refusing to spawn: the fleet's mux is herdr, and kingpin spawn cannot create a Herdr worker yet (issue #204); run with KINGPIN_MUX=tmux`. `kingpin restore` refuses a `MUX=herdr` record the same way, naming the record, the mux and #204, so no command half-creates a Herdr worker. `kingpin curate` under `KINGPIN_MUX=herdr` refuses with two lines that name the mux and the way back (`KINGPIN_MUX=tmux`): the backend's `herdr: creating a terminal for a task is not wired up yet (issue #144 phase E); run with KINGPIN_MUX=tmux`, then `kingpin-curate: could not launch the curator in herdr --session <name> curator`.

To look at a worker's window by hand, use the attach command `kingpin list` prints under the task rows: a plain `tmux attach` for the default server, `tmux -L <name> attach` for a named socket, and `tmux -S <path> attach` for a recorded socket path. From inside your own session, `TMUX= tmux -L kingpin attach -t kingpin` reaches the separate fleet server on the default setup instead of switching your client's server. `kingpin peek <task-id>` reads one pane without attaching.

### Who owns the server

`kingpin watch` does, and no systemd unit or timer owns the tmux server. The `kingpin-watch` unit only keeps the supervisor process alive; it names no socket. The socket is data, not configuration: each task record names its own `TMUX_SOCKET`, a fleet can hold records on more than one server during a move between them, and the same fleet may be running on the operator's default server (`KINGPIN_TMUX_SOCKET=default`) on one host and on a server of its own on the next. A unit that owned the server would have to name one socket, and on the operator-server configuration it would be a second owner for a server that is not the fleet's. So the supervisor owns the lifecycle of whatever socket the records name: on every sweep it checks each socket a live task record names, and when one no longer answers it hands that socket's tasks to `kingpin restore`, which recreates the session (and with it the server) and re-arms each window with a resume brief. The `OK:` line of a `kingpin spawn` that had to start the server itself says so, for example `, started the tmux server on socket 'kingpin' (it was not running)`.

The one thing this cannot cover is a supervisor that was itself running inside the server that died. Run `kingpin watch` outside the workers' server, which is what the shipped `kingpin-watch` unit does; on the operator-server configuration that is the same server your own session lives on, and its own lifecycle belongs to whatever started it (a systemd `tmux.service`, or your own tmux). When that server is back, the next sweep restores the windows. The supervisor follows the socket each record names, not a configured one, so a worker placed in the caller's session on the caller's server is restored there too, with `tmux -S <path>`.

### Window names

The window is pinned with `automatic-rename off` and `allow-rename off`, so ambient tmux settings and worker child commands cannot rename it; only `kingpin-wait` renames it.

### Choosing the session

The socket and the session are resolved together, never guessed, and each source is read once:
`--tmux-session <name>`, then `KINGPIN_TMUX_SESSION`, then `TMUX_SESSION` in
`$KINGPIN_HOME/config.env`, then the caller's own tmux session. A named session is resolved on the
resolved socket and must already exist, and an unknown name is refused instead of starting a
session for it: the refusal names the session, its source (`TMUX_SESSION in <path>`) and the
server. A user-typed target (`--tmux-session` or `KINGPIN_TMUX_SESSION`) may be an unambiguous
prefix, and the name tmux resolved it to is what gets recorded; a `TMUX_SESSION` from the config
file is matched exactly, so a `kingpin-workers` session is never taken for `kingpin`. Naming a
socket suppresses the caller default only, because the caller's session lives on
another server: `KINGPIN_TMUX_SOCKET` or `TMUX_SOCKET` still lets a configured `TMUX_SESSION`
apply, and a pair that does not exist on the chosen socket is refused with both sources named.
Outside tmux, or with a socket named, the spawn uses the one session a client is attached to on
that server, then the only session it holds. Several sessions with no client attached, or more than
one attached session, are refused, with every candidate named and all three ways to name a target.
Only a server with no session at all gets a `kingpin` fallback, and one `kingpin:` note on
stderr, from either `spawn` or `curate`, says the run created it. The resolution runs before the
worktree is leased, so a refusal costs no worktree and leaves no task record. The `OK:` line names
the chosen session and where it came from, for example `session from --tmux-session`, `session from
TMUX_SESSION in .../config.env`, or `session the caller's tmux session ($TMUX)`.

Sharing the operator's server means `tmux kill-server` there ends every worker on it. `kingpin
watch` and `kingpin restore` recreate the session and re-arm the windows from their records, so a
fleet on your server comes back the same way.

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

The `SESSION` column names the mux session the worker lives in: for a tmux task, the tmux session holding its window, read from the live window so a window moved to another session is reported where it really is, not where it was spawned; for a `MUX=herdr` task, the Herdr session its record names. Both are resolved through `lib/mux.sh`, and a task with no recorded terminal and no recorded target shows `-`.

A finished task is shown from `archive/` (with `--all`), never from the dossier link `kingpin done` leaves at its old `tasks/` path: that path resolves a review page, it is not a live task. An archived row has no live window left to read, so its `SESSION` shows the session recorded at spawn, or `-` when none was recorded.

A `checks:` note on a merged task is the row's last status, so a merge on a red rollup shows `checks: pr=<url> checks=FAILED` in the row (see [`The checks of the merged pull request`](#the-checks-of-the-merged-pull-request)).

The `STATE` column marks `WAITING` (blocked on a human), `SILENT` (a Stop without a report) and `DEAD`: a live task whose terminal is gone, or whose recorded harness pid (`harness.pid`) is no longer the pane's. A tmux server that died therefore reads as a dead fleet instead of a healthy one, and one `Fleet: <n> live task(s) have no live window; run kingpin restore` line follows the table, counting the dead tmux tasks: `kingpin restore` refuses a Herdr record until #204, so a dead Herdr row is named `DEAD` without being counted. `DEAD` combines with `Unseen: N` the way the other states do.

Every live task whose folder holds a `report.html` gets its dossier line printed below its row, whatever the task's mode or status: the Lavish session URL the listener recorded in the task's `dossier.url` when it opened the page, or the `lavish-axi <path>` command when no URL is recorded yet. Hand the URL over instead of running the command, which opens a second tab on the session the listener already opened (issue #146). The line is followed by `(listening: pid <n>)` while that task's listener runs, and by `(no listener)` when none does, so a page nobody will answer is not read as a review waiting on a decision. A finished or archived row gets no dossier line.

A session a reviewer left open on a finished task is named separately, under `Dossiers left open on finished tasks (kingpin watch ends them):`, with one row per record that recorded a `dossier.url`, still holds its `report.html`, and has no `dossier.ended` marker. Archived records are included even without `--all`, because the table hides their row and the open tab would otherwise be invisible. Each row names the task id and the session URL, and `kingpin watch` ends that session on its next sweep.

Every live row whose terminal is still alive also gets a `↳ Window:` line naming the mux, the session and the target that hold the worker, for example `↳ Window: tmux -L kingpin kingpin (@3)`, or `↳ Window: tmux -S /tmp/tux-1000/tmux-1000/probe probe (@1)` for a recorded socket path, or `↳ Window: herdr --session kp144 kp-144-list (w1:p7)` for a Herdr task, where the word after the session is the pane label the task resolves by. The footer prints one attach command per socket the live records actually name, for example `Workers live on the tmux server 'default': tmux attach (kingpin peek <task-id> reads one pane)`, and one `Workers live in the herdr session 'kp144': kingpin peek <task-id> reads one pane` line per Herdr session instead of an attach command, because a Herdr session has no attach in the contract Kingpin uses; a fleet with no live task names the fleet server a spawn uses outside tmux. The footer reads the records, not your `KINGPIN_TMUX_SOCKET`, so it never points at a server that holds no worker. A worker whose pane is gone gets no line, so the line never points at a session that is empty. A task record from before the split has no socket, so its line reads `tmux kingpin (@n)`: that window is on the default server.

When a live task record names a tmux server that is not running, `kingpin list` prints one warning on stderr naming that server, the tasks whose windows died with it, and the command that attaches once it is back, for example `kingpin: the tmux server 'kingpin' is not running; live tasks kp-1, kp-2 name it and their windows are gone. Attach once it is back: tmux -L kingpin attach; kingpin watch restarts it and runs kingpin restore (or run kingpin restore yourself)`. `kingpin wait` prints the same line once per server per process. Set `KINGPIN_SKIP_SOCKET_WARN=1` to silence it, the same kind of switch `KINGPIN_SKIP_GUARD=1` is for the guard warning. A `MUX=herdr` record is left out of the check on purpose, because socket health is a tmux-server concern: a Herdr session belongs to the operator (`herdr server` is a foreground process nothing in Kingpin starts or supervises), a lost pane is gone rather than left behind by a dead server, and per-record reachability is already `kingpin peek`'s business. A Herdr-only fleet therefore prints no socket warning and no `run kingpin restore` hint for it.

A live row whose task holds a browser daemon also gets `↳ Browser: 1 daemon, 412 MB (pid 1234)`: the `chrome-devtools-axi` bridge the task started, with its `chrome-devtools-mcp` child and headless Chrome, summed over the whole process tree. The scan takes one `ps -eo pid=,ppid=,rss=,args=` snapshot of the host and totals each daemon's tree from that snapshot, so it costs one `ps` however many daemons it finds (`lib/browser.sh`). Ownership is the daemon's working directory, so only a daemon started from the task folder or the task's worktree is counted (`lib/browser.sh`), and only a process whose argv runs the bridge script counts: a log tail or an editor that merely names it is neither listed nor stopped. A task that drives no browser gets no line, and an archived row never gets one, because `kingpin done` stops the daemons before it archives the task. A daemon left by a task archived before this change still runs, and no Kingpin command lists or stops it: its record is under `~/.kingpin/archive/<task-id>`, which `kingpin list` does not scan, and `kingpin done` only runs for a live task. Stop one by hand: find its pid, check that its working directory is that archive path (`readlink /proc/<pid>/cwd` on Linux, `lsof -a -p <pid> -d cwd -Fn` on macOS), and kill it. Two or more daemons print as `2 daemons` with their pids comma-separated.

## kingpin brief

**Usage:** `kingpin brief`

**Environment:** `KINGPIN_HOME`

One screen of fleet state for a session that has just started, so a node or an
orchestrator coming back after a compaction does not have to re-derive the fleet from
task directories and logs. It reads the records the fleet already writes, prints the
digest, and exits. It creates no file and no directory, starts no terminal and no
supervisor, so it is safe on a read-only fleet home, and an unknown argument exits 2.

```
Fleet: 4 live task(s), 1 waiting for approval, 1 dead - run kingpin restore
Supervisor: running (pid 4812, since 14:03)
AFK: on until 16:40 (pid 4790)
Queue: 4 waiting, paused (queue/pause)

TASK ID                PROJECT    HARNESS  MODE         STATE        NEWEST STATUS
-------                -------    -------  ----         -----        -------------
kp-188-todo-5-give     kingpin    claude   review       Unseen: 2    ready: branch=b review=APPROVE report=.agents/reviews/188-review.md
kp-189-todo-6-add      kingpin    claude   review       WAITING      needs-input: which board column?
kp-187-todo-4-fix      kingpin    codex    review       DEAD         fixed: high=0 report=.agents/reviews/187-review.md
kp-190-todo-7-x        kingpin    claude   auto         Unseen: 1    issue: #190 https://github.com/laanhema/kingpin/issues/190

Waiting for approval:
  kp-188-todo-5-give     APPROVE                            report: .agents/reviews/188-review.md

Dossiers without a listener:
  kp-188-todo-5-give     http://lenovo-thinkpad:4387/session/9f2c

Landing lanes:
  kingpin                holder kp-190-todo-7-x, 2 queued
```

The `Fleet:` line counts the live records: a cleaned-up record and the dossier link
`kingpin done` leaves at the old task path are not live, the same rule `kingpin list`
uses. When at least one live tmux record has no window, the line carries the dead count and
the `kingpin restore` hint; a dead Herdr record appears in the table as `DEAD` but is not
counted there, because `kingpin restore` refuses a Herdr record until #204.

`Supervisor:` and `AFK:` are the lines `lib/supervisor.sh` and `lib/afk.sh` print
elsewhere, read from `$KINGPIN_HOME/supervisor.pid` and `$KINGPIN_HOME/afk`; `AFK: off`
stands in while the switch is not armed.

`Queue:` reads the issue-queue runner's own state under `$KINGPIN_HOME/queue/`: `queue`
holds one issue number per line, and a `pause` file beside it makes the runner idle. The
line names the pause file, because removing it is how a pause ends. Kingpin only reads
that directory and never writes it, so a host with no queue runner prints `Queue: none`.

The table prints one row per live task. Its columns are the task id, the recorded project,
harness and mode, the state, and the newest status line, listener notes included. The
state is not the digest's own opinion: `kp_task_state` in `lib/status.sh` decides it for
`kingpin list` as well, so the board and the digest always agree.

| State | Meaning |
|---|---|
| `DEAD` | the worker's window is gone, or the recorded harness no longer runs in it. Run `kingpin restore` |
| `WAITING` | the window is still there and the newest line blocks on a human: `needs-input:`, the listener's `feedback:`, or the Stop hook's `waiting:` |
| `SILENT` | the window is still there and the last worker event is the Stop hook's `failed: no status:` |
| `Unseen: N` | N status lines have arrived since the last `kingpin ack`, so an event nobody dispatched stays visible |
| `running` | none of the above. `kingpin list` prints `-` in this column for the same answer |

`Waiting for approval:` lists the live reviews whose worker reported `ready:` or `fixed:`
and which no landing has picked up yet: no `landing_sent`, no `approve_pending` and no
`landing_in_progress` marker, and no id waiting in its project's landing queue. Each row
names the review verdict, or the `high=` count of the latest fix pass, and the report
path the worker handed over. A findings verdict
(`NEEDS CHANGES`, `APPROVE WITH NITS`) carries `(fix pass first)`, because `kingpin land`
runs the fix pass before it merges. A `fixed:` row whose `high=` count is not zero
carries `(needs re-review)` and is counted in the headline's own need-re-review column,
because `kingpin land` asks the worker for another review instead of merging it. A task
whose window is gone waits for the restore instead and is not listed here.

`Dossiers without a listener:` lists a live task with a `report.html` and no listener
behind it: its `listener.pid` is missing or names a dead process. The row is the URL the
listener recorded in `dossier.url`, or the `lavish-axi <path>` command when it recorded
none, and that command is the only time to open the page yourself.

`Landing lanes:` lists one row per project that holds or queues a landing, read from
`$KINGPIN_HOME/projects/<project>.landing` and `.landing_queue` through `lib/landing.sh`:
the holder, or `free`, and how many task ids wait in the queue. A lane with no holder and
an empty queue is left out.

The digest is bounded on purpose: one line per task, and no pane capture. It is the
command `orchestrator/contract.md` tells a fresh orchestrator session to run first, and
`kingpin list` remains the fuller board with windows, browsers and dossier links.

## kingpin stats

**Usage:** `kingpin stats [--since <duration>]`

**Flags:** `--since <duration>`

**Environment:** `KINGPIN_HOME`

Reads every task record, live under `tasks/` and archived under `archive/`, and prints one summary of finished work:

```
Window: all records
Records: 3 (finished 3, in flight 0, without a report 0)
Finished: 2 merged, 1 failed
Verdicts: APPROVE 2, APPROVE WITH NITS 0, NEEDS CHANGES 1, other 0
Fix passes: 1 of 3 reviewed tasks (33%)
Cleanup refused: 0
Failed:
  t-stats-failed  failed: tests red
Time to merged: median 2h, p90 3h (n=2)
```

`Records:` counts the records the run considered and splits them three ways: finished, in flight, and without a report (a record with no status line yet). A record counts as merged when any line of its status starts with `merged:`, because a `cleanup-refused:` line that follows the merge does not undo it; the `Cleanup refused:` line keeps a refused cleanup visible instead of burying it in the merged count. A record counts as failed only when its last worker line starts with `failed:`, so a task that failed once and later asked a question is in flight, not failed. `Failed:` lists each of them as a task id and its line.

`Verdicts:` reads the last `ready:` line of each record, the final review verdict, and puts it in `APPROVE`, `APPROVE WITH NITS`, `NEEDS CHANGES` or `other`. `Fix passes:` is the number of reviewed records (those with a `ready:` line) that also carry a `fixed:` line, over that same denominator, so a task that never reached review is not asked for a fix pass.

The time to merged runs from `CREATED` (recorded in `task.env`) to the record's last `status` write. The status protocol carries no timestamps, and the archive moves at cleanup time, which can lag the merge, so the status file's modification time is the closest local measure. The line prints the median and the p90 over the records with a readable `CREATED` and a non-negative span, and `none (no merged record)` when the window holds no merged record.

`--since` takes one or more `<n><unit>` segments with unit `s`, `m`, `h` or `d` (`7d`, `90m`, `1h30m`) and keeps only the records whose `CREATED` falls inside the window. A record without a readable `CREATED` is counted in the `Records:` line as `; N skipped: no CREATED` and left out of the buckets, since it cannot be placed in a window. Curator records (`CURATOR=1`) are counted as `; N curator skipped` and left out in every run, windowed or not, because a curator's verdict is `PENDING` by design.

The command writes nothing: no marker, index or temp file, so it is safe on a read-only fleet home. A missing or empty `$KINGPIN_HOME` prints the zero summary and exits 0 instead of an error. An unknown flag, or a `--since` that is not a duration, prints usage and exits 2.

## kingpin send

**Usage:** `kingpin send <task-id> "<text>"`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SEND_DELAY`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

The terminal is resolved by `lib/mux.sh`, from the mux the task record names. For a tmux task it is the task's own window name first, then a recorded window ID that still names this task's window, on the socket the record names (`TMUX_SOCKET`): a send after a tmux server restart therefore reaches the task's own window instead of whichever window inherited the stale id, and an id that names another task's window is refused with `tmux window <label> is not alive`. A Herdr task resolves its pane by `MUX_LABEL` first and by the recorded pane id second.

## kingpin peek

**Usage:** `kingpin peek <task-id> [--lines N]`

**Flags:** `--lines N`

**Environment:** `KINGPIN_HOME`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

### Finding the pane

It looks for the task's own window name in the task's session first (`TMUX_TARGET`), because the name is the one key that survives a tmux server restart, where window ids restart at `@0` and a recorded id can name a different task's window. When the name is gone it falls back to the recorded window ID (`TMUX_WINDOW_ID`), which is what keeps a hand-renamed window reachable; an id that names another window is refused rather than typed into. The socket comes from the same record (`TMUX_SOCKET`), so the window is resolved on the server that holds it. That rule is the tmux half of `lib/mux.sh`, and every reader reaches a terminal through it: `send`, `peek`, `wait`, `list`, `brief`, `ack`, `launch-check`, `stop`, `rename`, `done`, `restore` and `curate`. It is also why `peek` only needs `list-panes` and `capture-pane`. A task whose record says `MUX=herdr` resolves its pane by `MUX_LABEL` first and its recorded pane id second instead.

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

Exits 1 for an unknown task or one without `report.html`, 2 for a bad argument. `kingpin done` stops the listener, marks the dossier page finished (see [A finished dossier](#a-finished-dossier)), and its final reply says the page now shows the task as finished.

An archived task resolves: `kingpin listen <task-id>` on one prints `OK: task <task-id> is finished` with the archived dossier path and exits 0. A listener that finds its own task archived out from under it (a cleanup whose listener stop missed it) posts one final reply naming the archive and stops polling.

## kingpin wait

**Usage:** `kingpin wait [--timeout <sec>] [--once]`

**Flags:** `--timeout <sec>`, `--once`

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_SOCKET_WARN`

Each event is one `<task-id> <reason>` line, where the reason is `status` (a new status
line), `quiet` (a task that stopped reporting) or `exited` (a worker whose terminal is gone).
A live Herdr pane resolves through `lib/mux.sh`, so a Herdr task is never `exited` while its
session holds the pane, and a closed pane is `exited` because the terminal really is gone.

### Exit codes

Exits 0 on events and on a plain timeout (nothing printed); `--once` with no events exits 1; 2 for a bad argument.

An archived task raises no event: its leftover dossier link is not a live task, so it cannot wake the orchestrator twice.

### A server that is gone

A live task record that names a tmux server which no longer answers gets one warning on stderr per server, naming it, the tasks whose windows died with it, and the command that attaches once it is back. The warning is printed once per server per process and the check rides every pass, so a server that dies during a long `kingpin wait` is still named. `KINGPIN_SKIP_SOCKET_WARN=1` silences it. A `MUX=herdr` record is not on a tmux server, so it is left out of the check: a down Herdr session is a closed pane (an `exited` event), not a dead server with an attach hint, and `herdr server` belongs to the operator.

### A status file rewritten under the cursor

A worker is told to append, but a worker that rewrites its `status` file can leave the file the same length as its cursor: remove a handled line, append the next event, and the new line's number is one the cursor already covers, so a count comparison has nothing to see. The waiter compares the anchor `kingpin ack` records beside the count instead, and reports `status` when the handled line is no longer at its index, so the supervisor wakes, repairs the cursor and dispatches what is left. A file shorter than its cursor is the same case and takes the same path.

### See also

See [Fleet Overview](fleet-overview.md#fleet-overview--visual-review-dossiers).

## kingpin ack

**Usage:** `kingpin ack <task-id>... | --all | --through <line> [--rewind]`

**Flags:** `--all`, `--through <line>`, `--rewind`

**Environment:** `KINGPIN_HOME`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`

The cursor never moves backwards and is clamped to the file; `--rewind` lets `--through` move it back, and the supervisor is the only caller that asks, when it has found that the status file was rewritten under the cursor. An archived task is a no-op that exits 0 with a note, and no cursor is written into the archive.

### The anchor

Beside the `seen` count every cursor write records the handled line's own text in `seen_line`. A count alone cannot say which line it counted once a writer rewrote the file, so the anchor is what `kingpin wait` and `kingpin watch` compare the file against: another line at that index means the file was rewritten, and `kingpin watch` resumes after the last counted line that still holds the anchor instead of trusting the count. When the anchor is not among the counted lines at all, dispatch resumes at line 1 and the handled lines replay, which the at-least-once rule already allows; a crash between the anchor write and the count write is that shape. A line that is blank leaves no anchor.

## kingpin land

**Usage:** `kingpin land <task-id>` (alias: `kingpin approve <task-id>`)

**Environment:** `KINGPIN_HOME`

### An archived task

`kingpin land <task-id>` on a task that already landed resolves its archive, prints `OK: task <task-id> is already finished; nothing to land` and exits 0, so a stale queue entry or a paste of an old id says why instead of claiming the id is unknown. A queued entry for such a task is dropped by the lane with the reason `archived`.

### A curator task

A task whose `task.env` carries `CURATOR=1` is dispatched to `kingpin curate --land` before the review-verdict gate is read. Its work is a PR in the skills checkout, and the human approval that reached `kingpin land curator` is its review gate, so there is no `review=` line to parse.

### The review gate

The review gate fails closed: it reads `review=` from the worker's last `ready:` line whatever the field order. `APPROVE` lands; a findings verdict lands only when the review report it names has no blocking finding, as the next two sections describe.

### Fix passes

A findings verdict (`APPROVE WITH NITS` or `NEEDS CHANGES`, any case; `NEEDS_CHANGES` and `NEEDS-CHANGES` too) is decided by the review report the `ready:` line names. A Critical, High or Medium finding in the report's `## Issues Found` block blocks the merge, so the gate runs `/fix-findings` first and says how many findings block; landing continues after the worker reports `fixed:`. `NEEDS CHANGES` blocks on its own, even when the report lists only Low findings, because the verdict is the reviewer's "not yet" and a report that disagrees with it is contradictory input.

A report the gate cannot read (missing, empty, `report=none`, no `## Issues Found` block, or no recognized severity heading) also runs the fix pass: an unreadable report is not proof that nothing blocks.

That `fixed:` line has to report `high=0`: a line with `high` above zero sends `/review` again and exits 0 without landing, and a later `ready:` starts the next landing.

### Follow-up findings

When every open finding is Low (`### Suggestions (Low)`), the gate lands, writes the finding lines to `<task>/followups.md`, and names that path in its outcome line. The merge goes ahead and the file is how the nits stay tracked: the worker's preamble requires a `## Follow-up` checklist in the PR body, or one GitHub issue for them, before the worker reports `merged:`.

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

Every refusal names its reason on stderr and exits 1 with the record still in `tasks/` and nothing archived; a finished task also records the reason in its `cleanup-refused:` line. All but the last are raised before the teardown starts, so the worktree and the record are as the worker left them. The last one, a `treehouse return` failure, is known only after the window is closed, the listener stopped, the browser daemons stopped, and the spawn's injected paths, exclude file and codex trust entry cleared; it leaves the `lease-lost` marker described below, and `--force` re-attempts the full cleanup. The reasons:

- `worktree <path> has uncommitted changes` when a changed or untracked file is left in the worktree; `--force` discards them and continues.
- `HEAD <sha> is not yet merged into refs/remotes/origin/<branch>` when the worker's commits never reached the remote default branch. `--force` tears the worktree down anyway, and the remote branch is left in place because the merge was not verified.
- `branch <name> carries no commit of its own` when the worker's `HEAD` is still the commit the spawn leased the branch at (`BASE_SHA` in `task.env`). That commit is on the default branch only because the branch never left it, so nothing from it landed. The test is only that `HEAD` never moved off `BASE_SHA`: a worker that pulled the default tip without committing has moved, so it passes. This refusal does not clear by itself, so the supervisor retrying it will not help. `--force` tears the worktree down anyway, the issue is left unchecked as for the other merge-check refusals, and the remote branch is left in place.
- `HEAD <sha> cannot be verified: refs/remotes/origin/<branch> is missing` when the default branch ref is not there to compare against, with any `git fetch` failure named in the same line; `--force` is the way past it.
- `worktree <path> is held by unfinished task <id>` when another live task records the same worktree. This one is refused even with `--force`.
- `treehouse return failed for worktree <path>: <reason>` when the slot could not go back to the pool. The reason is recorded in the task's `lease-lost` marker (next section), and `--force` re-attempts the full cleanup.

### The lease-lost marker

The supervisor still retries a refused cleanup, but a task whose lease was lost carries a `lease-lost` marker in its task directory, so every retry re-reports that refusal with no network call and no external command until the owner runs `kingpin done <task-id> --force`, which bypasses the marker and re-attempts the full cleanup.

### Default-branch resolution and the merge check

The merge check resolves the default branch from the remote's `HEAD` (a read-only `git ls-remote --symref`, when the remote is reachable), then `origin/HEAD`, then `origin/master`, then `origin/main`, then the checkout's own `HEAD`, and a failed `git fetch` is reported on stderr rather than read as an unmerged commit: cleanup still succeeds when the last-known refs prove the merge, and the refusal names the fetch failure when they cannot. The check is the ancestor test plus a second test: a branch whose `HEAD` is still the `BASE_SHA` the spawn recorded has no commit of its own and is refused. The test is "`HEAD` never moved off `BASE_SHA`", and a worker that fast-forwards or merges the default tip without committing (for example a `git pull` after its blocker cleared) moves `HEAD` and still passes. That gap is accepted: a stronger test would have to tell the worker's own commits from the commits it pulled, and once the branch lands by fast-forward or merge both sit on the default branch, so no check separates them without refusing a branch that landed legitimately. A record with no `BASE_SHA`, written before this check or by the curator, gets the ancestor test alone. `KINGPIN_SKIP_MERGE_CHECK=1` skips the whole check, for a caller that verified the merge itself; the curator's automatic reconcile sets it.

### Queue handoff

The handoff to the next queued task skips entries that can no longer land (gone, archived, finished or already dispatched) and lands the next live one.

### The worktree guard

Refuses, even with `--force`, when another unfinished task records the same worktree.

### Status lines and the listener

A refusal is recorded as a `cleanup-refused:` status line only for a finished task (`merged:`, `failed:`); a worker that may still be live keeps its last status (for example `needs-input:`), and the reason goes to stderr. `done` also stops the task's dossier listener, and `kingpin ack` of an archived task is a no-op that exits 0 with a note.

### The issue a finished task names

A task record that carries `ISSUE` (or, for an older record, a worker's `issue: #<n>` line) gets one more step before the archive. When the merge check passed and `gh` reports the issue `OPEN`, `done` closes it and the `OK:` line says `closed issue #<n> after the merge`; an issue that is already closed is left alone and named `issue #<n> is closed`. A close that fails is reported as `issue #<n> is still open (close it by hand)`, and a state that cannot be read as `issue #<n> state could not be read (check that it is closed)`. The merge check is the permission, and a branch with no commit of its own does not pass it, so a failed worker's issue is never closed. A `--force` cleanup or a missing worktree reports `issue #<n> not checked (the merge was not verified)` and never closes anything. A record that names no issue, such as a curator record, gets no readout at all. Every `gh` failure is part of the `OK:` line and never fails the cleanup. `KINGPIN_GH` overrides the command, as it does for `kingpin spawn`, `kingpin rename` and `kingpin curate`.

### The checks of the merged pull request

A worker that merges on a red check rollup used to archive as a clean task. When the worker's last event is a `merged:` line with a `pr=<url>` field, whichever runs first, the `merged:` dispatch of `kingpin watch` or `kingpin done`, reads `gh pr view <url> --json statusCheckRollup` from the project path, with `KINGPIN_GH` as the command, and classifies it:

- `FAILED`: any entry with the conclusion `FAILURE`, `CANCELLED`, `TIMED_OUT`, `ACTION_REQUIRED`, `STARTUP_FAILURE` or `STALE`, or a commit status in the state `FAILURE` or `ERROR`.
- `PENDING`: no failed entry, and a check run that has not completed or a commit status in the state `PENDING` or `EXPECTED`.
- `PASSED`: everything else, including an empty rollup, because a repository with no checks has nothing red to report.
- `UNREADABLE`: the rollup could not be read (no `gh`, no `node`, a `gh` failure or an answer that is not JSON). The reason is recorded.

The result is kept in `<task>/checks.result`, three lines (the word, the pull request URL, and the names of the failing checks or the reason), and the file moves with the record into `archive/`. It is also the guard: the pull request is read once, and deleting the file is how a later read is asked for. A PENDING or UNREADABLE result is a snapshot of merge time and is not polled again.

A FAILED or PENDING result appends one note line to the status, `checks: pr=<url> checks=FAILED` (or `checks=PENDING`). The note is not a worker event: `kingpin list` shows it as the row's newest status, but `merged:` stays the last event, so the task stays finished for `kingpin brief`, `kingpin stats`, `kingpin restore` and the landing lane. A PASSED or UNREADABLE result writes no note, and a `merged:` line with no `pr=` field is skipped silently.

`kingpin done` appends the result to its `OK:` line after a verified merge: `; pull request checks FAILED (<url>)`, `; pull request checks still PENDING at merge (<url>)` or `; pull request checks not read (<reason>)`, and for FAILED and PENDING it also prints `kingpin-done: warning: the checks on <url> were <RESULT> when the task merged` on stderr. The cleanup is not refused and the exit status stays 0, because the merge already happened. A `--force` cleanup or a missing worktree reads nothing, though a result the supervisor already recorded is still reported.

While AFK is armed, `kingpin watch` holds the cleanup of a task whose result is FAILED or PENDING: it logs `merged but its pull request checks are <RESULT> (afk on); holding the cleanup for the operator: kingpin done <id>` and leaves the task live. The operator reads the pull request and runs `kingpin done <id>`. UNREADABLE never holds, because an offline host would otherwise stall every cleanup. Without AFK the cleanup runs and the `OK:` line carries the result.

### The dossier link

After a successful archive, `done` leaves a symlink at `~/.kingpin/tasks/<task-id>` pointing at `~/.kingpin/archive/<task-id>`. A Lavish session, and a link handed to someone in chat, keep resolving `report.html` and the dossier's sibling assets through that path, where before the merge the page went blank. The link is not a live task: every fleet reader treats a symlinked `tasks/` entry as finished (it has no list row, raises no `wait` event, is never dispatched by `watch`, landed, listened to or cleaned again), and `kingpin done` answers a repeat run from it without touching treehouse. The archive itself is never pruned: it is the record.

### A finished dossier

A page that a reviewer left open still renders its decision bar after the merge, so `done` rewrites the archived `report.html` before it ends the session. The page gains a banner as the first child of its content column (`<main>`, or `<body>` on a page without one) reading `This task is finished.`, naming the PR the `merged:` line reported, saying the task finished without a merge when it failed, or saying only that the task finished when the last line was neither, as in the `cleanup-refused:` recovery. The Approve & Land and Request Changes buttons lose their `onclick` handler and gain `disabled` and `aria-disabled="true"`, and the page's `kpAction` and `kpRequestChanges` functions become no-ops, so nothing on it can queue a prompt. The template marks its action bar and its READY FOR REVIEW badge with `data-kp-finished-hide`, and the banner hides them, so a finished page no longer headlines a decision that cannot be made; a page built without the hook keeps the bar and only loses the handlers. A button whose handler names neither function is the author's own control and is left alone.

The banner carries the marker `<!-- kingpin:finished -->`, and a page that already holds it is not rewritten, so a repeated run is a no-op. `done` records `marked its dossier finished` in its `OK:` line, and a page it cannot rewrite prints the reason on stderr while the cleanup still succeeds: the archive is already the record, the same rule the browser note and the issue readout follow. The session `done` ends gets a `dossier.ended` marker so the supervisor's sweep does not end it a second time, and the final reply says the page now shows the task as finished. A record that finished without `done` is marked and ended by `kingpin watch` instead.

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

The harness restarts with no conversational memory, so `<task-dir>/resume-prompt.txt` names the task, project, worktree, branch, mode and harness, repeats the last *worker* status line (an `approved:`, `feedback:` or `checks:` note never decides it), and maps that line to one next step: a `ready:` task is told the review stands and not to land, a `fixed:` task checks the PR state for the merge, an open question waits for its answer, and a task whose landing was already sent is told to check whether the merge happened and never to run `kingpin land` again. The brief also repeats the house rules: one literal status line per event, questions through `question.md` and `needs-input:`, and never `kingpin spawn`, `lock`, `land`, `done`, `listen` or `send`. The window's launch script reads that file instead of the original `prompt.txt`, which stays in the task folder for reference.

### Refusals

A task that cannot be brought back is named on stderr as `kingpin-restore: refused <id>: <reason>`, nothing is deleted, and the run exits 1. Refused are:

- a finished task, named with its archive path;
- a `MUX=herdr` record: `kingpin restore` cannot create a Herdr worker yet (issue #204), and the refusal comes before the tmux fields the record does not carry;
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

The supervisor's pidfile died with the tmux server. Under the `kingpin-watch` unit systemd restarts the supervisor after the restore, and a supervisor that runs outside the server re-arms the windows on its next sweep. Without the unit, start `kingpin watch` again; when the unit exists but is stopped, `systemctl --user start kingpin-watch` starts it. Restore does not re-arm a review dossier's listener: that is the supervisor's job.

### Exit codes

Exits 0 when every named task was restored or was already live; 1 when any task was refused or another restore holds the mutex; 2 for a bad argument, including an unknown flag, an invalid task id or an unknown harness name.

## kingpin lock

**Usage:** `kingpin lock [status|check|acquire [--harness <name>]|release|harness] [pid]`

**Flags:** `--harness <name>`; `[pid]` is a positional argument

**Environment:** `KINGPIN_HOME`, `KINGPIN_HARNESS`, `KINGPIN_LOCK_PID`

`--harness` records `claude`, `agy`, `opencode`, `pi` or `codex`; without it, `acquire` detects the harness in this order: `--harness`, `KINGPIN_HARNESS`, the command name or argv of the session process (`claude`, `agy`, `opencode`, `pi`, `codex`, including the `@earendil-works/pi-coding-agent` npm path), then the calling agent's own marker (`CLAUDECODE=1`, `OPENCODE=1`). A session that matches none records nothing. `acquire` also warns on stderr, naming `kingpin-watch.service`, when no fleet supervisor is running, and when the guard or the contract is missing or stale, even with `KINGPIN_SKIP_GUARD=1`, because it calls `kingpin guard check` directly. A numeric `[pid]` overrides the detected session pid, as does `KINGPIN_LOCK_PID`.

`acquire` (the default subcommand) records the calling session's pid and the harness it detected, `status` prints `lock: free`, `lock: held by pid <n> (<harness>)`, `lock: held by pid <n>` when the record carries no valid harness line, or `lock: stale`, and `harness` prints the recorded harness. A record whose holder pid is gone is ignored, and the next `acquire` rewrites the whole file.

`release` drops only the calling session's record and clears the AFK arm, and it refuses, naming the holder, while another live session holds the lock. `acquire` and `release` are serialized by a sibling mutex, `$KINGPIN_HOME/orchestrator.lock.mutex`, so sessions that start together get one `lock: acquired` and the rest exit 1 naming the holder; the wait is about nine seconds, and a mutex held longer refuses the same way. The lock file is published whole with a temporary file and a rename, so `status`, `check` and `harness` never read a half-written pid or harness line.

### Exit codes

`status` and `harness` exit 0, and `check` exits 0 with `lock: verified`. The refusals exit 1: another live session holds the lock (`check`, `acquire` and `release`), the mutex cannot be taken (`acquire` and `release`, naming its owner), a lock file that cannot be written, an AFK file that cannot be removed, and `acquire` with a `--harness` other than `claude`, `agy`, `opencode`, `pi` or `codex`. An unknown subcommand exits 2.

## kingpin afk

**Usage:** `kingpin afk [on [--ttl <duration>]|off|status]`

**Flags:** `--ttl <duration>`

**Environment:** `KINGPIN_HOME`

`on` arms auto-landing for this orchestrator session, `off` disarms it, and `status` prints `AFK: on until HH:MM (pid N)` or `AFK: off`. The state is the three-line file `$KINGPIN_HOME/afk` (holder pid, arm epoch, expiry epoch), published whole with a rename, and it is never a project or global setting.

`--ttl` takes one or more `<n><unit>` segments with unit `s`, `m`, `h` or `d` (`30m`, `8h`, `1h30m`); the default is `8h`. A bare number, an unknown unit, a zero total, an unknown subcommand or an unknown flag exits 2; a state file that cannot be written exits 1.

The arm reads as off once the expiry passes or the recorded pid is gone, so a session that died cannot leave the fleet landing on its own. `kingpin lock release` removes the file as well.

While armed, `kingpin watch` reacts to a new `ready:` line:

- a clean `APPROVE` verdict goes through `kingpin land` exactly as an operator's `kingpin land` would, and a landing that starts gains `approved: auto (afk)`; a line that only queues behind a busy project lane gains none, because the note records a decision that has completed;
- a findings verdict reaches the same command, which lands it when the review report's open findings are all Low, and runs the fix pass when one is Medium or above, when the report cannot be read, or when the verdict is `NEEDS CHANGES`. A landing past Low findings gains the same note and leaves `followups.md`, while a fix pass waits for the re-review. A clean `fixed:` landing that follows an AFK-started pass gains the same `approved: auto (afk)` note in `review` and `auto` mode alike, while a `fixed:` line that only queues gains none and drops its marker; a pass that still leaves High findings asks for `/review` and gains none. If the arm is off or expired by the time that `fixed:` line arrives, the landing still continues but gains no note;
- an unreadable verdict, a `needs-input:` question, a `cleanup-refused:` case and a `failed:` task hold for the operator, and nothing is forced.

A `merged:` line gets the same treatment in one case: when the checks on its pull request were FAILED or PENDING, the supervisor leaves the task live for the operator instead of running `kingpin done` ([`The checks of the merged pull request`](#the-checks-of-the-merged-pull-request)). A rollup that could not be read never holds it.

The dossier listener's `landing_sent` and `approve_pending` markers are checked first, so an approval the listener already took is never landed twice. AFK adds no merge path: the verdict gate and the per-project landing lane are the ones `kingpin land` always uses. The `kingpin report check` warning belongs to `kingpin watch`, not to `kingpin land`: the supervisor runs it on the dossier in its review branch and, while AFK is armed, in the clean branch before it lands. With AFK off or expired, `kingpin watch` behaves exactly as before.

`kingpin list` prints the same `AFK: on until ...` line below the supervisor line only while the arm is live.

## kingpin guard

**Usage:** `kingpin guard [install|check|warn] [--dir <kingpin-checkout>]`

**Flags:** `--dir <kingpin-checkout>`

**Subcommand:** `kingpin guard hook <orchestrator|worker>` is the hook entry point.

**Environment:** `KINGPIN_HOME`, `KINGPIN_SKIP_GUARD`; `KINGPIN_TASK_DIR` and `KINGPIN_WORKTREE` are read by the `guard hook worker` entry point (`lib/guard-hook.mjs`).

`install` writes the hook into a `PreToolUse` entry of `.claude/settings.local.json` in the checkout `--dir` names, and refuses a linked worktree.

### What install writes

`install` also writes the orchestrator contract: the tracked `orchestrator/contract.md`,
copied to `$KINGPIN_HOME/orchestrator.md`, to `.claude/rules/kingpin-orchestrator.md`, to
`.agents/rules/kingpin.md` (with the `trigger: always_on` frontmatter agy needs) and to the
`instructions` entry of `.opencode/opencode.json`. A checkout with no tracked contract skips
the copies and keeps the guard-only behaviour. The two in-checkout copies and the OpenCode
config are hidden in the `# kingpin guard` block of the checkout's `info/exclude`, which
each install rewrites and which adopts a loose line an older install appended.

`install` also removes the legacy `permissions.deny` rules, refuses an `opencode.json` that
carries JSONC comments instead of rewriting it, and stops on a `.agents/rules/kingpin.md`
it did not write. Only `install` refreshes a copy, because `kingpin spawn` and `kingpin sync`
never do. `check` names a stale copy, and `warn` is the quiet startup check `kingpin list`
and `kingpin wait` run: it prints one `warning:` line on stderr when the guard or the contract
is missing or stale and exits 0 either way, so its exit status is never the verdict.

### Fail-closed cases

The orchestrator hook denies `Edit`, `Write`, `NotebookEdit` and `Agent` when the session's
working directory is the main checkout of any git repository, where `git rev-parse --git-dir`
equals `git rev-parse --git-common-dir`, and it denies when it cannot resolve that directory
to a git worktree.

The worker hook allows `Edit`, `Write` and `NotebookEdit` inside the worktree pinned by
`KINGPIN_WORKTREE` or `WORKTREE=` in the task's `task.env`, and inside the task folder
(`KINGPIN_TASK_DIR`, where `report.html` and `question.md` live). It denies every other path, a
guarded call that names no file path, and a worker whose worktree cannot be resolved or is the
main checkout.

Both hooks fail closed: they deny when `kingpin-guard` cannot run (a missing script, a
missing `node`) or cannot read its payload, because the hook is installed with `|| exit 2`.

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

**Environment:** `KINGPIN_HOME`, `KINGPIN_CLAUDE`, `KINGPIN_CURATOR_CMD`, `KINGPIN_SKILLS_DIR`, `KINGPIN_CURATOR_AUTO`, `KINGPIN_GH`, `KINGPIN_MUX`, `KINGPIN_HERDR_SESSION`, `KINGPIN_TMUX_SOCKET`, `KINGPIN_TMUX_SESSION`

`curate` is not harness-neutral. It needs a skills checkout, `KINGPIN_SKILLS_DIR` or the default `~/.claude/skills`, and a missing one dies with `kingpin-curate: skills directory <dir> not found` on a manual run; `--auto` reports one line and exits 0 instead, because a missing checkout must never fail a fleet tick. The curator runs through `KINGPIN_CURATOR_CMD`, then `KINGPIN_CLAUDE`, then `claude`, so a host whose only harness is agy or OpenCode has to set both the directory and the command.

The prompt reaches that command on stdin, never as a command-line argument: Linux caps one argument at 128 KiB (`MAX_ARG_STRLEN`), so a batch past that used to fail with `E2BIG` and a bare exit 126. The launch script runs the command with `-p`, which is how `claude` reads a piped prompt, so an override has to read its prompt from stdin the same way and may carry its own flags. Kingpin refuses a prompt past its own 8 MiB curator prompt cap (`CURATOR_PROMPT_MAX` in `bin/kingpin-curate`) with a `failed:` line that names the size; the cap is a constant Kingpin picks rather than a platform limit, so the same batch behaves the same on Linux and macOS. A prompt file that is missing, empty or unreadable is refused with a `failed:` line too. An exit 126 or 127 is reported as a named launch failure, so `kingpin list` shows the cause instead of a dead window.

### The branch and the PR

Curation is a pull request, never a write to the default branch of the skills checkout. The curator creates `curator/<YYYY-MM-DD>` from `origin/<default>`, commits only the skill files the batch justifies, pushes, and opens a PR. The applied marker is written at PR-open time, so a pending PR is not applied twice and a merged one stays auditable.

### The curator task record

A real run creates `~/.kingpin/tasks/curator` with `MODE=review`, `CURATOR=1`, `NO_LEASE=1`, `TMUX_SOCKET` naming the resolved server and `TMUX_TARGET=<session>:curator`, and launches the curator into that window. The curator is a worker like any other, so it resolves its target the same way a spawn does: `KINGPIN_TMUX_SESSION`, then `TMUX_SESSION` in `$KINGPIN_HOME/config.env`, then the caller's own tmux session, then the fleet server's one session or its `kingpin` fallback. With no config and no caller that is `tmux -L kingpin kingpin:curator`. The resolved session is matched exactly, so a `kingpin-workers` session beside `kingpin` is never taken for it. The curator reports through the worker protocol: `ready: branch=<branch> review=PENDING report=<task>/report.html pr=<url>` starts a dossier listener, and `kingpin list` shows the row. `PENDING` is deliberate, so a curator can never auto-land: the review dossier's Approve & Land button runs `kingpin land curator`, and its Request Changes button queues the note for the orchestrator, which sends it to the curator window while it is alive (`kingpin send curator "..."`). Otherwise close the PR and run `kingpin curate` again. The task id `curator` is reserved; a `task.env` there without `CURATOR=1` makes the run refuse rather than overwrite a user's task.

### The automatic trigger

`kingpin watch` runs one check as the last step of every sweep, and `kingpin done` runs it after archiving the last task, so no daemon or timer is involved. `--auto` starts a curator only when all of these hold: `KINGPIN_CURATOR_AUTO` is not `0`; the skills directory is a git checkout; no run has been stamped today; no curator window is alive; at least three critiques are pending; and the fleet is idle. The fleet is idle when every `tasks/*` record is finished, every `projects/*.landing_queue` is empty and no `projects/*.landing` holder is live; an archived record's dossier link is not a task. A record is finished when its last worker status line is `merged:` or `failed:`, including `failed: no status:`, or when it carries a `done_cleaned` marker; any other record is still in flight, including one whose last line is `cleanup-refused:` and one with no status line at all, and a `landing_in_progress` marker on its own changes nothing. The daily stamp is `$KINGPIN_HOME/curator/last-run`: line 1 the epoch, line 2 the local calendar day. It is written when the window exists, so a failed run still consumes the day and the next calendar day retries; a launch that failed before the window is retried on the next tick.

The trigger never waits: it takes the curator mutex with a single non-blocking attempt and skips when someone else holds it, reads local files only, and always exits 0. A landing in flight is therefore never delayed. The curator window (`<session>:curator` on the resolved socket) is settled before any record is reconciled, because `kingpin done` closes a window by its name: an existing live window makes it a no-op that prints one line and claims the day, and a dead pane at the window the launch will use is reaped before the launch. A live curator task whose last status is terminal is then reconciled through `kingpin done curator`, and a finished curator record's symlink at `tasks/curator` is dropped so the new record is a real directory. A finished curator record that `kingpin done curator` could not archive stops the run before it writes over the record: `--auto` prints one line with its last status and exits 0, and a manual run refuses with the same status instead of replacing it. A live record that is not terminal, such as a curator waiting for review, holds the idle gate back and is named on stderr with its last status line and PR, so the fleet log says why the day started nothing. When another task record holds the gate, `--auto` names that record and its last status on stderr.

### Consumed critiques and the applied marker

A critique applied by a successful run is stamped beside the file (`critique.consumed`) and is not collected again, including after `kingpin done` archives the task; a critique rewritten while the curator is running is left pending, so the next run collects the new bytes. When the PR opens, the critique is renamed to `critique.applied.<epoch>` and the URL is written beside it as `critique.applied.<epoch>.pr`. A closed-unmerged PR therefore leaves its critiques consumed but auditable by URL: to re-apply them, delete the task's `critique.consumed` and `critique.applied.*` files and run `kingpin curate` again. A failed, reaped or non-zero run before the PR opens leaves every critique pending.

### `--mark-applied <pr-url>`

Marks the published batch applied with the PR URL and exits with the helper's status. The pull request is read through `gh api --hostname <host>` (`<host> repos/<owner>/<repo>/pulls/<number>`, with the host taken from the URL), so the check does not depend on a `--json` field any one gh version may lack and reaches the same host the PR URL names: a URL that is not a pull request is refused, a PR gh cannot read is refused with gh's own error, a PR whose base repository is not the skills checkout's origin is refused, and so is one whose head is not the branch the record opened. The curator calls it itself when the PR opens, and the launch wrapper calls it again after the child returns only as a fallback for a harness that exited before that step. It takes no mutex and writes no launch state. Calling it on an already-marked batch prints `OK: marked 0 critique(s)`.

### `--land`

Merges the curator's PR and finishes its record: it resolves `$KINGPIN_HOME/curator/pr`, reads that PR's base and head the way [`--mark-applied`](#--mark-applied-pr-url) does and refuses unless they are the skills checkout's origin and the branch the record opened, refuses when the skills checkout is on its default branch, merges with `KINGPIN_GH`, verifies the state is `MERGED`, appends `merged: pr=<url>` to the task status, and runs `kingpin done curator`. `--delete-branch` is omitted in a linked worktree, which cannot switch its checkout. `kingpin land curator` dispatches here before its review-verdict gate, because the human approval that reached it is the review gate. A failed merge removes the `landing_sent` marker and leaves the PR open.

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
| `KINGPIN_GH` | `gh` command `spawn` uses to read an issue title for the task slug, `curate` uses to create, view and merge the curator's PR, and `done` uses to read and close the issue a finished task names, and `watch` and `done` use to read the check rollup of a merged pull request (default `gh`). |
| `KINGPIN_TMUX_SESSION` | tmux session that `spawn` and `curate` place the worker window in when `--tmux-session` is not given, read before `TMUX_SESSION` in `$KINGPIN_HOME/config.env`. The session must already exist on the resolved socket; an unknown name is refused with its source and the server. Unset, the spawn follows the caller's own tmux session, then uses the one attached session or the only session on the fleet server, and refuses when several are unattached or more than one is attached. |
| `KINGPIN_SEND_DELAY` | Seconds between the literal text and the Enter key (default `0.2`). |
| `KINGPIN_MUX` | Multiplexer the fleet creates and reads workers with: `tmux`, `herdr`, or `auto` (default). `auto` selects Herdr only inside a Herdr pane (`HERDR_ENV=1`) and tmux everywhere else; any other value is refused by name. A task record's `MUX=` line, not this variable, decides where an existing task lives. |
| `KINGPIN_HERDR_SESSION` | Name of the fleet's Herdr session (default `kingpin`, the same name the tmux socket uses). The session must already be running: `herdr server` is a foreground process the operator owns, and nothing in Kingpin starts it. Inside a Herdr pane the inherited `HERDR_SESSION` is used instead. |
| `KINGPIN_TMUX_SOCKET` | Name of the tmux server a new worker lands on, read before `TMUX_SOCKET` in `$KINGPIN_HOME/config.env`. A value holding a `/` is a socket path (`tmux -S`). Unset, a spawn inside tmux follows the caller's own socket; outside tmux it is `kingpin` (`tmux -L kingpin`) unless configured. `default` puts workers back on your own server, and `kingpin` keeps them off it. `kingpin spawn` records the resolved value in `task.env` as `TMUX_SOCKET`, and every window reader resolves the record's socket. The test suites point it at their own socket. |
| `KINGPIN_CURATOR_CMD` | Command `curate` launches the curator with; it reads the prompt on stdin with `-p`, the way `claude -p` does. Falls back to `KINGPIN_CLAUDE`, then `claude`. |
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
