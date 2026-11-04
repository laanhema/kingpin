#!/usr/bin/env bash
# Checks both directions of the CLI reference:
#   scripts -> docs  every flag the commands parse and every KINGPIN_* variable the scripts
#                    read appears in README.md or docs/*.md (issue #82)
#   docs -> reference  every flag or KINGPIN_* variable the README or a docs page shows
#                    appears in docs/cli.md, the per-command reference
#
# `tests/lint.sh` calls it; run it alone to reproduce a failure without the syntax checks and
# the linter. `--root <dir>` runs it against another checkout, which is what
# tests/test-lint.sh uses.
#
# Flags come from the option labels in bin/kingpin*: a `case` arm (`--flag|-f)`) and a
# `= "--flag"` comparison. The label is cut at the first `)`, so explanatory text on the same
# line (`--issue needs a number`) is not read as another flag. lib/report-diffs.mjs parses its
# flags (`--repo`, `--base`, `--prose-only`) beside git argv literals such as `--verify`, which
# a text scan cannot tell apart; those three are documented but not checked here.
#
# The docs -> reference pass reads inline code spans, so a host tool's own flag is exempt
# through `host_tokens` below rather than being forced into the Kingpin reference.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
while [ $# -gt 0 ]; do
  case $1 in
    --root)
      [ $# -ge 2 ] || { echo "readme-cli-reference: --root needs a directory" >&2; exit 2; }
      root=$2
      shift 2
      ;;
    *)
      echo "readme-cli-reference: unknown argument: $1" >&2
      echo "usage: tests/readme-cli-reference.sh [--root <dir>]" >&2
      exit 2
      ;;
  esac
done
root=$(cd "$root" && pwd) || { echo "readme-cli-reference: no such directory: $root" >&2; exit 2; }
cd "$root"

flag_labels=$(
  { grep -hE '^[[:space:]]*(-[A-Za-z]|--[a-z])[A-Za-z0-9|=*_-]*\)' bin/kingpin* || true
    grep -hE '=[[:space:]]*"--?[A-Za-z][A-Za-z0-9=-]*"' bin/kingpin* || true
  } | sed 's/).*//'
)
flags=$(printf '%s\n' "$flag_labels" | grep -oE -- '-{1,2}[A-Za-z][A-Za-z0-9-]*' | LC_ALL=C sort -u) || true
vars=$(grep -rhoE 'KINGPIN_[A-Z0-9_]+' bin lib | LC_ALL=C sort -u) || true

# The reference is split across the README and docs/: the summary table stays in README.md and
# the per-command detail, environment table and helper notes live in docs/cli.md.
reference=(README.md docs/*.md)

missing=()
for tok in $flags $vars; do
  # A whole-word match: KINGPIN_HOME must not be satisfied by KINGPIN_HOME_DIR.
  grep -qE -- "(^|[^A-Za-z0-9_-])$tok([^A-Za-z0-9_-]|$)" "${reference[@]}" || missing+=("$tok")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "lint: README.md and docs/*.md do not document these flags and variables the scripts parse:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "lint: document each in README.md or docs/ (CLI reference or Environment variables), or remove it" >&2
  exit 1
fi

flag_count=$(printf '%s\n' "$flags" | grep -c . || true)
var_count=$(printf '%s\n' "$vars" | grep -c . || true)
echo "lint: CLI reference covers $flag_count flags and $var_count KINGPIN_* variables"

# The other direction: a flag or KINGPIN_* variable that README.md or a docs page shows has to
# reach docs/cli.md, the per-command reference. Host tools are exempt: their flags belong to
# git, gh or the harness CLI, not to Kingpin's surface, so forcing them into the reference
# would document someone else's interface.
host_tokens=(
  --auto      # Pi's CLI flag, shown in docs/harnesses.md's measured commands
  --approve   # Pi's CLI flag, same
  --body-file # gh's flag, in the prose-gate instructions for issue and PR bodies
  --cached    # git rm --cached, the .agents ignore remedy
  --ff-only   # git pull --ff-only, the sync fast-forward
)

readme_files=()
for f in README.md docs/*.md; do
  [ -f "$f" ] || continue
  readme_files+=("$f")
done

undocumented=()
if [ ${#readme_files[@]} -gt 0 ]; then
  if [ ! -f docs/cli.md ]; then
    echo "lint: README.md and docs/*.md document flags and variables, but docs/cli.md, the per-command reference, is missing" >&2
    exit 1
  fi
  for f in "${readme_files[@]}"; do
    # Inline code spans only, so a bare `--` in prose is not read as a flag. Every extraction
    # tolerates no match: under `pipefail` a `grep` that finds nothing would abort the script.
    tokens=$(
      # shellcheck disable=SC2016 # the backticks are a markdown code-span pattern, not a command
      { grep -oE '`[^`]*`' "$f" || true; } | { grep -oE -- '--[a-z][a-z0-9-]*' || true; }
      grep -oE 'KINGPIN_[A-Z0-9_]+' "$f" || true
    )
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case " ${host_tokens[*]} " in
        *" $tok "*) continue ;;
      esac
      grep -qE -- "(^|[^A-Za-z0-9_-])$tok([^A-Za-z0-9_-]|$)" docs/cli.md || undocumented+=("$tok ($f)")
    done <<< "$tokens"
  done
fi

if [ ${#undocumented[@]} -gt 0 ]; then
  echo "lint: README.md and docs/*.md document these flags and variables that docs/cli.md does not:" >&2
  printf '  %s\n' "${undocumented[@]}" >&2
  echo "lint: document each in docs/cli.md, or add a host tool's flag to host_tokens in tests/readme-cli-reference.sh" >&2
  exit 1
fi
