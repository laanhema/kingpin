#!/usr/bin/env bash
# kingpin report: the prose check reads markdown, ignoring the regions that are not prose and
# keeping the line numbers of the ones that are.
set -euo pipefail

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

check() { "$KP_BIN/kingpin" report check "$@"; }

echo "=== kingpin report check: markdown prose ==="

printf '# Title\n\nA prose line with an em dash \342\200\224 in it.\n' > "$T/prose.md"
out=$(check --prose-only "$T/prose.md" 2>&1) && fail "check accepted an em dash in markdown prose" || pass "check rejects an em dash in markdown prose"
echo "$out" | grep -q 'prose.md:3: em dash' && pass "the markdown failure names the file and line" || fail "no file:line for the em dash: $out"
echo "$out" | grep -q 'A prose line with an em dash' && pass "the markdown failure quotes the offending line" || fail "offending line not echoed: $out"

# Every construct markdown renders as code or a comment: the same em dash inside each one is
# ignored, and the prose line after all of them still reports its own line (25).
cat > "$T/masked.md" <<'MD'
# Title

A prose line with no tell.

```sh
code — dash
```

~~~
tilde — dash
~~~

````markdown
```js
nested — dash
```
````

    indented — dash

Inline `code — dash` span and ``double — dash``.

<!-- comment — dash -->

A final prose line with an em dash — here.
MD
out=$(check --prose-only "$T/masked.md" 2>&1) && fail "check accepted prose masking, it should fail on the final line" || pass "check masks every markdown construct and still reads the prose"
echo "$out" | grep -q 'masked.md:25: em dash' && pass "the line after the masked regions keeps its line number" || fail "wrong line after masking: $out"
[ "$(echo "$out" | grep -c ': em dash ')" -eq 1 ] && pass "only the unmasked em dash is reported" || fail "expected one em dash hit, got: $out"

# A clean file with the same constructs passes.
sed '$d' "$T/masked.md" > "$T/masked-clean.md"
check --prose-only "$T/masked-clean.md" >/dev/null 2>&1 && pass "a markdown file whose tells all sit in masked regions passes" || fail "masked regions tripped the check"

# Prose inside a nested list item or a list-item continuation paragraph is still read: four spaces
# there continues the list, it does not open an indented code block, so the tell is not masked.
printf -- '- parent item\n    - nested item with an em dash \342\200\224 here\n' > "$T/nested.md"
out=$(check --prose-only "$T/nested.md" 2>&1) && fail "check accepted a tell in a nested list item" || pass "check reads a nested list item's prose"
echo "$out" | grep -q 'nested.md:2: em dash' && pass "the nested list tell keeps its line number" || fail "nested list line wrong: $out"

printf '1. step one\n\n    A continuation with an em dash \342\200\224 here.\n' > "$T/continuation.md"
out=$(check --prose-only "$T/continuation.md" 2>&1) && fail "check accepted a tell in a list-item continuation" || pass "check reads a list-item continuation's prose"
echo "$out" | grep -q 'continuation.md:3: em dash' && pass "the continuation tell keeps its line number" || fail "continuation line wrong: $out"

# The other direction still holds: a code block inside a list item is four columns past the item's
# content column, so its tell stays masked and it does not cry wolf.
printf -- '- item\n\n      a code — dash\n' > "$T/nested-code.md"
check --prose-only "$T/nested-code.md" >/dev/null 2>&1 && pass "an indented code block inside a list item stays masked" || fail "a list item's code block tripped the check"

# CRLF line endings must not shift the reported line.
printf 'line one\r\nline two\r\nA CRLF em dash \342\200\224 here.\r\n' > "$T/crlf.md"
out=$(check --prose-only "$T/crlf.md" 2>&1) && fail "check accepted an em dash in a CRLF file" || pass "check rejects an em dash in a CRLF file"
echo "$out" | grep -q 'crlf.md:3: em dash' && pass "a CRLF file reports the right line number" || fail "CRLF line number wrong: $out"

# `<!-- unslop:ignore -->` stays the single escape, on its own line only.
cat > "$T/escaped.md" <<'MD'
A line with an em dash — kept <!-- unslop:ignore -->
Another line with an em dash — caught
MD
out=$(check --prose-only "$T/escaped.md" 2>&1) && fail "the escape exempted the whole file" || pass "the escape works in markdown"
[ "$(echo "$out" | grep -c ': em dash ')" -eq 1 ] && pass "only the un-escaped markdown line is reported" || fail "expected one em dash hit, got: $out"
echo "$out" | grep -q 'escaped.md:2: em dash' && pass "the un-escaped markdown line is named with its line number" || fail "un-escaped line not reported: $out"

printf 'A line with an em dash \342\200\224 kept <!-- unslop:ignore -->\n' > "$T/escaped-only.md"
check --prose-only "$T/escaped-only.md" >/dev/null 2>&1 && pass "a fully escaped markdown file passes" || fail "the escape did not exempt its own line"

# `.markdown` is read as markdown too: the fenced dash is ignored.
printf '%s\n' '# Title' '' '```' 'a fence — dash' '```' > "$T/clean.markdown"
check --prose-only "$T/clean.markdown" >/dev/null 2>&1 && pass ".markdown is read as markdown" || fail ".markdown was not masked as markdown"

echo "=== kingpin report check: markdown rule list ==="

# One prose line per rule. Every id must appear, and the source must still hold exactly eight, so a
# later edit cannot drop or add a rule without this test noticing.
cat > "$T/rules.md" <<'MD'
An em dash — here.
This is a testament to the work.
This is not just a change.
We delve into it.
A seamless flow.
We do it in order to ship.
Let me know if it breaks.
I hope this helps.
MD
out=$(check --prose-only "$T/rules.md" 2>&1) && fail "check accepted a file carrying every tell" || pass "check rejects a file carrying every tell"
rule_ids=(
  'em dash'
  '"testament to"'
  '"it'"'"'s not just"'
  '"delve"'
  '"seamless"'
  '"in order to"'
  '"let me know"'
  '"I hope this helps"'
)
for id in "${rule_ids[@]}"; do
  echo "$out" | grep -qF -- "$id (" && pass "rule $id is reported" || fail "rule $id is missing from the output"
done
n=$(echo "$out" | grep -c '^FAILED: ' || true)
[ "$n" -eq 8 ] && pass "all eight rules fire once" || fail "expected 8 rule hits, got $n: $out"
n=$(grep -c '^  { id: ' "$KP_ROOT/lib/report-diffs.mjs")
[ "$n" -eq 8 ] && pass "PROSE_RULES still holds eight rules" || fail "PROSE_RULES holds $n rules, expected 8"

echo "=== kingpin report check: markdown without --prose-only ==="

printf '# Clean\n\nA short paragraph with no tell.\n' > "$T/clean.md"
out=$(check --prose-only "$T/clean.md" 2>&1) && pass "check --prose-only accepts a clean markdown file" || fail "check --prose-only rejected a clean markdown file: $out"
echo "$out" | grep -q 'has clean prose' && pass "the clean markdown OK line names the prose" || fail "unexpected OK line: $out"
out=$(check "$T/clean.md" 2>&1) && pass "a markdown file needs no diff section" || fail "check demanded a diff section from markdown: $out"
echo "$out" | grep -q 'has clean prose' && pass "the plain markdown check still reports clean prose" || fail "unexpected OK line: $out"
printf '# Sloppy\n\nWe delve into it.\n' > "$T/sloppy.md"
check "$T/sloppy.md" >/dev/null 2>&1 && fail "a plain markdown check accepted sloppy prose" || pass "a plain markdown check still rejects sloppy prose"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL MARKDOWN TESTS PASSED"
else
  echo "MARKDOWN TESTS FAILED"
  exit 1
fi
