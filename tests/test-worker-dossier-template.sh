#!/usr/bin/env bash
# worker dossier and handover templates: the files ship together, the sections the contract relies on stay,
# the header pills sit on the pixel grid, the option rows keep their shape, the diffs keep a static
# fallback, the shared style block stays identical and the page passes the report gate.
#
# assets/lavish/worker-dossier/ is what every worker's report.html and every page handed to the boss
# is copied from, so a missing section, a lost Lavish guard or a prose regression there spreads to
# every page made from it.
set -euo pipefail

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"
TPL="$KP_ROOT/assets/lavish/worker-dossier"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# check_badge_wrap <file>: 0 when a table-cell badge wraps inside its pill.
# The rule also pins the line box, so a one-line pill keeps its 1rem height.
# Exactly one rule is allowed: a second one further down overrides the first and
# renders the page as before the fix, so reading one of two would pass a lost rule.
check_badge_wrap() {
  local f=$1 rule d n
  n=$(perl -0ne 'my $n = () = /td > \.badge\s*\{/g; print $n' "$f")
  [ "$n" -eq 1 ] || { echo "expected exactly one td > .badge rule, found $n" >&2; return 1; }
  rule=$(perl -0ne 'print $1 if /td > \.badge\s*\{([^}]*)\}/s' "$f" || true)
  for d in 'white-space: normal' 'max-width: 100%' 'height: auto' 'min-height: var(--size)' 'line-height: 1.4'; do
    case "$rule" in
      *"$d"*) ;;
      *) echo "td > .badge lost its wrap declaration: $d" >&2; return 1 ;;
    esac
  done
}

# check_pills <file>: 0 when the header pills carry the odd height and the cap-height trim block.
# A 12px capital is 9px tall, so only an odd pill height can put its ink on the grid. The @supports
# block is inert on DaisyUI's inline-flex badge, so the height and the sans face are what land it.
check_pills() {
  local f=$1 n
  grep -q '@supports (text-box: trim-both cap alphabetic)' "$f" || { echo "no @supports block for the cap-height trim" >&2; return 1; }
  perl -0ne 'exit(/@supports \(text-box: trim-both cap alphabetic\)\s*\{[^}]*text-box:\s*trim-both cap alphabetic/ ? 0 : 1)' "$f" || { echo "the @supports block lost its text-box declaration" >&2; return 1; }
  grep -q '\.badge-pill { height: 25px; }' "$f" || { echo "the header pill rule lost height: 25px" >&2; return 1; }
  # Count inside the header badge row: a class added to a table pill must not stand in for a header
  # pill that lost it.
  n=$(perl -0ne 'if (/<div class="flex gap-2 items-center flex-wrap">(.*?)<\/div>/s) { my $n = () = $1 =~ /badge-pill/g; print $n }' "$f")
  n=${n:-0}
  [ "$n" -eq 3 ] || { echo "expected badge-pill on the 3 header pills, found $n" >&2; return 1; }
}

# check_option_rows <file>: 0 when every option row is a bold title over a description, the
# control carries the measured nudge onto that title's ink, and the label leads its state pill.
check_option_rows() {
  local f=$1 rows titles
  grep -q '\.q-option input { margin-top: calc(\.2rem + 1px); flex: none; }' "$f" || { echo "the option control lost its 1px nudge" >&2; return 1; }
  rows=$(grep -c 'class="q-option"' "$f" || true)
  titles=$(grep -c 'class="q-option".*class="text-sm font-semibold' "$f" || true)
  [ "$rows" -gt 0 ] && [ "$titles" -eq "$rows" ] || { echo "an option row has no bold title ($titles of $rows)" >&2; return 1; }
  grep -q 'badge-outline badge-sm">Option B</span> <span class="badge badge-success badge-sm">RECOMMENDED' "$f" || { echo "the state pill leads the option label" >&2; return 1; }
}

# check_shared_style <dir>: 0 when the two templates carry the same shared style block, up to the
# last shared rule. The how-to comment also mentions <style>, so the range is anchored at the real
# tag: an unanchored one restarts at the comment and runs to the end of the file.
check_shared_style() {
  local dir=$1 a b
  a=$(sed -n '/^<style>$/,/^  \.kp-diff \.kp-fallback/p' "$dir/template.html")
  b=$(sed -n '/^<style>$/,/^  \.kp-diff \.kp-fallback/p' "$dir/handover.html")
  [ -n "$a" ] || { echo "template.html has no anchored style block" >&2; return 1; }
  [ "$a" = "$b" ] || { echo "the shared style block drifted between the two templates" >&2; return 1; }
}

# check_dir <dir>: 0 when the folder is a complete, self-contained, gate-clean template.
# Prints the reason on stderr when it is not, so a negative case explains itself.
check_dir() {
  local dir=$1 f ref s buttons surfaces fallbacks cols
  for f in template.html DESIGN.md; do
    [ -s "$dir/$f" ] || { echo "missing or empty: $f" >&2; return 1; }
  done
  # No local absolute path and no ref that climbs out of the folder: the template is copied as a
  # folder, so such a ref breaks every report made from it.
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
    # HTML comments are skipped: the template keeps an optional screenshot section in one.
    perl -0pe 's/<!--.*?-->//gs' "$dir/template.html" | grep -o 'src="[^"]*"' | sed 's/^src="//; s/"$//' || true
    perl -0pe 's/<!--.*?-->//gs' "$dir/template.html" | grep -o 'href="[^"]*"' | sed 's/^href="//; s/"$//' || true
  )
  # The root tag: the dark theme keeps badge colours the same everywhere, and annotation starts off.
  grep -q '<html [^>]*data-theme="dark"' "$dir/template.html" || { echo "<html> has no data-theme=\"dark\"" >&2; return 1; }
  grep -q '<html [^>]*data-lavish-annotate="off"' "$dir/template.html" || { echo "<html> has no data-lavish-annotate=\"off\"" >&2; return 1; }
  # The sections a dossier is read for.
  for s in 'What Changed and Why' 'Acceptance Criteria Verification' 'Review Verdict and Every Finding' 'Validation' 'Code Changes'; do
    grep -q ">$s</h[23]>" "$dir/template.html" || { echo "missing section: $s" >&2; return 1; }
  done
  # The four stat cards.
  for s in 'Review Verdict' 'Validation' 'Files Modified' 'Git State'; do
    grep -q "uppercase\">$s</div>" "$dir/template.html" || { echo "missing stat card: $s" >&2; return 1; }
  done
  # Fixed-layout tables need column widths, or every column gets an equal share.
  cols=$(grep -c '<colgroup>' "$dir/template.html" || true)
  [ "$cols" -ge 3 ] || { echo "expected a colgroup on each of the 3 tables, found $cols" >&2; return 1; }
  # A pill in a narrow column wraps inside its border instead of spilling.
  check_badge_wrap "$dir/template.html" || return 1
  # The header pills sit on the pixel grid, and the two templates share one style block.
  check_pills "$dir/template.html" || return 1
  # Rule 4: the id pill keeps the mono face and the status pill takes the sans one.
  grep -q 'class="[^"]*font-mono[^"]*">kp-000-example-task' "$dir/template.html" || { echo "the task id pill lost its mono face" >&2; return 1; }
  if grep -q 'class="[^"]*font-mono[^"]*">READY FOR REVIEW' "$dir/template.html"; then
    echo "the status pill still uses the mono face" >&2
    return 1
  fi
  check_shared_style "$dir" || return 1
  # The action bar: both buttons, each backed by a handler that guards window.lavish.
  buttons=$(grep -c 'onclick="kp\(Action\|RequestChanges\)(' "$dir/template.html" || true)
  [ "$buttons" -ge 2 ] || { echo "the action bar lost a button ($buttons of 2)" >&2; return 1; }
  grep -q 'window\.lavish' "$dir/template.html" || { echo "the action handlers no longer guard window.lavish" >&2; return 1; }
  grep -q 'queuePrompt(' "$dir/template.html" || { echo "the action handlers no longer call queuePrompt" >&2; return 1; }
  # Each diff surface carries a static copy of its diff for when the renderer cannot load.
  surfaces=$(grep -c 'class="kp-diff"' "$dir/template.html" || true)
  fallbacks=$(grep -c 'class="kp-fallback"' "$dir/template.html" || true)
  [ "$surfaces" -ge 1 ] && [ "$fallbacks" -eq "$surfaces" ] || { echo "a diff surface has no static fallback ($fallbacks for $surfaces surfaces)" >&2; return 1; }
  # The gate every copied report inherits: renderable diffs, contained layout and clean prose.
  grep -q 'Run the unslop skill' "$dir/template.html" || { echo "the how-to no longer tells the author to run the unslop skill" >&2; return 1; }
  "$KP_BIN/kingpin-report" check "$dir/template.html" >/dev/null || { echo "template.html fails the diff or prose check" >&2; return 1; }
  "$KP_BIN/kingpin-report" check --prose-only "$dir/DESIGN.md" >/dev/null || { echo "DESIGN.md fails the prose check" >&2; return 1; }
  return 0
}

# check_handover <dir>: 0 when handover.html is a complete, self-contained, gate-clean template.
check_handover() {
  local dir=$1 f=$1/handover.html ref s forms handlers surfaces fallbacks recs
  [ -s "$f" ] || { echo "missing or empty: handover.html" >&2; return 1; }
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
    perl -0pe 's/<!--.*?-->//gs' "$f" | grep -o 'src="[^"]*"' | sed 's/^src="//; s/"$//' || true
    perl -0pe 's/<!--.*?-->//gs' "$f" | grep -o 'href="[^"]*"' | sed 's/^href="//; s/"$//' || true
  )
  grep -q '<html [^>]*data-theme="dark"' "$f" || { echo "<html> has no data-theme=\"dark\"" >&2; return 1; }
  grep -q '<html [^>]*data-lavish-annotate="off"' "$f" || { echo "<html> has no data-lavish-annotate=\"off\"" >&2; return 1; }
  for s in 'What Is Wrong Today' 'How It Would Work' 'Three Options Compared' 'Risks' 'The Change' 'Decisions'; do
    grep -q ">$s</h[23]>" "$f" || { echo "missing section: $s" >&2; return 1; }
  done
  grep -q '<svg [^>]*role="img"' "$f" || { echo "the diagram is not an inline svg with role=img" >&2; return 1; }
  grep -q '<title id=' "$f" || { echo "the diagram has no title" >&2; return 1; }
  recs=$(grep -c 'badge-success badge-sm">RECOMMENDED</span>' "$f" || true)
  [ "$recs" -eq 1 ] || { echo "expected exactly one RECOMMENDED option, found $recs" >&2; return 1; }
  # A pill in a narrow column wraps inside its border instead of spilling.
  check_badge_wrap "$f" || return 1
  # The header pills, the option rows and the kind and status pills' faces.
  check_pills "$f" || return 1
  check_option_rows "$f" || return 1
  if grep -q 'class="[^"]*font-mono[^"]*">PROPOSAL' "$f"; then
    echo "the kind pill still uses the mono face" >&2
    return 1
  fi
  if grep -q 'class="[^"]*font-mono[^"]*">DECISION NEEDED' "$f"; then
    echo "the status pill still uses the mono face" >&2
    return 1
  fi
  forms=$(grep -c 'data-lavish-question=' "$f" || true)
  [ "$forms" -ge 2 ] || { echo "expected at least 2 decision forms, found $forms" >&2; return 1; }
  handlers=$(grep -c '<form [^>]*data-lavish-question="[^"]*"[^>]*onsubmit="kpAnswer(event)"' "$f" || true)
  [ "$handlers" -eq "$forms" ] || { echo "a decision form lost its onsubmit handler ($handlers of $forms)" >&2; return 1; }
  grep -q 'queuePrompt(' "$f" || { echo "the handler no longer calls queuePrompt" >&2; return 1; }
  grep -q 'window\.lavish' "$f" || { echo "the handler no longer guards window.lavish" >&2; return 1; }
  grep -q 'Paste this answer into chat' "$f" || { echo "a copy opened without Lavish has no fallback message" >&2; return 1; }
  surfaces=$(grep -c 'class="kp-diff"' "$f" || true)
  fallbacks=$(grep -c 'class="kp-fallback"' "$f" || true)
  [ "$surfaces" -ge 1 ] && [ "$fallbacks" -eq "$surfaces" ] || { echo "a diff surface has no static fallback ($fallbacks for $surfaces surfaces)" >&2; return 1; }
  grep -q 'Run the unslop skill' "$f" || { echo "the how-to no longer tells the author to run the unslop skill" >&2; return 1; }
  "$KP_BIN/kingpin-report" check "$f" >/dev/null || { echo "handover.html fails the diff or prose check" >&2; return 1; }
  return 0
}

echo "=== the vendored template ==="
[ -d "$TPL" ] && pass "assets/lavish/worker-dossier/ exists" || fail "assets/lavish/worker-dossier/ is missing"
for f in template.html DESIGN.md; do
  [ -s "$TPL/$f" ] && pass "$f ships with the template" || fail "$f is missing or empty"
done
out=$(check_dir "$TPL" 2>&1) && pass "the template is complete, relative and gate-clean" || fail "the template does not check out: $out"
[ -s "$TPL/handover.html" ] && pass "handover.html ships with the template" || fail "handover.html is missing or empty"
out=$(check_handover "$TPL" 2>&1) && pass "the handover template is complete, relative and gate-clean" || fail "the handover template does not check out: $out"

echo "=== it is the default for worker dossiers ==="
grep -q 'assets/lavish/worker-dossier/template.html' "$KP_ROOT/worker/preamble.md" && pass "the worker preamble points at the template" || fail "worker/preamble.md does not name assets/lavish/worker-dossier/template.html"
grep -q 'assets/lavish/worker-dossier/template.html' "$KP_ROOT/worker/curator-preamble.md" && pass "the curator preamble points at the template" || fail "worker/curator-preamble.md does not name assets/lavish/worker-dossier/template.html"
grep -q 'kingpin land curator' "$KP_ROOT/worker/curator-preamble.md" && pass "the curator preamble keeps the curator land command" || fail "worker/curator-preamble.md lost the 'kingpin land curator' command"
grep -q 'assets/lavish/worker-dossier/template.html' "$KP_ROOT/AGENTS.md" && pass "AGENTS.md names the worker template" || fail "AGENTS.md does not name assets/lavish/worker-dossier/template.html"
grep -q 'assets/lavish/worker-dossier/handover.html' "$KP_ROOT/AGENTS.md" && pass "AGENTS.md names the handover template" || fail "AGENTS.md does not name assets/lavish/worker-dossier/handover.html"
grep -q 'start a handover artifact from the noir' -i "$KP_ROOT/AGENTS.md" && fail "AGENTS.md still starts handover pages from the noir template" || pass "AGENTS.md no longer starts handover pages from noir"
[ -s "$KP_ROOT/assets/lavish/noir-dossier/template.html" ] && pass "the noir dossier template is still in the repo" || fail "the noir dossier template was removed"

echo "=== the check fails on a broken copy ==="
cp -a "$TPL" "$T/good"
check_dir "$T/good" >/dev/null 2>&1 && pass "a pristine copy passes" || fail "a pristine copy was rejected"

cp -a "$TPL" "$T/no-design"
rm "$T/no-design/DESIGN.md"
out=$(check_dir "$T/no-design" 2>&1) && fail "a copy without DESIGN.md passed" || pass "a missing DESIGN.md fails"
echo "$out" | grep -q 'missing or empty: DESIGN.md' && pass "the failure names the missing file" || fail "unclear reason: $out"

cp -a "$TPL" "$T/no-html"
rm "$T/no-html/template.html"
out=$(check_dir "$T/no-html" 2>&1) && fail "a copy without template.html passed" || pass "a missing template.html fails"
echo "$out" | grep -q 'missing or empty: template.html' && pass "the failure names the missing page" || fail "unclear reason: $out"

for sec in 'Validation' 'Code Changes' 'Review Verdict and Every Finding'; do
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

# shellcheck disable=SC2088 # the tilde is literal: it is the HTML src path under test, not a shell expansion
for bad in '/home/lauri/shot.png' '~/shot.png' 'file:///tmp/shot.png' 'C:/shot.png'; do
  rm -rf "$T/abs"
  cp -a "$TPL" "$T/abs"
  printf '<img src="%s" alt="shot">\n' "$bad" >> "$T/abs/template.html"
  out=$(check_dir "$T/abs" 2>&1) && fail "an absolute image path passed: $bad" || pass "an absolute image path fails: $bad"
  echo "$out" | grep -q 'absolute path' && pass "the failure names the absolute path: $bad" || fail "unclear reason for $bad: $out"
done

rm -rf "$T/sloppy"
cp -a "$TPL" "$T/sloppy"
printf '<p>A seamless change — in order to ship it.</p>\n' >> "$T/sloppy/template.html"
out=$(check_dir "$T/sloppy" 2>&1) && fail "a prose regression passed" || pass "a prose regression fails"
echo "$out" | grep -q 'fails the diff or prose check' && pass "the failure names the check" || fail "unclear reason: $out"

rm -rf "$T/no-diff-args"
cp -a "$TPL" "$T/no-diff-args"
sed -i 's/oldFile: { name: f.oldName, contents: f.oldContents },//' "$T/no-diff-args/template.html"
out=$(check_dir "$T/no-diff-args" 2>&1) && fail "a FileDiff call without oldFile passed" || pass "a FileDiff call without oldFile fails"
echo "$out" | grep -q 'fails the diff or prose check' && pass "the failure names the diff check" || fail "unclear reason: $out"

rm -rf "$T/no-fallback"
cp -a "$TPL" "$T/no-fallback"
sed -i 's|class="kp-fallback"|class="plain"|' "$T/no-fallback/template.html"
out=$(check_dir "$T/no-fallback" 2>&1) && fail "a diff surface without its static fallback passed" || pass "a diff surface without its static fallback fails"
echo "$out" | grep -q 'no static fallback' && pass "the failure names the missing fallback" || fail "unclear reason: $out"

rm -rf "$T/no-bridge"
cp -a "$TPL" "$T/no-bridge"
sed -i 's/window\.lavish/window.nothing/g' "$T/no-bridge/template.html"
out=$(check_dir "$T/no-bridge" 2>&1) && fail "handlers without the Lavish guard passed" || pass "handlers without the Lavish guard fail"
echo "$out" | grep -q 'guard window.lavish' && pass "the failure names the missing guard" || fail "unclear reason: $out"

rm -rf "$T/no-colgroup"
cp -a "$TPL" "$T/no-colgroup"
sed -i 's|<colgroup>.*</colgroup>||' "$T/no-colgroup/template.html"
out=$(check_dir "$T/no-colgroup" 2>&1) && fail "tables without column widths passed" || pass "tables without column widths fail"
echo "$out" | grep -q 'colgroup' && pass "the failure names the missing colgroup" || fail "unclear reason: $out"

rm -rf "$T/no-badge-wrap"
cp -a "$TPL" "$T/no-badge-wrap"
perl -0pi -e 's/td > \.badge \{[^}]*\}/td > .badge { vertical-align: top; margin-top: .15rem; }/' "$T/no-badge-wrap/template.html"
out=$(check_dir "$T/no-badge-wrap" 2>&1) && fail "a template without the cell-badge wrap rule passed" || pass "a template without the cell-badge wrap rule fails"
echo "$out" | grep -q 'td > .badge lost its wrap declaration' && pass "the failure names the missing wrap declaration" || fail "unclear reason: $out"

rm -rf "$T/no-badge-override"
cp -a "$TPL" "$T/no-badge-override"
perl -0pi -e 's|(  td > \.badge \{[^}]*\}\n)|$1  td > .badge { white-space: nowrap; height: var(--size); }\n|' "$T/no-badge-override/template.html"
out=$(check_dir "$T/no-badge-override" 2>&1) && fail "a template with a second cell-badge rule passed" || pass "a template with a second cell-badge rule fails"
echo "$out" | grep -q 'expected exactly one td > .badge rule' && pass "the failure names the second rule" || fail "unclear reason: $out"

rm -rf "$T/no-trim"
cp -a "$TPL" "$T/no-trim"
sed -i '/@supports (text-box: trim-both cap alphabetic) {/,/^  }$/d' "$T/no-trim/template.html"
out=$(check_dir "$T/no-trim" 2>&1) && fail "a template without the cap-height trim passed" || pass "a template without the cap-height trim fails"
echo "$out" | grep -q 'no @supports block for the cap-height trim' && pass "the failure names the missing @supports block" || fail "unclear reason: $out"

rm -rf "$T/no-text-box"
cp -a "$TPL" "$T/no-text-box"
sed -i 's|\.badge { text-box: trim-both cap alphabetic; }|.badge { text-box: normal; }|' "$T/no-text-box/template.html"
out=$(check_dir "$T/no-text-box" 2>&1) && fail "an @supports block without its text-box declaration passed" || pass "an @supports block without its text-box declaration fails"
echo "$out" | grep -q 'lost its text-box declaration' && pass "the failure names the lost text-box declaration" || fail "unclear reason: $out"

rm -rf "$T/no-pill-height"
cp -a "$TPL" "$T/no-pill-height"
sed -i 's|\.badge-pill { height: 25px; }|.badge-pill { height: 24px; }|' "$T/no-pill-height/template.html"
out=$(check_dir "$T/no-pill-height" 2>&1) && fail "a template with an even header pill height passed" || pass "a template with an even header pill height fails"
echo "$out" | grep -q 'the header pill rule lost height: 25px' && pass "the failure names the lost pill height" || fail "unclear reason: $out"

rm -rf "$T/no-pill-class"
cp -a "$TPL" "$T/no-pill-class"
sed -i '0,/badge-outline badge-pill text-xs/s//badge-outline text-xs/' "$T/no-pill-class/template.html"
out=$(check_dir "$T/no-pill-class" 2>&1) && fail "a header pill without the pill class passed" || pass "a header pill without the pill class fails"
echo "$out" | grep -q 'expected badge-pill on the 3 header pills, found 2' && pass "the failure names the missing pill class" || fail "unclear reason: $out"

rm -rf "$T/pill-elsewhere"
cp -a "$TPL" "$T/pill-elsewhere"
sed -i '0,/badge-outline badge-pill text-xs/s//badge-outline text-xs/' "$T/pill-elsewhere/template.html"
sed -i 's|<span class="badge badge-error badge-xs">High</span>|<span class="badge badge-error badge-pill badge-xs">High</span>|' "$T/pill-elsewhere/template.html"
out=$(check_dir "$T/pill-elsewhere" 2>&1) && fail "a copy with badge-pill moved to a table pill passed" || pass "a table pill's badge-pill does not stand in for a header pill"
echo "$out" | grep -q 'expected badge-pill on the 3 header pills, found 2' && pass "the failure counts the header row only" || fail "unclear reason: $out"

rm -rf "$T/no-id-mono"
cp -a "$TPL" "$T/no-id-mono"
sed -i 's|badge-pill font-mono text-xs">kp-000-example-task|badge-pill text-xs">kp-000-example-task|' "$T/no-id-mono/template.html"
out=$(check_dir "$T/no-id-mono" 2>&1) && fail "a task id pill without the mono face passed" || pass "a task id pill without the mono face fails"
echo "$out" | grep -q 'the task id pill lost its mono face' && pass "the failure names the id pill's mono face" || fail "unclear reason: $out"

rm -rf "$T/status-mono"
cp -a "$TPL" "$T/status-mono"
sed -i 's|badge-pill font-semibold text-xs">READY FOR REVIEW|badge-pill font-mono font-semibold text-xs">READY FOR REVIEW|' "$T/status-mono/template.html"
out=$(check_dir "$T/status-mono" 2>&1) && fail "a mono status pill passed" || pass "a mono status pill fails"
echo "$out" | grep -q 'the status pill still uses the mono face' && pass "the failure names the mono status pill" || fail "unclear reason: $out"

rm -rf "$T/shared-drift"
cp -a "$TPL" "$T/shared-drift"
sed -i 's|td, th { line-height: 1.25rem; }|td, th { line-height: 1.5rem; }|' "$T/shared-drift/template.html"
out=$(check_dir "$T/shared-drift" 2>&1) && fail "a template whose shared style drifted passed" || pass "a template whose shared style drifted fails"
echo "$out" | grep -q 'the shared style block drifted between the two templates' && pass "the failure names the style drift" || fail "unclear reason: $out"

rm -rf "$T/unslop"
cp -a "$TPL" "$T/unslop"
sed -i 's/Run the unslop skill/Skip the prose pass/' "$T/unslop/template.html"
out=$(check_dir "$T/unslop" 2>&1) && fail "a worker template how-to without the unslop step passed" || pass "a worker template how-to without the unslop step fails"
echo "$out" | grep -q 'unslop skill' && pass "the failure names the unslop step" || fail "unclear reason: $out"

echo "=== the handover check fails on a broken copy ==="
cp -a "$TPL" "$T/h-good"
check_handover "$T/h-good" >/dev/null 2>&1 && pass "a pristine handover copy passes" || fail "a pristine handover copy was rejected"

cp -a "$TPL" "$T/h-none"
rm "$T/h-none/handover.html"
out=$(check_handover "$T/h-none" 2>&1) && fail "a copy without handover.html passed" || pass "a missing handover.html fails"
echo "$out" | grep -q 'missing or empty: handover.html' && pass "the failure names the missing page" || fail "unclear reason: $out"

for sec in 'Risks' 'Decisions' 'How It Would Work'; do
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

rm -rf "$T/h-badge-wrap"
cp -a "$TPL" "$T/h-badge-wrap"
perl -0pi -e 's/td > \.badge \{[^}]*\}/td > .badge { vertical-align: top; margin-top: .15rem; }/' "$T/h-badge-wrap/handover.html"
out=$(check_handover "$T/h-badge-wrap" 2>&1) && fail "a handover template without the cell-badge wrap rule passed" || pass "a handover template without the cell-badge wrap rule fails"
echo "$out" | grep -q 'td > .badge lost its wrap declaration' && pass "the failure names the missing wrap declaration" || fail "unclear reason: $out"

rm -rf "$T/h-badge-override"
cp -a "$TPL" "$T/h-badge-override"
perl -0pi -e 's|(  td > \.badge \{[^}]*\}\n)|$1  td > .badge { white-space: nowrap; height: var(--size); }\n|' "$T/h-badge-override/handover.html"
out=$(check_handover "$T/h-badge-override" 2>&1) && fail "a handover template with a second cell-badge rule passed" || pass "a handover template with a second cell-badge rule fails"
echo "$out" | grep -q 'expected exactly one td > .badge rule' && pass "the failure names the second rule" || fail "unclear reason: $out"

rm -rf "$T/h-no-trim"
cp -a "$TPL" "$T/h-no-trim"
sed -i '/@supports (text-box: trim-both cap alphabetic) {/,/^  }$/d' "$T/h-no-trim/handover.html"
out=$(check_handover "$T/h-no-trim" 2>&1) && fail "a handover template without the cap-height trim passed" || pass "a handover template without the cap-height trim fails"
echo "$out" | grep -q 'no @supports block for the cap-height trim' && pass "the handover failure names the missing @supports block" || fail "unclear reason: $out"

rm -rf "$T/h-no-pill-height"
cp -a "$TPL" "$T/h-no-pill-height"
sed -i 's|\.badge-pill { height: 25px; }|.badge-pill { height: 24px; }|' "$T/h-no-pill-height/handover.html"
out=$(check_handover "$T/h-no-pill-height" 2>&1) && fail "a handover template with an even header pill height passed" || pass "a handover template with an even header pill height fails"
echo "$out" | grep -q 'the header pill rule lost height: 25px' && pass "the handover failure names the lost pill height" || fail "unclear reason: $out"

rm -rf "$T/h-kind-mono"
cp -a "$TPL" "$T/h-kind-mono"
sed -i 's|badge badge-primary badge-pill text-xs">PROPOSAL|badge badge-primary badge-pill font-mono text-xs">PROPOSAL|' "$T/h-kind-mono/handover.html"
out=$(check_handover "$T/h-kind-mono" 2>&1) && fail "a handover template with a mono kind pill passed" || pass "a handover template with a mono kind pill fails"
echo "$out" | grep -q 'the kind pill still uses the mono face' && pass "the failure names the mono kind pill" || fail "unclear reason: $out"

rm -rf "$T/h-status-mono"
cp -a "$TPL" "$T/h-status-mono"
sed -i 's|badge-warning badge-pill font-semibold text-xs">DECISION NEEDED|badge-warning badge-pill font-mono font-semibold text-xs">DECISION NEEDED|' "$T/h-status-mono/handover.html"
out=$(check_handover "$T/h-status-mono" 2>&1) && fail "a handover template with a mono status pill passed" || pass "a handover template with a mono status pill fails"
echo "$out" | grep -q 'the status pill still uses the mono face' && pass "the handover failure names the mono status pill" || fail "unclear reason: $out"

rm -rf "$T/h-no-option-title"
cp -a "$TPL" "$T/h-no-option-title"
sed -i '0,/class="text-sm font-semibold text-white">A: Do nothing/s//class="text-sm text-gray-200">A: Do nothing/' "$T/h-no-option-title/handover.html"
out=$(check_handover "$T/h-no-option-title" 2>&1) && fail "an option row without its bold title passed" || pass "an option row without its bold title fails"
echo "$out" | grep -q 'an option row has no bold title (8 of 9)' && pass "the failure names the option row without a title" || fail "unclear reason: $out"

rm -rf "$T/h-badge-order"
cp -a "$TPL" "$T/h-badge-order"
sed -i 's|<span class="badge badge-outline badge-sm">Option B</span> <span class="badge badge-success badge-sm">RECOMMENDED</span>|<span class="badge badge-success badge-sm">RECOMMENDED</span> <span class="badge badge-outline badge-sm">Option B</span>|' "$T/h-badge-order/handover.html"
out=$(check_handover "$T/h-badge-order" 2>&1) && fail "an option card with the state pill first passed" || pass "an option card with the state pill first fails"
echo "$out" | grep -q 'the state pill leads the option label' && pass "the failure names the badge order" || fail "unclear reason: $out"

rm -rf "$T/h-annot"
cp -a "$TPL" "$T/h-annot"
sed -i 's|data-lavish-annotate="off"|data-lavish-annotate="on"|' "$T/h-annot/handover.html"
out=$(check_handover "$T/h-annot" 2>&1) && fail "a decision page that starts annotation on passed" || pass "a decision page that starts annotation on fails"

rm -rf "$T/h-sloppy"
cp -a "$TPL" "$T/h-sloppy"
printf '<p>A seamless change — in order to ship it.</p>\n' >> "$T/h-sloppy/handover.html"
out=$(check_handover "$T/h-sloppy" 2>&1) && fail "a handover prose regression passed" || pass "a handover prose regression fails"
echo "$out" | grep -q 'fails the diff or prose check' && pass "the failure names the check" || fail "unclear reason: $out"

rm -rf "$T/h-unslop"
cp -a "$TPL" "$T/h-unslop"
sed -i 's/Run the unslop skill/Skip the prose pass/' "$T/h-unslop/handover.html"
out=$(check_handover "$T/h-unslop" 2>&1) && fail "a handover how-to without the unslop step passed" || pass "a handover how-to without the unslop step fails"
echo "$out" | grep -q 'unslop skill' && pass "the failure names the unslop step" || fail "unclear reason: $out"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL WORKER-DOSSIER-TEMPLATE TESTS PASSED"
else
  echo "WORKER-DOSSIER-TEMPLATE TESTS FAILED"
  exit 1
fi
