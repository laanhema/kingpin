#!/usr/bin/env bash
# Lint every shell script (bin/*, lib/*.sh, tests/*.sh) and every node module (lib/*.mjs):
# `bash -n` and `node --check` for syntax, then shellcheck (settings in .shellcheckrc).
# Every suite has to be a leg of the CI matrix and have a row in docs/testing.md, and no
# page the citation check reads may cite a source file by line number (tests/doc-citations.sh).
# The README/docs CLI-reference check runs in both directions: every parsed flag and
# KINGPIN_* variable has to be documented, and every flag a docs page shows has to reach
# docs/cli.md.
#
# Usage: tests/lint.sh [--root <dir>]
#   --root <dir>  lint that checkout instead of the one this script lives in, which is what
#                 tests/test-lint.sh uses to run the real lint against a throwaway fixture.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
while [ $# -gt 0 ]; do
  case $1 in
    --root)
      [ $# -ge 2 ] || { echo "lint: --root needs a directory" >&2; exit 2; }
      root=$2
      shift 2
      ;;
    *)
      echo "lint: unknown argument: $1" >&2
      echo "usage: tests/lint.sh [--root <dir>]" >&2
      exit 2
      ;;
  esac
done
root=$(cd "$root" && pwd) || { echo "lint: no such directory: $root" >&2; exit 2; }
cd "$root"

command -v shellcheck >/dev/null || {
  echo "lint: shellcheck not found (pip install shellcheck-py==0.11.0.1, or use your package manager)" >&2
  exit 127
}
# The node modules ship as source, so a syntax error in one reaches a user at runtime
# instead of at a build step (issue #81).
command -v node >/dev/null || {
  echo "lint: node not found (the lib/*.mjs modules are checked with node --check)" >&2
  exit 127
}

files=(bin/* lib/*.sh tests/*.sh)
for f in "${files[@]}"; do
  bash -n "$f" || { echo "lint: bash -n failed: $f" >&2; exit 1; }
done
shellcheck "${files[@]}"

# `node --check` parses a module without running it, and a .mjs is parsed as ESM.
node_files=(lib/*.mjs)
for f in "${node_files[@]}"; do
  node --check "$f" || { echo "lint: node --check failed: $f" >&2; exit 1; }
done

# Every tests/test-<suite>.sh must be a leg of the CI test matrix, and every leg a file:
# a suite missing from ci.yml would pass here and never run in CI.
ci_suites=$(sed -n 's/^ *suite: \[\(.*\)\]$/\1/p' .github/workflows/ci.yml | tr -d ' ' | tr ',' '\n' | LC_ALL=C sort)
disk_suites=$(printf '%s\n' tests/test-*.sh | sed 's|^tests/test-||; s|\.sh$||' | LC_ALL=C sort)
if [ "$ci_suites" != "$disk_suites" ]; then
  echo "lint: the 'suite:' matrix in .github/workflows/ci.yml and tests/test-*.sh differ (< ci.yml, > tests/):" >&2
  diff <(echo "$ci_suites") <(echo "$disk_suites") >&2 || true
  exit 1
fi

# Every suite needs a row in the docs/testing.md table, and every row needs a suite that
# exists: a suite with no row is one a reader cannot find, and a row naming a deleted suite
# sends the reader to a file that is gone (issue #178). Both sides are deduplicated, so a
# repeated row is harmless.
[ -f docs/testing.md ] || { echo "lint: docs/testing.md is missing; every suite needs a row in it" >&2; exit 1; }
# shellcheck disable=SC2016 # the backticks are markdown code-span literals, not a command
table_suites=$(sed -n 's/^| `test-\([a-z0-9-]*\)\.sh`.*/\1/p' docs/testing.md | LC_ALL=C sort -u)
disk_suites=$(printf '%s\n' tests/test-*.sh | sed 's|^tests/test-||; s|\.sh$||' | LC_ALL=C sort -u)
missing_rows=$(comm -13 <(printf '%s\n' "$table_suites") <(printf '%s\n' "$disk_suites"))
stale_rows=$(comm -23 <(printf '%s\n' "$table_suites") <(printf '%s\n' "$disk_suites"))
if [ -n "$missing_rows" ] || [ -n "$stale_rows" ]; then
  if [ -n "$missing_rows" ]; then
    echo "lint: docs/testing.md has no row for these suites:" >&2
    while IFS= read -r s; do
      echo "  test-$s.sh" >&2
    done <<< "$missing_rows"
  fi
  if [ -n "$stale_rows" ]; then
    echo "lint: docs/testing.md lists these suites that do not exist:" >&2
    while IFS= read -r s; do
      echo "  test-$s.sh" >&2
    done <<< "$stale_rows"
  fi
  echo "lint: give every suite a row in docs/testing.md, and drop the rows of deleted suites" >&2
  exit 1
fi

# The .agents/ artifact directories are in .gitignore, and an ignore rule never applies to a
# path that is already in the index: a force-add, or a branch cut before the rules landed,
# keeps the file tracked on every clone (issue #84). Catch it here, before it spreads.
if ! tracked=$(git ls-files -- .agents/plans .agents/reports .agents/reviews 2>&1); then
  # $tracked holds git's own stderr here, and it prints under the named line so the usage hint
  # is what the operator reads first, rather than a bare `fatal: not a git repository`.
  echo "lint: cannot list tracked paths (run this inside a git checkout)" >&2
  printf '%s\n' "$tracked" >&2
  exit 1
fi
if [ -n "$tracked" ]; then
  echo "lint: .agents/plans, .agents/reports and .agents/reviews must never be tracked; these are:" >&2
  while IFS= read -r p; do
    echo "  $p" >&2
  done <<< "$tracked"
  echo "lint: run 'git rm --cached <path>' (the file stays on disk and is ignored)" >&2
  exit 1
fi

if [ -x "$script_dir/readme-cli-reference.sh" ]; then
  "$script_dir/readme-cli-reference.sh" --root "$root"
fi

if [ -x "$script_dir/doc-citations.sh" ]; then
  "$script_dir/doc-citations.sh" --root "$root"
fi

echo "lint: ${#files[@]} shell files and ${#node_files[@]} node files clean"
