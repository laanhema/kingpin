#!/usr/bin/env bash
# .agents/ policy: the whole directory is ignored and never tracked, because it holds agent
# working artifacts (plans, reports, reviews, rules and issue drafts), not project sources.
#
# The check lives in tests/lint.sh, so this suite runs the real lint inside a fixture copy: a
# force-added artifact must fail it by name, the printed `git rm --cached` remedy must clear that
# failure, and a new .agents/PRDs file must be ignored rather than committable without a force-add.
set -euo pipefail

. "$(dirname "$0")/lib.sh"

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

FIX=$T/fixture
STUB=$T/stubbin
mkdir -p "$FIX" "$STUB"

# A no-op shellcheck, because the lint demands version 0.11.0 while the test matrix installs only
# tmux and treehouse. `bash -n` still runs for real, and the check under test does not need it.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/shellcheck"
chmod +x "$STUB/shellcheck"

# lint <repo>: run that checkout's own tests/lint.sh with the stubbed shellcheck.
# Sets LINT_RC and LINT_OUT; never aborts the suite, so a pass and a failure are both assertable.
lint() {
  LINT_RC=0
  LINT_OUT=$(cd "$1" && PATH="$STUB:$PATH" ./tests/lint.sh 2>&1) || LINT_RC=$?
}

# This checkout: nothing under .agents/ is tracked.
tracked=$(git -C "$KP_ROOT" ls-files -- .agents)
[ -z "$tracked" ] && pass "no .agents file is tracked" || fail "tracked artifacts: $(echo "$tracked" | tr '\n' ' ')"

# One rule covers the whole directory; a narrower rule would leave its other subdirectories open.
grep -qx '\.agents/' "$KP_ROOT/.gitignore" && pass ".gitignore ignores .agents/" || fail ".gitignore does not ignore .agents/"

[ "$(grep -c '^\.agents' "$KP_ROOT/.gitignore")" = 1 ] && pass ".gitignore carries exactly one .agents rule" || fail ".gitignore carries more than one .agents rule"

# The fixture: this checkout's lint inputs, committed, with nothing under .agents/ yet.
# README.md and docs/ are inputs too: the CLI-reference check reads them.
cp -a "$KP_ROOT"/bin "$KP_ROOT"/lib "$KP_ROOT"/tests "$KP_ROOT"/.github "$KP_ROOT"/.gitignore "$KP_ROOT"/README.md "$KP_ROOT"/docs "$FIX"/
(
  cd "$FIX" || exit 1
  git init -q .
  git config user.email test@example.com
  git config user.name kingpin-test
  git add -A
  git commit -qm fixture
)

lint "$FIX"
if [ "$LINT_RC" -eq 0 ] && grep -q 'files clean' <<< "$LINT_OUT"; then
  pass "the lint passes in a clean checkout"
else
  fail "the lint failed in a clean checkout: $LINT_OUT"
fi

# Every subdirectory is ignored, not just the three artifact folders: a PRD needs a force-add,
# which the lint then catches like any other leak.
mkdir -p "$FIX/.agents/PRDs"
printf '# product requirements\n' > "$FIX/.agents/PRDs/example.md"
git -C "$FIX" check-ignore -q .agents/PRDs/example.md && pass "git ignores a new .agents/PRDs file" || fail "git does not ignore .agents/PRDs/example.md"
if (cd "$FIX" && git add .agents/PRDs/example.md 2>/dev/null); then
  fail "git added .agents/PRDs/example.md without -f"
else
  pass "git refuses .agents/PRDs/example.md without -f"
fi
lint "$FIX"
[ "$LINT_RC" -eq 0 ] && pass "the lint passes with the ignored .agents/PRDs file on disk" || fail "the lint failed with an ignored PRD: $LINT_OUT"

# A forced artifact is the leak the issue describes: the lint names it and exits non-zero.
mkdir -p "$FIX/.agents/plans"
printf '# leaked plan\n' > "$FIX/.agents/plans/leak.md"
# Assert git's ignore decision itself, not just the .gitignore text above: a later negation rule
# would leave those string checks green while the artifact became trackable without a force-add.
git -C "$FIX" check-ignore -q .agents/plans/leak.md && pass "git ignores a new .agents/plans artifact" || fail "git does not ignore .agents/plans/leak.md"
(cd "$FIX" && git add -f .agents/plans/leak.md && git commit -qm leak)
lint "$FIX"
if [ "$LINT_RC" -ne 0 ] && grep -qF '.agents/plans/leak.md' <<< "$LINT_OUT" && grep -qF 'git rm --cached' <<< "$LINT_OUT"; then
  pass "the lint fails on a force-added artifact and names it"
else
  fail "the lint accepted a force-added artifact (rc=$LINT_RC): $LINT_OUT"
fi

# The remedy the message prints clears the failure, because the file stays on disk and ignored.
(cd "$FIX" && git rm -q --cached .agents/plans/leak.md && git commit -qm untrack)
lint "$FIX"
[ "$LINT_RC" -eq 0 ] && pass "'git rm --cached' clears the failure and the file stays on disk" || fail "the lint still failed after 'git rm --cached': $LINT_OUT"
[ -f "$FIX/.agents/plans/leak.md" ] && pass "the untracked artifact is still on disk" || fail "the artifact disappeared from disk"

kp_test_finish AGENTS-PATHS
