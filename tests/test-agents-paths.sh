#!/usr/bin/env bash
# .agents/ artifact policy (issue #84): the plans, reports and reviews folders are ignored and
# never tracked, while .agents/ itself stays trackable for files such as a PRD.
#
# The check lives in tests/lint.sh, so this suite runs the real lint inside a fixture copy: a
# force-added artifact must fail it by name, the printed `git rm --cached` remedy must clear that
# failure, and a new .agents/PRDs file must stay trackable and leave the lint green.
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

# This checkout: nothing under the three artifact directories is tracked.
tracked=$(git -C "$KP_ROOT" ls-files -- .agents/plans .agents/reports .agents/reviews)
[ -z "$tracked" ] && pass "no .agents plan, report or review file is tracked" || fail "tracked artifacts: $(echo "$tracked" | tr '\n' ' ')"

# The ignore rules stay limited to the three artifact directories, so .agents/ itself is open.
for d in plans reports reviews; do
  grep -qx "\.agents/$d/" "$KP_ROOT/.gitignore" && pass ".gitignore ignores .agents/$d/" || fail ".gitignore does not ignore .agents/$d/"
done

[ "$(grep -c '^\.agents' "$KP_ROOT/.gitignore")" = 3 ] && pass ".gitignore carries no broader .agents rule" || fail ".gitignore carries .agents rules beyond the three directories"

# The fixture: this checkout's lint inputs, committed, with nothing under .agents/ yet.
cp -a "$KP_ROOT"/bin "$KP_ROOT"/lib "$KP_ROOT"/tests "$KP_ROOT"/.github "$KP_ROOT"/.gitignore "$FIX"/
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

# .agents/ stays trackable: a PRD can be added and the lint still passes.
mkdir -p "$FIX/.agents/PRDs"
printf '# product requirements\n' > "$FIX/.agents/PRDs/example.md"
if (cd "$FIX" && git add .agents/PRDs/example.md && git commit -qm prd); then
  pass "a new .agents/PRDs file can be added and committed"
else
  fail "git refused .agents/PRDs/example.md"
fi
lint "$FIX"
[ "$LINT_RC" -eq 0 ] && pass "the lint passes with a tracked .agents/PRDs file" || fail "the lint failed on a tracked PRD: $LINT_OUT"

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
