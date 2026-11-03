#!/usr/bin/env bash
# kingpin report: generated dossier diffs are renderable, and check rejects blank-diff reports.
set -euo pipefail

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# Repo with one modified, one added (committed), one untracked and one renamed file on a feature branch.
git init -q -b main "$T/repo"
(
  cd "$T/repo"
  git config user.email t@example.com && git config user.name t
  printf 'one\ntwo\n' > a.txt
  printf 'keep\nme\nplease\nrenamed\n' > old-name.txt
  git add . && git commit -qm init
  git checkout -q -b feature
  printf 'one\nTWO\n</script><b>x</b>\n' > a.txt
  git mv old-name.txt new-name.txt
  printf 'added\n' > added.txt
  git add . && git commit -qm change
  printf 'untracked\n' > untracked.txt
)

echo "=== kingpin report diffs ==="
"$KP_BIN/kingpin" report diffs --repo "$T/repo" --base main > "$T/frag.html" && pass "diffs exits 0" || fail "diffs failed"
n=$(grep -c 'class="kp-diff"' "$T/frag.html" || true)
[ "$n" -eq 4 ] && pass "one container per changed file (4)" || fail "expected 4 containers, got $n"
grep -q 'oldFile' "$T/frag.html" && grep -q 'newFile' "$T/frag.html" && pass "render call passes oldFile and newFile" || fail "oldFile/newFile missing"
grep -q 'untracked.txt' "$T/frag.html" && pass "untracked file is included" || fail "untracked file missing"
grep -q 'new-name.txt' "$T/frag.html" && grep -q 'renamed from\|from old-name.txt' "$T/frag.html" && pass "rename is reported" || fail "rename missing"
[ "$(grep -c '</script>' "$T/frag.html")" -eq 2 ] && pass "file text cannot close the data script early" || fail "embedded </script> broke the fragment"
"$KP_BIN/kingpin" report check "$T/frag.html" >/dev/null && pass "check accepts the generated fragment" || fail "check rejected generated fragment"

echo "=== kingpin report check ==="
printf '<div class="kp-diff-box"><div class="kp-diff"></div></div><script type="module">new FileDiff(o).render({containerWrapper: c, patch: d})</script>' > "$T/bad.html"
out=$("$KP_BIN/kingpin" report check "$T/bad.html" 2>&1) && fail "check accepted a patch: report" || pass "check rejects a report"
echo "$out" | grep -q 'patch:' && pass "check names the invalid patch option" || fail "no patch message: $out"
echo "$out" | grep -q 'without oldFile and newFile' && pass "check names the missing oldFile/newFile" || fail "no oldFile message: $out"
echo "$out" | grep -q 'empty' && pass "check names the empty container" || fail "no empty-container message: $out"
printf '<p>no diffs here</p>' > "$T/none.html"
"$KP_BIN/kingpin" report check "$T/none.html" >/dev/null 2>&1 && fail "check accepted a report without FileDiff" || pass "check rejects a report without FileDiff"
"$KP_BIN/kingpin" report check "$T/missing.html" >/dev/null 2>&1 && fail "check accepted a missing file" || pass "check rejects a missing file"
{ echo '<p>We replaced the old patch: approach and the FileDiff call.</p>'; cat "$T/frag.html"; } > "$T/prose-ok.html"
"$KP_BIN/kingpin" report check "$T/prose-ok.html" >/dev/null 2>&1 && pass "check ignores patch: in prose" || fail "check failed a good report because of prose"
printf '<p>FileDiff oldFile newFile</p>' > "$T/prose-only.html"
"$KP_BIN/kingpin" report check "$T/prose-only.html" >/dev/null 2>&1 && fail "check accepted a report whose only FileDiff is prose" || pass "check rejects a report whose only FileDiff is prose"
{ echo '<div class="kp-diff-title"></div>'; cat "$T/frag.html"; } > "$T/title-empty.html"
"$KP_BIN/kingpin" report check "$T/title-empty.html" >/dev/null 2>&1 && pass "check does not treat kp-diff-title as a diff container" || fail "kp-diff-title wrongly counted as an empty diff container"
"$KP_BIN/kingpin" --help | grep -q 'report' && pass "kingpin --help lists report" || fail "--help does not list report"

echo "=== kingpin report check: prose ==="
{
  echo "<h1>It's not just a bug — it's a system flaw</h1>"
  echo '<p>This change is a testament to the crew, and we delve into the seam in order to find it.</p>'
  cat "$T/frag.html"
} > "$T/sloppy.html"
out=$("$KP_BIN/kingpin" report check "$T/sloppy.html" 2>&1) && fail "check accepted sloppy prose" || pass "check rejects sloppy prose"
echo "$out" | grep -q 'sloppy.html:1: em dash' && pass "prose failure names the file, line and tell" || fail "no file:line for the em dash: $out"
echo "$out" | grep -q "sloppy.html:1: \"it's not just\"" && pass "prose failure names the negative parallelism" || fail "no it's-not-just hit: $out"
echo "$out" | grep -q 'sloppy.html:2: "testament to"' && pass "prose failure names the second line" || fail "no testament-to hit: $out"
echo "$out" | grep -q 'FileDiff' && fail "prose check tripped on the valid diff section" || pass "prose failure leaves the diff section alone"
echo "$out" | grep -q "testament to the crew" && pass "prose failure quotes the offending line" || fail "offending line not echoed: $out"

{
  echo '<h1>One fix in the diff path</h1>'
  echo '<p>We replaced the old approach and pass the file contents to FileDiff.</p>'
  cat "$T/frag.html"
} > "$T/clean.html"
out=$("$KP_BIN/kingpin" report check "$T/clean.html" 2>&1) && pass "check accepts clean prose" || fail "check rejected clean prose: $out"
echo "$out" | grep -q 'has renderable diffs and clean prose' && pass "check says diffs and prose are clean" || fail "unexpected OK line: $out"

{
  echo '<p title="testament to seamless">A short paragraph that says what changed.</p>'
  echo '<pre><code>delve — seamless</code></pre>'
  echo '<script type="module">const s = "delve — seamless";</script>'
  echo '<p>Keep this em — dash here. <!-- unslop:ignore --></p>'
  cat "$T/frag.html"
} > "$T/ignored.html"
out=$("$KP_BIN/kingpin" report check "$T/ignored.html" 2>&1) && pass "prose pass ignores code, script bodies, attributes and the escape" || fail "ignored regions tripped the check: $out"
echo '<p>Another em — dash slips through.</p>' >> "$T/ignored.html"
out=$("$KP_BIN/kingpin" report check "$T/ignored.html" 2>&1) && fail "the escape exempts the whole page" || pass "the escape only exempts its own line"
[ "$(echo "$out" | grep -c ': em dash ')" -eq 1 ] && pass "only the un-escaped line is reported" || fail "expected one em dash hit, got: $out"
echo "$out" | grep -q 'ignored.html:[0-9]*: em dash .*Another em' && pass "the un-escaped line is named with its line number" || fail "un-escaped line not reported: $out"

{
  echo '<p'
  echo '  class="seamless-panel">A wrapped start tag keeps its attribute out of the prose.</p>'
  echo '<a'
  echo '  title="read > more — and more"'
  echo '  href="#">A wrapped link.</a>'
  cat "$T/frag.html"
} > "$T/wrapped-attributes.html"
out=$("$KP_BIN/kingpin" report check "$T/wrapped-attributes.html" 2>&1) && pass "prose pass ignores wrapped tags and attribute values holding >" || fail "wrapped attributes tripped the check: $out"

printf '<html><body><h1>One fix in the diff path</h1><p>The patch is small.</p></body></html>' > "$T/page.html"
"$KP_BIN/kingpin" report check "$T/page.html" >/dev/null 2>&1 && fail "check accepts a page with no diff section" || pass "check still requires a diff section"
"$KP_BIN/kingpin" report check --prose-only "$T/page.html" >/dev/null 2>&1 && pass "check --prose-only accepts a clean page with no diffs" || fail "check --prose-only rejected a clean page"
printf '<html><body><p>We delve into it.</p></body></html>' > "$T/page-sloppy.html"
"$KP_BIN/kingpin" report check --prose-only "$T/page-sloppy.html" >/dev/null 2>&1 && fail "--prose-only accepted sloppy prose" || pass "--prose-only rejects sloppy prose"
"$KP_BIN/kingpin" report check --bogus "$T/page.html" >/dev/null 2>&1 && fail "check accepted an unknown option" || pass "check rejects an unknown option"

printf '<html><body><p>Delving into the code, it is not just a fix.</p></body></html>' > "$T/page-inflected.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/page-inflected.html" 2>&1) && fail "--prose-only accepted inflected tells" || pass "--prose-only rejects inflected tells"
echo "$out" | grep -q 'page-inflected.html:1: "delve"' && pass "check catches delving" || fail "delving not caught: $out"
echo "$out" | grep -q 'page-inflected.html:1: "it.s not just"' && pass "check catches it is not just" || fail "expanded negative parallelism not caught: $out"

printf '<html><body><div class="kp-diff"></div><p>The patch is small.</p></body></html>' > "$T/page-empty-container.html"
"$KP_BIN/kingpin" report check --prose-only "$T/page-empty-container.html" >/dev/null 2>&1 && pass "--prose-only ignores an empty diff container" || fail "--prose-only failed an empty diff container"
"$KP_BIN/kingpin" report check "$T/page-empty-container.html" >/dev/null 2>&1 && fail "full check accepted an empty diff container" || pass "full check still rejects an empty diff container"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL REPORT TESTS PASSED"
else
  echo "REPORT TESTS FAILED"
  exit 1
fi
