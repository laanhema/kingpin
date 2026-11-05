#!/usr/bin/env bash
# Verification test for Kingpin: kingpin sync.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "sync"
kp_test_project

kp_test_stub_lavish

# Test 21: kingpin sync fast-forwards the main checkout, never discards anything
# ---------------------------------------------------------------------------
echo "--- Test 21: kingpin sync ---"
t21="$T/t21"
mkdir -p "$t21"
git init -q --bare "$t21/origin.git"
git clone -q "$t21/origin.git" "$t21/main" 2>/dev/null
git clone -q "$t21/origin.git" "$t21/other" 2>/dev/null
for d in main other; do
  git -C "$t21/$d" config user.email t@t
  git -C "$t21/$d" config user.name t
done
(
  cd "$t21/main"
  git checkout -q -b main
  echo one > f.txt
  printf 'ignored.log\n' > .gitignore
  git add f.txt .gitignore
  git commit -qm "first"
  git push -q -u origin main
)
git -C "$t21/other" fetch -q origin
git -C "$t21/other" checkout -q -b main origin/main
t21_push() { # <message>: commit from the second clone and push
  (cd "$t21/other" && git pull -q --ff-only origin main && echo "$1" >> f.txt && git commit -qam "$1" && git push -q origin main)
}
t21_sync() { # run kingpin sync in $1; sets t21_out, t21_err, t21_rc
  t21_rc=0
  t21_out=$(cd "$1" && "$KP_BIN/kingpin" sync 2>"$t21/err") || t21_rc=$?
  t21_err=$(cat "$t21/err")
}

t21_sync "$t21/main"
[ "$t21_rc" -eq 0 ] && [ "$t21_out" = "already up to date" ] && pass "t21: up to date prints 'already up to date'" || fail "t21: up-to-date rc=$t21_rc out=$t21_out err=$t21_err"

t21_push "second"
t21_push "third"
t21_old=$(git -C "$t21/main" rev-parse --short HEAD)
t21_new_full=$(git -C "$t21/other" rev-parse HEAD)
t21_sync "$t21/main"
t21_new=$(git -C "$t21/main" rev-parse --short HEAD)
if [ "$t21_rc" -eq 0 ] && [ "$(git -C "$t21/main" rev-parse HEAD)" = "$t21_new_full" ] \
   && echo "$t21_out" | grep -q "$t21_old\.\.$t21_new" \
   && echo "$t21_out" | grep -q " second$" && echo "$t21_out" | grep -q " third$" && ! echo "$t21_out" | grep -q " first$"; then
  pass "t21: success pulls the commits and prints old/new SHAs and the log"
else
  fail "t21: success rc=$t21_rc out=$t21_out err=$t21_err"
fi

t21_push "fourth"
echo "local edit" >> "$t21/main/f.txt"
t21_head=$(git -C "$t21/main" rev-parse HEAD)
t21_sync "$t21/main"
if [ "$t21_rc" -ne 0 ] \
   && echo "$t21_err" | grep -qF 'working tree is dirty; commit or remove the changes first (nothing was changed)' \
   && [ "$(git -C "$t21/main" rev-parse HEAD)" = "$t21_head" ] && grep -q "local edit" "$t21/main/f.txt"; then
  pass "t21: dirty tracked change is refused and left untouched"
else
  fail "t21: tracked change: rc=$t21_rc out=$t21_out err=$t21_err"
fi
git -C "$t21/main" checkout -q -- f.txt

echo noise > "$t21/main/ignored.log"
t21_sync "$t21/main"
[ "$t21_rc" -eq 0 ] && echo "$t21_out" | grep -q " fourth$" && [ -f "$t21/main/ignored.log" ] && pass "t21: ignored file does not block the sync" || fail "t21: ignored rc=$t21_rc out=$t21_out err=$t21_err"

# An untracked handover page is not a dirty tree: AGENTS.md tells the orchestrator
# to keep it in `.lavish/`, and the sync must leave it in place so the open Lavish
# tab keeps resolving (issue #121).
t21_push "lavish"
mkdir -p "$t21/main/.lavish"
printf '<html>page</html>\n' > "$t21/main/.lavish/page.html"
t21_sync "$t21/main"
if [ "$t21_rc" -eq 0 ] && echo "$t21_out" | grep -q " lavish$" \
   && [ "$(cat "$t21/main/.lavish/page.html")" = "<html>page</html>" ]; then
  pass "t21: untracked .lavish artifact does not block the sync and survives"
else
  fail "t21: untracked .lavish artifact: rc=$t21_rc out=$t21_out err=$t21_err page=$(cat "$t21/main/.lavish/page.html" 2>/dev/null)"
fi

# An untracked path the incoming tree would overwrite is a different condition:
# git aborts before writing, and the sync names the path it would not overwrite.
(cd "$t21/other" && git pull -q --ff-only origin main \
  && echo incoming > collide.txt && echo "incoming line" >> f.txt \
  && git add -A && git commit -qm "add collide.txt" && git push -q origin main)
echo local > "$t21/main/collide.txt"
t21_head=$(git -C "$t21/main" rev-parse HEAD)
t21_sync "$t21/main"
if [ "$t21_rc" -ne 0 ] \
   && echo "$t21_err" | grep -qF 'kingpin-sync: the incoming commits would overwrite these untracked paths: collide.txt; move or remove them first (nothing was changed)' \
   && ! echo "$t21_err" | grep -q "would be overwritten by merge" \
   && ! echo "$t21_err" | grep -q "dirty" \
   && [ "$(cat "$t21/main/collide.txt")" = "local" ] \
   && ! grep -q "incoming line" "$t21/main/f.txt" \
   && [ "$(git -C "$t21/main" rev-parse HEAD)" = "$t21_head" ] \
   && [ -z "$(git -C "$t21/main" status --porcelain --untracked-files=no)" ]; then
  pass "t21: untracked overwrite collision is refused with the path named and nothing applied"
else
  fail "t21: untracked overwrite collision: rc=$t21_rc err=$t21_err file=$(cat "$t21/main/collide.txt" 2>/dev/null) head=$(git -C "$t21/main" rev-parse --short HEAD)"
fi
rm -f "$t21/main/collide.txt"
t21_sync "$t21/main"
if [ "$t21_rc" -eq 0 ] && grep -q "incoming line" "$t21/main/f.txt"; then
  pass "t21: the same sync completes after the untracked collision is removed"
else
  fail "t21: collision cleanup: rc=$t21_rc out=$t21_out err=$t21_err"
fi

# A second collision shape: git prints one header per kind of loss, so a directory
# that would be replaced by an incoming file is listed before the file list, past a
# blank line. Every path in both lists has to be named in the sync's own line.
(cd "$t21/other" && git pull -q --ff-only origin main \
  && echo incoming > df.txt && echo incoming > sub.txt \
  && git add -A && git commit -qm "add df.txt and sub.txt" && git push -q origin main)
mkdir -p "$t21/main/df.txt" && echo keep > "$t21/main/df.txt/keep.txt"
echo local > "$t21/main/sub.txt"
t21_head=$(git -C "$t21/main" rev-parse HEAD)
t21_sync "$t21/main"
t21_named=$(echo "$t21_err" | grep -F 'kingpin-sync: the incoming commits would overwrite these untracked paths:' || true)
if [ "$t21_rc" -ne 0 ] && [ -n "$t21_named" ] \
   && echo "$t21_named" | grep -qF "df.txt" && echo "$t21_named" | grep -qF "sub.txt" \
   && ! echo "$t21_err" | grep -q "would be overwritten by merge" \
   && [ "$(cat "$t21/main/df.txt/keep.txt")" = "keep" ] \
   && [ "$(cat "$t21/main/sub.txt")" = "local" ] \
   && [ "$(git -C "$t21/main" rev-parse HEAD)" = "$t21_head" ]; then
  pass "t21: directory-replacement collision is refused with every path named and nothing applied"
else
  fail "t21: directory collision: rc=$t21_rc err=$t21_err df=$(ls "$t21/main/df.txt" 2>/dev/null) sub=$(cat "$t21/main/sub.txt" 2>/dev/null)"
fi
rm -rf "$t21/main/df.txt" "$t21/main/sub.txt"
t21_sync "$t21/main"
if [ "$t21_rc" -eq 0 ] && [ "$(cat "$t21/main/df.txt")" = "incoming" ] && [ -f "$t21/main/sub.txt" ]; then
  pass "t21: the same sync completes after both collision shapes are removed"
else
  fail "t21: directory collision cleanup: rc=$t21_rc out=$t21_out err=$t21_err"
fi

# Non-fast-forward: a local commit and a different remote commit.
(cd "$t21/main" && echo local >> f.txt && git commit -qam "local only")
t21_push "fifth"
t21_head=$(git -C "$t21/main" rev-parse HEAD)
t21_sync "$t21/main"
if [ "$t21_rc" -ne 0 ] && echo "$t21_err" | grep -q "cannot fast-forward" && [ "$(git -C "$t21/main" rev-parse HEAD)" = "$t21_head" ] && [ -z "$(git -C "$t21/main" status --porcelain --untracked-files=no)" ]; then
  pass "t21: non-fast-forward is refused without touching HEAD or the tree"
else
  fail "t21: non-ff rc=$t21_rc err=$t21_err"
fi

git -C "$t21/main" worktree add -q -b t21-wt "$t21/wt" HEAD
t21_sync "$t21/wt"
[ "$t21_rc" -ne 0 ] && echo "$t21_err" | grep -q "linked worktree" && pass "t21: linked worktree is refused" || fail "t21: worktree rc=$t21_rc err=$t21_err"

git -C "$t21/main" checkout -q -b t21-noup
t21_sync "$t21/main"
[ "$t21_rc" -ne 0 ] && echo "$t21_err" | grep -q "no upstream" && pass "t21: branch without upstream is refused" || fail "t21: no-upstream rc=$t21_rc err=$t21_err"

t21_sync "$t21"
[ "$t21_rc" -ne 0 ] && echo "$t21_err" | grep -q "not a git repository" && pass "t21: non-repo directory is refused" || fail "t21: non-repo rc=$t21_rc err=$t21_err"

t21_rc=0
t21_out=$("$KP_BIN/kingpin" sync --help 2>&1) || t21_rc=$?
[ "$t21_rc" -eq 0 ] && echo "$t21_out" | grep -q "usage: kingpin-sync" && pass "t21: --help exits 0 with usage" || fail "t21: --help rc=$t21_rc out=$t21_out"

t21_rc=0
(cd "$t21/main" && "$KP_BIN/kingpin" sync --bogus >/dev/null 2>&1) || t21_rc=$?
[ "$t21_rc" -eq 2 ] && pass "t21: unknown argument exits 2" || fail "t21: unknown arg rc=$t21_rc"

# usage() is the one place a command is described (issue #178), so the help output is the
# only surface to assert; the hand-kept file-header list it used to duplicate is gone.
"$KP_BIN/kingpin" --help | grep -q "^  sync " && pass "t21: sync is in the kingpin help" || fail "t21: sync missing from the kingpin help"

rm -rf "$t21"

kp_test_finish SYNC
