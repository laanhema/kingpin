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

echo "=== kingpin report check: layout ==="
FIX="$KP_ROOT/tests/fixtures/dossier-layout.html"
"$KP_BIN/kingpin-report" --help | grep -q 'layout' && pass "--help documents the layout pass" || fail "--help does not mention the layout pass"
out=$("$KP_BIN/kingpin" report check "$FIX" 2>&1) && pass "check accepts the corrected dossier" || fail "check rejected the corrected dossier: $out"
echo "$out" | grep -q 'has renderable diffs and clean prose' && pass "the fixture keeps the existing OK line" || fail "unexpected OK line: $out"

# Each page below is a full document: the layout pass applies. The line numbers are the line of the
# element or rule the failure must name, so a verdict without a location cannot pass here.
cat > "$T/pre-bare.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<pre>./tests/test-report.sh --filter a-line-that-never-wraps</pre>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/pre-bare.html" 2>&1) && fail "check accepted a <pre> with no wrap rule" || pass "check rejects a <pre> with no wrap rule"
echo "$out" | grep -q 'pre-bare.html:6: <pre> has no wrap rule' && pass "the <pre> failure names its line" || fail "no file:line for the <pre>: $out"

cat > "$T/table-bare.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<table><tbody><tr><td><code>tests/test-report.sh</code></td></tr></tbody></table>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/table-bare.html" 2>&1) && fail "check accepted a table with no wrap rule" || pass "check rejects a table with no wrap rule"
echo "$out" | grep -q 'table-bare.html:6: <table> has no wrap rule' && pass "the table failure names its line" || fail "no file:line for the table: $out"

cat > "$T/grid-bare.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  code { overflow-wrap: anywhere; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; }
</style></head><body>
<div class="grid"><p>left</p><p>right</p></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/grid-bare.html" 2>&1) && fail "check accepted a grid with no shrink guard" || pass "check rejects a grid with no shrink guard"
echo "$out" | grep -q 'grid-bare.html:4: grid/flex layout has no shrink guard' && pass "the grid failure names its line" || fail "no file:line for the grid: $out"

printf '<!DOCTYPE html>\n<html><head><style>\n  * { box-sizing: border-box; min-width: 0; }\n  code { overflow-wrap: anywhere; }\n</style></head><body>\n<img src="/home/lauri/kingpin.jpg" alt="banner" />\n</body></html>\n' > "$T/abs-src.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/abs-src.html" 2>&1) && fail "check accepted an absolute asset path" || pass "check rejects an absolute asset path"
echo "$out" | grep -q 'abs-src.html:6: absolute asset path: /home/lauri/kingpin.jpg' && pass "the absolute path failure names its line" || fail "no file:line for the absolute path: $out"

printf '<!DOCTYPE html>\n<html><head><style>\n  * { box-sizing: border-box; min-width: 0; }\n  code { overflow-wrap: anywhere; }\n</style></head><body>\n<img src="../kingpin.jpg" alt="banner" />\n</body></html>\n' > "$T/climb-src.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/climb-src.html" 2>&1) && fail "check accepted an asset path climbing out of the folder" || pass "check rejects an asset path that climbs out of the folder"
echo "$out" | grep -q 'climb-src.html:6: asset path climbs out of the page folder: ../kingpin.jpg' && pass "the climbing path failure names its line" || fail "no file:line for the climbing path: $out"

# A diff fragment is not a page: it has no viewport and no layout of its own, so the pass stays out
# of it. This is what keeps the generated diffs fragment and DESIGN.md-style files passing.
printf '<div><pre>a line the host page must wrap</pre></div>\n' > "$T/fragment-pre.html"
"$KP_BIN/kingpin" report check --prose-only "$T/fragment-pre.html" >/dev/null 2>&1 && pass "a fragment is not layout-checked" || fail "a fragment was treated as a full page"

# The fixture with its guards stripped is the page that used to reach review looking broken.
sed -e 's/min-width: 0;//' -e 's/ overflow-wrap: anywhere;//g' -e 's/table-layout: fixed;//' -e 's/white-space: pre-wrap;//g' -e 's/overflow-x: auto;//' -e 's/max-width: 100%;//' "$FIX" > "$T/stripped.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/stripped.html" 2>&1) && fail "check accepted the stripped fixture" || pass "check rejects the stripped fixture"
echo "$out" | grep -q 'stripped.html:[0-9]*: <pre> has no wrap rule' && pass "the stripped fixture names a <pre>" || fail "no <pre> hit in the stripped fixture: $out"
echo "$out" | grep -q 'stripped.html:[0-9]*: <table> has no wrap rule' && pass "the stripped fixture names a table" || fail "no table hit in the stripped fixture: $out"
echo "$out" | grep -q 'stripped.html:[0-9]*: <code> has no wrap rule' && pass "the stripped fixture names the inline code" || fail "no code hit in the stripped fixture: $out"
echo "$out" | grep -q 'stripped.html:[0-9]*: <img> has no max-width rule' && pass "the stripped fixture names an image" || fail "no <img> hit in the stripped fixture: $out"

# An image keeps its intrinsic width unless a max-width rule reaches it.
cat > "$T/img-bare.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<img src="shot.png" alt="a screenshot with no size rule" />
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/img-bare.html" 2>&1) && fail "check accepted an image with no max-width rule" || pass "check rejects an image with no max-width rule"
echo "$out" | grep -q 'img-bare.html:6: <img> has no max-width rule' && pass "the image failure names its line" || fail "no file:line for the image: $out"

# overflow-wrap inherits, so a rule on p reaches the inline code inside it.
cat > "$T/inherited-wrap.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  p { overflow-wrap: anywhere; }
</style></head><body>
<p><code>/home/lauri/.treehouse/kingpin-edca9a/3/kingpin/tests/test-watch-supervisor.sh</code></p>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/inherited-wrap.html" >/dev/null 2>&1 && pass "a wrap rule on p reaches the inline code inside it" || fail "an inherited overflow-wrap was not seen"

# Inheritance follows the real markup: a `p` rule does not reach a code element in a div. This page
# measured 3128/1280 in Chrome while the old selector-shape matcher printed OK.
long=$(printf 'a%.0s' $(seq 1 400))
cat > "$T/p-wrap-outside-code.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  p { overflow-wrap: anywhere; }
</style></head><body>
<div><code>${long}</code></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/p-wrap-outside-code.html" 2>&1) && fail "check lent a p wrap rule to code outside a p" || pass "a wrap rule on p does not reach code in a div"
echo "$out" | grep -q 'p-wrap-outside-code.html:6: <code> has no wrap rule' && pass "the unreachable code failure names its line" || fail "no file:line for the unreachable code: $out"

# A child guard belongs to the container's real children: `p { min-width: 0 }` does not guard divs.
# This page measured 2879/1280 in Chrome while the old selector-shape matcher printed OK.
cat > "$T/grid2-p-guard.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  code { overflow-wrap: anywhere; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; }
  p { min-width: 0; }
</style></head><body>
<div class="grid2"><div>${long}</div><div>right</div></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/grid2-p-guard.html" 2>&1) && fail "check lent a p min-width rule to a grid of divs" || pass "a min-width rule on p does not guard a grid of divs"
echo "$out" | grep -q 'grid2-p-guard.html:4: grid/flex layout has no shrink guard' && pass "the unguarded grid failure names its rule line" || fail "no file:line for the unguarded grid: $out"

# A `p` wrap rule does not reach a table's cells either, so a fixed table still needs its own rule.
cat > "$T/table-fixed-p-wrap.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  p { overflow-wrap: anywhere; }
  table { width: 100%; max-width: 100%; table-layout: fixed; }
</style></head><body>
<table><tbody><tr><td>${long}</td><td>b</td></tr></tbody></table>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/table-fixed-p-wrap.html" 2>&1) && fail "check lent a p wrap rule to a table's cells" || pass "a wrap rule on p does not reach a table's cells"
echo "$out" | grep -q 'table-fixed-p-wrap.html:7: <table> has no wrap rule' && pass "the unreachable cell wrap failure names the table" || fail "no file:line for the table: $out"

# A layout guard is judged per layout rule: an unrelated min-width rule does not cover this grid.
cat > "$T/grid-unrelated-guard.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  code { overflow-wrap: anywhere; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; }
  .muted { min-width: 0; color: #888; }
</style></head><body>
<div class="grid"><p class="muted">left</p><p>right</p></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/grid-unrelated-guard.html" 2>&1) && fail "check accepted a grid guarded only by an unrelated rule" || pass "check does not lend an unrelated min-width rule to a grid"
echo "$out" | grep -q 'grid-unrelated-guard.html:4: grid/flex layout has no shrink guard' && pass "the grid failure names the layout rule's line" || fail "no file:line for the unguarded grid: $out"

# `display` declared only in an inline style is still a layout.
cat > "$T/grid-inline-display.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  code { overflow-wrap: anywhere; }
</style></head><body>
<div style="display: grid; grid-template-columns: 1fr 1fr"><p>left</p><p>right</p></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/grid-inline-display.html" 2>&1) && fail "check accepted a grid declared only in an inline style" || pass "check reads display from an inline style"
echo "$out" | grep -q 'grid-inline-display.html:5: grid/flex layout has no shrink guard' && pass "the inline grid failure names its element's line" || fail "no file:line for the inline grid: $out"

# A comment and a script body are not rendered, so the elements written there are not judged.
cat > "$T/ignored-elements.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<!-- The old page had <pre> without a wrap rule and .grid { display: grid; grid-template-columns: 1fr 1fr; } -->
<p>Clean page.</p>
<script>const template = "<table><tr><td>no wrap rule</td></tr></table>";</script>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/ignored-elements.html" >/dev/null 2>&1 && pass "comments and script bodies are not scanned as elements" || fail "a comment or script body tripped the layout pass"

# A fixed table layout alone leaves a long token running into the next column.
cat > "$T/table-fixed-bare.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
  table { width: 100%; max-width: 100%; table-layout: fixed; }
</style></head><body>
<table><tbody><tr><td>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</td><td>b</td></tr></tbody></table>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/table-fixed-bare.html" 2>&1) && fail "check accepted a fixed table with no cell wrap rule" || pass "check requires a cell wrap rule on a fixed table"
echo "$out" | grep -q 'table-fixed-bare.html:7: <table> has no wrap rule' && pass "the fixed-table failure names its line" || fail "no file:line for the fixed table: $out"

# The declaration parser accepts the shorthand, !important and a single-quoted style.
cat > "$T/pre-overflow-shorthand.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
  pre { overflow: auto; }
</style></head><body>
<pre>$ ./tests/test-report.sh --filter a-line-that-never-wraps</pre>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/pre-overflow-shorthand.html" >/dev/null 2>&1 && pass "pre accepts the overflow shorthand" || fail "pre { overflow: auto } was rejected"

cat > "$T/pre-important.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
  pre { white-space: pre-wrap !important; }
</style></head><body>
<pre>$ ./tests/test-report.sh --filter a-line-that-never-wraps</pre>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/pre-important.html" >/dev/null 2>&1 && pass "pre accepts !important on its wrap rule" || fail "white-space: pre-wrap !important was rejected"

cat > "$T/pre-single-quote.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<pre style='white-space: pre-wrap'>$ ./tests/test-report.sh --filter a-line-that-never-wraps</pre>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/pre-single-quote.html" >/dev/null 2>&1 && pass "an inline style in single quotes is read" || fail "a single-quoted inline style was rejected"

# The documented block and the checker cannot drift: a page built from the block in
# worker/preamble.md must pass, with a table, a long pre, a grid, inline code and an image.
{
  echo '<!DOCTYPE html>'
  echo '<html><head>'
  awk '/^```html$/ { if (!seen) { seen = 1; inside = 1; next } } inside && /^```$/ { exit } inside { print }' "$KP_ROOT/worker/preamble.md"
  echo '<style>'
  echo '  .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }'
  echo '</style>'
  echo '</head><body>'
  echo '<p>Built from the documented block.</p>'
  echo '<table><thead><tr><th>File</th><th>Change</th></tr></thead><tbody><tr><td><code>/home/lauri/.treehouse/kingpin-edca9a/3/kingpin/tests/test-watch-supervisor.sh</code></td><td>A cell that has to wrap inside its column.</td></tr></tbody></table>'
  echo '<pre>$ ./tests/test-report.sh --filter /home/lauri/.treehouse/kingpin-edca9a/3/kingpin/tests/test-watch-supervisor-2026-11-03T16-02-odd-and-very-long-run-identifier-0123456789abcdef.sh</pre>'
  echo '<div class="cols"><div><p>Left column with a long unbroken token aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</p></div><div><p>Right column.</p></div></div>'
  echo '<img src="screenshot-before.svg" alt="a screenshot" />'
  echo '</body></html>'
} > "$T/block.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/block.html" 2>&1) && pass "a page built from the documented block passes" || fail "the documented block no longer satisfies the check: $out"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL REPORT TESTS PASSED"
else
  echo "REPORT TESTS FAILED"
  exit 1
fi
