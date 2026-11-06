# Running Automated Tests

[Back to the README](../README.md).

Run the lint and the full test suite from the repository root:

```bash
# Lint: bash -n + shellcheck over bin/*, lib/*.sh and tests/*.sh (config in .shellcheckrc),
# node --check over lib/*.mjs, a check that every tests/test-*.sh is a leg of the CI matrix
# and has a row in the suite table below, a check that the ci-ok aggregate in that workflow
# needs every other job and runs with `if: always()`, a check that no tests/test-*.sh puts a
# fixed `sleep` directly before an assertion (wait with kp_wait_until or kp_holds_for instead),
# a check that no tests/*.sh reads `$?` on a `NAME=$?` assignment while errexit is on
# (capture with kp_run instead), a check that no page cites a source file by line,
# a check in both directions over README.md and docs/*.md: every parsed flag and KINGPIN_*
# variable is documented, and every `--` flag in a backtick span and every KINGPIN_* name a
# docs page shows appears in the per-command reference docs/cli.md (a host tool's own flag
# is exempt; backticks in a fenced block count too, since no fence state is tracked), and a
# check that no .agents file is tracked. Pass --root <dir> to lint
# another checkout instead of this one
./tests/lint.sh

# Every suite, one after the other
for s in tests/test-*.sh; do "./$s" || break; done
```

The suites, one file per feature (shared setup is in `tests/lib.sh`: private tmux server, scratch repo, the `kp_wait_until` and `kp_holds_for` waits, other helpers):

| Suite | Covers |
|---|---|
| `test-lifecycle.sh` | `init`, `list`, `watch` auto-lifecycle, `run`, fleet-server targeting |
| `test-wait.sh` | `wait` and `ack`: blocking, wake filtering, exit codes, the `seen_line` anchor a written cursor carries, the `--rewind` rules, the event a file shorter than its cursor raises, and a static check that `bin/kingpin-wait` sources each library once |
| `test-watch-once.sh` | `watch --once`: one status line dispatched once by two concurrent `--once` sweeps and by a `--once` sweep beside a running supervisor, the heartbeat that keeps a slow sweep's lock fresh past the mutex staleness rule, the shared sweep lock (`--once` skips a held lock and names the holder, never refuses, and leaves the pidfile alone; the daemon logs a skipped pass and dispatches the un-acked line on a later wait), and a fresh pass after the lock is released |
| `test-watch-supervisor.sh` | `watch`: single supervisor with a pidfile, stale reclaim, `list` line, `lock acquire` warning that names `kingpin-watch.service`, the shipped user unit (`Type=simple`, `Restart=always`, `RestartSec=30`, daemon `ExecStart`), events handled across turns, a status file rewritten under the cursor and the one-time repair line it logs |
| `test-lock.sh` | `lock`: lifecycle, collisions, stale locks, recorded harness, parallel acquire race, atomic publish, release ownership |
| `test-afk.sh` | `afk`: state lifecycle, the 8-hour default, TTL and dead-pid expiry, the `list` line, `lock release` clearing it, the clean-land path and its note, an all-Low findings verdict that lands through the gate and gains one, the listener's no-double-land markers, every refusal, the Stop-hook boundary the note leaves alone, a disarmed fix pass that lands without a note, an auto-mode NITS pass that gains one, and the skipped review listener |
| `test-curate.sh` | `curate`: lifecycle, quote robustness, a run on a server that holds only a same-prefix session, and the curator window following the configured and environment tmux target |
| `test-curate-auto.sh` | the automatic daily curator trigger: threshold, idle/live-fleet and landing gates, the finished-record shapes that let the run start (`merged:`, `failed: no status:`, `done_cleaned`, a terminal record still carrying `landing_in_progress`), an interrupted `cleanup-refused:` record that holds the run, a finished curator record the reconcile cannot archive that both paths leave intact, the in-flight record named on stderr, once-a-day stamp, existing-window no-op, concurrency, the applied marker, `kingpin land curator`, and no delay to a landing, and a skipped tick that starts no tmux server |
| `test-curate-prompt.sh` | the curator prompt delivery: a batch past the argument limit reaches the harness on stdin, a multi-word override keeps its flags, a missing prompt and a prompt past Kingpin's read cap each write a named `failed:` line, and an unrunnable command names its cause |
| `test-land.sh` | `land`: review-gate verdicts, fix pass, re-review, report path resolution, output wording |
| `test-landing-lane.sh` | land lane: dead worker window (including one whose landing had follow-ups to write), dead queue entry, concurrent lands, append-after-release |
| `test-review-findings.sh` | the review-report reader and the landing gate: the severity split (Critical, High and Medium block, Low is follow-up), the prose, table and CRLF shapes it must not count, the missing, empty, blockless, headingless and unknown-section reports it refuses, the real `land` for an all-Low report, a Medium, High and Critical report, an unknown-heading report and an all-Low `NEEDS CHANGES` line (with the message that names the verdict as the blocker), and the preamble's follow-up duty |
| `test-done.sh` | `done`: refused cleanup, archive, slot guard, branch cleanup, single-flight, default-branch resolution |
| `test-merged-checks.sh` | the checks of a merged task's pull request, read through a fake `gh` that returns rollup JSON: a green or empty rollup stays silent, a red or pending one records the `checks:` note and names itself in `kingpin list` and in the `kingpin done` `OK:` line and warning, the AFK hold and its manual release, an unreadable pull request never fails or holds the cleanup, one `gh` call however often the line replays, a `merged:` line with no `pr=`, `--force` reads nothing, the classifier table, and the other status kinds and `merged:` as the last event |
| `test-dossier-retire.sh` | a finished task's dossier: the banner, marker, disabled decision controls and hidden action bar `done` writes, a second cleanup, a refused cleanup and its `--force` recovery, the `(no listener)` line and the open-dossier section `list` prints, the sweep that ends a leftover session once and retires a `failed:` record, a hand-archived record whose work is not finished, a finished record with no page (which `list` does not name), and a minimal page with a single-quoted handler |
| `test-archive-link.sh` | an archived task's dossier link: the page keeps resolving, and `list`/`wait`/`watch`/`land`/`listen`/`spawn`/`ack` treat the link as finished |
| `test-brief.sh` | `brief`: the one-screen digest on an empty fleet and on a fixture of every row shape, the state it shares with `list`, one line per task with no pane dump, the approval and no-listener dossier sections and the markers that drop a row, a queued review and a fix pass with High findings left outside the approval count, a window that outlived its harness, the issue-queue pause state, the AFK and supervisor lines, the landing lanes, a record naming a dead server, the no-write guarantee, and `--help` |
| `test-listen.sh` | `listen`: dossier opening, live listener, prompt routing |
| `test-restore.sh` | `restore` after a tmux server restart, the `DEAD` list state, and the shared window resolver |
| `test-send-peek.sh` | `send` and `peek` |
| `test-spawn.sh` | `spawn`: window ID tracking, descriptive slugs, pinned window names, and the tmux target precedence (config pair, env and flag over config, the caller-session default, the stale-`$TMUX` and out-of-tmux fallbacks) |
| `test-stats.sh` | `stats`: the summary counts on a three-task fixture, `--since`, archived records and their dossier links, curator and undated records skipped, the merged and failed precedence rules, and the no-write guarantee |
| `test-tmux-isolation.sh` | tmux isolation: the operator's session and server killed under a running worker, the static checks that every tmux call goes through `lib/tmux.sh`, every session check goes through `kp_tmux_has_session` and no caller types a second socket fallback, `kp_tmux_live_by_socket` grouping live tasks by socket, `list` naming the socket and session, and `done` closing the fleet window |
| `test-fleet-server.sh` | the fleet tmux server: a dead server read as `DEAD`, the socket warning, the supervisor's restore sweep, the spawn line that says it started the server, and the `-S` attach hint and warning a socket-path record gets |
| `test-mux.sh` | the mux contract: `KINGPIN_MUX` selection, the per-record mux reader, every verb's argv against a fake Herdr, and the two static checks |
| `test-mux-herdr-real.sh` | the opt-in real-Herdr leg: `lib/mux.sh`'s backend against the installed `herdr`, self-skipping when it is absent |
| `test-sync.sh` | `sync` |
| `test-git-compat.sh` | git 2.30 shim: `sync` and `guard install` refusals, `spawn` lease, `info/exclude` resolution, and helper paths with no `--path-format` line |
| `test-cli-help.sh` | `--help` on every command in `kingpin --help`: usage text, exit 0, no window or task started |
| `test-launch-check.sh` | `kingpin-launch-check`: workers that die at launch |
| `test-worker-stop.sh` | `bin/kingpin-stop`: the outcome a Stop leaves (`failed:`/`waiting:`), fail-soft, `WAITING`/`SILENT`/`Unseen` in `list`, all four harnesses |
| `test-status.sh` | `lib/status.sh`, the shared status protocol, and `kp_env_set`, the one `task.env` key writer: an unchanged value leaves the file untouched, a missing key is added, values with `\|` or `&` land verbatim, and a failed write leaves the record intact |
| `test-report.sh` | `report`: generated diffs are renderable, blank-diff reports are rejected |
| `test-markdown.sh` | `report check`: markdown prose masking, CRLF line numbers, the full rule list |
| `test-ranks.sh` | rank voice: the contract's Ranks section, the capo preamble, and the neutral status lines |
| `test-noir-template.sh` | noir dossier template: the three files ship together, every ref stays inside the folder, the diffs keep static fallbacks, the prose stays clean |
| `test-worker-dossier-template.sh` | worker dossier and handover templates: the files ship together, the sections each page is read for stay, the header pills keep their odd height and cap-height trim, the option rows keep their bold title, 1px nudge and badge order, the two style blocks stay identical, the diffs keep static fallbacks, the decision forms keep their handler, the preambles and `AGENTS.md` keep the legacy "still shipped" mention, the prose stays clean |
| `test-kingpin-dossier-template.sh` | the case-file dossier template: the four files ship together, every ref stays inside the folder, both pages keep the nine approved decisions (the handover's hero markup and the template's dark code region included), the worker page keeps the retire hook, the diffs keep their static fallback and breakpoint repaint, the handover keeps its decision forms, handlers and recommendation, the preambles, `AGENTS.md` and the docs name `hero.jpg` beside the copy, the CI leg and suite-table row exist, and each page passes its check |
| `test-harnesses.sh` | Multi-harness contract and isolation |
| `test-pi-harness.sh` | Pi worker extension (`lib/pi-harness.mjs`): the `agent_settled` stop call, the `resources_discover` skills bridge, and the per-worktree `project_trust` answer |
| `test-worker-scope.sh` | Worker instruction context: what each harness really loads, the spawn refusal, the installed contract |
| `test-worker-settings.sh` | Orchestrator tool guard and worker edit boundary |
| `test-excludes.sh` | spawn and done never write the main checkout's `.git/info/exclude`, and injected harness files stay out of a worktree's `git status` |
| `test-browser-daemons.sh` | browser daemons: ownership by working directory, the process-tree stop, and the memory total the `↳ Browser:` line shows |
| `test-acceptance.sh` | 3-worker parallel concurrency and serial landing |
| `test-agents-paths.sh` | `.agents` policy: the whole directory is ignored, nothing under it is tracked, a PRD needs a force-add, and the lint fails on a forced artifact |
| `test-lint.sh` | the lint itself: a syntax error in a shell script or a `lib/*.mjs` module fails it by name, a suite with no CI leg fails the matrix check, a suite with no row in the table above fails by name, a fixed `sleep` before an assertion fails by name with its line and both waits (a trailing comment on the sleep still counts, while a here-document body is skipped), a `NAME=$?` line after an unguarded capture fails by name with its line and `kp_run` (the guarded `\|\| rc=$?` form, a `set +e` block and a here-document body pass), and a source file cited by line fails by name, and a `ci-ok` gate without `if: always()`, a job the gate does not need (an inline comment on the job key changes nothing), a gate with a display `name:` and a missing gate each fail by name, while a block-sequence `needs` and a commented `needs` list pass |

Run one suite with `./tests/test-<name>.sh`. Run suites one at a time in a checkout: `test-lifecycle.sh`, `test-acceptance.sh` and `test-landing-lane.sh` briefly replace `bin/kingpin-send` with a stub (restored on exit), so a second suite that sends keys to a worker during that window hits the stub and fails. CI legs do not clash, since each runs in its own checkout.

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every PR and push to `main`, then the `ci-ok` aggregate, which passes only when every leg passed; `ci-ok` is the one check `main` requires once the protection command in `AGENTS.md` has run. The suites need `git`, `tmux`, `node`, `treehouse` and a git identity (the suites set one themselves). They use fake agents, so no harness binary is required, and no `lavish-axi` either: `tests/lib.sh` installs a recording stub in `kp_test_setup`, plus a `lavish-axi` shim first on `PATH` that records a real call and exits 1, so a suite never reaches the real Lavish server by omission or by unsetting `KINGPIN_LAVISH`. A suite that drives that stub on purpose declares `kp_test_expect_lavish_calls`, optionally with shell-glob patterns its recorded calls must match; a declaration that records nothing fails, and any other call, or a real call, fails the suite at `kp_test_finish` and names the arguments. A new suite needs a matrix leg and a row in the suite table above; `./tests/lint.sh` fails until both are there.
