#!/usr/bin/env bash
# case-file dossier template: the four files ship together, every ref stays inside the folder, both
# pages keep the nine approved decisions, the worker page keeps the retire hook, the diffs keep a
# static fallback, the decision forms keep their handlers and the pages pass their report check.
#
# assets/lavish/kingpin-dossier/ is what every worker's report.html, every curator report and every
# page handed to the boss is copied from, so a missing file, a lost rule or a prose regression there
# spreads to every page made from it.
set -euo pipefail

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"
TPL="$KP_ROOT/assets/lavish/kingpin-dossier"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# stripped <file>: the page with its HTML and CSS comments removed, so the optional Before and
# After block, the how-to block and a comment about a rule neither supply a ref nor trip a rule.
stripped() {
  perl -0pe 's/<!--.*?-->//gs; s{/\*.*?\*/}{}gs' "$1"
}

# check_refs <dir> <file>: 0 when every relative src/href resolves inside the folder.
# Prints the reason on stderr when it is not, so a negative case explains itself.
check_refs() {
  local dir=$1 file=$2 ref
  while IFS= read -r ref; do
    case "$ref" in
      http://*|https://*|data:*|mailto:*|tel:*|'#'*) continue ;;
      /*|~*|file:*|[A-Za-z]:[\\/]*) echo "absolute path: $ref" >&2; return 1 ;;
    esac
    case "/${ref//\\//}/" in
      */../*) echo "path climbs out of the folder: $ref" >&2; return 1 ;;
    esac
    [ -s "$dir/$ref" ] || { echo "missing asset: $ref" >&2; return 1; }
  done < <(
    stripped "$file" | grep -o 'src="[^"]*"' | sed 's/^src="//; s/"$//' || true
    stripped "$file" | grep -o 'href="[^"]*"' | sed 's/^href="//; s/"$//' || true
  )
}

# check_fonts <file>: 0 when every face loads from a link and nothing loads from an @import.
check_fonts() {
  local f=$1
  stripped "$f" | grep -q 'fonts.googleapis.com/css2?family=Courier+Prime' \
    || { echo "the Google Fonts link no longer names Courier Prime" >&2; return 1; }
  for face in 'Playfair+Display' 'Special+Elite' 'Source+Serif+4'; do
    stripped "$f" | grep -q "$face" || { echo "the Google Fonts link no longer names $face" >&2; return 1; }
  done
  stripped "$f" | grep -q '@fontsource/commit-mono@5/400.css' \
    || { echo "the Commit Mono 400 link is missing" >&2; return 1; }
  stripped "$f" | grep -q '@fontsource/commit-mono@5/700.css' \
    || { echo "the Commit Mono 700 link is missing" >&2; return 1; }
  if stripped "$f" | grep -q '@import'; then
    echo "a face loads through @import, which the browser drops after a rule" >&2
    return 1
  fi
}

# check_decisions <file>: 0 when the nine approved decisions survive as rules and tokens.
# Each case names the decision it guards, so a broken copy explains itself.
check_decisions() {
  local f=$1 th link approve changes
  grep -q -- '--ink: #12100c;' "$f" || { echo "decision 1 lost the ink token" >&2; return 1; }
  grep -q -- '--paper: #efe6d2;' "$f" || { echo "decision 1 lost the paper token" >&2; return 1; }
  grep -q -- '--code-tint: #ddcfab;' "$f" || { echo "decision 3 lost the code chip token" >&2; return 1; }
  grep -q '\.noir-figure {' "$f" || { echo "decision 2 lost the framed hero" >&2; return 1; }
  grep -q '\.noir-stamp {' "$f" || { echo "decision 2 lost the sideways stamp" >&2; return 1; }
  grep -q '\.noir-kicker {' "$f" || { echo "decision 2 lost the kicker" >&2; return 1; }
  grep -q 'text-transform: uppercase; color: var(--paper); margin: 6px 0 0;' "$f" \
    || { echo "decision 2 lost the uppercase Playfair title" >&2; return 1; }
  grep -q '\.kp-label {' "$f" || { echo "decision 4 lost the tape label" >&2; return 1; }
  th=$(perl -0ne 'print $1 if /\.card-custom th\s*\{([^}]*)\}/s' "$f" || true)
  case "$th" in
    *'font-family: "Special Elite", "Courier New", monospace'*) ;;
    *) echo "decision 4: the table heads lost the typewriter face" >&2; return 1 ;;
  esac
  case "$th" in
    *'font-size: 10.5px'*) ;;
    *) echo "decision 4: the table heads lost the 10.5px size" >&2; return 1 ;;
  esac
  case "$th" in
    *'letter-spacing: .16em'*) ;;
    *) echo "decision 4: the table heads lost the .16em tracking" >&2; return 1 ;;
  esac
  grep -q 'border-bottom: 1px solid rgba(111,90,64,.7) !important;' "$f" \
    || { echo "decision 4 lost the sepia rule that closes a table" >&2; return 1; }
  approve=$(perl -0ne 'print $1 if /\.kp-btn\.approve\s*\{([^}]*)\}/s' "$f" || true)
  case "$approve" in
    *'var(--pass)'*) ;;
    *) echo "decision 5: the approve stamp lost the pass green" >&2; return 1 ;;
  esac
  case "$approve" in
    *'rotate(-2deg)'*) ;;
    *) echo "decision 5: the approve stamp lost its tilt" >&2; return 1 ;;
  esac
  changes=$(perl -0ne 'print $1 if /\.kp-btn\.changes\s*\{([^}]*)\}/s' "$f" || true)
  case "$changes" in
    *'var(--blood)'*) ;;
    *) echo "decision 5: the changes stamp lost the blood red" >&2; return 1 ;;
  esac
  case "$changes" in
    *'rotate(1.5deg)'*) ;;
    *) echo "decision 5: the changes stamp lost its tilt" >&2; return 1 ;;
  esac
  grep -q 'rgba(45,74,36,.17)' "$f" || { echo "decision 5 lost the green hover wash" >&2; return 1; }
  grep -q 'rgba(125,32,32,.15)' "$f" || { echo "decision 5 lost the red hover wash" >&2; return 1; }
  link=$(perl -0ne 'print $1 if /\.kp-brief a, \.card-custom a\s*\{([^}]*)\}/s' "$f" || true)
  case "$link" in
    *'color: var(--blood)'*) ;;
    *) echo "decision 7: links lost the stamp red" >&2; return 1 ;;
  esac
  grep -q '\.kp-brief a:hover, \.card-custom a:hover { color: var(--gold); }' "$f" \
    || { echo "decision 7: links lost the gold hover" >&2; return 1; }
  grep -q 'border-bottom: 2px solid rgba(27,23,18,.45);' "$f" \
    || { echo "decision 8 lost the 2px heading rule" >&2; return 1; }
}

# check_diffs <file>: 0 when every diff block keeps its fallback and the renderer's data lines up.
check_diffs() {
  local f=$1 surfaces fallbacks out
  surfaces=$(grep -c 'class="kp-diff"' "$f" || true)
  fallbacks=$(grep -c 'class="kp-fallback"' "$f" || true)
  [ "$surfaces" -ge 1 ] || { echo "expected at least 1 diff surface, found $surfaces" >&2; return 1; }
  [ "$fallbacks" -eq "$surfaces" ] \
    || { echo "a diff surface has no static fallback ($fallbacks for $surfaces surfaces)" >&2; return 1; }
  grep -q 'FileDiff' "$f" || { echo "the diff renderer lost its FileDiff call" >&2; return 1; }
  grep -q 'oldFile' "$f" || { echo "the diff renderer lost oldFile" >&2; return 1; }
  grep -q 'newFile' "$f" || { echo "the diff renderer lost newFile" >&2; return 1; }
  grep -q 'themeType: "dark"' "$f" || { echo "the diff renderer lost themeType: \"dark\"" >&2; return 1; }
  grep -q 'overflow: "wrap"' "$f" || { echo "the diff renderer lost overflow: \"wrap\"" >&2; return 1; }
  grep -q '(min-width: 1000px)' "$f" || { echo "the diff renderer lost its 1000px breakpoint" >&2; return 1; }
  grep -q 'diffStyle: wide.matches ? "split" : "unified"' "$f" \
    || { echo "the diff renderer no longer splits at the breakpoint" >&2; return 1; }
  grep -q 'addEventListener("change", paint)' "$f" \
    || { echo "the diff renderer no longer repaints on the breakpoint" >&2; return 1; }
  out=$(node -e 'const fs=require("fs");const t=fs.readFileSync(process.argv[1],"utf8");const m=t.match(/<script type="application\/json" id="kp-diff-data">([\s\S]*?)<\/script>/);if(!m){console.error("no kp-diff-data block");process.exit(1)}let d;try{d=JSON.parse(m[1])}catch(e){console.error("invalid JSON: "+e.message);process.exit(1)}if(!Array.isArray(d)||d.length===0){console.error("no entries");process.exit(1)}const boxes=(t.match(/class="kp-diff"/g)||[]).length;if(d.length!==boxes){console.error("differences: "+d.length+" entries, "+boxes+" blocks");process.exit(1)}for(const f of d){if(typeof f.name!=="string"||typeof f.oldContents!=="string"||typeof f.newContents!=="string"){console.error("entry lacks name/oldContents/newContents: "+JSON.stringify(f.name));process.exit(1)}}' "$f" 2>&1) \
    || { echo "kp-diff-data is unusable: $out" >&2; return 1; }
}

# check_source_data <dir>: 0 when no source task's data survives in any shipped file, the JSON included.
check_source_data() {
  local dir=$1 hit
  hit=$(grep -nE 'kp-186|dossier-retire|pull/219|laanhema/kingpin/issues/186|A finished dossier says it is finished' \
    "$dir/template.html" "$dir/handover.html" "$dir/DESIGN.md" || true)
  [ -z "$hit" ] || { echo "source task data found: $hit" >&2; return 1; }
}

# check_handover <dir>: 0 when handover.html is a complete, self-contained, gate-clean page.
check_handover() {
  local dir=$1 f=$1/handover.html s forms handlers recs
  [ -s "$f" ] || { echo "missing or empty: handover.html" >&2; return 1; }
  check_refs "$dir" "$f" || return 1
  check_decisions "$f" || return 1
  check_fonts "$f" || return 1
  grep -q '<html [^>]*data-theme="dark"' "$f" || { echo "<html> has no data-theme=\"dark\"" >&2; return 1; }
  grep -q '<html [^>]*data-lavish-annotate="off"' "$f" || { echo "<html> has no data-lavish-annotate=\"off\"" >&2; return 1; }
  for s in 'What Is Wrong Today' 'How It Would Work' 'Three Options Compared' 'Risks' 'Decisions'; do
    grep -q ">$s</h[23]>" "$f" || { echo "missing section: $s" >&2; return 1; }
  done
  grep -q '<svg [^>]*role="img"' "$f" || { echo "the diagram is not an inline svg with role=img" >&2; return 1; }
  grep -q '<title id=' "$f" || { echo "the diagram has no title" >&2; return 1; }
  recs=$(grep -c 'badge-success badge-sm">RECOMMENDED</span>' "$f" || true)
  [ "$recs" -eq 1 ] || { echo "expected exactly one RECOMMENDED option, found $recs" >&2; return 1; }
  forms=$(grep -c 'data-lavish-question=' "$f" || true)
  [ "$forms" -ge 2 ] || { echo "expected at least 2 decision forms, found $forms" >&2; return 1; }
  handlers=$(grep -c '<form [^>]*data-lavish-question="[^"]*"[^>]*onsubmit="kpAnswer(event)"' "$f" || true)
  [ "$handlers" -eq "$forms" ] || { echo "a decision form lost its onsubmit handler ($handlers of $forms)" >&2; return 1; }
  grep -q 'function kpAnswer(event)' "$f" || { echo "the handover lost its kpAnswer handler" >&2; return 1; }
  grep -q 'function kpAction(text, label)' "$f" || { echo "the handover lost its kpAction handler" >&2; return 1; }
  grep -q 'function kpRequestChanges(taskId)' "$f" || { echo "the handover lost its kpRequestChanges handler" >&2; return 1; }
  grep -q 'Paste this answer into chat' "$f" || { echo "a copy opened without Lavish has no fallback message" >&2; return 1; }
  grep -q 'queuePrompt(' "$f" || { echo "the decision handler no longer calls queuePrompt" >&2; return 1; }
  grep -q 'window\.lavish' "$f" || { echo "the handlers no longer guard window.lavish" >&2; return 1; }
  ! grep -q 'data-kp-finished-hide' "$f" \
    || { echo "the handover carries a retire hook, but only the worker page is retired" >&2; return 1; }
  grep -q 'href="#decisions"' "$f" || { echo "the handover lost its Go to the decisions link" >&2; return 1; }
  if grep -q 'id="kp-diffs"' "$f"; then
    echo "the handover carries a diff section, which belongs on the worker page" >&2
    return 1
  fi
  "$KP_BIN/kingpin-report" check --prose-only "$f" >/dev/null \
    || { echo "handover.html fails the prose check" >&2; return 1; }
}

# check_dir <dir>: 0 when the folder is a complete, self-contained, gate-clean template.
# Prints the reason on stderr when it is not, so a negative case explains itself.
check_dir() {
  local dir=$1 f s hide
  for f in template.html handover.html DESIGN.md hero.jpg; do
    [ -s "$dir/$f" ] || { echo "missing or empty: $f" >&2; return 1; }
  done
  [ "$(head -c 3 "$dir/hero.jpg" | od -An -tx1 | tr -d ' \n')" = ffd8ff ] || { echo "hero.jpg is not a JPEG" >&2; return 1; }
  cmp -s "$dir/hero.jpg" "$KP_ROOT/assets/kingpin.jpg" || { echo "hero.jpg is not a copy of assets/kingpin.jpg" >&2; return 1; }
  check_refs "$dir" "$dir/template.html" || return 1
  grep -q '<html [^>]*data-theme="dark"' "$dir/template.html" || { echo "<html> has no data-theme=\"dark\"" >&2; return 1; }
  grep -q '<html [^>]*data-lavish-annotate="off"' "$dir/template.html" || { echo "<html> has no data-lavish-annotate=\"off\"" >&2; return 1; }
  # The hero: the framed picture, the sideways stamp, the kicker and the blood-red word.
  grep -q '\.noir-hero {' "$dir/template.html" || { echo "the template lost the hero block" >&2; return 1; }
  grep -q 'src="hero.jpg"' "$dir/template.html" || { echo "the hero is not the relative hero.jpg" >&2; return 1; }
  grep -q 'class="noir-stamp"' "$dir/template.html" || { echo "the hero lost its sideways stamp" >&2; return 1; }
  grep -q 'class="noir-kicker"' "$dir/template.html" || { echo "the hero lost its kicker" >&2; return 1; }
  grep -q '<em style="color:#7d2020;font-style:normal">' "$dir/template.html" \
    || { echo "the hero title lost its blood-red word" >&2; return 1; }
  # The sections a dossier is read for.
  for s in 'What Changed and Why' 'Acceptance Criteria Verification' 'Review Verdict and Every Finding' 'Validation' 'Code Changes'; do
    grep -q ">$s</h[23]>" "$dir/template.html" || { echo "missing section: $s" >&2; return 1; }
  done
  grep -q 'Before and After' "$dir/template.html" || { echo "missing section: Before and After" >&2; return 1; }
  # The four stat cards.
  for s in 'Review Verdict' 'Validation' 'Files Modified' 'Git State'; do
    grep -q "uppercase\">$s</div>" "$dir/template.html" || { echo "missing stat card: $s" >&2; return 1; }
  done
  check_decisions "$dir/template.html" || return 1
  check_fonts "$dir/template.html" || return 1
  # The action bar: both stamped buttons, each backed by a handler that guards window.lavish.
  [ "$(grep -c 'onclick="kp\(Action\|RequestChanges\)(' "$dir/template.html" || true)" -ge 2 ] \
    || { echo "the action bar lost a button" >&2; return 1; }
  grep -q 'window\.lavish' "$dir/template.html" || { echo "the action handlers no longer guard window.lavish" >&2; return 1; }
  grep -q 'queuePrompt(' "$dir/template.html" || { echo "the action handlers no longer call queuePrompt" >&2; return 1; }
  grep -q 'navigator\.clipboard' "$dir/template.html" || { echo "the clipboard fallback is gone" >&2; return 1; }
  # The retire hook sits on the action strip and the status stamp, or a finished page keeps its buttons.
  hide=$(grep -oE '<[a-z]+[^>]* data-kp-finished-hide' "$dir/template.html" | wc -l | tr -d ' ')
  [ "$hide" -ge 2 ] || { echo "expected at least 2 data-kp-finished-hide elements, found $hide" >&2; return 1; }
  grep -q 'data-kp-finished-hide class="kp-telegram"' "$dir/template.html" \
    || { echo "the action telegram lost its data-kp-finished-hide hook" >&2; return 1; }
  grep -q 'data-kp-finished-hide class="kp-stamp' "$dir/template.html" \
    || { echo "the status stamp lost its data-kp-finished-hide hook" >&2; return 1; }
  check_diffs "$dir/template.html" || return 1
  grep -q 'Run the unslop skill' "$dir/template.html" || { echo "the how-to no longer tells the author to run the unslop skill" >&2; return 1; }
  check_source_data "$dir" || return 1
  check_handover "$dir" || return 1
  "$KP_BIN/kingpin-report" check "$dir/template.html" >/dev/null \
    || { echo "template.html fails the diff or prose check" >&2; return 1; }
  "$KP_BIN/kingpin-report" check --prose-only "$dir/DESIGN.md" >/dev/null \
    || { echo "DESIGN.md fails the prose check" >&2; return 1; }
  return 0
}

echo "=== the vendored template ==="
[ -d "$TPL" ] && pass "assets/lavish/kingpin-dossier/ exists" || fail "assets/lavish/kingpin-dossier/ is missing"
for f in template.html handover.html DESIGN.md hero.jpg; do
  [ -s "$TPL/$f" ] && pass "$f ships with the template" || fail "$f is missing or empty"
done
[ -s "$TPL/hero.jpg" ] && cmp -s "$TPL/hero.jpg" "$KP_ROOT/assets/kingpin.jpg" \
  && pass "hero.jpg is the repo image, copied beside the page" \
  || fail "hero.jpg is not a copy of assets/kingpin.jpg"
out=$(check_dir "$TPL" 2>&1) && pass "the folder is complete, relative and gate-clean" || fail "the folder does not check out: $out"

echo "=== it is the default for the fleet's pages ==="
for f in "$KP_ROOT/worker/preamble.md" "$KP_ROOT/worker/curator-preamble.md"; do
  grep -q 'assets/lavish/kingpin-dossier/template.html' "$f" && pass "$(basename "$f") points at the case-file template" \
    || fail "$(basename "$f") does not name assets/lavish/kingpin-dossier/template.html"
  grep -q 'assets/lavish/kingpin-dossier/DESIGN.md' "$f" && pass "$(basename "$f") points at the rules" \
    || fail "$(basename "$f") does not name assets/lavish/kingpin-dossier/DESIGN.md"
  grep -q 'assets/lavish/worker-dossier/template.html' "$f" && pass "$(basename "$f") keeps the older folder named" \
    || fail "$(basename "$f") no longer names the older worker-dossier template"
done
# The copy step carries the hero: a page copied alone loads no banner.
for f in "$KP_ROOT/worker/preamble.md" "$KP_ROOT/worker/curator-preamble.md" \
         "$KP_ROOT/AGENTS.md" "$KP_ROOT/docs/fleet-overview.md"; do
  grep -q 'hero\.jpg' "$f" && pass "$(basename "$f") names hero.jpg beside the copied page" \
    || fail "$(basename "$f") never tells the author to copy hero.jpg"
done
for f in template.html handover.html; do
  grep -q 'copy hero\.jpg' "$TPL/$f" && pass "$f tells the author to copy hero.jpg beside the page" \
    || fail "$f no longer copies hero.jpg beside the page"
done
grep -q 'hero\.jpg' "$TPL/DESIGN.md" && grep -q 'beside the copy' "$TPL/DESIGN.md" \
  && pass "DESIGN.md copies hero.jpg beside the page" \
  || fail "DESIGN.md's Using it step does not copy hero.jpg beside the page"
grep -q 'assets/lavish/kingpin-dossier/template.html' "$KP_ROOT/AGENTS.md" && pass "AGENTS.md names the case-file template" || fail "AGENTS.md does not name assets/lavish/kingpin-dossier/template.html"
grep -q 'assets/lavish/kingpin-dossier/handover.html' "$KP_ROOT/AGENTS.md" && pass "AGENTS.md names the case-file handover" || fail "AGENTS.md does not name assets/lavish/kingpin-dossier/handover.html"
grep -q 'tests/test-kingpin-dossier-template.sh' "$KP_ROOT/AGENTS.md" && pass "AGENTS.md names the new suite" || fail "AGENTS.md does not name tests/test-kingpin-dossier-template.sh"
grep -q 'case-file dossier template' "$KP_ROOT/README.md" && pass "README.md points at the case-file dossier template" || fail "README.md does not name the case-file dossier template"
grep -q 'assets/lavish/kingpin-dossier/' "$KP_ROOT/docs/fleet-overview.md" && pass "docs/fleet-overview.md names the new folder" || fail "docs/fleet-overview.md does not name assets/lavish/kingpin-dossier/"
grep -q 'test-kingpin-dossier-template.sh' "$KP_ROOT/docs/testing.md" && pass "docs/testing.md has a row for the new suite" || fail "docs/testing.md has no row for test-kingpin-dossier-template.sh"
grep -q 'kingpin-dossier-template' "$KP_ROOT/.github/workflows/ci.yml" && pass "the CI matrix has the new suite's leg" || fail ".github/workflows/ci.yml has no kingpin-dossier-template leg"
for d in worker-dossier noir-dossier; do
  [ -s "$KP_ROOT/assets/lavish/$d/template.html" ] && [ -s "$KP_ROOT/assets/lavish/$d/DESIGN.md" ] \
    && pass "the older $d folder still ships" \
    || fail "the older $d folder was removed"
done

echo "=== the retire hook survives dossier-finish ==="
mkdir -p "$T/retire"
cp "$TPL/template.html" "$T/retire/report.html"
out=$(node "$KP_ROOT/lib/dossier-finish.mjs" "$T/retire/report.html" --state merged --task kp-000-example-task --pr https://github.com/OWNER/REPO/pull/0 2>&1) \
  && pass "dossier-finish marked a copy of the template" \
  || fail "dossier-finish refused the template: $out"
grep -q 'data-kingpin-finished' "$T/retire/report.html" && pass "the marked page carries the finished marker" || fail "the marked page carries no finished marker"
grep -q '\[data-kp-finished-hide\] { display: none !important; }' "$T/retire/report.html" \
  && pass "the finished banner hides the retire-hook elements" \
  || fail "the finished banner does not hide the retire-hook elements"
! grep -qE '<button[^>]*onclick="kp(Action|RequestChanges)\(' "$T/retire/report.html" \
  && pass "no decision button keeps a live handler" \
  || fail "a decision button still carries its handler"
out=$("$KP_BIN/kingpin-report" check "$T/retire/report.html" 2>&1) \
  && pass "the marked page still passes kingpin-report check" \
  || fail "the marked page fails kingpin-report check: $out"

echo "=== the check fails on a broken copy ==="
cp -a "$TPL" "$T/good"
check_dir "$T/good" >/dev/null 2>&1 && pass "a pristine copy passes" || fail "a pristine copy was rejected"

cp -a "$TPL" "$T/no-design"
rm "$T/no-design/DESIGN.md"
out=$(check_dir "$T/no-design" 2>&1) && fail "a copy without DESIGN.md passed" || pass "a missing DESIGN.md fails"
echo "$out" | grep -q 'missing or empty: DESIGN.md' && pass "the failure names the missing file" || fail "unclear reason: $out"

cp -a "$TPL" "$T/no-handover"
rm "$T/no-handover/handover.html"
out=$(check_dir "$T/no-handover" 2>&1) && fail "a copy without handover.html passed" || pass "a missing handover.html fails"
echo "$out" | grep -q 'missing or empty: handover.html' && pass "the failure names the missing handover" || fail "unclear reason: $out"

cp -a "$TPL" "$T/no-hero"
rm "$T/no-hero/hero.jpg"
out=$(check_dir "$T/no-hero" 2>&1) && fail "a copy without hero.jpg passed" || pass "a missing hero.jpg fails"
echo "$out" | grep -q 'missing or empty: hero.jpg' && pass "the failure names the missing hero" || fail "unclear reason: $out"

# shellcheck disable=SC2088 # the tilde is literal: it is the HTML src path under test, not a shell expansion
for bad in '/home/lauri/hero.jpg' '~/hero.jpg' 'file:///tmp/hero.jpg' 'C:/hero.jpg'; do
  rm -rf "$T/abs"
  cp -a "$TPL" "$T/abs"
  sed -i "s|src=\"hero.jpg\"|src=\"$bad\"|" "$T/abs/template.html"
  out=$(check_dir "$T/abs" 2>&1) && fail "an absolute hero path passed: $bad" || pass "an absolute hero path fails: $bad"
  echo "$out" | grep -q 'absolute path' && pass "the failure names the absolute path: $bad" || fail "unclear reason for $bad: $out"
done

rm -rf "$T/climb"
mkdir -p "$T/climb/sub"
cp -a "$TPL/." "$T/climb/sub/"
cp "$TPL/hero.jpg" "$T/climb/hero.jpg"
sed -i 's|src="hero.jpg"|src="../hero.jpg"|' "$T/climb/sub/template.html"
out=$(check_dir "$T/climb/sub" 2>&1) && fail "a src that climbs out of the folder passed" || pass "a src that climbs out of the folder fails"
echo "$out" | grep -q 'climbs out of the folder' && pass "the failure names the escaping ref" || fail "unclear reason: $out"

for sec in 'Validation' 'Code Changes' 'Review Verdict and Every Finding' 'What Changed and Why'; do
  rm -rf "$T/no-section"
  cp -a "$TPL" "$T/no-section"
  sed -i "s|>$sec</h\\([23]\\)>|>Renamed</h\\1>|" "$T/no-section/template.html"
  out=$(check_dir "$T/no-section" 2>&1) && fail "a copy without the $sec section passed" || pass "a missing section fails: $sec"
  echo "$out" | grep -q "missing section: $sec" && pass "the failure names the section: $sec" || fail "unclear reason for $sec: $out"
done

rm -rf "$T/no-theme"
cp -a "$TPL" "$T/no-theme"
sed -i 's| data-theme="dark"||' "$T/no-theme/template.html"
out=$(check_dir "$T/no-theme" 2>&1) && fail "a page without data-theme passed" || pass "a page without data-theme=\"dark\" fails"
echo "$out" | grep -q 'data-theme' && pass "the failure names data-theme" || fail "unclear reason: $out"

rm -rf "$T/annotate-on"
cp -a "$TPL" "$T/annotate-on"
sed -i 's|data-lavish-annotate="off"|data-lavish-annotate="on"|' "$T/annotate-on/template.html"
out=$(check_dir "$T/annotate-on" 2>&1) && fail "a template that starts annotation on passed" || pass "a template that starts annotation on fails"
echo "$out" | grep -q 'data-lavish-annotate' && pass "the failure names data-lavish-annotate" || fail "unclear reason: $out"

rm -rf "$T/no-token"
cp -a "$TPL" "$T/no-token"
sed -i '/--ink: #12100c;/d' "$T/no-token/template.html"
out=$(check_dir "$T/no-token" 2>&1) && fail "a copy without the ink token passed" || pass "a missing decision token fails"
echo "$out" | grep -q 'lost the ink token' && pass "the failure names the lost token" || fail "unclear reason: $out"

rm -rf "$T/no-table-head"
cp -a "$TPL" "$T/no-table-head"
sed -i 's|letter-spacing: .16em; text-transform: uppercase;|text-transform: uppercase;|' "$T/no-table-head/template.html"
out=$(check_dir "$T/no-table-head" 2>&1) && fail "table heads without the .16em tracking passed" || pass "table heads without the .16em tracking fail"
echo "$out" | grep -q 'lost the .16em tracking' && pass "the failure names the lost tracking" || fail "unclear reason: $out"

rm -rf "$T/no-table-rule"
cp -a "$TPL" "$T/no-table-rule"
sed -i 's|border-bottom: 1px solid rgba(111,90,64,.7) !important;|border-bottom: 1px solid var(--paper-rule) !important;|' "$T/no-table-rule/template.html"
out=$(check_dir "$T/no-table-rule" 2>&1) && fail "a table closing rule gone neutral passed" || pass "a table closing rule gone neutral fails"
echo "$out" | grep -q 'sepia rule that closes a table' && pass "the failure names the table rule" || fail "unclear reason: $out"

rm -rf "$T/no-hover"
cp -a "$TPL" "$T/no-hover"
sed -i '/rgba(45,74,36,.17)/d' "$T/no-hover/template.html"
out=$(check_dir "$T/no-hover" 2>&1) && fail "a stamped button without its hover wash passed" || pass "a stamped button without its hover wash fails"
echo "$out" | grep -q 'green hover wash' && pass "the failure names the hover wash" || fail "unclear reason: $out"

rm -rf "$T/no-link"
cp -a "$TPL" "$T/no-link"
sed -i 's|color: var(--blood); text-decoration: none;|color: #2f4a63; text-decoration: none;|' "$T/no-link/template.html"
out=$(check_dir "$T/no-link" 2>&1) && fail "a link without the stamp red passed" || pass "a link without the stamp red fails"
echo "$out" | grep -q 'links lost the stamp red' && pass "the failure names the link colour" || fail "unclear reason: $out"

rm -rf "$T/no-heading-rule"
cp -a "$TPL" "$T/no-heading-rule"
sed -i 's|border-bottom: 2px solid rgba(27,23,18,.45);|border-bottom: 1px solid rgba(27,23,18,.45);|' "$T/no-heading-rule/template.html"
out=$(check_dir "$T/no-heading-rule" 2>&1) && fail "a brief heading without its 2px rule passed" || pass "a brief heading without its 2px rule fails"
echo "$out" | grep -q '2px heading rule' && pass "the failure names the heading rule" || fail "unclear reason: $out"

rm -rf "$T/no-font"
cp -a "$TPL" "$T/no-font"
sed -i '/@fontsource\/commit-mono@5\/700.css/d' "$T/no-font/template.html"
out=$(check_dir "$T/no-font" 2>&1) && fail "a page without the 700 Commit Mono link passed" || pass "a missing font link fails"
echo "$out" | grep -q 'Commit Mono 700 link is missing' && pass "the failure names the missing font link" || fail "unclear reason: $out"

rm -rf "$T/font-import"
cp -a "$TPL" "$T/font-import"
printf '<style>\n@import url("https://example.test/face.css");\n</style>\n' >> "$T/font-import/template.html"
out=$(check_dir "$T/font-import" 2>&1) && fail "a face loaded through @import passed" || pass "a face loaded through @import fails"
echo "$out" | grep -q '@import' && pass "the failure names the @import" || fail "unclear reason: $out"

rm -rf "$T/no-button"
cp -a "$TPL" "$T/no-button"
sed -i '0,/onclick="kpAction([^"]*)"/s//data-action="none"/' "$T/no-button/template.html"
sed -i '0,/onclick="kpRequestChanges([^"]*)"/s//data-action="none"/' "$T/no-button/template.html"
out=$(check_dir "$T/no-button" 2>&1) && fail "an action bar without its handlers passed" || pass "an action bar without its handlers fails"
echo "$out" | grep -q 'action bar lost a button' && pass "the failure names the missing buttons" || fail "unclear reason: $out"

rm -rf "$T/no-bridge"
cp -a "$TPL" "$T/no-bridge"
sed -i 's/window\.lavish/window.nothing/g' "$T/no-bridge/template.html"
out=$(check_dir "$T/no-bridge" 2>&1) && fail "handlers without the Lavish guard passed" || pass "handlers without the Lavish guard fail"
echo "$out" | grep -q 'guard window.lavish' && pass "the failure names the missing guard" || fail "unclear reason: $out"

rm -rf "$T/no-clipboard"
cp -a "$TPL" "$T/no-clipboard"
sed -i 's/navigator\.clipboard/navigator.nowhere/g' "$T/no-clipboard/template.html"
out=$(check_dir "$T/no-clipboard" 2>&1) && fail "a page without the clipboard fallback passed" || pass "a page without the clipboard fallback fails"
echo "$out" | grep -q 'clipboard fallback is gone' && pass "the failure names the missing fallback" || fail "unclear reason: $out"

rm -rf "$T/no-hide"
cp -a "$TPL" "$T/no-hide"
sed -i 's/data-kp-finished-hide/data-kp-keep/g' "$T/no-hide/template.html"
out=$(check_dir "$T/no-hide" 2>&1) && fail "a page without the retire hook passed" || pass "a page without the retire hook fails"
echo "$out" | grep -q 'data-kp-finished-hide' && pass "the failure names the retire hook" || fail "unclear reason: $out"

rm -rf "$T/no-fallback"
cp -a "$TPL" "$T/no-fallback"
sed -i 's|class="kp-fallback"|class="plain"|' "$T/no-fallback/template.html"
out=$(check_dir "$T/no-fallback" 2>&1) && fail "a diff surface without its static fallback passed" || pass "a diff surface without its static fallback fails"
echo "$out" | grep -q 'no static fallback' && pass "the failure names the missing fallback" || fail "unclear reason: $out"

rm -rf "$T/no-breakpoint"
cp -a "$TPL" "$T/no-breakpoint"
sed -i 's|(min-width: 1000px)|(min-width: 900px)|' "$T/no-breakpoint/template.html"
out=$(check_dir "$T/no-breakpoint" 2>&1) && fail "a diff renderer without the 1000px breakpoint passed" || pass "a diff renderer without the 1000px breakpoint fails"
echo "$out" | grep -q '1000px breakpoint' && pass "the failure names the breakpoint" || fail "unclear reason: $out"

rm -rf "$T/no-repaint"
cp -a "$TPL" "$T/no-repaint"
sed -i 's|wide.addEventListener("change", paint);||' "$T/no-repaint/template.html"
out=$(check_dir "$T/no-repaint" 2>&1) && fail "a diff renderer that never repaints passed" || pass "a diff renderer that never repaints fails"
echo "$out" | grep -q 'repaints on the breakpoint' && pass "the failure names the repaint" || fail "unclear reason: $out"

rm -rf "$T/bad-data"
cp -a "$TPL" "$T/bad-data"
sed -i 's|id="kp-diff-data">\[|id="kp-diff-data">[{|' "$T/bad-data/template.html"
out=$(check_dir "$T/bad-data" 2>&1) && fail "diff data out of step with the page passed" || pass "diff data out of step with the page fails"
echo "$out" | grep -q 'invalid JSON' && pass "the failure names the broken diff data" || fail "unclear reason: $out"

rm -rf "$T/source-data"
cp -a "$TPL" "$T/source-data"
printf '<!-- kp-186-todo-3-retire -->\n' >> "$T/source-data/DESIGN.md"
out=$(check_dir "$T/source-data" 2>&1) && fail "a source task id left in the folder passed" || pass "a source task id left in the folder fails"
echo "$out" | grep -q 'source task data found' && pass "the failure names the source data" || fail "unclear reason: $out"

rm -rf "$T/sloppy"
cp -a "$TPL" "$T/sloppy"
printf '<p>A seamless change — in order to ship it.</p>\n' >> "$T/sloppy/template.html"
out=$(check_dir "$T/sloppy" 2>&1) && fail "a prose regression passed" || pass "a prose regression fails"
echo "$out" | grep -q 'fails the diff or prose check' && pass "the failure names the check" || fail "unclear reason: $out"

echo "=== the handover check fails on a broken copy ==="
cp -a "$TPL" "$T/h-good"
check_handover "$T/h-good" >/dev/null 2>&1 && pass "a pristine handover copy passes" || fail "a pristine handover copy was rejected"

for sec in 'Risks' 'Decisions' 'Three Options Compared'; do
  rm -rf "$T/h-sec"
  cp -a "$TPL" "$T/h-sec"
  sed -i "s|>$sec</h\\([23]\\)>|>Renamed</h\\1>|" "$T/h-sec/handover.html"
  out=$(check_handover "$T/h-sec" 2>&1) && fail "a handover copy without $sec passed" || pass "a missing handover section fails: $sec"
  echo "$out" | grep -q "missing section: $sec" && pass "the failure names the section: $sec" || fail "unclear reason for $sec: $out"
done

rm -rf "$T/h-handler"
cp -a "$TPL" "$T/h-handler"
sed -i '0,/<form [^>]*onsubmit="kpAnswer(event)"/s/ onsubmit="kpAnswer(event)"//' "$T/h-handler/handover.html"
out=$(check_handover "$T/h-handler" 2>&1) && fail "a form without its handler passed" || pass "a decision form without its handler fails"
echo "$out" | grep -q 'lost its onsubmit handler' && pass "the failure names the handler" || fail "unclear reason: $out"

rm -rf "$T/h-nomsg"
cp -a "$TPL" "$T/h-nomsg"
sed -i 's/Paste this answer into chat/Nothing here/' "$T/h-nomsg/handover.html"
out=$(check_handover "$T/h-nomsg" 2>&1) && fail "a handler without the no-Lavish message passed" || pass "a handler without the no-Lavish message fails"
echo "$out" | grep -q 'no fallback message' && pass "the failure names the missing message" || fail "unclear reason: $out"

rm -rf "$T/h-rec"
cp -a "$TPL" "$T/h-rec"
sed -i 's|badge-success badge-sm">RECOMMENDED</span>|badge-outline badge-sm">Option</span>|' "$T/h-rec/handover.html"
out=$(check_handover "$T/h-rec" 2>&1) && fail "an options block with no recommendation passed" || pass "an options block with no recommendation fails"
echo "$out" | grep -q 'exactly one RECOMMENDED' && pass "the failure names the recommendation rule" || fail "unclear reason: $out"

rm -rf "$T/h-diff"
cp -a "$TPL" "$T/h-diff"
sed -i 's|</main>|<section id="kp-diffs"></section>\n</main>|' "$T/h-diff/handover.html"
out=$(check_handover "$T/h-diff" 2>&1) && fail "a handover with a diff section passed" || pass "a handover with a diff section fails"
echo "$out" | grep -q 'carries a diff section' && pass "the failure names the stray diff section" || fail "unclear reason: $out"

rm -rf "$T/h-sloppy"
cp -a "$TPL" "$T/h-sloppy"
printf '<p>A seamless change — in order to ship it.</p>\n' >> "$T/h-sloppy/handover.html"
out=$(check_handover "$T/h-sloppy" 2>&1) && fail "a handover prose regression passed" || pass "a handover prose regression fails"
echo "$out" | grep -q 'fails the prose check' && pass "the failure names the handover check" || fail "unclear reason: $out"

rm -rf "$T/h-token"
cp -a "$TPL" "$T/h-token"
sed -i '/--ink: #12100c;/d' "$T/h-token/handover.html"
out=$(check_handover "$T/h-token" 2>&1) && fail "a handover without the ink token passed" || pass "a handover without a palette token fails"
echo "$out" | grep -q 'lost the ink token' && pass "the failure names the handover's lost token" || fail "unclear reason: $out"

rm -rf "$T/h-font"
cp -a "$TPL" "$T/h-font"
sed -i '/@fontsource\/commit-mono@5\/700.css/d' "$T/h-font/handover.html"
out=$(check_handover "$T/h-font" 2>&1) && fail "a handover without the 700 Commit Mono link passed" || pass "a handover without a font link fails"
echo "$out" | grep -q 'Commit Mono 700 link is missing' && pass "the failure names the handover's missing font" || fail "unclear reason: $out"

rm -rf "$T/h-hide"
cp -a "$TPL" "$T/h-hide"
sed -i 's|class="kp-telegram"|data-kp-finished-hide class="kp-telegram"|' "$T/h-hide/handover.html"
out=$(check_handover "$T/h-hide" 2>&1) && fail "a handover carrying the retire hook passed" || pass "a handover carrying the retire hook fails"
echo "$out" | grep -q 'retire hook' && pass "the failure names the stray retire hook" || fail "unclear reason: $out"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL KINGPIN-DOSSIER-TEMPLATE TESTS PASSED"
else
  echo "KINGPIN-DOSSIER-TEMPLATE TESTS FAILED"
  exit 1
fi
