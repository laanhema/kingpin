# Running Automated Tests

[Back to the README](../README.md).

Run the lint and the full test suite from the repository root:

```bash
# Lint: bash -n + shellcheck over bin/*, lib/*.sh and tests/*.sh (config in .shellcheckrc),
# node --check over lib/*.mjs, a check that every tests/test-*.sh is a leg of the CI matrix,
# a check in both directions over README.md and docs/*.md: every parsed flag and KINGPIN_*
# variable is documented, and every `--` flag in an inline code span and every KINGPIN_*
# name a docs page shows appears in the per-command reference docs/cli.md (a host tool's
# own flag is exempt; a flag shown only inside a fenced example is not read), and a
# check that no .agents plan, report or review file is tracked. Pass --root <dir> to lint
# another checkout instead of this one
./tests/lint.sh

# Every suite, one after the other
for s in tests/test-*.sh; do "./$s" || break; done
```

The suites, one file per feature (shared setup is in `tests/lib.sh`: private tmux server, scratch repo, helpers):

| Suite | Covers |
|---|---|
| `test-lifecycle.sh` | `init`, `list`, `watch` auto-lifecycle, `run`, tmux session targeting |
| `test-wait.sh` | `wait` and `ack`: blocking, wake filtering, exit codes |
| `test-watch-supervisor.sh` | `watch`: single supervisor with a pidfile, stale reclaim, `list` line, `lock acquire` warning, events handled across turns |
| `test-lock.sh` | `lock`: lifecycle, collisions, stale locks, recorded harness, parallel acquire race, atomic publish, release ownership |
| `test-curate.sh` | `curate` |
| `test-land.sh` | `land`: review-gate verdicts, fix pass, re-review, output wording |
| `test-landing-lane.sh` | land lane: dead worker window, dead queue entry, concurrent lands, append-after-release |
| `test-done.sh` | `done`: refused cleanup, archive, slot guard, branch cleanup, single-flight, default-branch resolution |
| `test-archive-link.sh` | an archived task's dossier link: the page keeps resolving, and `list`/`wait`/`watch`/`land`/`listen`/`spawn`/`ack` treat the link as finished |
| `test-listen.sh` | `listen`: dossier opening, live listener, prompt routing |
| `test-send-peek.sh` | `send` and `peek` |
| `test-spawn.sh` | `spawn`: window ID tracking, descriptive slugs, pinned window names |
| `test-sync.sh` | `sync` |
| `test-cli-help.sh` | `--help` on every command in `kingpin --help`: usage text, exit 0, no window or task started |
| `test-launch-check.sh` | `kingpin-launch-check`: workers that die at launch |
| `test-worker-stop.sh` | `bin/kingpin-stop`: the outcome a Stop leaves (`failed:`/`waiting:`), fail-soft, `WAITING`/`SILENT`/`Unseen` in `list`, all four harnesses |
| `test-status.sh` | `lib/status.sh`, the shared status protocol |
| `test-report.sh` | `report`: generated diffs are renderable, blank-diff reports are rejected |
| `test-markdown.sh` | `report check`: markdown prose masking, CRLF line numbers, the full rule list |
| `test-ranks.sh` | rank voice: the contract's Ranks section, the capo preamble, and the neutral status lines |
| `test-noir-template.sh` | noir dossier template: the three files ship together, every ref stays inside the folder, the diffs keep static fallbacks, the prose stays clean |
| `test-harnesses.sh` | Multi-harness contract and isolation |
| `test-pi-harness.sh` | Pi worker extension (`lib/pi-harness.mjs`): the `agent_settled` stop call, the `resources_discover` skills bridge, and the per-worktree `project_trust` answer |
| `test-worker-scope.sh` | Worker instruction context: what each harness really loads, the spawn refusal, the installed contract |
| `test-worker-settings.sh` | Orchestrator tool guard and worker edit boundary |
| `test-acceptance.sh` | 3-worker parallel concurrency and serial landing |
| `test-agents-paths.sh` | `.agents` artifact policy: nothing under `plans/`, `reports/` or `reviews/` is tracked, other `.agents/` files stay trackable, and the lint fails on a forced artifact |
| `test-lint.sh` | the lint itself: a syntax error in a shell script or a `lib/*.mjs` module fails it by name, and a suite with no CI leg fails the matrix check |

Run one suite with `./tests/test-<name>.sh`. Run suites one at a time in a checkout: `test-lifecycle.sh`, `test-acceptance.sh` and `test-landing-lane.sh` briefly replace `bin/kingpin-send` with a stub (restored on exit), so a second suite that sends keys to a worker during that window hits the stub and fails. CI legs do not clash, since each runs in its own checkout.

CI (`.github/workflows/ci.yml`) runs the lint plus one matrix leg per suite on every PR and push to `main`. The suites need `git`, `tmux`, `node`, `treehouse` and a git identity (the suites set one themselves). They use fake agents, so no harness binary is required, and no `lavish-axi` either: `tests/lib.sh` installs a recording stub in `kp_test_setup`, plus a `lavish-axi` shim first on `PATH` that records a real call and exits 1, so a suite never reaches the real Lavish server by omission or by unsetting `KINGPIN_LAVISH`. A suite that drives that stub on purpose declares `kp_test_expect_lavish_calls`, optionally with shell-glob patterns its recorded calls must match; a declaration that records nothing fails, and any other call, or a real call, fails the suite at `kp_test_finish` and names the arguments. A new suite needs a matrix leg; `./tests/lint.sh` fails until it has one.
