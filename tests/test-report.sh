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

# H4: a layout container with no element children (a text-only badge or a flex heading) has nothing
# that can overflow, and a layout rule that matches no element has no rendered layout. Neither is a
# finding. Both pages carry the documented block and measured 1280/1280 and 1024/1024 in Chrome.
{
  echo '<!DOCTYPE html>'
  echo '<html><head>'
  awk '/^```html$/ { if (!seen) { seen = 1; inside = 1; next } } inside && /^```$/ { exit } inside { print }' "$KP_ROOT/worker/preamble.md"
  echo '<style>'
  echo '  .badge { display: inline-flex; align-items: center; padding: 1px 10px; }'
  echo '</style>'
  echo '</head><body>'
  echo '<p>Status: <span class="badge">APPROVE</span></p>'
  echo '</body></html>'
} > "$T/block-badge.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/block-badge.html" 2>&1) && pass "a text-only inline-flex badge passes" || fail "the documented block cannot pass for a text-only badge: $out"

{
  echo '<!DOCTYPE html>'
  echo '<html><head>'
  awk '/^```html$/ { if (!seen) { seen = 1; inside = 1; next } } inside && /^```$/ { exit } inside { print }' "$KP_ROOT/worker/preamble.md"
  echo '<style>'
  echo '  .cards-2up { display: grid; grid-template-columns: 1fr 1fr; }'
  echo '</style>'
  echo '</head><body>'
  echo '<p>A rule for a class no element uses.</p>'
  echo '</body></html>'
} > "$T/block-unused-grid.html"
"$KP_BIN/kingpin" report check --prose-only "$T/block-unused-grid.html" >/dev/null 2>&1 && pass "a layout rule that matches no element is skipped" || fail "an unmatched layout rule still failed the page"

# The same flex rule over text and no element children cannot overflow either; measured 1280/1280
# and 1024/1024 in Chrome.
cat > "$T/flex-heading.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  body { margin: 0; }
  h2 { display: flex; align-items: center; gap: 10px; }
</style></head><body>
<h2>5. The report names its own line</h2>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/flex-heading.html" >/dev/null 2>&1 && pass "a text-only flex heading passes" || fail "a text-only flex heading was rejected"

# A flex row with real children and no guard still fails: H4 skips only the childless case.
cat > "$T/flex-row-bare.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  .row { display: flex; }
</style></head><body>
<div class="row"><span>left</span><span>right</span></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/flex-row-bare.html" 2>&1) && fail "check accepted an unguarded flex row with real children" || pass "an unguarded flex row with real children still fails"
echo "$out" | grep -q 'flex-row-bare.html:3: grid/flex layout has no shrink guard' && pass "the unguarded flex row failure names its rule line" || fail "no file:line for the unguarded flex row: $out"

# M5: a selector list inside :where()/:is() is still a selector list. Both pages measured 1280/1280
# and 1024/1024 in Chrome and were rejected by the old parser, which split them on the inner comma.
cat > "$T/where-wrap.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  :where(p, td) { overflow-wrap: anywhere; }
  table { width: 100%; max-width: 100%; table-layout: fixed; }
</style></head><body>
<p><code>${long}</code></p>
<table><tbody><tr><td><code>${long}</code></td><td>b</td></tr></tbody></table>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/where-wrap.html" >/dev/null 2>&1 && pass ":where(p, td) contributes a wrap rule" || fail "a selector list inside :where was not matched"

cat > "$T/where-guard.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  code { overflow-wrap: anywhere; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; }
  :where(.cell) { min-width: 0; }
</style></head><body>
<div class="grid"><div class="cell"><code>${long}</code></div><div class="cell">right</div></div>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/where-guard.html" >/dev/null 2>&1 && pass ":where(.cell) contributes a shrink guard" || fail "a selector inside :where was not matched"

# M6: a scoped rule reaches only what the whole chain matches. The old matcher credited the last
# compound only, so these two pages printed OK while measuring 3128/1280 and 2879/1280 in Chrome.
cat > "$T/scoped-wrap.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  .panel p { overflow-wrap: anywhere; }
</style></head><body>
<div class="panel"><p>Short text.</p></div>
<p><code>${long}</code></p>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/scoped-wrap.html" 2>&1) && fail "check lent a scoped .panel p wrap rule to a p outside the panel" || pass "a scoped wrap rule reaches only p inside the panel"
echo "$out" | grep -q 'scoped-wrap.html:7: <code> has no wrap rule' && pass "the scoped wrap failure names the unreached code" || fail "no file:line for the scoped wrap: $out"

cat > "$T/scoped-guard.html" <<HTML
<!DOCTYPE html>
<html><head><style>
  .grid-a { display: grid; grid-template-columns: 1fr 1fr; }
  .grid-b { display: grid; grid-template-columns: 1fr 1fr; }
  .grid-a .cell { min-width: 0; }
</style></head><body>
<div class="grid-a"><div class="cell">left</div><div class="cell">right</div></div>
<div class="grid-b"><div class="cell">${long}</div><div class="cell">right</div></div>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/scoped-guard.html" 2>&1) && fail "check lent a .grid-a .cell guard to .grid-b" || pass "a scoped guard reaches only cells inside its own grid"
echo "$out" | grep -q 'scoped-guard.html:4: grid/flex layout has no shrink guard' && pass "the scoped guard failure names the other grid's rule line" || fail "no file:line for the scoped guard: $out"

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

echo "=== kingpin report check: stylesheet parse and palette ==="

# The two-line repro from issue #128: a declaration outside any selector. The browser's recovery
# swallows the rule that follows it, so the body palette never reaches the page.
cat > "$T/stray-decl.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  color-scheme: dark;
  body {
    margin: 0;
    background: #0d1117;
    color: #e6edf3;
  }
  pre { white-space: pre-wrap; overflow-wrap: anywhere; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<p>Clean prose.</p>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/stray-decl.html" 2>&1) && fail "check accepted a declaration outside any selector" || pass "check rejects a declaration outside any selector"
echo "$out" | grep -q 'stray-decl.html:4: declaration outside any selector' && pass "the stray declaration failure names its line" || fail "no file:line for the stray declaration: $out"
echo "$out" | grep -q 'color-scheme: dark;' && pass "the stray declaration failure quotes the line" || fail "the offending line is not quoted: $out"

# The same page with the declaration moved inside :root passes.
cat > "$T/stray-fixed.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  :root { color-scheme: dark; }
  body {
    margin: 0;
    background: #0d1117;
    color: #e6edf3;
  }
  pre { white-space: pre-wrap; overflow-wrap: anywhere; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<p>Clean prose.</p>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/stray-fixed.html" >/dev/null 2>&1 && pass "the same page passes with the declaration inside :root" || fail "the fixed two-line repro was rejected"

# The walk is by brace depth, not a search for color-scheme.
printf '<!DOCTYPE html>\n<html><head><style>\n  * { box-sizing: border-box; min-width: 0; }\n  margin: 0;\n  body { margin: 0; }\n  code { overflow-wrap: anywhere; }\n</style></head><body><p>Clean prose.</p></body></html>\n' > "$T/stray-generic.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/stray-generic.html" 2>&1) && fail "check accepted a bare margin declaration" || pass "check rejects a stray declaration that is not color-scheme"
echo "$out" | grep -q 'stray-generic.html:4: declaration outside any selector' && pass "the generic stray declaration names its line" || fail "no file:line for the generic stray declaration: $out"
echo "$out" | grep -q 'margin: 0;' && pass "the generic stray declaration quotes the line" || fail "the generic line is not quoted: $out"

# A declaration with no trailing semicolon still swallows the rule it precedes.
printf '<!DOCTYPE html>\n<html><head><style>\n  * { box-sizing: border-box; min-width: 0; }\n  color-scheme: dark\n  body { margin: 0; background: #0d1117; color: #e6edf3; }\n  code { overflow-wrap: anywhere; }\n</style></head><body><p>Clean prose.</p></body></html>\n' > "$T/stray-no-semicolon.html"
out=$("$KP_BIN/kingpin" report check --prose-only "$T/stray-no-semicolon.html" 2>&1) && fail "check accepted a stray declaration with no semicolon" || pass "check rejects a stray declaration with no semicolon"
echo "$out" | grep -q 'stray-no-semicolon.html:4: declaration outside any selector' && pass "the semicolon-less declaration names its line" || fail "no file:line for the semicolon-less declaration: $out"

# An at-statement and an at-rule block at depth 0 are not declarations.
cat > "$T/at-rules.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; min-width: 0; }
  body { margin: 0; background: #0d1117; color: #e6edf3; }
  pre { white-space: pre-wrap; overflow-wrap: anywhere; }
  code { overflow-wrap: anywhere; }
  @media (min-width: 600px) {
    body { font-size: 18px; }
  }
</style></head><body><p>Clean prose.</p></body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/at-rules.html" >/dev/null 2>&1 && pass "at-statements and at-rule blocks are not declarations" || fail "an at-rule at depth 0 was rejected"

# Only a live stylesheet is judged. A `<style>` block inside an HTML comment is markup in a comment,
# like the elements the layout pass ignores.
cat > "$T/commented-style.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  body { margin: 0; background: #0d1117; color: #e6edf3; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<!--
<style>
  color-scheme: dark;
  body { background: none; }
</style>
-->
<p>Clean prose.</p>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/commented-style.html" >/dev/null 2>&1 && pass "a <style> block inside an HTML comment is not judged" || fail "a commented-out <style> block was parsed as a sheet"

# A `<style>` sequence inside a script string is JavaScript, not a sheet.
cat > "$T/script-style.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  * { box-sizing: border-box; min-width: 0; }
  body { margin: 0; background: #0d1117; color: #e6edf3; }
  code { overflow-wrap: anywhere; }
</style></head><body>
<p>Clean prose.</p>
<script>const sheet = "<style> color-scheme: dark; </style>";</script>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/script-style.html" >/dev/null 2>&1 && pass "a <style> sequence inside a script body is not judged" || fail "a <style> sequence in a script string was parsed as a sheet"

# A legacy `<style><!-- … --></style>` CDO/CDC wrapper: the CSS parser drops the two tokens and keeps
# the declarations between them, so the sheet is live and its declarations are read as usual.
cat > "$T/cdo-wrap.html" <<'HTML'
<!DOCTYPE html>
<html><head><style><!--
  * { box-sizing: border-box; min-width: 0; }
  body { margin: 0; background: #0d1117; color: #e6edf3; }
  code { overflow-wrap: anywhere; }
--></style></head><body>
<p>Clean prose.</p>
</body></html>
HTML
"$KP_BIN/kingpin" report check --prose-only "$T/cdo-wrap.html" >/dev/null 2>&1 && pass "a CDO/CDC wrapper is not a declaration" || fail "the CDO/CDC wrapper's own tokens were read as a declaration"

# The wrapped sheet is live, so a declaration outside a selector inside it is still reported, and the
# wrapper's tokens are not.
cat > "$T/cdo-wrap-stray.html" <<'HTML'
<!DOCTYPE html>
<html><head><style><!--
  * { box-sizing: border-box; min-width: 0; }
  color-scheme: dark;
  body { margin: 0; background: #0d1117; color: #e6edf3; }
  code { overflow-wrap: anywhere; }
--></style></head><body>
<p>Clean prose.</p>
</body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/cdo-wrap-stray.html" 2>&1) && fail "check accepted a stray declaration inside a CDO/CDC wrapper" || pass "check still reads the declarations of a wrapped sheet"
echo "$out" | grep -q 'cdo-wrap-stray.html:4: declaration outside any selector' && pass "the wrapped stray declaration names its line" || fail "no file:line for the wrapped stray declaration: $out"
echo "$out" | grep -q 'cdo-wrap-stray.html:7:' && fail "the wrapper's closing token was reported as a declaration: $out" || pass "the wrapper's tokens are not declarations"

# A dark claim with no background on body, html or :root leaves a white page.
cat > "$T/palette-missing.html" <<'HTML'
<!DOCTYPE html>
<html><head><style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; min-width: 0; }
  body { margin: 0; color: #e6edf3; }
  code { overflow-wrap: anywhere; }
</style></head><body><p>Clean prose.</p></body></html>
HTML
out=$("$KP_BIN/kingpin" report check --prose-only "$T/palette-missing.html" 2>&1) && fail "check accepted a dark claim with no background" || pass "check rejects a dark claim with no background"
echo "$out" | grep -q 'palette-missing.html:3: color-scheme: dark has no background rule on body, html or :root' && pass "the palette failure names the claim's line" || fail "no file:line for the missing palette: $out"

# Every legitimate way of painting the root or body satisfies the claim.
palette_pass() {
  local name=$1 body=$2
  printf '<!DOCTYPE html>\n<html><head><style>\n%s\n  * { box-sizing: border-box; min-width: 0; }\n  pre { white-space: pre-wrap; overflow-wrap: anywhere; }\n  code { overflow-wrap: anywhere; }\n</style></head>%s</html>\n' "$body" "$3" > "$T/$name.html"
  "$KP_BIN/kingpin" report check --prose-only "$T/$name.html" >/dev/null 2>&1 && pass "palette: $name passes" || fail "palette: $name was rejected"
}
palette_pass "palette-html" '  :root { color-scheme: dark; }
  html { background: #0d1117; }
  html { color: #e6edf3; }' '<body><p>Clean prose.</p></body>'
palette_pass "palette-root" '  :root { color-scheme: dark; background: #0d1117; }
  body { margin: 0; color: #e6edf3; }' '<body><p>Clean prose.</p></body>'
palette_pass "palette-var" '  :root { color-scheme: dark; --bg: #0d1117; }
  body { margin: 0; background: var(--bg); color: #e6edf3; }' '<body><p>Clean prose.</p></body>'
palette_pass "palette-gradient" '  :root { color-scheme: dark; --ink: #12100c; }
  body { margin: 0; background: radial-gradient(1200px 700px at 50% -10%, #241f18 0%, transparent 60%), var(--ink); color: #efe6d2; }' '<body><p>Clean prose.</p></body>'
palette_pass "palette-inline" '  :root { color-scheme: dark; }' '<body style="background: #0d1117; color: #e6edf3"><p>Clean prose.</p></body>'
palette_pass "palette-class" '  :root { color-scheme: dark; }
  .page { background: #0d1117; color: #e6edf3; }' '<body class="page"><p>Clean prose.</p></body>'

# A page that makes no dark claim is not asked to paint one.
printf '<!DOCTYPE html>\n<html><head><style>\n  * { box-sizing: border-box; min-width: 0; }\n  body { margin: 0; }\n  code { overflow-wrap: anywhere; }\n</style></head><body><p>Clean prose.</p></body></html>\n' > "$T/palette-unclaimed.html"
"$KP_BIN/kingpin" report check --prose-only "$T/palette-unclaimed.html" >/dev/null 2>&1 && pass "a page with no dark claim needs no palette" || fail "a page with no dark claim was rejected"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL REPORT TESTS PASSED"
else
  echo "REPORT TESTS FAILED"
  exit 1
fi
