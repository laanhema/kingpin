# Code Review: kingpin/kp-61-add-shellcheck-ci

**Scope**: branch `kingpin/kp-61-add-shellcheck-ci` vs merge base d290271, including uncommitted and untracked changes, checked against issue #61
**Recommendation**: NEEDS CHANGES

## Summary

Adds `tests/lint.sh` (`bash -n` + shellcheck over `bin/*` and `tests/*.sh`), `.shellcheckrc`, a `.github/workflows/ci.yml` (lint job plus a five-suite test matrix), git-identity exports in three suites, and README/AGENTS.md docs. With shellcheck 0.11.0 everything is clean and all five suites pass under `env -i` with no git identity. The lint job is not pinned to that version though: with shellcheck 0.9.0 (the version Ubuntu runners and apt ship) the lint fails on six SC2002 hits, so the first CI run would likely go red.

Acceptance criteria:
1. Shellcheck over `bin/*`, `tests/*.sh`, sourced files; minimal documented disables: met with 0.11.0 (one global disable SC2015 with reason, local disables carry reasons). The only sourced files are generated env files (`bin/kingpin-done:26`, `bin/kingpin-spawn:79`), not scripts. Fragile across versions, see H1.
2. Workflow runs shellcheck plus `bash -n` on PR and push to main: workflow present (`bash -n` runs inside `lint.sh`); not yet run on GitHub, and H1 predicts a failure.
3. Workflow runs the five suites: met in the workflow; I ran all five locally with `env -i` and no git identity, all pass. The treehouse v3.1.1 asset and `checksums.txt` exist at the URLs used.
4. README and AGENTS.md name the local lint command: met (`README.md` "Running Automated Tests", `AGENTS.md` "Validation").

## Issues Found

### Critical
None

### High Priority
- **H1** `.github/workflows/ci.yml:26` — the lint job uses whatever shellcheck the runner has (the step only installs one when absent) while only 0.11.0 was validated. **Why:** with shellcheck 0.9.0 `./tests/lint.sh` exits 1 on six SC2002 (style) hits: `bin/kingpin-ack:57`, `bin/kingpin-wait:121`, `bin/kingpin-wait:169`, `bin/kingpin-wait:171`, `tests/test-automation.sh:239`, `tests/test-automation.sh:279` (reproduced with `shellcheck-py==0.9.0.6`). Ubuntu hosted runner images ship 0.9.x, so the lint job would fail on its first run; this is inferred from the image, not observed on GitHub. **Fix:** pin one version in CI (for example `pip install shellcheck-py==0.11.0.1` or download the release binary, mirroring the pinned treehouse step) and use the same pin in the AGENTS.md/README install hint; alternatively fix the six `cat f | tr` sites (`tr ... < f`) or disable SC2002 in `.shellcheckrc` with a reason.

### Medium Priority
None

### Suggestions (Low)
- **L1** `README.md:30` — `pip install shellcheck-py` installs the latest version, which can drift from the CI version. **Why:** local lint and CI could disagree. **Fix:** once H1 pins a version, name the same version here and in `AGENTS.md:54`.

**Noted, not a finding**: GitHub Actions run is pending until the branch is pushed (stated in the implementation report); treehouse pinned to v3.1.1 rather than v3.1.8 by decision.

## Validation Results

| Check | Status | Notes |
|-------|--------|-------|
| Build / Type Check | N/A | bash project; `bash -n` runs inside `tests/lint.sh` |
| Warnings | NONE | with shellcheck 0.11.0; 6 SC2002 with 0.9.0 (see H1) |
| Lint | PASS (0.11.0) / FAIL (0.9.0) | `PATH=/tmp/kp61-venv/bin:$PATH ./tests/lint.sh`: 24 files clean; with shellcheck-py 0.9.0.6 in a scratch venv: 6 SC2002, exit 1 |
| Tests | PASS | `env -i HOME=... PATH=... ./tests/test-{report,worker-settings,harnesses,acceptance,automation}.sh` on host, no git identity: all five print their ALL ... PASSED line; none skipped |
| UI verification | N/A | no UI change |

## What's Good

- Disables are minimal and each carries a reason; the SC2015 repo-wide disable is justified and documented.
- CI hardening: least-privilege `permissions`, concurrency cancel, checksum-verified treehouse download, `fail-fast: false` matrix.
- The git identity exports make the suites pass on identity-less runners (verified).

## Recommendation

Pin the shellcheck version in CI (H1), then push and confirm the first Actions run is green.
