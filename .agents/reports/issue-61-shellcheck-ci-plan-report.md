# Implementation Report

**Plan**: `.agents/plans/completed/issue-61-shellcheck-ci-plan.md`
**Branch**: `kingpin/kp-61-add-shellcheck-ci`
**Status**: COMPLETE (CI-run step PENDING, see below)

## Summary

Added `tests/lint.sh` (`bash -n` + shellcheck over `bin/*` and `tests/*.sh`) with a root `.shellcheckrc` (one global disable, SC2015). Fixed or locally disabled, with reasons, the 24 remaining findings. Added `.github/workflows/ci.yml` (`lint` job, `test` matrix of the five suites) with treehouse pinned to v3.1.1 and verified against the release `checksums.txt`. The three git-using suites now export a git identity. README.md and AGENTS.md document the lint.

Resolved decisions applied: treehouse pinned to v3.1.1 in one variable (`TREEHOUSE_VERSION`); identity exported inside the suites; shellcheck not pinned in CI.

## Tasks Completed

| # | Task | File | Status |
|---|------|------|--------|
| 1 | shellcheck 0.11.0 in `/tmp/kp61-venv` | scratch | PASS |
| 2 | Make code shellcheck-clean | `.shellcheckrc`, `tests/test-automation.sh`, `tests/test-harnesses.sh`, `bin/kingpin-{curate,guard,rename,spawn}` | PASS |
| 3 | Add lint entry point | `tests/lint.sh` | PASS |
| 4 | Git identity in suites | `tests/test-{automation,harnesses,acceptance}.sh` | PASS |
| 5 | CI workflow | `.github/workflows/ci.yml` | PASS (YAML parse and install step run locally; not run on GitHub) |
| 6 | Docs | `README.md`, `AGENTS.md` | PASS |
| 7 | Full validation, CI run | n/a | local PASS; CI run PENDING (no commit/push allowed) |

## Validation Results

| Check | Result | Command / environment |
|-------|--------|-----------------------|
| Type check (syntax) | PASS | `for f in bin/* tests/*.sh; do bash -n "$f"; done` (also in lint.sh) - host |
| Lint | PASS (`lint: 24 files clean`) | `PATH=/tmp/kp61-venv/bin:$PATH ./tests/lint.sh` - host, shellcheck 0.11.0 |
| Tests | PASS (17 + 79 + 57 + 19 + 304 = 476, 0 FAIL) | `bash tests/test-<name>.sh` for each suite - host; `git status` shows `bin/kingpin-send` unmodified afterwards |
| E2E 1: lint can fail | PASS | unquoted `x=$1; echo $x` appended to a scratch copy of `bin/kingpin-peek`: shellcheck exit 1; `PATH=/usr/bin ./tests/lint.sh`: exit 127 with install hint |
| E2E 2: hosted-runner simulation | PASS (17 / 79 / 57 / 19 / 304, all exit 0) | `env -i HOME=$SIM/home PATH=$SIM/bin:/usr/bin:/bin GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null TERM=xterm ./tests/test-$t.sh`, with `treehouse` v3.1.1 from the workflow's own install step, no git identity in the env |
| E2E 3: workflow YAML | PASS | PyYAML parse: jobs `{lint,test}`, matrix of 5 suites. Workflow's treehouse install step extracted and run verbatim in scratch: `treehouse-v3.1.1-linux-amd64.tar.gz: OK` (sha256 vs release checksums.txt), `treehouse --version` = v3.1.1 |
| E2E 3b/4: run on GitHub (`gh run watch`, throwaway negative branch) | PENDING | needs a pushed branch/PR; run `gh run list --branch kingpin/kp-61-add-shellcheck-ci --limit 1` after push |

Lint "red before" is the plan's measured baseline (440 findings on HEAD, shellcheck 0.11.0); not re-run.

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `.shellcheckrc` | CREATE | +9 |
| `tests/lint.sh` | CREATE (executable) | +17 |
| `.github/workflows/ci.yml` | CREATE | +57 |
| `tests/test-automation.sh` | UPDATE | +24/-21 |
| `tests/test-harnesses.sh` | UPDATE | +3/-1 |
| `tests/test-acceptance.sh` | UPDATE | +2 |
| `bin/kingpin-curate` | UPDATE | +5/-3 |
| `bin/kingpin-guard` | UPDATE | +1 |
| `bin/kingpin-rename` | UPDATE | +1 |
| `bin/kingpin-spawn` | UPDATE | +1 |
| `README.md` | UPDATE | +7/-1 |
| `AGENTS.md` | UPDATE | +4 |

## Deviations from Plan

- `tests/lint.sh` reports `24 files clean`, not 23: bin has 18 files and tests now has 6 `*.sh` (the five suites plus lint.sh itself); the plan miscounted.
- One extra SC2034 finding the plan's list missed: `tests/test-automation.sh:956` (`for i` counter, unused) changed to `for _`. The plan's pre-computed 9 residual findings omitted it (it showed once the others were fixed).
- Also gave a reason to the pre-existing `# shellcheck disable=SC2086` in `tests/test-automation.sh` (as the plan directed); no other disables added beyond the plan.
- In `pane_has_line` (`tests/test-automation.sh`) `local want=$1 i` became `local want=$1` since `i` is no longer used.
- Treehouse pinned to v3.1.1 (resolved decision) instead of the plan's v3.1.8; the workflow comment says so.
- Not done, as instructed: no commit, no push, so the GitHub Actions run and the optional negative-branch check are PENDING.

## Tests Written

No new test cases; `tests/lint.sh` is itself a check and was exercised by the E2E checks above (it is shellcheck-clean and covers itself). Existing suites updated only for the git identity export and the shellcheck fixes.
