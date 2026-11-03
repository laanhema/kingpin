# Plan: Add shellcheck and a CI workflow that runs the test suites

## Summary

Add a single lint entry point, `tests/lint.sh` (`bash -n` over every script, then `shellcheck`), configured by a root `.shellcheckrc` with one documented global disable (SC2015, the `cond && pass || fail` idiom behind 416 of the 440 findings). Fix or locally disable, with a reason, the remaining 24 findings (verified: they are SC1010 x14, SC1087 x1, SC2034 x4, SC2016 x2, SC2086 x2, SC2129 x1; shellcheck 0.11.0, default severity). Add `.github/workflows/ci.yml` with a `lint` job and a `test` job (one matrix leg per suite) on `ubuntu-latest`, triggered by `pull_request` and `push` to `main`. The suites can run on a hosted runner without a stub: their fake agents, mock lavish, and private tmux sockets are already self-contained, and the two real requirements are met by installing a pinned `treehouse` release binary and exporting a git identity (three suites die with exit 128 on a machine with no `user.name`/`user.email`). Document the lint command in README.md and AGENTS.md.

## User Story

As a Kingpin maintainer
I want shellcheck and the test suites to run on every PR and push to main
So that a script that passes in one environment cannot silently fail in another, and workers can report a real "Lint" result

## Metadata

| Field | Value |
|-------|-------|
| Type | ENHANCEMENT |
| Complexity | MEDIUM |
| Systems Affected | `.shellcheckrc` (new), `.github/workflows/ci.yml` (new), `tests/lint.sh` (new), `bin/kingpin-curate`, `bin/kingpin-guard`, `bin/kingpin-rename`, `bin/kingpin-spawn`, `tests/test-automation.sh`, `tests/test-harnesses.sh`, `tests/test-acceptance.sh` (git identity), `README.md`, `AGENTS.md` |
| GitHub Issue | #61 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Environment Findings

Probed on this host (Fedora, 2026-11-03); nothing was installed system-wide.

| Probe | Result |
|-------|--------|
| `shellcheck` on PATH | Not installed. |
| Routes to get it locally | (a) `python3 -m venv ~/.venvs/shellcheck && ~/.venvs/shellcheck/bin/pip install shellcheck-py` : user-level, no root; I used exactly this (wheel `shellcheck_py-0.11.0.1`, `shellcheck --version` = 0.11.0) in `/tmp/sc-venv` (scratch; recreate it, it may be gone). (b) `sudo dnf install ShellCheck` : `ShellCheck-0.11.0-4.fc44` is available, but it is a system-wide install, so ask first. (c) `podman`/`docker` exist with `koalaman/shellcheck`; not pulled. (d) static binary from `github.com/koalaman/shellcheck/releases` (latest `v0.11.0`). `pipx` is absent; `npm`, `cargo`, `go` exist but were not needed. |
| How CI gets it | `ubuntu-latest` ships shellcheck preinstalled. The workflow still runs `command -v shellcheck \|\| sudo apt-get install -y shellcheck` and prints `shellcheck --version`. Caveat: the apt copy on Ubuntu 24.04 is 0.9.x, older than the 0.11.0 used here; I could not test 0.9 (see Risks). |
| Shell scripts in scope | `bin/*` (18 files, all `#!/usr/bin/env bash`) and `tests/*.sh` (5 files). `lib/*.mjs` is Node, not shell. `worker/hooks.json` embeds commands but is JSON. Sourced files: only `. "$conf"` (`bin/kingpin-spawn:79`) and `. "$env_file"` (`bin/kingpin-done:26`), both dynamic paths that already carry `# shellcheck source=/dev/null` (`bin/kingpin-spawn:78`, `bin/kingpin-done:25`). There are no sourced library `.sh` files. |
| Baseline shellcheck (`-x -P SCRIPTDIR`, all severities) | 440 findings: SC2015 x416, SC1010 x14 (`kingpin done` unquoted: `test-automation.sh` lines 165, 186, 193, 870, 1132, 1497, 1503, 1528, 1529, 1536, 1565, 1651, 1962, 1968), SC2034 x4, SC2016 x2, SC2086 x2, SC1087 x1, SC2129 x1. |
| Findings left after disabling SC2015 and applying the two seds in Task 2 (run on a scratch copy) | 9: SC2129 `bin/kingpin-curate:40`; SC2016 `bin/kingpin-guard:95`, `tests/test-automation.sh:1668`; SC2086 `bin/kingpin-rename:41`, `bin/kingpin-spawn:106`; SC2034 `tests/test-automation.sh:191` (`spawn_out_fallback`), `:256` (`quiet_after_ack`), `:269` (`exit_after_ack`), `:1228` (`i` in `for i in $(seq ...)`). |
| Test suites, green baseline on this host | `test-report` 17 PASS, `test-worker-settings` 79 PASS, `test-harnesses` 57 PASS, `test-acceptance` 19 PASS, `test-automation` 304 PASS (476 total, 0 FAIL). Wall time: 1s, 9s, 5s, 12s, 57s. Working tree stayed clean. |
| What the suites actually need | Real `git`, `tmux` (private socket via a `tmux` wrapper in `$T/bin`), `node` (trust/guard helpers), and the real `treehouse` binary (`treehouse get --lease -b`, `treehouse return`, `treehouse status` in `bin/kingpin-spawn:134`, `bin/kingpin-done:174`, `tests/test-acceptance.sh:166`; installed here: v3.1.1, upstream latest v3.1.8). Everything else is faked: harnesses via `KINGPIN_CLAUDE/AGY/OPENCODE=$T/fake-agent` (`tests/test-harnesses.sh:62-73`), lavish via `KINGPIN_LAVISH` mock (`tests/test-automation.sh:881-906`), `treehouse return` via a stub in one test (`:1402`). `claude`, `agy`, `opencode`, `lavish-axi` are never required. `gh` is optional (spawn degrades to `kp-<n>`). |
| Hosted-runner simulation | Ran all five suites with `env -i`, an empty `$HOME`, `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null`, and a PATH of only `treehouse` + `/usr/bin:/bin` (no `claude`/`agy`/`opencode`/`lavish-axi`). Result: `test-report` and `test-worker-settings` pass; `test-harnesses`, `test-acceptance`, `test-automation` **exit 128** immediately on `git commit` (no identity). Adding `GIT_AUTHOR_NAME/EMAIL` and `GIT_COMMITTER_NAME/EMAIL` made all five pass with the same counts (57 / 19 / 304). So the only hosted-runner gaps are the treehouse binary and a git identity. |
| Treehouse release pin | Release assets are `treehouse-v<ver>-linux-amd64.tar.gz` plus `checksums.txt`; the tarball root holds a `treehouse` binary (from the upstream `install.sh`). I could not download and run v3.1.8 here (the sandbox blocked the fetch), so the pin is unvalidated; see Open Questions. |
| Timing flake | `test-acceptance` failed once here (`gamma not merged`) while another session ran the same suite on this machine, then passed on every rerun. It relies on fixed `sleep 2`/`sleep 3` (`tests/test-acceptance.sh:102,136,143,150`). |
| `tests/test-acceptance.sh` side effect | It overwrites the tracked `bin/kingpin-send` in place (`:114-124`) and restores it at `:169-170` and in `cleanup` (`:34-38`). A killed run leaves `bin/kingpin-send` modified. Harmless on a fresh CI checkout. |
| Workflow validation tooling | No `actionlint`; `python3` has PyYAML 6.0.3 for a parse check. |

## Patterns to Follow

### Naming

```
// SOURCE: tests/test-acceptance.sh:1-6 (test script header and strictness)
#!/usr/bin/env bash
# Full acceptance test: 3 parallel workers, separate worktrees, serial landing, clean teardown.
set -euo pipefail

unset TMUX
export KINGPIN_SKIP_GUARD=1
```

### Error Handling

```
// SOURCE: tests/test-acceptance.sh:15-17 and :168-177 (pass/fail helpers and final verdict)
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
...
if [ "$FAILED" -eq 0 ]; then
  echo "ALL ACCEPTANCE TESTS PASSED"
else
  echo "ACCEPTANCE TESTS FAILED"
  exit 1
fi
```

### Tests

```
// SOURCE: tests/test-automation.sh:437 and bin/kingpin-spawn:78-79 (existing shellcheck directives: one-line, with the reason on the line above or implied)
# shellcheck source=/dev/null
. "$conf"
```

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `.shellcheckrc` | CREATE | `external-sources=true`, `source-path=SCRIPTDIR`, and the single global `disable=SC2015` with its reason. |
| `tests/lint.sh` | CREATE | One command for `bash -n` + shellcheck; used locally and by CI; checks itself (it matches `tests/*.sh`). |
| `.github/workflows/ci.yml` | CREATE | `lint` job and `test` matrix on `ubuntu-latest`; PR and push-to-main triggers. |
| `tests/test-automation.sh` | UPDATE | Quote `"done"` x14 (SC1010); fix or disable the 4 SC2034 and 1 SC2016; export a git identity near the top. |
| `tests/test-harnesses.sh` | UPDATE | `${h}[[:space:]]` (SC1087); export a git identity. |
| `tests/test-acceptance.sh` | UPDATE | Export a git identity. |
| `bin/kingpin-curate` | UPDATE | Group the three redirects into one `{ ...; } >> "$input_file"` (SC2129). |
| `bin/kingpin-guard` | UPDATE | `# shellcheck disable=SC2016` with reason at line 95 (`node -e '...'` program, single quotes intended). |
| `bin/kingpin-rename`, `bin/kingpin-spawn` | UPDATE | `# shellcheck disable=SC2086` with reason (`$GH_TIMEOUT` is a command prefix that must word-split). |
| `README.md` | UPDATE | Add `shellcheck` to Prerequisites (optional, for contributors), a "Lint" entry in "Running Automated Tests", and the CI mention. |
| `AGENTS.md` | UPDATE | Add a short "Validation" section after "Orchestrator Tool Guard" naming `./tests/lint.sh` and the five suites. |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Get shellcheck locally

- **File**: none (scratch)
- **Action**: CHECK
- **Implement**: `python3 -m venv /tmp/sc-venv && /tmp/sc-venv/bin/pip install -q shellcheck-py` (or reuse the venv if `/tmp/sc-venv/bin/shellcheck` still exists), then `export PATH=/tmp/sc-venv/bin:$PATH`. Do not use `dnf`/`sudo`. Record `shellcheck --version` (0.11.0 expected).
- **Mirror**: n/a
- **Validate**: `shellcheck --version | sed -n 2p`

### Task 2: Make the existing code shellcheck-clean

- **File**: `.shellcheckrc`, `tests/test-automation.sh`, `tests/test-harnesses.sh`, `bin/kingpin-curate`, `bin/kingpin-guard`, `bin/kingpin-rename`, `bin/kingpin-spawn`
- **Action**: CREATE / UPDATE
- **Implement**:
  1. Create `.shellcheckrc`:
     ```
     # Follow `source` directives and resolve them relative to the script.
     external-sources=true
     source-path=SCRIPTDIR

     # SC2015: `cond && pass "..." || fail "..."` is the test-suite assertion idiom
     # (416 uses). pass() only echoes, so it cannot fail and "A && B || C" cannot
     # run C after A succeeded. Disabled repo-wide; do not use the idiom with a
     # command that can fail.
     disable=SC2015
     ```
  2. SC1010 (14 places in `tests/test-automation.sh`): `sed -i -E 's/(kingpin" )done /\1"done" /' tests/test-automation.sh` (verified on a scratch copy: clears all 14, and `kingpin "done"` runs the same subcommand). Confirm with `grep -c 'kingpin" done ' tests/test-automation.sh` printing 0.
  3. SC1087 (`tests/test-harnesses.sh:238`): `sed -i 's/\$h\[\[:space:\]\]"/${h}[[:space:]]"/' tests/test-harnesses.sh`.
  4. SC2034 (`tests/test-automation.sh:191`): the variable is never read; change to `TMUX="/tmp/nonexistent-sock,99999,99999" "$KP_BIN/kingpin" spawn ... --mode review >/dev/null` (keeps the `set -e` semantics: the spawn must still succeed). `:256` and `:269` sit inside `set +e ... set -e` and only the exit status matters: drop the `quiet_after_ack=` / `exit_after_ack=` prefix and add `>/dev/null`. `:1228`: `for i in $(seq 1 50)` loop variable is a counter; use `for _ in $(seq 1 50)`.
  5. SC2016 (`bin/kingpin-guard:95`, `tests/test-automation.sh:1668`): add `# shellcheck disable=SC2016 # single quotes are intentional: the program runs in node / the inner bash -c` on the line above each.
  6. SC2086 (`bin/kingpin-rename:41`, `bin/kingpin-spawn:106`): add `# shellcheck disable=SC2086 # GH_TIMEOUT is "timeout N" or empty and must word-split` above each (the existing `tests/test-automation.sh:437` disable has no reason; add one while there).
  7. SC2129 (`bin/kingpin-curate:38-42`): wrap the three appends: `{ echo "--- Task $task_id ---"; cat "$crit_file"; echo ""; } >> "$input_file"`.
- **Mirror**: `bin/kingpin-spawn:78-79` (directive placement), `tests/test-automation.sh:437`
- **Validate**: `shellcheck bin/* tests/*.sh && echo clean`

### Task 3: Add `tests/lint.sh`

- **File**: `tests/lint.sh` (executable)
- **Action**: CREATE
- **Implement**: this exact script (tried in a scratch copy: exits 127 with the hint when shellcheck is missing, exits 1 on findings, and is itself shellcheck-clean):
  ```bash
  #!/usr/bin/env bash
  # Lint every shell script: `bash -n` for syntax, then shellcheck (settings in .shellcheckrc).
  set -euo pipefail

  cd "$(dirname "$0")/.."

  command -v shellcheck >/dev/null || {
    echo "lint: shellcheck not found (pip install shellcheck-py, or use your package manager)" >&2
    exit 127
  }

  files=(bin/* tests/*.sh)
  for f in "${files[@]}"; do
    bash -n "$f" || { echo "lint: bash -n failed: $f" >&2; exit 1; }
  done
  shellcheck "${files[@]}"
  echo "lint: ${#files[@]} files clean"
  ```
  `chmod +x tests/lint.sh`.
- **Mirror**: `tests/test-report.sh:1-10` (short script header)
- **Validate**: `./tests/lint.sh` (expect `lint: 23 files clean`, exit 0)

### Task 4: Make the git-identity requirement explicit in the tests

- **File**: `tests/test-automation.sh`, `tests/test-harnesses.sh`, `tests/test-acceptance.sh`
- **Action**: UPDATE
- **Implement**: right after the existing `export KINGPIN_SKIP_GUARD=1` / `unset ...` block of each of the three suites, add `export GIT_AUTHOR_NAME=kingpin-test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=kingpin-test GIT_COMMITTER_EMAIL=test@example.com` with a one-line comment ("CI runners have no global git identity"). This makes the suites pass on a machine with no `git config user.*` (reproduced: exit 128 without it), so the workflow does not depend on an env block that a local run lacks. (Alternative if the owner prefers: set these four vars only in the workflow `env:`; see Open Questions.) `test-report.sh` and `test-worker-settings.sh` already pass identity inline and need nothing.
- **Mirror**: `tests/test-worker-settings.sh:69` (`-c user.email=t@t -c user.name=t`)
- **Validate**: the hosted-runner simulation (see End-to-End Verification), without the `GIT_AUTHOR_*` vars in its `env -i` list: `harnesses` 57, `acceptance` 19, `automation` 304 PASS.

### Task 5: Create the CI workflow

- **File**: `.github/workflows/ci.yml`
- **Action**: CREATE
- **Implement**:
  ```yaml
  name: CI

  on:
    pull_request:
    push:
      branches: [main]

  permissions:
    contents: read

  concurrency:
    group: ci-${{ github.ref }}
    cancel-in-progress: true

  env:
    TREEHOUSE_VERSION: v3.1.8   # see plan Open Question 1

  jobs:
    lint:
      runs-on: ubuntu-latest
      timeout-minutes: 5
      steps:
        - uses: actions/checkout@v4
        - name: Ensure shellcheck
          run: |
            command -v shellcheck >/dev/null || sudo apt-get install -y shellcheck
            shellcheck --version
        - name: bash -n + shellcheck
          run: ./tests/lint.sh

    test:
      runs-on: ubuntu-latest
      timeout-minutes: 15
      strategy:
        fail-fast: false
        matrix:
          suite: [report, worker-settings, harnesses, acceptance, automation]
      steps:
        - uses: actions/checkout@v4
        - name: Install tmux
          run: sudo apt-get update && sudo apt-get install -y tmux
        - name: Install treehouse ${{ env.TREEHOUSE_VERSION }}
          run: |
            d=$(mktemp -d)
            f=treehouse-${TREEHOUSE_VERSION}-linux-amd64.tar.gz
            base=https://github.com/kunchenguid/treehouse/releases/download/${TREEHOUSE_VERSION}
            curl -fsSL "$base/$f" -o "$d/$f"
            curl -fsSL "$base/checksums.txt" -o "$d/checksums.txt"
            (cd "$d" && grep " $f\$" checksums.txt | sha256sum -c -)
            mkdir -p "$RUNNER_TEMP/bin"
            tar xzf "$d/$f" -C "$RUNNER_TEMP/bin" treehouse
            echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
        - name: Versions
          run: git --version && tmux -V && node --version && treehouse --version
        - name: tests/test-${{ matrix.suite }}.sh
          run: ./tests/test-${{ matrix.suite }}.sh
  ```
  Notes for the implementer: the `treehouse` tarball root file name is `treehouse` (per the upstream `install.sh`); if `checksums.txt` lists the file with a `./` prefix or other path, adjust the `grep`. Keep action versions at the current majors (`actions/checkout@v4`). Do not add secrets or `pull_request_target`. If the `git identity` was exported inside the suites (Task 4), no `env:` block is needed.
- **Mirror**: n/a (the repo has no `.github/` yet)
- **Validate**: `python3 -c 'import yaml,sys; d=yaml.safe_load(open(".github/workflows/ci.yml")); assert set(d["jobs"])=={"lint","test"}; print("yaml ok", d[True].keys())'` (PyYAML parses the unquoted `on` key as `True`; that is expected).

### Task 6: Document the lint command

- **File**: `README.md`, `AGENTS.md`
- **Action**: UPDATE
- **Implement**:
  - `README.md` Prerequisites (line ~26 "Optional:"): add `shellcheck` (contributors; `pip install shellcheck-py` into a venv, or your package manager). In "Running Automated Tests" (line ~187), add before the suites: `# Lint: bash -n + shellcheck over bin/* and tests/*.sh (config in .shellcheckrc)` / `./tests/lint.sh`, and one sentence: CI (`.github/workflows/ci.yml`) runs the lint plus each suite on every PR and push to `main`; the suites need `git`, `tmux`, `node`, `treehouse` and a git identity (the suites set one themselves), and use fake agents, so no harness binary is required.
  - `AGENTS.md`: add `## Validation` after the Orchestrator Tool Guard bullet list (before `## How to Handle Requests`, line ~51): "Lint with `./tests/lint.sh` (`bash -n` plus shellcheck; install shellcheck with `pip install shellcheck-py` in a venv). The five suites are `tests/test-*.sh`; CI runs both on every PR. Disable a shellcheck rule only with a `# shellcheck disable=SCnnnn # reason` line, or in `.shellcheckrc` with a comment."
- **Mirror**: `README.md:187-206` (existing test section style), `AGENTS.md:50` (single-bullet style)
- **Validate**: `grep -n 'tests/lint.sh' README.md AGENTS.md`

### Task 7: Full local validation, then CI

- **File**: none
- **Action**: CHECK
- **Implement**: run the commands in Validation and End-to-End Verification. Push the branch and confirm the workflow goes green on the PR (both jobs, all five matrix legs). If a leg fails only on the runner, fix per Risks before reporting done. In the PR description: say the suites run in CI with a real pinned `treehouse` (no stub needed) and name the pinned version.
- **Mirror**: n/a
- **Validate**: `gh run list --branch kingpin/kp-61-add-shellcheck-ci --limit 1` shows `completed success`

---

## Validation

```bash
# Type check / Build: syntax of every script (also part of lint.sh)
for f in bin/* tests/*.sh; do bash -n "$f" || echo "SYNTAX: $f"; done

# Lint (the new command; needs shellcheck on PATH, e.g. /tmp/sc-venv/bin)
./tests/lint.sh

# Tests (green baseline on HEAD: 17 / 79 / 57 / 19 / 304 PASS)
for t in report worker-settings harnesses acceptance automation; do ./tests/test-$t.sh || echo "FAILED: $t"; done
git status --short   # must stay empty (test-acceptance rewrites bin/kingpin-send and restores it)
```

## End-to-End Verification

1. Lint is red before, green after. On HEAD (before Task 2) `shellcheck -x -P SCRIPTDIR bin/* tests/*.sh` reports 440 findings; after Task 2 `./tests/lint.sh` prints `lint: 23 files clean`. Prove the check can fail: append `x=$1; echo $x` (unquoted, SC2086) to a scratch copy of any `bin/` file, run `shellcheck` on it, and see a nonzero exit; also run `PATH=/usr/bin ./tests/lint.sh` and see exit 127 with the install hint.
2. Hosted-runner simulation (proves the suites need nothing beyond treehouse, tmux, node, git on a clean machine). After Tasks 2 and 4, with `SIM=$(mktemp -d); mkdir -p $SIM/home $SIM/bin; ln -s "$(command -v treehouse)" $SIM/bin/treehouse`, run for each suite `t`:
   `env -i HOME=$SIM/home PATH=$SIM/bin:/usr/bin:/bin GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null TERM=xterm ./tests/test-$t.sh`
   Expected: exit 0 for all five, with PASS counts 17 / 79 / 57 / 19 / 304. Before Task 4 this exact command exits 128 for `harnesses`, `acceptance`, `automation` (reproduced).
3. Workflow: `python3` YAML parse (Task 5 Validate), then push and watch `gh run watch`. Expected: `lint` green, five `test (<suite>)` legs green. Each leg should finish well under the 15-minute timeout (local times 1-57s).
4. Negative check in CI: on a throwaway branch commit an unquoted-variable line to `bin/kingpin-peek`, confirm `lint` goes red, then delete the branch. (Optional if step 1 is done.)

## Risks

| Risk | Mitigation |
|------|------------|
| Ubuntu's apt/preinstalled shellcheck (0.9.x on 24.04) is older than 0.11.0 used here, so it could report different or extra findings, or miss ours. | In scope: read the first CI log. If CI reports something local does not, fix it the same way (or disable with a reason). Optionally pin 0.11.0 in CI via the static release tarball with checksum. Not tested here: the sandbox blocked container pulls and release downloads. |
| `treehouse` pin (`v3.1.8`) is untested against the suites; this host runs v3.1.1. | In scope: first CI run is the test. If a leg fails on treehouse behaviour, try v3.1.1 (`TREEHOUSE_VERSION` is one env var) and report the difference. Never install via `curl \| sh` from `latest`: that makes CI drift. |
| `test-acceptance` uses fixed `sleep 2/3` waits and failed once here under load. A runner could flake. | Out of scope unless it flakes in CI. If it does (more than once), replace the sleeps at `tests/test-acceptance.sh:102,136,143,150` with a bounded poll (`for _ in $(seq 50); do grep -q ... && break; sleep 0.2; done`) in the same PR or a follow-up; do not add a CI retry. |
| `test-acceptance` edits the tracked `bin/kingpin-send` in place; a cancelled run leaves the tree modified. | Out of scope (harmless on a fresh runner; the `concurrency` block cancels superseded runs, which is safe because the checkout is thrown away). Flag in the PR; fixing it means a `KINGPIN_SEND` override in `bin/kingpin-land`. |
| Global SC2015 disable hides a real `A && B || C` bug (B failing, C running). | Documented in `.shellcheckrc`; the only affected idiom is `pass`/`fail`. Out of scope to rewrite 416 lines as `if`. |
| Adding the identity export to the suites changes their environment for child processes. | In scope: the vars are exported only inside the test processes, and the suites already create their own repos. `test-worker-settings` still passes unchanged, which covers a no-identity path. |
| Workflow supply chain: downloads a binary from a third-party release. | `sha256sum -c` against the release's `checksums.txt`, pinned tag, `permissions: contents: read`, no secrets, no `pull_request_target`. |

## Open Questions

1. **Which treehouse version should CI pin?** Proposed default: `v3.1.8` (latest release, has `linux-amd64` tarball and `checksums.txt`), falling back to `v3.1.1` (what this host runs and what the suites were green on) if a CI leg fails. Not blocking.
2. **Git identity in the suites or in the workflow `env:`?** Proposed default: in the three suites (Task 4), so a contributor with no global git config can also run them. The workflow-only alternative changes no test file but leaves local no-identity runs failing with exit 128.
3. **Should CI pin shellcheck to 0.11.0?** Proposed default: no; use the runner's preinstalled copy as the issue states, and only pin if findings differ (Risks row 1).

## Acceptance Criteria

- [ ] All tasks completed
- [ ] `./tests/lint.sh` exits 0 over `bin/*` and `tests/*.sh` (shellcheck 0.11.0); the only global disable is SC2015, documented in `.shellcheckrc`; every other disable is inline with a reason
- [ ] `.github/workflows/ci.yml` runs lint (`bash -n` + shellcheck) and the five suites on every PR and push to `main`, and is green on the PR
- [ ] Suites run on the hosted runner with a pinned, checksum-verified real `treehouse` (no stub needed); the PR states this
- [ ] README.md and AGENTS.md name `./tests/lint.sh` and how to install shellcheck locally
- [ ] All five suites still pass locally (17 / 79 / 57 / 19 / 304) and `git status` is clean afterwards
- [ ] Follows existing patterns
