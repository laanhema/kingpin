# Plan: Narrow Agent and OpenCode Exclusions in Git info/exclude

## Summary

When spawning `agy` and `opencode` workers, `bin/kingpin-spawn` previously excluded the entire `.agents` and `.opencode` directories in `info/exclude`, which prevented git from tracking legitimate user or worker artifacts such as review reports and plans under `.agents/` across worktrees. This change updates `bin/kingpin-spawn` to exclude only the specific files injected by Kingpin (`.agents/rules/kingpin.md`, `.agents/hooks.json` for agy; `.opencode/config.json`, `.opencode/plugins/package.json`, `.opencode/plugins/kingpin-stop.js` for opencode), migrates existing broad exclusions automatically in `info/exclude`, updates `tests/test-harnesses.sh` with regression assertions, and updates documentation in `README.md`.

## User Story

As a fleet operator using Antigravity CLI or OpenCode harnesses,
I want Kingpin to exclude only its own injected worker configuration files from git,
so that newly generated review reports, plans, and user files under `.agents/` and `.opencode/` can be detected and tracked by git.

## Metadata

| Field | Value |
|-------|-------|
| Type | BUG_FIX |
| Complexity | LOW |
| Systems Affected | `bin/kingpin-spawn`, `tests/test-harnesses.sh`, `README.md` |
| GitHub Issue | #8 |
| PRD Phase | N/A |
| Prototype Patch | N/A |

---

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `bin/kingpin-spawn` | UPDATE | Replace broad `.agents` and `.opencode` exclusions with exact file paths, and add migration to strip legacy broad lines from `info/exclude` |
| `tests/test-harnesses.sh` | UPDATE | Verify specific files are excluded, broad directories are not excluded, and new `.agents/reviews/x.md` / `.opencode/notes.txt` appear in `git status` |
| `README.md` | UPDATE | Document that Kingpin excludes injected configuration files rather than entire configuration directories |

---

## Tasks

Execute in order. Each task is atomic and verifiable.

### Task 1: Update bin/kingpin-spawn with narrow exclusions and legacy migration

- **File**: `bin/kingpin-spawn`
- **Action**: UPDATE
- **Implement**: Add `migrate_legacy_excludes` function to remove broad `^/?\.agents/?$` and `^/?\.opencode/?$` from `info/exclude`. In `agy` harness case, replace `exclude_path '.agents'` with `exclude_path '.agents/rules/kingpin.md'` and `exclude_path '.agents/hooks.json'`. In `opencode` harness case, replace `exclude_path '.opencode'` with `exclude_path '.opencode/config.json'`, `exclude_path '.opencode/plugins/package.json'`, and `exclude_path '.opencode/plugins/kingpin-stop.js'`.
- **Mirror**: `bin/kingpin-spawn:119-129`
- **Validate**: `bash -n bin/kingpin-spawn`

### Task 2: Update tests in tests/test-harnesses.sh

- **File**: `tests/test-harnesses.sh`
- **Action**: UPDATE
- **Implement**: Update Test 2 (AGY) and Test 3 (OpenCode) to verify that specific files are in `info/exclude`, broad `.agents`/`.opencode` are not in `info/exclude`, `git status` is clean after spawn, and creating a file in `.agents/reviews/` or `.opencode/` shows as untracked in `git status`.
- **Mirror**: `tests/test-harnesses.sh:97-103`
- **Validate**: `bash tests/test-harnesses.sh`

### Task 3: Update README.md documentation and perform one-off repository info/exclude cleanup

- **File**: `README.md`
- **Action**: UPDATE
- **Implement**: Update line 143 of `README.md` to clarify that Kingpin excludes injected files rather than whole directories. Clean up legacy `.agents` entry from the host repository's `.git/info/exclude` if present.
- **Mirror**: `README.md:135-144`
- **Validate**: `git diff README.md`

### Task 4: Run full test suite regression checks

- **File**: `tests/test-acceptance.sh`
- **Action**: CHECK
- **Implement**: Run multi-harness and acceptance test suites to guarantee full end-to-end multi-worker fleet stability.
- **Mirror**: `tests/test-acceptance.sh:1-150`
- **Validate**: `bash tests/test-harnesses.sh && bash tests/test-acceptance.sh`

---

## Validation

```bash
# Type check / Build
bash -n bin/* tests/*.sh

# Lint
bash -n bin/* tests/*.sh

# Tests
bash tests/test-harnesses.sh && bash tests/test-acceptance.sh

# Reproduction (BUG_FIX only, red on unfixed code, green after fix)
python3 -c '
import subprocess, tempfile, os

with tempfile.TemporaryDirectory() as td:
    subprocess.run(["git", "init", td], check=True, capture_output=True)
    subprocess.run(["git", "-C", td, "config", "user.name", "T"], check=True)
    subprocess.run(["git", "-C", td, "config", "user.email", "t@t.com"], check=True)
    with open(f"{td}/f", "w") as f: f.write("x\n")
    subprocess.run(["git", "-C", td, "add", "f"], check=True)
    subprocess.run(["git", "-C", td, "commit", "-m", "init"], check=True)
    # Simulate agy spawn with narrow exclude
    os.makedirs(f"{td}/.agents/rules", exist_ok=True)
    os.makedirs(f"{td}/.agents/reviews", exist_ok=True)
    with open(f"{td}/.agents/rules/kingpin.md", "w") as f: f.write("rule\n")
    with open(f"{td}/.agents/hooks.json", "w") as f: f.write("{}\n")
    with open(f"{td}/.agents/reviews/x.md", "w") as f: f.write("report\n")
    excl = f"{td}/.git/info/exclude"
    with open(excl, "w") as f: f.write(".agents/rules/kingpin.md\n.agents/hooks.json\n")
    out = subprocess.run(["git", "-C", td, "status", "--porcelain"], check=True, capture_output=True, text=True).stdout
    assert ".agents/reviews/x.md" in out, "Failed: .agents/reviews/x.md should appear in git status"
    assert "kingpin.md" not in out, "Failed: kingpin.md should be excluded"
    assert "hooks.json" not in out, "Failed: hooks.json should be excluded"
print("Reproduction check: PASS")
'
```

## End-to-End Verification

1. Run `bash tests/test-harnesses.sh` and ensure:
   - For AGY spawn: `.agents/rules/kingpin.md` and `.agents/hooks.json` are recorded in `info/exclude`, but broad `.agents` is not.
   - For AGY spawn: after creating `.agents/reviews/x.md`, `git status --porcelain` lists `.agents/reviews/x.md`.
   - For OpenCode spawn: `.opencode/config.json`, `.opencode/plugins/package.json`, and `.opencode/plugins/kingpin-stop.js` are in `info/exclude`, but broad `.opencode` is not.
   - For OpenCode spawn: after creating `.opencode/notes.txt`, `git status --porcelain` lists `.opencode/notes.txt`.
2. Run `bash tests/test-acceptance.sh` to confirm concurrent worker spawning and serial landing remain green.
3. Verify `/home/lauri/github/kingpin/.git/info/exclude` has no bare `.agents` or `.opencode` lines.

## Risks

| Risk | Mitigation |
|------|------------|
| Git matching differences across git versions with relative exclude patterns | Relative paths without leading slash (`.agents/rules/kingpin.md`) match from the repo root in `info/exclude` on all modern git versions; tested and verified. In-scope. |
| Existing repositories already have `.agents` or `.opencode` in their shared `info/exclude` | `migrate_legacy_excludes` automatically strips `^/?\.agents/?$` and `^/?\.opencode/?$` upon spawn, ensuring old exclusions don't persist. In-scope. |

## Acceptance Criteria

- [ ] Spawning an agy worker excludes only the files kingpin writes (`.agents/rules/kingpin.md`, `.agents/hooks.json`), not the whole `.agents/` folder
- [ ] A new `.agents/reviews/x.md` shows in `git status` after an agy spawn
- [ ] Spawning an opencode worker excludes only the files kingpin writes (`.opencode/config.json`, `.opencode/plugins/package.json`, `.opencode/plugins/kingpin-stop.js`), not the whole `.opencode/` folder
- [ ] A new file under `.opencode/` (e.g. `notes.txt`) shows in `git status` after an opencode spawn
- [ ] Existing broad `.agents` and `.opencode` lines are migrated by `kingpin-spawn` and cleaned from local repository `info/exclude`
- [ ] Multi-harness tests (`bash tests/test-harnesses.sh`) pass
- [ ] Acceptance tests (`bash tests/test-acceptance.sh`) pass
