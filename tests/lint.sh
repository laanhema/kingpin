#!/usr/bin/env bash
# Lint every shell script (bin/*, lib/*.sh, tests/*.sh): `bash -n` for syntax, then shellcheck (settings in .shellcheckrc).
set -euo pipefail

cd "$(dirname "$0")/.."

command -v shellcheck >/dev/null || {
  echo "lint: shellcheck not found (pip install shellcheck-py==0.11.0.1, or use your package manager)" >&2
  exit 127
}

files=(bin/* lib/*.sh tests/*.sh)
for f in "${files[@]}"; do
  bash -n "$f" || { echo "lint: bash -n failed: $f" >&2; exit 1; }
done
shellcheck "${files[@]}"

# Every tests/test-<suite>.sh must be a leg of the CI test matrix, and every leg a file:
# a suite missing from ci.yml would pass here and never run in CI.
ci_suites=$(sed -n 's/^ *suite: \[\(.*\)\]$/\1/p' .github/workflows/ci.yml | tr -d ' ' | tr ',' '\n' | LC_ALL=C sort)
disk_suites=$(printf '%s\n' tests/test-*.sh | sed 's|^tests/test-||; s|\.sh$||' | LC_ALL=C sort)
if [ "$ci_suites" != "$disk_suites" ]; then
  echo "lint: the 'suite:' matrix in .github/workflows/ci.yml and tests/test-*.sh differ (< ci.yml, > tests/):" >&2
  diff <(echo "$ci_suites") <(echo "$disk_suites") >&2 || true
  exit 1
fi

echo "lint: ${#files[@]} files clean"
