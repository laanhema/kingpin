#!/usr/bin/env bash
# A page that says a source file's line number promises something the file no longer holds the
# moment someone edits above that line, and every list of them goes stale (issue #178). This
# check fails on a backticked `bin/`, `lib/`, `tests/` or `worker/` path followed by `:<digits>`
# in the pages it reads (`README.md`, `AGENTS.md`, `docs/*.md`, `orchestrator/contract.md` and
# `worker/*.md`), whether the digits sit inside the code span or just after it. A code comment
# cites the same way and drifts the same way (issue #207), so the check also fails on a bare or
# backticked path followed by `:<digits>` inside a whole-comment line of `bin/*`, `lib/*.sh`
# and `lib/*.mjs`. Only whole-comment lines are read: a `#` or `//` after code would
# need quote-aware parsing to keep lines like `grep -q "^# marker"` out, and a line that
# opens with `/*` but carries code after a mid-line `*/` is a code line, not a comment
# line, so its trailing comment goes unread too, and the repo does not cite from trailing
# comments today. The remedy everywhere is to cite the file, the function
# or the command by name, without a line number.
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

# The code files whose comments the check reads: everything under `bin/`, every
# `lib/*.sh` helper and every `lib/*.mjs` module. A file a glob skips (none
# today) is simply not scanned.
code_files=()
for f in bin/* lib/*.sh lib/*.mjs; do
  [ -f "$f" ] || continue
  code_files+=("$f")
done

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

# The comment scan reads whole-comment lines only: in a `*.sh` file a line whose first
# non-blank character is `#`, and in a `*.mjs` file a line that is a comment from end to
# end, a `//` line or a block comment that accounts for the whole line. In a block comment
# that opens or continues on the line, no `*/` may sit between the line's start and the
# citation, and then either the block stays open (no `*/` on the line at all) or the
# closer that follows the citation ends the line: code after a mid-line `*/` makes the
# line a code line, whose comments are trailing. A run of text that holds no `*/` is what
# `( [^*] | \*[^/] )*` matches, and the after-citation run of the open case is its
# stronger `( [^*/] | \*[^/] | /[^*] )*` below, so a citation reached through a close is
# not read. The backticked forms are caught by the same pattern, and the closing backtick
# is optional before the colon there, as in the page scan above: the digits drift in both
# `path:3` and `path`:3`.
code_hits=()
if [ ${#code_files[@]} -gt 0 ]; then
  cite_re='(bin|lib|tests|worker)/[A-Za-z0-9._/-]+`?:[0-9]+'
  notcloser_re='([^*]|\*[^/])*'
  open_re='([^*/]|\*[^/]|/[^*])*'
  for f in "${code_files[@]}"; do
    case $f in
      *.mjs) file_re='^[[:space:]]*//.*'"$cite_re"'|^[[:space:]]*(/\*|\*)'"$notcloser_re$cite_re"'('"$open_re"'$|'"$notcloser_re"'\*/[[:space:]]*$)' ;;
      *)     file_re='^[[:space:]]*#.*'"$cite_re" ;;
    esac
    found=$(grep -HnE "$file_re" "$f" || true)
    [ -n "$found" ] || continue
    while IFS= read -r hit; do
      code_hits+=("$hit")
    done <<< "$found"
  done
fi

# Both lists print in one run: an operator with citations in a page and a comment sees
# every hit on the first pass, instead of fixing a list and finding a second one waiting.
rc=0
if [ ${#hits[@]} -gt 0 ]; then
  echo "lint: these pages cite a source file by line, which drifts when the file changes:" >&2
  printf '  %s\n' "${hits[@]}" >&2
  echo "lint: cite the file or the function by name, without a line number" >&2
  rc=1
fi

if [ ${#code_hits[@]} -gt 0 ]; then
  echo "lint: these code comments cite a source file by line, which drifts when the file changes:" >&2
  printf '  %s\n' "${code_hits[@]}" >&2
  echo "lint: cite the function or the command by name, without a line number" >&2
  rc=1
fi

if [ "$rc" -ne 0 ]; then
  exit 1
fi

echo "lint: ${#pages[@]} pages and ${#code_files[@]} code files carry no path:line citation"
