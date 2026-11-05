#!/usr/bin/env bash
# The lint's own checks (issue #81, issue #178): shell syntax, node module syntax, the CI
# matrix, the docs/testing.md suite table, and the path:line citation rule.
#
# The checks live in tests/lint.sh, which takes a --root <dir> argument, so this suite runs the
# real lint against a minimal fixture: only the files the lint reads, built here, with nothing
# copied from this checkout. A fixture that mirrored the real tree could not show which single
# input made a check go red.
set -euo pipefail

. "$(dirname "$0")/lib.sh"

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

FIX=$T/fixture
STUB=$T/stubbin
mkdir -p "$FIX"/bin "$FIX"/lib "$FIX"/tests "$FIX"/docs "$FIX"/.github/workflows "$STUB"

# A no-op shellcheck, because the lint demands version 0.11.0 while the test matrix installs only
# tmux and treehouse. `bash -n` and `node --check` run for real, and they are what this suite tests.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/shellcheck"
chmod +x "$STUB/shellcheck"

# lint: run this checkout's real lint against $FIX with the stubbed shellcheck.
# Sets LINT_RC and LINT_OUT; never aborts the suite, so a pass and a failure are both assertable.
lint() {
  LINT_RC=0
  LINT_OUT=$(PATH="$STUB:$PATH" "$KP_ROOT/tests/lint.sh" --root "$FIX" 2>&1) || LINT_RC=$?
}

fixture_init() {
  (
    cd "$FIX" || exit 1
    git init -q .
    git config user.email test@example.com
    git config user.name kingpin-test
    git add -A
    git commit -qm fixture
  )
}

# The fixture holds exactly one valid file per glob the lint reads: bin/*, lib/*.sh,
# tests/test-*.sh, lib/*.mjs, plus the CI matrix the suite check reads and the docs pages the
# reference and citation checks read.
cat > "$FIX/bin/kingpin-fixture" << 'F'
#!/usr/bin/env bash
set -euo pipefail
echo "OK: fixture"
F
chmod +x "$FIX/bin/kingpin-fixture"

cat > "$FIX/lib/fixture.sh" << 'F'
#!/usr/bin/env bash
# A shell helper the lint reads as one of lib/*.sh.
kp_fixture() { echo fixture; }
F

cat > "$FIX/tests/test-demo.sh" << 'F'
#!/usr/bin/env bash
# A suite the CI matrix below lists as its one leg.
set -euo pipefail
echo "ALL DEMO TESTS PASSED"
F
chmod +x "$FIX/tests/test-demo.sh"

cat > "$FIX/lib/fixture.mjs" << 'F'
export const answer = 42;
F

cat > "$FIX/.github/workflows/ci.yml" << 'F'
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        suite: [demo]
F

cat > "$FIX/.gitignore" << 'F'
.agents/plans/
.agents/reports/
.agents/reviews/
F

cat > "$FIX/.shellcheckrc" << 'F'
# The fixture's shellcheck settings; the stubbed shellcheck reads nothing.
disable=SC2015
F

# The docs the CLI-reference and citation checks read, and the suite table the lint reads:
# without a row for the demo suite, the clean-fixture case would fail the new check.
printf '# Fixture\n' > "$FIX/README.md"
printf '# Reference\n' > "$FIX/docs/cli.md"
cat > "$FIX/docs/testing.md" << 'F'
# Testing

| Suite | Covers |
|---|---|
| `test-demo.sh` | the demo suite |
F

fixture_init

echo "=== Test 1: a clean fixture passes ==="
lint
if [ "$LINT_RC" -eq 0 ] && grep -q '3 shell files' <<< "$LINT_OUT" && grep -q '1 node files clean' <<< "$LINT_OUT"; then
  pass "the lint passes on the minimal fixture and counts both file kinds"
else
  fail "the lint failed on a clean fixture (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 2: a broken node module fails the lint ==="
printf 'export const broken = ;\n' > "$FIX/lib/broken.mjs"
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'node --check failed: lib/broken.mjs' <<< "$LINT_OUT"; then
  pass "a syntax error in lib/*.mjs fails the lint and names the module"
else
  fail "the lint accepted a broken node module (rc=$LINT_RC): $LINT_OUT"
fi
rm -f "$FIX/lib/broken.mjs"
lint
[ "$LINT_RC" -eq 0 ] && pass "removing the broken module makes the lint green again" || fail "the lint stayed red after the module was removed: $LINT_OUT"

echo "=== Test 3: a broken shell script fails the lint ==="
printf 'if then\n' > "$FIX/lib/broken.sh"
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'bash -n failed: lib/broken.sh' <<< "$LINT_OUT"; then
  pass "a syntax error in a shell script fails the lint and names the file"
else
  fail "the lint accepted a broken shell script (rc=$LINT_RC): $LINT_OUT"
fi
rm -f "$FIX/lib/broken.sh"

echo "=== Test 4: a suite with no CI leg fails the lint ==="
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$FIX/tests/test-orphan.sh"
chmod +x "$FIX/tests/test-orphan.sh"
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'orphan' <<< "$LINT_OUT"; then
  pass "a suite missing from the CI matrix fails the lint and is named"
else
  fail "the lint accepted a suite with no CI leg (rc=$LINT_RC): $LINT_OUT"
fi
rm -f "$FIX/tests/test-orphan.sh"

echo "=== Test 5: the argument parser rejects what it does not understand ==="
LINT_RC=0
LINT_OUT=$("$KP_ROOT/tests/lint.sh" --root 2>&1) || LINT_RC=$?
if [ "$LINT_RC" -ne 0 ] && grep -qF -- '--root needs a directory' <<< "$LINT_OUT"; then
  pass "a --root with no directory is rejected"
else
  fail "--root with no directory was accepted (rc=$LINT_RC): $LINT_OUT"
fi
LINT_RC=0
LINT_OUT=$("$KP_ROOT/tests/lint.sh" --nosuch 2>&1) || LINT_RC=$?
if [ "$LINT_RC" -ne 0 ] && grep -qF 'unknown argument: --nosuch' <<< "$LINT_OUT"; then
  pass "an unknown argument is rejected with a usage line"
else
  fail "an unknown argument was accepted (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 6: a token documented in the README but missing from docs/cli.md fails the lint ==="
mkdir -p "$FIX/docs"
cat > "$FIX/README.md" << 'F'
# Fixture

Run `kingpin fixture --fixture-flag` and set `KINGPIN_FIXTURE_VAR`.
F
cat > "$FIX/docs/cli.md" << 'F'
# Reference
F
lint
if [ "$LINT_RC" -ne 0 ] \
  && grep -qF -- '--fixture-flag (README.md)' <<< "$LINT_OUT" \
  && grep -qF 'KINGPIN_FIXTURE_VAR (README.md)' <<< "$LINT_OUT" \
  && grep -qF 'docs/cli.md' <<< "$LINT_OUT"; then
  pass "a documented token missing from the reference fails the lint and is named with its file"
else
  fail "the lint accepted a documented token missing from docs/cli.md (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 7: documenting that token in docs/cli.md makes the lint green ==="
cat >> "$FIX/docs/cli.md" << 'F'

`--fixture-flag` and `KINGPIN_FIXTURE_VAR`.
F
lint
if [ "$LINT_RC" -eq 0 ] && grep -q '3 shell files' <<< "$LINT_OUT"; then
  pass "the docs pass goes green once docs/cli.md documents the token"
else
  fail "the lint stayed red after docs/cli.md documented the token (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 8: a token repeated on a page is reported once ==="
cat > "$FIX/README.md" << 'F'
# Fixture

Run `kingpin fixture --fixture-flag`, set `KINGPIN_FIXTURE_VAR`, and pass `--fixture-flag`
again to show it twice.
F
printf '# Reference\n' > "$FIX/docs/cli.md"
lint
count=$(grep -cF -- '--fixture-flag (README.md)' <<< "$LINT_OUT" || true)
if [ "$LINT_RC" -ne 0 ] && [ "$count" -eq 1 ]; then
  pass "a token repeated on a page is listed once"
else
  fail "the check listed a repeated omission $count times (rc=$LINT_RC): $LINT_OUT"
fi

# Tests 6 to 8 leave a token missing from the reference on purpose; reset the two minimal
# pages so the cases below start from a fixture that passes.
printf '# Fixture\n' > "$FIX/README.md"
printf '# Reference\n' > "$FIX/docs/cli.md"

echo "=== Test 9: a suite with no row in docs/testing.md fails the lint ==="
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$FIX/tests/test-extra.sh"
chmod +x "$FIX/tests/test-extra.sh"
cat > "$FIX/.github/workflows/ci.yml" << 'F'
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        suite: [demo, extra]
F
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'test-extra.sh' <<< "$LINT_OUT" && grep -qF 'has no row' <<< "$LINT_OUT"; then
  pass "a suite missing from docs/testing.md fails the lint and is named"
else
  fail "the lint accepted a suite with no docs/testing.md row (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 10: adding the row makes the lint green ==="
# shellcheck disable=SC2016 # the backticks are a markdown code-span pattern, not a command
printf '| `test-extra.sh` | the extra suite |\n' >> "$FIX/docs/testing.md"
lint
if [ "$LINT_RC" -eq 0 ] && grep -q 'files clean' <<< "$LINT_OUT"; then
  pass "the suite-table check goes green once the suite has a row"
else
  fail "the lint stayed red after the suite got a row (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 11: a row naming a suite that does not exist fails the lint ==="
cp "$FIX/docs/testing.md" "$T/testing.md.saved"
# shellcheck disable=SC2016 # the backticks are a markdown code-span pattern, not a command
printf '| `test-ghost.sh` | a suite that is gone |\n' >> "$FIX/docs/testing.md"
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'test-ghost.sh' <<< "$LINT_OUT" && grep -qF 'do not exist' <<< "$LINT_OUT"; then
  pass "a row naming a deleted suite fails the lint and is named"
else
  fail "the lint accepted a row naming a missing suite (rc=$LINT_RC): $LINT_OUT"
fi
cp "$T/testing.md.saved" "$FIX/docs/testing.md"

echo "=== Test 12: a source file cited by line fails the lint with page and line ==="
cat > "$FIX/docs/page.md" << 'F'
# Page

See `bin/kingpin-fixture:42` for the detail.
F
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'docs/page.md:3' <<< "$LINT_OUT" && grep -qF 'bin/kingpin-fixture:42' <<< "$LINT_OUT"; then
  pass "a path:line citation fails the lint and names the page and line"
else
  fail "the lint accepted a path:line citation (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 13: a range, a comma list and the worker and orchestrator pages are caught ==="
mkdir -p "$FIX/worker" "$FIX/orchestrator"
cat > "$FIX/docs/page.md" << 'F'
# Page

See `worker/hooks.json:9-19` and `lib/fixture.mjs:109,153` for the wiring.
F
cat > "$FIX/worker/preamble.md" << 'F'
# Worker

Read `worker/preamble.md:8` before you start.
F
cat > "$FIX/orchestrator/contract.md" << 'F'
# Contract

Follow `bin/kingpin-fixture:12`.
F
lint
if [ "$LINT_RC" -ne 0 ] \
  && grep -qF 'docs/page.md:3' <<< "$LINT_OUT" \
  && grep -qF 'worker/preamble.md:3' <<< "$LINT_OUT" \
  && grep -qF 'orchestrator/contract.md:3' <<< "$LINT_OUT" \
  && grep -qF 'worker/hooks.json:9' <<< "$LINT_OUT" \
  && grep -qF 'lib/fixture.mjs:109' <<< "$LINT_OUT"; then
  pass "a range, a comma list and the worker and orchestrator pages are each named with their line"
else
  fail "the citation check missed a page or a line (rc=$LINT_RC): $LINT_OUT"
fi

echo "=== Test 14: a bare path with no line number passes ==="
rm -f "$FIX/worker/preamble.md" "$FIX/orchestrator/contract.md"
cat > "$FIX/docs/page.md" << 'F'
# Page

See `bin/kingpin-fixture` and `lib/fixture.sh`.
F
lint
if [ "$LINT_RC" -eq 0 ] && grep -q 'files clean' <<< "$LINT_OUT"; then
  pass "a page that cites a file by name passes the citation check"
else
  fail "the lint rejected a bare path citation (rc=$LINT_RC): $LINT_OUT"
fi
rm -f "$FIX/docs/page.md"
rmdir "$FIX/worker" "$FIX/orchestrator"

echo "=== Test 15: a line number after the closing backtick fails the lint with page and line ==="
cat > "$FIX/docs/page.md" << 'F'
# Page

See `bin/kingpin-fixture`:42 for the detail.
F
lint
if [ "$LINT_RC" -ne 0 ] && grep -qF 'docs/page.md:3' <<< "$LINT_OUT" && grep -qF 'bin/kingpin-fixture`:42' <<< "$LINT_OUT"; then
  pass "a citation with the colon outside the code span fails the lint and names the page and line"
else
  fail "the lint accepted a path:line citation with the colon outside the code span (rc=$LINT_RC): $LINT_OUT"
fi
rm -f "$FIX/docs/page.md"

kp_test_finish LINT
