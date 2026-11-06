# Fleet Overview & Visual Review Dossiers

[Back to the README](../README.md).

Kingpin is CLI-first for fleet monitoring and visual-first for code review:

### 1. Terminal Fleet Overview (`kingpin list`)

Monitor all active workers, leased worktrees, and current statuses:

```bash
kingpin list
```

For any live task whose folder holds a `report.html`, whatever its mode or status, `kingpin list` displays the dossier line directly below the task row: the recorded Lavish session URL, or the `lavish-axi <path>` command when none is recorded. It carries `(listening: pid <n>)` while that task's listener runs and `(no listener)` when none does; finished and archived rows show no dossier line, and `--all` shows the archived rows without one. An open session on a finished task is named in its own `Dossiers left open on finished tasks (kingpin watch ends them):` section, archived records included, so a tab left open on a page nobody will answer is visible on the board until the supervisor ends it.

The `STATE` column describes a live pane: `WAITING` means the worker is blocked on a human (`needs-input:`, a listener's `feedback:` note, or the Stop hook's `waiting:` line), `SILENT` means it stopped without reporting (`failed: no status:`), `DEAD` means the task is live but its window is gone (or the recorded harness is no longer in it), and `Unseen: N` counts status lines written since the supervisor last acknowledged the task. `-` is a worker that is running normally. When any live task is `DEAD`, one `Fleet: <n> live task(s) have no live window; run kingpin restore` line follows the table.

The `SESSION` column names the tmux session the worker's window lives in, read from the live window, so a window moved to another session is reported where it really is. An archived row shows the session recorded at spawn, because its window is gone; `-` means neither a live window nor a recorded target.

`kingpin wait` wakes the orchestrator only for events that need action: a new status line other than the informational `issue:` line, a worker that stopped (`quiet`), or a window that is gone (`exited`). A worker whose last acknowledged status is `needs-input:` is not reported `quiet` again until its status or pane activity changes, and a task that `kingpin spawn` is still launching (its `launching` marker is fresh) is not reported `exited`.

A worker that stops without writing a status line gets one at the moment it stops. The Stop hook (`bin/kingpin-stop`, wired into all four harnesses) appends `failed: no status: stopped without reporting` when no status line was written since the previous stop and the pane shows no working marker (a running background agent, for example), or `waiting: needs-input <question path>` when the worker stopped again while its last line was `needs-input:` or a listener's `feedback:` note. It never overwrites a status written in that turn, and it fails soft: an unwritable task folder prints a warning on stderr and the session still stops. A harness that dies before its Stop hook fires is caught after the grace period by `kingpin wait`, and so by `kingpin watch` and `kingpin run`, with `failed: no status: <task> (<harness>) ...`; `kingpin list` then shows that line instead of `(pending)`. A worker that wrote only `issue:` and then died is the case neither catches: `kingpin wait` skips the launch check as soon as the status file has any non-blank line, and the Stop hook counts any worker line as a report in the first turn, so no `failed: no status:` line is written and the task surfaces as `exited` or `quiet` in `kingpin wait`, with no state marker in `kingpin list`; `kingpin run` ends that task with exit 1 naming `exited` and the last status. "Stopped" means the tmux window or pane is gone, or the Stop hook fired and the window stayed silent for the grace period without showing a working marker (such as a wait on background agents). The grace period is 30 seconds from launch (or from the last stop), and `KINGPIN_STATUS_GRACE` sets it in seconds. A worker that is only slow to start is left alone. `kingpin peek <task-id>` shows the pane while the window is open, and `kingpin done <task-id>` releases the worktree. A worker that died before its first commit is refused (`carries no commit of its own`) and needs `kingpin done <task-id> --force` on the boss's word; see [A refused cleanup](cli.md#a-refused-cleanup).

### What a worker's death takes with it

A worker lives wherever the fleet put it, which is your own tmux session by default when you spawn from inside tmux. `kingpin spawn` follows the caller's own client, so the worker appears beside you on your server; a spawn started outside tmux uses the fleet server (`tmux -L kingpin`), or whatever socket `TMUX_SOCKET`/`KINGPIN_TMUX_SOCKET` names, and the session a configured `TMUX_SESSION` names. The trade is plain: sharing your server means closing your last session, quitting tmux, or restarting your own server takes every worker on it with it, though `kingpin watch` and `kingpin restore` bring the windows back from their records. Set `KINGPIN_TMUX_SOCKET=kingpin`, or `TMUX_SOCKET=kingpin` in `~/.kingpin/config.env`, to keep workers on a server of the fleet's own and keep the isolation issue #142 introduced.

What kills a worker on either arrangement is the end of the server it lives on: `tmux kill-server` there, a host reboot, or a tmp cleaner removing `/tmp/tmux-<uid>/kingpin`. Every task fact is a file, so nothing about the task is lost, and `kingpin spawn` and `kingpin curate` create the session again when it is gone. The windows that died with the server come back through `kingpin restore`, which `kingpin watch` runs on its next sweep for each socket a live task record names; run `kingpin restore` yourself to bring them back without waiting for the supervisor. Attach with the command `kingpin list` prints for each socket the live records name: a plain `tmux attach` for the default server, `tmux -L <name> attach` for a named socket, or `tmux -S <path> attach` for a recorded socket path, and `kingpin list` also names the window each live worker holds.

To see why a worker is quiet or stuck, look at the tail of its pane without touching it:

```bash
kingpin peek <task-id>              # last 20 non-empty lines
kingpin peek <task-id> --lines 50   # more context
```

A tmux server that dies takes every worker window with it, and a resurrected fleet comes back as plain shells. `kingpin list` marks those tasks `DEAD` and prints the hint, and `kingpin restore` brings each live task back: it reclaims a same-named window or creates one, in the task's own worktree and on the branch the worktree has checked out, relaunches the recorded harness from a regenerated launch script, hands it a resume brief that says where the work stands and what to do next, and repairs `TMUX_WINDOW_ID`. A task it cannot restore is refused by name with the reason, and nothing is deleted. A supervisor that was itself running inside the server that died dies with it, so run `kingpin watch` outside the workers' server, which the shipped `kingpin-watch` user unit does; one that runs outside restores those windows on its next sweep without a hand from you. A review dossier's listener is the supervisor's job, not restore's.

To pick up merged changes in the main checkout, fast-forward it without raw git:

```bash
kingpin sync    # old..new short SHAs and the commits pulled, or "already up to date"
```

Finished tasks are archived by `kingpin done` and hidden from `kingpin list`; run `kingpin list --all` to include them. The task path survives the merge as a symlink to the archive, so a dossier link still opens the reviewed page instead of a blank one, and `kingpin` never treats that link as a live task. `kingpin stats` answers a period question over those archived records, and `--since 7d` limits it to the last seven days. `kingpin curate` still collects skill critiques from archived tasks, and it also runs on its own from the supervisor's idle pass, at most once a calendar day, landing its skill edits through a review dossier.

### 2. Task Review Dossiers (`lavish-axi`)

When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. The task's listener opens it once and records the Lavish session URL in the task directory's `dossier.url`, and `kingpin list` prints that URL under the task's row. Hand the URL over rather than running `lavish-axi` on a page a listener already opened, which puts a second tab on the same session. A task with no recorded URL still shows the `lavish-axi <path>` command.

A dossier is retired when its task finishes, so a page left open never reads as a review still waiting on someone. `kingpin done` rewrites the archived page with a banner naming the merged PR, disables the Approve & Land and Request Changes buttons and removes their handlers, then ends the session; `kingpin watch` marks and ends the records that finished without that step. Reopening an ended session is still allowed and is the operator's choice. [`kingpin done`](cli.md#a-finished-dossier) has the marker and the `OK:` line.

Review the changes and click **Approve & Land** on the dossier or run:

```bash
kingpin land <task-id>
```

### 3. Handover Artifacts (case-file handover template)

Pages handed to the boss for a decision (proposals, plans, comparisons, review summaries) start from the case-file handover template that ships with the repo:

```
assets/lavish/kingpin-dossier/
  handover.html   the page: telegram, stat cards, problem, inline-SVG diagram, options, risks, decision forms
  template.html   a worker's report.html, section 4 below
  hero.jpg        the banner picture, referenced beside the pages
  DESIGN.md       the rules the look depends on, beside the files they describe
```

Copy `handover.html` and `hero.jpg` from the same folder into the artifact's directory (`.lavish/`), rename the page, change the title first, then swap the sample content and `REPLACE` comments. The hero travels with the page because both load it by relative path. `DESIGN.md` lists the rules (paper on ink, the stamped controls, option cards and one comparison table, one form per question) and how to trim the page into a review summary. A handover carries no diff section, so it takes `kingpin report check --prose-only`; the worker page takes the full check. Check it at 1280 and 1024 wide with nothing scrolling sideways, then open it:

```bash
lavish-axi .lavish/<artifact>.html
```

`tests/test-kingpin-dossier-template.sh` fails when the folder loses a file, when a page loses one of its nine decisions, when a diff loses its static fallback, when a decision form loses its handler or its no-Lavish message, when either page stops passing its check, or when the preambles stop pointing at the folder.

The older worker dossier template (`assets/lavish/worker-dossier/`, tested by `tests/test-worker-dossier-template.sh`) stays in the repo for pages already made from it. The noir dossier template (`assets/lavish/noir-dossier/`, tested by `tests/test-noir-template.sh`) stays for a future parchment look. Neither is the default for a new page.

### 4. Worker Review Dossiers (case-file dossier template)

A worker's `report.html` starts from the case-file dossier template, which is the default for every task:

```
assets/lavish/kingpin-dossier/
  template.html   the page: hero, telegram, stat cards, what changed, acceptance, review findings, validation, diffs
  hero.jpg        the banner picture, referenced as src="hero.jpg"
  DESIGN.md       the rules the look depends on, beside the files they describe
```

`worker/curator-preamble.md` gives the curator the same template, with a note on how its critiques, skipped items and `PENDING` verdict fit the sections. `worker/preamble.md` tells the worker to copy `template.html` and `hero.jpg` into the task folder, name the page `report.html`, swap the sample values and `REPLACE` comments for the task's own, and paste the output of `kingpin report diffs` over the sample diff section. The look is a case file: parchment cards on ink, a framed hero with a sideways stamp, four typefaces with one job each, stamped controls, and one dark code region. `DESIGN.md` records the rules, including the palette and the retire hook a finished worker dossier reads. `tests/test-kingpin-dossier-template.sh` fails when the folder loses a file, when a page loses one of its nine decisions, when a diff loses its static fallback, or when the preamble stops pointing at it. The handover template shares its look, so a report and a proposal read the same way.
