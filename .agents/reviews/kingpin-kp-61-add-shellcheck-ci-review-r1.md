# Code Review: kingpin/kp-61-add-shellcheck-ci (re-review r1)

**Scope**: branch `kingpin/kp-61-add-shellcheck-ci` vs merge base d290271, including uncommitted and untracked changes (nothing is committed), checked against issue #61
**Recommendation**: APPROVE WITH NITS

## Summary

Re-review after `/fix-findings`. The lint job in `.github/workflows/ci.yml` now installs the pinned `shellcheck-py==0.11.0.1` (shellcheck 0.11.0) into a venv in `$RUNNER_TEMP` and prepends it to `$GITHUB_PATH`, so it takes precedence over a runner-preinstalled shellcheck; a "Versions" step prints which binary runs. README.md and AGENTS.md name the same pin. `PATH=/tmp/kp61-venv/bin:$PATH ./tests/lint.sh` prints `lint: 24 files clean` with shellcheck 0.11.0. The fix touched only the workflow and docs, so the earlier suite results (all five pass, also under `env -i` without a git identity) still hold.

Acceptance criteria:
1. Shellcheck over `bin/*` and `tests/*.sh` with documented, minimal disables: met, now version-stable because CI pins 0.11.0.
2. Workflow runs shellcheck plus `bash -n` on every PR and push to `main`: met in the workflow (`bash -n` runs inside `tests/lint.sh`). Not yet run on GitHub, since the branch is not pushed; confirm the first Actions run is green.
3. Workflow runs the five suites: met (matrix leg per suite; treehouse v3.1.1 pinned and checksum-verified; no stub needed, the suites fake agents and sockets).
4. README and AGENTS.md name how to run the lint locally: met, with the pinned install hint.

## Fix Verification

| ID | Status | Evidence |
|----|--------|----------|
| H1 | fixed | `.github/workflows/ci.yml:20` (`SHELLCHECK_PY_VERSION: 0.11.0.1`), `:28-33` (venv install, `$GITHUB_PATH` prepend), `:34-35` (Versions step) |
| L1 | fixed | `README.md:28` and `AGENTS.md:54` name `pip install shellcheck-py==0.11.0.1` and shellcheck 0.11.0 |

## Issues Found

### Critical
None

### High Priority
None

### Medium Priority
None

### Suggestions (Low)
- **L2** `tests/lint.sh:9` — the missing-shellcheck hint says `pip install shellcheck-py`, which installs the latest version, while README/AGENTS.md now name the pin. **Why:** a contributor who follows the script's own hint can get a different shellcheck than CI. **Fix:** change the hint to `pip install shellcheck-py==0.11.0.1`, or point at the README line.

**Noted, not a finding**: the GitHub Actions run is pending until the branch is pushed; treehouse is pinned to v3.1.1 rather than v3.1.8 by decision.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | bash project; `bash -n` runs inside `tests/lint.sh` |
| Warnings | NONE | shellcheck 0.11.0 |
| Lint | PASS | `PATH=/tmp/kp61-venv/bin:$PATH ./tests/lint.sh` on host: 24 files clean; `shellcheck --version` 0.11.0 |
| Tests | PASS | not re-run in full: the fix changed only the workflow and docs; the fix pass ran `test-report.sh` and `test-worker-settings.sh` (PASS); the first review ran all five under `env -i` (PASS) |
| UI verification | N/A | no UI change |

## What's Good

- The pin uses the same shape as the treehouse pin (one env variable) and the venv is prepended to `PATH`, so a preinstalled shellcheck cannot win.
- The Versions step makes a wrong binary visible in the CI log.

## Recommendation

Optionally align the hint in `tests/lint.sh` (L2), then push and confirm the first Actions run is green.
