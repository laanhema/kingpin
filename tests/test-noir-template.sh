#!/usr/bin/env bash
# noir dossier template: the three files ship together, every ref stays inside the folder, the
# diffs keep a static fallback and the prose is clean.
#
# The page in assets/lavish/noir-dossier/ is what handover artifacts are copied from, so a missing
# file, an absolute or escaping ref, a diff with no fallback or a prose regression there spreads to
# every artifact made from it.
set -euo pipefail

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KP_BIN="$KP_ROOT/bin"
TPL="$KP_ROOT/assets/lavish/noir-dossier"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# check_dir <dir>: 0 when the folder is a complete, self-contained, gate-clean template.
# Prints the reason on stderr when it is not, so a negative case explains itself.
check_dir() {
  local dir=$1 f ref forms queues handlers surfaces fallbacks
  for f in template.html kingpin.jpg DESIGN.md; do
    [ -s "$dir/$f" ] || { echo "missing or empty: $f" >&2; return 1; }
  done
  grep -q '<section' "$dir/template.html" || { echo "template.html has no sections" >&2; return 1; }
  # The status palette is the only way a verification row reads pass, warn or fail, so a copy that
  # loses a token or a chip class has lost the semantic layer this template exists to carry.
  local status tok
  for tok in --pass --warn --fail; do
    grep -q -- "$tok:" "$dir/template.html" || { echo "status token missing: $tok" >&2; return 1; }
  done
  for status in pass warn fail; do
    grep -q "\.chip\.$status" "$dir/template.html" || { echo "chip class missing: .chip.$status" >&2; return 1; }
  done
  # No local absolute path, no ref that climbs out of the folder, and every relative src/href
  # resolves beside the page. The template is copied as a folder, so a ref through `..` breaks
  # every artifact made from it.
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
    grep -o 'src="[^"]*"' "$dir/template.html" | sed 's/^src="//; s/"$//'
    grep -o 'href="[^"]*"' "$dir/template.html" | sed 's/^href="//; s/"$//'
  )
  # The banner is the file beside the page, never an absolute or home path.
  grep -q 'src="kingpin.jpg"' "$dir/template.html" || { echo "banner is not a relative kingpin.jpg" >&2; return 1; }
  [ -s "$dir/kingpin.jpg" ] || { echo "banner image is empty" >&2; return 1; }
  [ "$(head -c 3 "$dir/kingpin.jpg" | od -An -tx1 | tr -d ' \n')" = ffd8ff ] || { echo "kingpin.jpg is not a JPEG" >&2; return 1; }
  # Every decision form keeps a handler, and a handler queues a prompt.
  forms=$(grep -c 'data-lavish-question=' "$dir/template.html" || true)
  [ "$forms" -ge 2 ] || { echo "expected at least 2 decision forms, found $forms" >&2; return 1; }
  handlers=$(grep -c '<form class="q"[^>]*data-lavish-question="[^"]*"[^>]*onsubmit="[a-zA-Z]*(' "$dir/template.html" || true)
  [ "$handlers" -eq "$forms" ] || { echo "a decision form lost its onsubmit handler ($handlers of $forms)" >&2; return 1; }
  queues=$(grep -c 'queuePrompt(' "$dir/template.html" || true)
  [ "$queues" -ge "$forms" ] || { echo "a handler no longer calls queuePrompt ($queues for $forms forms)" >&2; return 1; }
  # A copy opened as a plain file has no Lavish bridge: the handlers must say so, not throw.
  grep -q 'window\.lavish' "$dir/template.html" || { echo "the queue handlers no longer guard window.lavish" >&2; return 1; }
  grep -q 'Paste this answer into chat' "$dir/template.html" || { echo "a copy opened without Lavish has no fallback message" >&2; return 1; }
  # Each diff surface carries a static copy of its diff for when the renderer cannot load.
  surfaces=$(grep -c 'class="diff-surface"' "$dir/template.html" || true)
  fallbacks=$(grep -c 'class="diff-fallback"' "$dir/template.html" || true)
  [ "$surfaces" -ge 1 ] && [ "$fallbacks" -eq "$surfaces" ] || { echo "a diff surface has no static fallback ($fallbacks for $surfaces surfaces)" >&2; return 1; }
  # The gate every copied artifact inherits: renderable diffs and clean prose.
  "$KP_BIN/kingpin-report" check "$dir/template.html" >/dev/null || { echo "template.html fails the diff or prose check" >&2; return 1; }
  "$KP_BIN/kingpin-report" check --prose-only "$dir/DESIGN.md" >/dev/null || { echo "DESIGN.md fails the prose check" >&2; return 1; }
  return 0
}

echo "=== the vendored template ==="
[ -d "$TPL" ] && pass "assets/lavish/noir-dossier/ exists" || fail "assets/lavish/noir-dossier/ is missing"
for f in template.html kingpin.jpg DESIGN.md; do
  [ -s "$TPL/$f" ] && pass "$f ships with the template" || fail "$f is missing or empty"
done
[ -s "$TPL/kingpin.jpg" ] && cmp -s "$TPL/kingpin.jpg" "$KP_ROOT/assets/kingpin.jpg" && pass "banner is the repo image, copied beside the page" || fail "banner is not a copy of assets/kingpin.jpg"
for tok in --pass --warn --fail; do
  grep -q -- "$tok:" "$TPL/template.html" && pass "template.html defines $tok" || fail "template.html does not define $tok"
done
for status in pass warn fail; do
  grep -q "\.chip\.$status" "$TPL/template.html" && pass "template.html defines .chip.$status" || fail "template.html does not define .chip.$status"
done
out=$(check_dir "$TPL" 2>&1) && pass "the template is complete, relative and gate-clean" || fail "the template does not check out: $out"

echo "=== the check fails on a broken copy ==="
cp -a "$TPL" "$T/good"
check_dir "$T/good" >/dev/null 2>&1 && pass "a pristine copy passes" || fail "a pristine copy was rejected"

cp -a "$TPL" "$T/no-design"
rm "$T/no-design/DESIGN.md"
out=$(check_dir "$T/no-design" 2>&1) && fail "a copy without DESIGN.md passed" || pass "a missing DESIGN.md fails"
echo "$out" | grep -q 'missing or empty: DESIGN.md' && pass "the failure names the missing file" || fail "unclear reason: $out"

cp -a "$TPL" "$T/no-token"
sed -i '/--warn:/d' "$T/no-token/template.html"
out=$(check_dir "$T/no-token" 2>&1) && fail "a copy without the warn token passed" || pass "a missing status token fails"
echo "$out" | grep -q 'status token missing: --warn' && pass "the failure names the missing token" || fail "unclear reason: $out"

cp -a "$TPL" "$T/no-banner"
rm "$T/no-banner/kingpin.jpg"
out=$(check_dir "$T/no-banner" 2>&1) && fail "a copy without kingpin.jpg passed" || pass "a missing banner image fails"
echo "$out" | grep -q 'missing or empty: kingpin.jpg' && pass "the failure names the missing banner" || fail "unclear reason: $out"

cp -a "$TPL" "$T/no-html"
rm "$T/no-html/template.html"
out=$(check_dir "$T/no-html" 2>&1) && fail "a copy without template.html passed" || pass "a missing template.html fails"
echo "$out" | grep -q 'missing or empty: template.html' && pass "the failure names the missing page" || fail "unclear reason: $out"

# shellcheck disable=SC2088 # the tilde is literal: it is the HTML src path under test, not a shell expansion
for bad in '/home/lauri/kingpin.jpg' '~/kingpin.jpg' 'file:///tmp/kingpin.jpg' 'C:/kingpin.jpg'; do
  rm -rf "$T/abs"
  cp -a "$TPL" "$T/abs"
  sed -i "s|src=\"kingpin.jpg\"|src=\"$bad\"|" "$T/abs/template.html"
  out=$(check_dir "$T/abs" 2>&1) && fail "an absolute banner path passed: $bad" || pass "an absolute banner path fails: $bad"
  echo "$out" | grep -q 'absolute path' && pass "the failure names the absolute path: $bad" || fail "unclear reason for $bad: $out"
done

rm -rf "$T/sloppy"
cp -a "$TPL" "$T/sloppy"
printf '<p>A seamless change — in order to ship it.</p>\n' >> "$T/sloppy/template.html"
out=$(check_dir "$T/sloppy" 2>&1) && fail "a prose regression passed" || pass "a prose regression fails"
echo "$out" | grep -q 'fails the diff or prose check' && pass "the failure names the check" || fail "unclear reason: $out"

rm -rf "$T/no-diff-args"
cp -a "$TPL" "$T/no-diff-args"
sed -i 's/oldFile: before, newFile: after/oldFile: before/' "$T/no-diff-args/template.html"
out=$(check_dir "$T/no-diff-args" 2>&1) && fail "a FileDiff call without oldFile/newFile passed" || pass "a FileDiff call without oldFile/newFile fails"
echo "$out" | grep -q 'fails the diff or prose check' && pass "the failure names the diff check" || fail "unclear reason: $out"

rm -rf "$T/climb"
mkdir -p "$T/climb/sub"
cp -a "$TPL/." "$T/climb/sub/"
cp "$TPL/kingpin.jpg" "$T/climb/kingpin.jpg"
sed -i 's|src="kingpin.jpg"|src="../kingpin.jpg"|' "$T/climb/sub/template.html"
out=$(check_dir "$T/climb/sub" 2>&1) && fail "a src that climbs out of the folder passed" || pass "a src that climbs out of the folder fails"
echo "$out" | grep -q 'climbs out of the folder' && pass "the failure names the escaping ref" || fail "unclear reason: $out"

rm -rf "$T/bad-href"
cp -a "$TPL" "$T/bad-href"
sed -i 's|href="https://github.com/laanhema/kingpin"|href="missing.html"|' "$T/bad-href/template.html"
out=$(check_dir "$T/bad-href" 2>&1) && fail "a relative href to a missing file passed" || pass "a relative href to a missing file fails"
echo "$out" | grep -q 'missing asset: missing.html' && pass "the failure names the missing href target" || fail "unclear reason: $out"

rm -rf "$T/no-fallback"
cp -a "$TPL" "$T/no-fallback"
sed -i '/<pre class="diff-fallback">/,/<\/pre>/d' "$T/no-fallback/template.html"
out=$(check_dir "$T/no-fallback" 2>&1) && fail "a diff surface without its static fallback passed" || pass "a diff surface without its static fallback fails"
echo "$out" | grep -q 'no static fallback' && pass "the failure names the missing fallback" || fail "unclear reason: $out"

rm -rf "$T/no-bridge"
cp -a "$TPL" "$T/no-bridge"
sed -i '/if (!hasLavish()) {/,/^    }$/d' "$T/no-bridge/template.html"
out=$(check_dir "$T/no-bridge" 2>&1) && fail "a handler without the Lavish guard passed" || pass "a handler without the Lavish guard fails"
echo "$out" | grep -q 'no fallback message' && pass "the failure names the missing no-bridge message" || fail "unclear reason: $out"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL NOIR-TEMPLATE TESTS PASSED"
else
  echo "NOIR-TEMPLATE TESTS FAILED"
  exit 1
fi
