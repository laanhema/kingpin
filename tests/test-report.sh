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

if [ "$FAILED" -eq 0 ]; then
  echo "ALL REPORT TESTS PASSED"
else
  echo "REPORT TESTS FAILED"
  exit 1
fi
