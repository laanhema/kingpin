# Fleet Overview & Visual Review Dossiers

[Back to the README](../README.md).

Kingpin is CLI-first for fleet monitoring and visual-first for code review:

### 1. Terminal Fleet Overview (`kingpin list`)

Monitor all active workers, leased worktrees, and current statuses:

```bash
kingpin list
```

For any live task whose folder holds a `report.html`, whatever its mode or status, `kingpin list` displays the dossier command directly below the task row, with `(listening: pid <n>)` while that task's listener runs; finished and archived rows show no dossier line, and `--all` shows the archived rows without one.

The `STATE` column describes a live pane: `WAITING` means the worker is blocked on a human (`needs-input:`, a listener's `feedback:` note, or the Stop hook's `waiting:` line), `SILENT` means it stopped without reporting (`failed: no status:`), and `Unseen: N` counts status lines written since the supervisor last acknowledged the task. `-` is a worker that is running normally or whose window is gone.

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

When a worker completes a task, it compiles a visual review dossier (`report.html`) containing problem context, verification tables, independent review verdicts, and syntax-highlighted split code diffs. Open it with Lavish:

```bash
lavish-axi ~/.kingpin/tasks/<task-id>/report.html
```

Review the changes and click **Approve & Land** on the dossier or run:

```bash
kingpin land <task-id>
```

### 3. Handover Artifacts (noir dossier template)

Pages handed to the boss for a decision (proposals, plans, comparisons, review summaries) start from the noir dossier template that ships with the repo:

```
assets/lavish/noir-dossier/
  template.html   the page: exhibits A-F, inline-SVG diagrams, @pierre/diffs, two working decision forms
  kingpin.jpg     the banner, the same image as assets/kingpin.jpg, referenced relatively
  DESIGN.md       the rules the look depends on, beside the file they describe
```

Copy the folder into the artifact's directory (`.lavish/`), rename the html, swap the content, and keep the chrome. `DESIGN.md` lists the rules (paper on ink, one accent, one display face, exhibit labels, forms for decisions) and the two widths to check, 1180 px and 480 px, with nothing scrolling sideways. Then open it:

```bash
lavish-axi .lavish/<artifact>.html
```

Worker review dossiers are not made from this template: `worker/preamble.md` and `kingpin report diffs` own their layout. `tests/test-noir-template.sh` fails when the folder loses one of the three files, when `template.html` points at a file with an absolute path or through `..`, when a diff block loses its static fallback, or when the page stops passing the full `kingpin report check` (renderable diffs, contained layout and clean prose).

