#!/usr/bin/env bash
# Lint every shell script (bin/*, lib/*.sh, tests/*.sh) and every node module (lib/*.mjs):
# `bash -n` and `node --check` for syntax, then shellcheck (settings in .shellcheckrc).
# Every suite has to be a leg of the CI matrix and have a row in docs/testing.md, the ci-ok
# merge-gate check below has to find one aggregate job that needs every other job and carries
# no display `name:`, the fixed sleeps before assertions check and the unguarded `$?` check
# below have to stay quiet, and neither a page the citation check reads nor a whole-comment
# line in bin/ or lib may cite a source file by line number (tests/doc-citations.sh).
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

# The merge gate is one aggregate job: `ci-ok` needs every other job in this workflow and
# runs with `if: always()`, so a failed, cancelled or skipped leg turns the required check
# red instead of leaving it pending (issue #220). GitHub needs the job to exist before the
# branch protection setting can require it, and a job added here without joining `needs`
# would be a leg the gate silently ignores. A display `name:` on the job would replace the
# `ci-ok` context the protection setting requires, so it is refused too. `needs` may be an
# inline list or a block sequence, and a trailing comment hides neither a job key nor an
# entry.
ci_ok_block=$(awk '
  /^  [A-Za-z0-9_-]+:/ {
    injob = (index($1, "ci-ok:") == 1)
    if (!injob) { next }
  }
  injob { print }
' .github/workflows/ci.yml)
ci_ok_problems=()
if [ -z "$ci_ok_block" ]; then
  ci_ok_problems+=("there is no ci-ok job in .github/workflows/ci.yml")
else
  ci_ok_needs=$(printf '%s\n' "$ci_ok_block" | awk '
    /^    needs:[[:space:]]*(#.*)?$/ { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      entry = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", entry)
      sub(/[[:space:]]*#.*$/, "", entry)
      if (entry != "") print entry
      next
    }
    inlist { inlist = 0 }
    /^    needs:/ {
      entry = $0
      sub(/^    needs:[[:space:]]*/, "", entry)
      sub(/[[:space:]]*#.*$/, "", entry)
      if (entry != "") print entry
    }
  ')
  ci_ok_tokens=$(printf '%s\n' "$ci_ok_needs" | tr -d '[] ' | tr ',' '\n')
  ci_ok_jobs=$(awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { sub(/:$/, "", $1); print $1 }
  ' .github/workflows/ci.yml)
  while IFS= read -r ci_ok_job; do
    [ -n "$ci_ok_job" ] || continue
    [ "$ci_ok_job" = ci-ok ] && continue
    printf '%s\n' "$ci_ok_tokens" | grep -qx "$ci_ok_job" \
      || ci_ok_problems+=("ci-ok does not need $ci_ok_job, so a failure in that job cannot turn the gate red")
  done <<< "$ci_ok_jobs"
  if printf '%s\n' "$ci_ok_block" | grep -qE '^    name:'; then
    ci_ok_problems+=("ci-ok has a 'name:' key, so GitHub would report that display name instead of the required context")
  fi
  printf '%s\n' "$ci_ok_block" | grep -qE '^    if:[[:space:]]*(\$\{\{[[:space:]]*)?always\(\)' \
    || ci_ok_problems+=("ci-ok has no 'if: always()', so a failed leg would leave it skipped")
fi
if [ "${#ci_ok_problems[@]}" -gt 0 ]; then
  echo "lint: the ci-ok merge gate in .github/workflows/ci.yml is not the aggregate this repository requires:" >&2
  printf '  %s\n' "${ci_ok_problems[@]}" >&2
  echo "lint: ci-ok must need every other job, run with 'if: always()', and carry no display name, so one required check covers the whole run" >&2
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

# A `NAME=$?` assignment that follows a command while errexit is on can never see a
# non-zero status: `set -e` aborts the suite at the command, so the assertion's fail
# branch is dead and the run dies without a FAIL line (issue #180). The fix is
# `kp_run <out-var> <rc-var> <cmd...>` in tests/lib.sh, which captures the status without
# tripping errexit. The scan reads every `tests/*.sh`, not only the suites, so a helper
# shared by suites is held to the same rule (review of #180 L1). It tracks `set +e` /
# `set -e` in file order, because a block that turns errexit off is one place the bare
# form is valid, and it checks the state at the assignment rather than at end of line, so
# the compact `set +e; out=$(cmd); rc=$?; set -e` form stays green. A `set` counts only in
# command position, so a message that mentions `set -e` does not change the state. The
# assignment may end the line or carry a trailing `;` or redirect (review of #180 M1).
# `local NAME=$?` is the cleanup-trap idiom and is not matched, and neither is a `NAME=$?`
# guarded by `||`, `&&` or an `else`/`then` branch of a condition. Here-document bodies
# are data, so they are skipped: the opener is read outside quotes, a here-string (`<<<`)
# is not one, and a comment line is not scanned for one (review of #180 M2).
rc_hits=()
for f in tests/*.sh; do
  [ -f "$f" ] || continue
  found=$(awk -v file="$f" '
    function heredoc_open(line,    i, n, c, j, rest, quote, delim, strip) {
      i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\047") {
          j = index(substr(line, i + 1), "\047")
          if (j == 0) return 0
          i = i + j + 1
          continue
        }
        if (c == "\"") {
          i++
          while (i <= n) {
            c = substr(line, i, 1)
            if (c == "\\") { i += 2; continue }
            if (c == "\"") { i++; break }
            i++
          }
          continue
        }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) return 0
        if (c == "<" && substr(line, i + 1, 1) == "<") {
          if (substr(line, i + 2, 1) == "<") { i += 3; continue }
          rest = substr(line, i + 2)
          strip = 0
          if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
          sub(/^[ \t]+/, "", rest)
          quote = substr(rest, 1, 1)
          if (quote == "\047" || quote == "\"") {
            rest = substr(rest, 2)
            j = index(rest, quote)
            if (j == 0) return 0
            delim = substr(rest, 1, j - 1)
          } else if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
            delim = substr(rest, 1, RLENGTH)
          } else {
            i += 2
            continue
          }
          if (delim == "") return 0
          hd_delim = delim
          hd_strip = strip
          return 1
        }
        i++
      }
      return 0
    }
    function word_before(line, at,    k, j) {
      k = at - 1
      while (k > 0 && substr(line, k, 1) ~ /[ \t]/) k--
      if (k == 0) return ""
      if (substr(line, k, 1) !~ /[A-Za-z0-9_]/) return substr(line, k, 1)
      j = k
      while (j > 0 && substr(line, j, 1) ~ /[A-Za-z0-9_]/) j--
      return substr(line, j + 1, k - j)
    }
    function guarded(line, at,    w) {
      w = word_before(line, at)
      if (w == "|" || w == "&") return 1
      return w ~ /^(local|declare|typeset|export|readonly|else|then|do|elif)$/
    }
    function trailing_ok(line, after,    tail) {
      tail = substr(line, after)
      if (tail ~ /^[ \t]*$/ || tail ~ /^[ \t]*#/) return 1
      if (tail ~ /^[ \t]*;/) return 1
      if (tail ~ /^[ \t]*[0-9]*[<>]/) return 1
      if (tail ~ /^[ \t]*[|&)}]/) return 1
      return 0
    }
    function command_position(line, at,    k) {
      k = at - 1
      while (k > 0 && substr(line, k, 1) ~ /[ \t]/) k--
      if (k == 0) return 1
      return substr(line, k, 1) ~ /[;&|({!]/
    }
    function in_code(line, at,    i, n, c, j, k) {
      i = 1; n = length(line)
      while (i < at) {
        c = substr(line, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\047") {
          j = index(substr(line, i + 1), "\047")
          if (j == 0 || i + j >= at) return 0
          i = i + j + 1
          continue
        }
        if (c == "\"") {
          k = i + 1
          while (k <= n) {
            c = substr(line, k, 1)
            if (c == "\\") { k += 2; continue }
            if (c == "\"") break
            k++
          }
          if (k >= at) return 0
          i = k + 1
          continue
        }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) return 0
        i++
      }
      return 1
    }
    BEGIN { errexit = 1; heredoc = ""; hd_delim = ""; hd_strip = 0 }
    {
      if (heredoc != "") {
        body = $0
        if (hd_strip) sub(/^\t+/, "", body)
        if (body == hd_delim) { heredoc = ""; hd_delim = "" }
        next
      }
      if ($0 ~ /^[ \t]*#/) next
      hd_delim = ""; hd_strip = 0
      if (heredoc_open($0)) heredoc = hd_delim
      line = $0
      n = length(line)
      pos = 1
      while (pos <= n) {
        sp = 0
        scan = pos
        while (scan <= n) {
          rest = substr(line, scan)
          if (!match(rest, /set[ \t]+[+-][A-Za-z]*e[A-Za-z]*/)) break
          sp = scan + RSTART - 1
          if (command_position(line, sp) && in_code(line, sp)) break
          scan = sp + 3
          sp = 0
        }
        rp = 0
        scan = pos
        while (scan <= n) {
          rest = substr(line, scan)
          if (!match(rest, /[A-Za-z_][A-Za-z0-9_]*=\$\?/)) break
          rp = scan + RSTART - 1
          rlen = RLENGTH
          if (rp > 1 && substr(line, rp - 1, 1) ~ /[A-Za-z0-9_]/) { scan = rp + rlen; rp = 0; continue }
          if (!in_code(line, rp)) { scan = rp + rlen; rp = 0; continue }
          break
        }
        if (sp == 0 && rp == 0) break
        if (rp == 0 || (sp > 0 && sp < rp)) {
          rest = substr(line, sp)
          match(rest, /^set[ \t]+[+-]/)
          if (substr(rest, RLENGTH, 1) == "+") errexit = 0
          else errexit = 1
          pos = sp + 3
          continue
        }
        if (errexit == 1 && !guarded(line, rp) && trailing_ok(line, rp + rlen)) {
          printf "%s:%d: %s\n", file, NR, line
        }
        pos = rp + rlen
      }
    }
  ' "$f" || true)
  [ -n "$found" ] || continue
  while IFS= read -r hit; do
    rc_hits+=("$hit")
  done <<< "$found"
done
if [ "${#rc_hits[@]}" -gt 0 ]; then
  echo "lint: these test scripts read \$? after a command that errexit would already have aborted, so their fail branch never runs:" >&2
  for hit in "${rc_hits[@]}"; do
    echo "  $hit" >&2
  done
  echo "lint: capture with kp_run <out-var> <rc-var> <cmd...> from tests/lib.sh, which records the status without tripping set -e" >&2
  exit 1
fi

# The whole .agents/ directory is in .gitignore, and an ignore rule never applies to a path
# that is already in the index: a force-add, or a branch cut before the rule landed, keeps
# the file tracked on every clone (issue #84). Catch it here, before it spreads.
if ! tracked=$(git ls-files -- .agents 2>&1); then
  # $tracked holds git's own stderr here, and it prints under the named line so the usage hint
  # is what the operator reads first, rather than a bare `fatal: not a git repository`.
  echo "lint: cannot list tracked paths (run this inside a git checkout)" >&2
  printf '%s\n' "$tracked" >&2
  exit 1
fi
if [ -n "$tracked" ]; then
  echo "lint: nothing under .agents/ may be tracked; these are:" >&2
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
