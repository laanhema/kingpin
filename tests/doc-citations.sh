#!/usr/bin/env bash
# A page that says a source file's line number promises something the file no longer holds the
# moment someone edits above that line, and every list of them goes stale (issue #178). This
# check fails on a backticked `bin/`, `lib/`, `tests/` or `worker/` path followed by `:<digits>`
# in the pages it reads (`README.md`, `AGENTS.md`, `docs/*.md`, `orchestrator/contract.md` and
# `worker/*.md`), whether the digits sit inside the code span or just after it, and the remedy
# is to cite the file or the function by name.
#
# `tests/lint.sh` calls it; run it alone to reproduce a failure without the syntax checks and
# the linter. `--root <dir>` runs it against another checkout, which is what tests/test-lint.sh
# uses.
#
# No fence is masked: a citation inside a fenced block still points at a line that drifts, so
# the pattern is the whole rule.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
while [ $# -gt 0 ]; do
  case $1 in
    --root)
      [ $# -ge 2 ] || { echo "doc-citations: --root needs a directory" >&2; exit 2; }
      root=$2
      shift 2
      ;;
    *)
      echo "doc-citations: unknown argument: $1" >&2
      echo "usage: tests/doc-citations.sh [--root <dir>]" >&2
      exit 2
      ;;
  esac
done
root=$(cd "$root" && pwd) || { echo "doc-citations: no such directory: $root" >&2; exit 2; }
cd "$root"

pages=()
for f in README.md AGENTS.md docs/*.md orchestrator/contract.md worker/*.md; do
  [ -f "$f" ] || continue
  pages+=("$f")
done
[ ${#pages[@]} -gt 0 ] || { echo "doc-citations: no documentation pages found"; exit 0; }

hits=()
for f in "${pages[@]}"; do
  # A page with no citation is the normal case, so a grep that finds nothing must not abort the
  # script under `pipefail`.
  # The closing backtick is optional, so `` `bin/foo.sh`:12 `` is caught as well as
  # `` `bin/foo.sh:12` ``: the line number drifts in both forms.
  # shellcheck disable=SC2016 # the backticks are a markdown code-span pattern, not a command
  found=$(grep -HnoE '`(bin|lib|tests|worker)/[^`]*`?:[0-9]+' "$f" || true)
  [ -n "$found" ] || continue
  while IFS= read -r hit; do
    hits+=("$hit")
  done <<< "$found"
done

if [ ${#hits[@]} -gt 0 ]; then
  echo "lint: these pages cite a source file by line, which drifts when the file changes:" >&2
  printf '  %s\n' "${hits[@]}" >&2
  echo "lint: cite the file or the function by name, without a line number" >&2
  exit 1
fi

echo "lint: ${#pages[@]} pages carry no path:line citation"
