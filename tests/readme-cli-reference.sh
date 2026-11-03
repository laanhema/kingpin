#!/usr/bin/env bash
# Checks that the CLI reference in README.md and docs/*.md documents every flag the commands
# parse and every KINGPIN_* variable the scripts read (issue #82). A token documented in either
# place satisfies the check. `tests/lint.sh` calls it; run it alone to reproduce a failure without
# the syntax and shellcheck passes.
#
# Flags come from the option labels in bin/kingpin*: a `case` arm (`--flag|-f)`) and a
# `= "--flag"` comparison. The label is cut at the first `)`, so explanatory text on the same
# line (`--issue needs a number`) is not read as another flag. lib/report-diffs.mjs parses its
# flags (`--repo`, `--base`, `--prose-only`) beside git argv literals such as `--verify`, which
# a text scan cannot tell apart; those three are documented but not checked here.
set -euo pipefail

cd "$(dirname "$0")/.."

flag_labels=$(
  { grep -hE '^[[:space:]]*(-[A-Za-z]|--[a-z])[A-Za-z0-9|=*_-]*\)' bin/kingpin* || true
    grep -hE '=[[:space:]]*"--?[A-Za-z][A-Za-z0-9=-]*"' bin/kingpin* || true
  } | sed 's/).*//'
)
flags=$(printf '%s\n' "$flag_labels" | grep -oE -- '-{1,2}[A-Za-z][A-Za-z0-9-]*' | LC_ALL=C sort -u)
vars=$(grep -rhoE 'KINGPIN_[A-Z0-9_]+' bin lib | LC_ALL=C sort -u)

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

echo "lint: CLI reference covers $(printf '%s\n' "$flags" | wc -l | tr -d ' ') flags and $(printf '%s\n' "$vars" | wc -l | tr -d ' ') KINGPIN_* variables"
