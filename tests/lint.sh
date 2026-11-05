#!/usr/bin/env bash
# Lint every shell script (bin/*, lib/*.sh, tests/*.sh) and every node module (lib/*.mjs):
# `bash -n` and `node --check` for syntax, then shellcheck (settings in .shellcheckrc).
# Every suite has to be a leg of the CI matrix and have a row in docs/testing.md, the fixed
# sleeps before assertions check and the unguarded `$?` check below have to stay quiet, and no
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

# A bare `sleep` whose next non-blank line asserts is a fixed pause where the suite needs a
# poll: the work it waits for has no bound, so a loaded runner reads the state before the
# thing happened and the suite fails for a reason unrelated to the code (issue #179). Six
# suites had each grown their own poll loop for it before the waits landed in tests/lib.sh.
# A trailing comment on the sleep line is still that pause, so the pattern allows one. A
# comment or an assignment between the pause and the assertion ends the inspection, because
# a suite that captures a value and then asserts is setup, not a race this check can read.
# The body of a here-document is data, not suite code, so its lines are skipped: a fixture
# may show the rejected shape without tripping the check (issue #179 review L1).
sleep_hits=()
for f in tests/test-*.sh; do
  [ -f "$f" ] || continue
  found=$(awk -v file="$f" '
    function open_heredoc(text,    i, rest, quote, close_at) {
      while ((i = index(text, "<<")) > 0) {
        rest = substr(text, i + 2)
        if (substr(rest, 1, 1) == "<") { text = substr(rest, 2); continue }
        tab_strip = 0
        if (substr(rest, 1, 1) == "-") { tab_strip = 1; rest = substr(rest, 2) }
        sub(/^[ \t]+/, "", rest)
        quote = substr(rest, 1, 1)
        if (quote == "\047" || quote == "\"") {
          rest = substr(rest, 2)
          close_at = index(rest, quote)
          if (close_at == 0) { text = rest; continue }
          heredoc = substr(rest, 1, close_at - 1)
        } else if (match(rest, /^[A-Za-z_][^ \t;&|<>()]*/)) {
          heredoc = substr(rest, 1, RLENGTH)
        } else {
          text = rest
          continue
        }
        return
      }
    }
    heredoc != "" {
      body = $0
      if (tab_strip) sub(/^\t+/, "", body)
      if (body == heredoc) heredoc = ""
      next
    }
    {
      if ($0 !~ /^[[:space:]]*#/) open_heredoc($0)
      if ($0 ~ /^[[:space:]]*sleep[[:space:]]+[0-9]+(\.[0-9]+)?[[:space:]]*(#.*)?$/) { sleep_line = NR; sleep_text = $0; next }
      if ($0 ~ /^[[:space:]]*$/) next
      if (sleep_line && ($0 ~ /pass "/ || $0 ~ /fail "/)) {
        printf "%s:%d: %s, then an assertion on line %d\n", file, sleep_line, sleep_text, NR
      }
      sleep_line = 0
    }
  ' "$f" || true)
  [ -n "$found" ] || continue
  while IFS= read -r hit; do
    sleep_hits+=("$hit")
  done <<< "$found"
done
if [ "${#sleep_hits[@]}" -gt 0 ]; then
  echo "lint: these suites pause and then assert once, which races the work they wait for:" >&2
  for hit in "${sleep_hits[@]}"; do
    echo "  $hit" >&2
  done
  echo "lint: wait with kp_wait_until <seconds> <cmd...> for a positive wait, or kp_holds_for <seconds> <cmd...> when nothing must happen, both in tests/lib.sh" >&2
  exit 1
fi

# A `NAME=$?` line that follows a command while errexit is on can never see a non-zero
# status: `set -e` aborts the suite at the command, so the assertion's fail branch is dead
# and the run dies without a FAIL line (issue #180). The fix is `kp_run <out-var> <rc-var>
# <cmd...>` in tests/lib.sh, which captures the status without tripping errexit. The scan
# tracks `set +e` / `set -e` in file order, because a block that turns errexit off is the
# one place the bare form is valid, and it skips here-document bodies, which are data. A
# `set` counts only in command position, so a message that mentions `set -e` does not
# change the state.
rc_hits=()
rc_pattern='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\?[[:space:]]*(#.*)?$'
heredoc_pattern="<<-?[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*)"
for f in tests/test-*.sh; do
  [ -f "$f" ] || continue
  errexit=1
  heredoc=
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ -n "$heredoc" ]; then
      body=$line
      while [ "${body:0:1}" = $'\t' ]; do body=${body#?}; done
      [ "$body" = "$heredoc" ] && heredoc=
      continue
    fi
    if [[ $line =~ $heredoc_pattern ]]; then
      heredoc=${BASH_REMATCH[1]}
    fi
    if [[ $line =~ ^[[:space:]]*# ]]; then
      continue
    fi
    rest=$line
    while [[ $rest =~ (^[[:space:]]*|[;\&\|][[:space:]]*)set[[:space:]]+([+-])[A-Za-z]*e[A-Za-z]* ]]; do
      case ${BASH_REMATCH[2]} in
        +) errexit=0 ;;
        -) errexit=1 ;;
      esac
      rest=${rest#*"${BASH_REMATCH[0]}"}
    done
    if [ "$errexit" -eq 1 ] && [[ $line =~ $rc_pattern ]]; then
      rc_hits+=("$f:$line_no: $line")
    fi
  done < "$f"
done
if [ "${#rc_hits[@]}" -gt 0 ]; then
  echo "lint: these suites read \$? after a command that errexit would already have aborted, so their fail branch never runs:" >&2
  for hit in "${rc_hits[@]}"; do
    echo "  $hit" >&2
  done
  echo "lint: capture with kp_run <out-var> <rc-var> <cmd...> from tests/lib.sh, which records the status without tripping set -e" >&2
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
