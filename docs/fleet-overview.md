# Fleet Overview & Visual Review Dossiers

[Back to the README](../README.md).

Kingpin is CLI-first for fleet monitoring and visual-first for code review:

### 1. Terminal Fleet Overview (`kingpin list`)

Monitor all active workers, leased worktrees, and current statuses:

```bash
kingpin list
```

For any live task whose folder holds a `report.html`, whatever its mode or status, `kingpin list` displays the dossier line directly below the task row: the recorded Lavish session URL, or the `lavish-axi <path>` command when none is recorded. It carries `(listening: pid <n>)` while that task's listener runs; finished and archived rows show no dossier line, and `--all` shows the archived rows without one.

The `STATE` column describes a live pane: `WAITING` means the worker is blocked on a human (`needs-input:`, a listener's `feedback:` note, or the Stop hook's `waiting:` line), `SILENT` means it stopped without reporting (`failed: no status:`), and `Unseen: N` counts status lines written since the supervisor last acknowledged the task. `-` is a worker that is running normally or whose window is gone.

The `SESSION` column names the tmux session the worker's window lives in, read from the live window, so a window moved to another session is reported where it really is. An archived row shows the session recorded at spawn, because its window is gone; `-` means neither a live window nor a recorded target.

`kingpin wait` wakes the orchestrator only for events that need action: a new status line other than the informational `issue:` line, a worker that stopped (`quiet`), or a window that is gone (`exited`). A worker whose last acknowledged status is `needs-input:` is not reported `quiet` again until its status or pane activity changes, and a task that `kingpin spawn` is still launching (its `launching` marker is fresh) is not reported `exited`.

A worker that stops without writing a status line gets one at the moment it stops. The Stop hook (`bin/kingpin-stop`, wired into all four harnesses) appends `failed: no status: stopped without reporting` when no status line was written since the previous stop and the pane shows no working marker (a running background agent, for example), or `waiting: needs-input <question path>` when the worker stopped again while its last line was `needs-input:` or a listener's `feedback:` note. It never overwrites a status written in that turn, and it fails soft: an unwritable task folder prints a warning on stderr and the session still stops. A harness that dies before its Stop hook fires is caught after the grace period by `kingpin wait`, and so by `kingpin watch` and `kingpin run`, with `failed: no status: <task> (<harness>) ...`; `kingpin list` then shows that line instead of `(pending)`. A worker that wrote only `issue:` and then died is the case neither catches: `kingpin wait` skips the launch check as soon as the status file has any non-blank line, and the Stop hook counts any worker line as a report in the first turn, so no `failed: no status:` line is written and the task surfaces as `exited` or `quiet` in `kingpin wait`, with no state marker in `kingpin list`; `kingpin run` ends that task with exit 1 naming `exited` and the last status. "Stopped" means the tmux window or pane is gone, or the Stop hook fired and the window stayed silent for the grace period without showing a working marker (such as a wait on background agents). The grace period is 30 seconds from launch (or from the last stop), and `KINGPIN_STATUS_GRACE` sets it in seconds. A worker that is only slow to start is left alone. `kingpin peek <task-id>` shows the pane while the window is open, and `kingpin done <task-id>` releases the worktree.

To see why a worker is quiet or stuck, look at the tail of its pane without touching it:

```bash
kingpin peek <task-id>              # last 20 non-empty lines
kingpin peek <task-id> --lines 50   # more context
```

To pick up merged changes in the main checkout, fast-forward it without raw git:

```bash
kingpin sync    # old..new short SHAs and the commits pulled, or "already up to date"
```

Finished tasks are archived by `kingpin done` and hidden from `kingpin list`; run `kingpin list --all` to include them. The task path survives the merge as a symlink to the archive, so a dossier link still opens the reviewed page instead of a blank one, and `kingpin` never treats that link as a live task. `kingpin curate` still collects skill critiques from archived tasks, and it also runs on its own from the supervisor's idle pass, at most once a calendar day, landing its skill edits through a review dossier.

### 2. Task Review Dossiers (`lavish-axi`)

When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. The task's listener opens it once and records the Lavish session URL in the task directory's `dossier.url`, and `kingpin list` prints that URL under the task's row. Hand the URL over rather than running `lavish-axi` on a page a listener already opened, which puts a second tab on the same session. A task with no recorded URL still shows the `lavish-axi <path>` command.

Review the changes and click **Approve & Land** on the dossier or run:

```bash
kingpin land <task-id>
```

### 3. Handover Artifacts (handover template)

Pages handed to the boss for a decision (proposals, plans, comparisons, review summaries) start from the handover template that ships with the repo, in the same folder as the worker dossier template:

```
assets/lavish/worker-dossier/
  handover.html   the page: decision header, stat cards, problem, inline-SVG diagram, options, risks, diff, decision forms
  template.html   a worker's report.html, section 4 below
  DESIGN.md       the rules the look depends on, beside the files they describe
```

Copy `handover.html` into the artifact's directory (`.lavish/`), rename it, change the title first, then swap the sample content and `REPLACE` comments. `DESIGN.md` lists the rules (dark palette, what each colour means, option cards and one comparison table, one form per question) and how to trim the page into a review summary. Check it at 1280 and 1024 wide with nothing scrolling sideways, then open it:

```bash
lavish-axi .lavish/<artifact>.html
```

`tests/test-worker-dossier-template.sh` fails when the folder loses a file, when a section a page is read for goes missing, when a decision form loses its handler or its no-Lavish message, or when the page stops passing the full `kingpin report check`.

The noir dossier template (`assets/lavish/noir-dossier/`, tested by `tests/test-noir-template.sh`) stays in the repo for a future parchment look. Nothing uses it by default.

### 4. Worker Review Dossiers (worker dossier template)

A worker's `report.html` starts from the worker dossier template, which is the default for every task:

```
assets/lavish/worker-dossier/
  template.html   the page: action bar, stat cards, what changed, review findings, validation, diffs
  DESIGN.md       the rules the look depends on, beside the file they describe
```

`worker/preamble.md` tells the worker to copy `template.html` to the task folder as `report.html`, swap the sample values and `REPLACE` comments for the task's own, and paste the output of `kingpin report diffs` over the sample diff section. The look came from the dossiers that read most clearly: a dark GitHub palette on Tailwind and DaisyUI, one numbered Problem and Solution block per change, every review finding as a table row with its pass, ID, severity and outcome, and a validation table. `DESIGN.md` records the rules, including what each colour means. `tests/test-worker-dossier-template.sh` fails when the folder loses a file, when a section the dossier is read for goes missing, when the page stops passing the full `kingpin report check`, or when the preamble stops pointing at it. The handover template shares its look, so a report and a proposal read the same way.
