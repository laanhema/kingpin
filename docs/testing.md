# Running Automated Tests

[Back to the README](../README.md).

Run the lint and the full test suite from the repository root:

```bash
# Lint: bash -n + shellcheck over bin/*, lib/*.sh and tests/*.sh (config in .shellcheckrc),
# node --check over lib/*.mjs, a check that every tests/test-*.sh is a leg of the CI matrix
# and has a row in the suite table below, a check that no tests/test-*.sh puts a fixed
# `sleep` directly before an assertion (wait with kp_wait_until or kp_holds_for instead),
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
| `test-wait.sh` | `wait` and `ack`: blocking, wake filtering, exit codes, the `seen_line` anchor a written cursor carries, the `--rewind` rules, and the event a file shorter than its cursor raises |
| `test-watch-supervisor.sh` | `watch`: single supervisor with a pidfile, stale reclaim, `list` line, `lock acquire` warning, events handled across turns, a status file rewritten under the cursor and the one-time repair line it logs |
| `test-lock.sh` | `lock`: lifecycle, collisions, stale locks, recorded harness, parallel acquire race, atomic publish, release ownership |
| `test-afk.sh` | `afk`: state lifecycle, the 8-hour default, TTL and dead-pid expiry, the `list` line, `lock release` clearing it, the clean-land path and its note, an all-Low findings verdict that lands through the gate and gains one, the listener's no-double-land markers, every refusal, the Stop-hook boundary the note leaves alone, a disarmed fix pass that lands without a note, an auto-mode NITS pass that gains one, and the skipped review listener |
| `test-curate.sh` | `curate`: lifecycle, quote robustness, a run on a server that holds only a same-prefix session, and the curator window following the configured and environment tmux target |
| `test-curate-auto.sh` | the automatic daily curator trigger: threshold, idle/live-fleet and landing gates, the finished-record shapes that let the run start (`merged:`, `failed: no status:`, `done_cleaned`, a terminal record still carrying `landing_in_progress`), an interrupted `cleanup-refused:` record that holds the run, a finished curator record the reconcile cannot archive that both paths leave intact, the in-flight record named on stderr, once-a-day stamp, existing-window no-op, concurrency, the applied marker, `kingpin land curator`, and no delay to a landing, and a skipped tick that starts no tmux server |
| `test-curate-prompt.sh` | the curator prompt delivery: a batch past the argument limit reaches the harness on stdin, a multi-word override keeps its flags, a missing prompt and a prompt past Kingpin's read cap each write a named `failed:` line, and an unrunnable command names its cause |
| `test-land.sh` | `land`: review-gate verdicts, fix pass, re-review, report path resolution, output wording |
| `test-landing-lane.sh` | land lane: dead worker window (including one whose landing had follow-ups to write), dead queue entry, concurrent lands, append-after-release |
| `test-review-findings.sh` | the review-report reader and the landing gate: the severity split (Critical, High and Medium block, Low is follow-up), the prose, table and CRLF shapes it must not count, the missing, empty, blockless, headingless and unknown-section reports it refuses, the real `land` for an all-Low report, a Medium, High and Critical report, an unknown-heading report and an all-Low `NEEDS CHANGES` line (with the message that names the verdict as the blocker), and the preamble's follow-up duty |
| `test-done.sh` | `done`: refused cleanup, archive, slot guard, branch cleanup, single-flight, default-branch resolution |
| `test-archive-link.sh` | an archived task's dossier link: the page keeps resolving, and `list`/`wait`/`watch`/`land`/`listen`/`spawn`/`ack` treat the link as finished |
| `test-listen.sh` | `listen`: dossier opening, live listener, prompt routing |
| `test-restore.sh` | `restore` after a tmux server restart, the `DEAD` list state, and the shared window resolver |
| `test-send-peek.sh` | `send` and `peek` |
| `test-spawn.sh` | `spawn`: window ID tracking, descriptive slugs, pinned window names, and the tmux target precedence (config pair, env and flag over config, the caller-session default, the stale-`$TMUX` and out-of-tmux fallbacks) |
| `test-stats.sh` | `stats`: the summary counts on a three-task fixture, `--since`, archived records and their dossier links, curator and undated records skipped, the merged and failed precedence rules, and the no-write guarantee |
| `test-tmux-isolation.sh` | tmux isolation: the operator's session and server killed under a running worker, the static checks that every tmux call goes through `lib/tmux.sh` and every session check goes through `kp_tmux_has_session`, `list` naming the socket and session, and `done` closing the fleet window |
| `test-fleet-server.sh` | the fleet tmux server: a dead server read as `DEAD`, the socket warning, the supervisor's restore sweep, the spawn line that says it started the server, and the `-S` attach hint and warning a socket-path record gets |
| `test-mux.sh` | the mux contract: `KINGPIN_MUX` selection, the per-record mux reader, every verb's argv against a fake Herdr, and the two static checks |
| `test-mux-herdr-real.sh` | the opt-in real-Herdr leg: `lib/mux.sh`'s backend against the installed `herdr`, self-skipping when it is absent |
| `test-sync.sh` | `sync` |
| `test-git-compat.sh` | git 2.30 shim: `sync` and `guard install` refusals, `spawn` lease, `info/exclude` resolution, and helper paths with no `--path-format` line |
| `test-cli-help.sh` | `--help` on every command in `kingpin --help`: usage text, exit 0, no window or task started |
| `test-launch-check.sh` | `kingpin-launch-check`: workers that die at launch |
| `test-worker-stop.sh` | `bin/kingpin-stop`: the outcome a Stop leaves (`failed:`/`waiting:`), fail-soft, `WAITING`/`SILENT`/`Unseen` in `list`, all four harnesses |
| `test-status.sh` | `lib/status.sh`, the shared status protocol |
| `test-report.sh` | `report`: generated diffs are renderable, blank-diff reports are rejected |
| `test-markdown.sh` | `report check`: markdown prose masking, CRLF line numbers, the full rule list |
| `test-ranks.sh` | rank voice: the contract's Ranks section, the capo preamble, and the neutral status lines |
| `test-noir-template.sh` | noir dossier template: the three files ship together, every ref stays inside the folder, the diffs keep static fallbacks, the prose stays clean |
| `test-worker-dossier-template.sh` | worker dossier and handover templates: the files ship together, the sections each page is read for stay, the diffs keep static fallbacks, the decision forms keep their handler, the preamble points at the worker template, the prose stays clean |
| `test-harnesses.sh` | Multi-harness contract and isolation |
| `test-pi-harness.sh` | Pi worker extension (`lib/pi-harness.mjs`): the `agent_settled` stop call, the `resources_discover` skills bridge, and the per-worktree `project_trust` answer |
| `test-worker-scope.sh` | Worker instruction context: what each harness really loads, the spawn refusal, the installed contract |
| `test-worker-settings.sh` | Orchestrator tool guard and worker edit boundary |
| `test-excludes.sh` | spawn and done never write the main checkout's `.git/info/exclude`, and injected harness files stay out of a worktree's `git status` |
| `test-browser-daemons.sh` | browser daemons: ownership by working directory, the process-tree stop, and the memory total the `↳ Browser:` line shows |
| `test-acceptance.sh` | 3-worker parallel concurrency and serial landing |
| `test-agents-paths.sh` | `.agents` policy: the whole directory is ignored, nothing under it is tracked, a PRD needs a force-add, and the lint fails on a forced artifact |
| `test-lint.sh` | the lint itself: a syntax error in a shell script or a `lib/*.mjs` module fails it by name, a suite with no CI leg fails the matrix check, a suite with no row in the table above fails by name, a fixed `sleep` before an assertion fails by name with its line and both waits (a trailing comment on the sleep still counts, while a here-document body is skipped), a `NAME=$?` line after an unguarded capture fails by name with its line and `kp_run` (the guarded `\|\| rc=$?` form, a `set +e` block and a here-document body pass), and a source file cited by line fails by name |

Run one suite with `./tests/test-<name>.sh`. Run suites one at a time in a checkout: `test-lifecycle.sh`, `test-acceptance.sh` and `test-landing-lane.sh` briefly replace `bin/kingpin-send` with a stub (restored on exit), so a second suite that sends keys to a worker during that window hits the stub and fails. CI legs do not clash, since each runs in its own checkout.

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every PR and push to `main`. The suites need `git`, `tmux`, `node`, `treehouse` and a git identity (the suites set one themselves). They use fake agents, so no harness binary is required, and no `lavish-axi` either: `tests/lib.sh` installs a recording stub in `kp_test_setup`, plus a `lavish-axi` shim first on `PATH` that records a real call and exits 1, so a suite never reaches the real Lavish server by omission or by unsetting `KINGPIN_LAVISH`. A suite that drives that stub on purpose declares `kp_test_expect_lavish_calls`, optionally with shell-glob patterns its recorded calls must match; a declaration that records nothing fails, and any other call, or a real call, fails the suite at `kp_test_finish` and names the arguments. A new suite needs a matrix leg and a row in the suite table above; `./tests/lint.sh` fails until both are there.
