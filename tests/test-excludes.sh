#!/usr/bin/env bash
# Verification test for Kingpin: a spawn and a done never write the main checkout's
# .git/info/exclude, while the harness files a spawn injects still stay out of the
# leased worktree's git status (issue #77).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "excludes"
kp_test_project

export KINGPIN_CLAUDE=$T/fake-worker
export KINGPIN_OPENCODE=$T/fake-worker

# Keep the harness config directories inside the scratch tree, so a developer's own
# global instruction files cannot decide this suite's result.
export XDG_CONFIG_HOME=$T/xdg
mkdir -p "$XDG_CONFIG_HOME"

proj_excl=$(git -C "$T/proj" rev-parse --path-format=absolute --git-path info/exclude)
printf '# a line the user wrote\nmy-notes.txt\n' >> "$proj_excl"
cp -p "$proj_excl" "$T/exclude.user"

# The worktree-side ignore file a spawn points the harness files at.
task_exclude_of() { printf '%s/tasks/%s/exclude' "$KINGPIN_HOME" "$1"; }

echo "=== Test 1: agy spawn leaves the main checkout's exclude byte-identical ==="
"$KP_BIN/kingpin-spawn" demo-auto --issue 901 --id excl-agy --harness agy >/dev/null
cmp -s "$proj_excl" "$T/exclude.user" && pass "agy spawn left the main checkout's .git/info/exclude byte-identical" \
  || { fail "agy spawn rewrote the main checkout's .git/info/exclude"; diff -u "$T/exclude.user" "$proj_excl" || true; }

wt_agy=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-agy/task.env" || true)
[ -n "$wt_agy" ] && pass "agy spawn recorded its worktree" || fail "agy spawn recorded no worktree"
agy_excl=$(git -C "${wt_agy:-/nonexistent}" config --get --worktree core.excludesFile 2>/dev/null || true)
[ "$agy_excl" = "$(task_exclude_of excl-agy)" ] && pass "the agy worktree reads its own exclude file" \
  || fail "the agy worktree reads '${agy_excl:-nothing}' as core.excludesFile"
for rel in .agents/hooks.json .agents/rules/kingpin.md; do
  git -C "${wt_agy:-/nonexistent}" check-ignore -v "$rel" 2>/dev/null | grep -qF "$(task_exclude_of excl-agy)" \
    && pass "the agy worktree ignores $rel through the task's exclude file" \
    || fail "the agy worktree does not ignore $rel through the task's exclude file"
done
[ -z "$(git -C "${wt_agy:-/nonexistent}" status --porcelain 2>/dev/null)" ] && pass "the agy worktree has no untracked harness files" \
  || fail "the agy worktree reports harness files: $(git -C "${wt_agy:-/nonexistent}" status --porcelain 2>/dev/null)"
touch "${wt_agy:-/nonexistent}/.agents/PRD.md"
git -C "${wt_agy:-/nonexistent}" status --porcelain -u 2>/dev/null | grep -q '\.agents/PRD\.md' \
  && pass "a worker's own .agents/PRD.md stays visible in the agy worktree" \
  || fail "the agy exclude hides a worker's own .agents file"
rm -f "${wt_agy:-/nonexistent}/.agents/PRD.md"
! git -C "$T/proj" check-ignore -q .agents/hooks.json 2>/dev/null && pass "the main checkout did not inherit the task's exclude" \
  || fail "the main checkout ignores .agents/hooks.json after the spawn"

echo "=== Test 2: opencode spawn leaves the main checkout's exclude byte-identical ==="
"$KP_BIN/kingpin-spawn" demo-auto --issue 902 --id excl-oc --harness opencode >/dev/null
cmp -s "$proj_excl" "$T/exclude.user" && pass "opencode spawn left the main checkout's .git/info/exclude byte-identical" \
  || { fail "opencode spawn rewrote the main checkout's .git/info/exclude"; diff -u "$T/exclude.user" "$proj_excl" || true; }

wt_oc=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-oc/task.env" || true)
for rel in .opencode/opencode.json .opencode/plugins/package.json .opencode/plugins/kingpin-stop.js; do
  git -C "${wt_oc:-/nonexistent}" check-ignore -v "$rel" 2>/dev/null | grep -qF "$(task_exclude_of excl-oc)" \
    && pass "the opencode worktree ignores $rel through the task's exclude file" \
    || fail "the opencode worktree does not ignore $rel through the task's exclude file"
done
[ -z "$(git -C "${wt_oc:-/nonexistent}" status --porcelain 2>/dev/null)" ] && pass "the opencode worktree has no untracked harness files" \
  || fail "the opencode worktree reports harness files: $(git -C "${wt_oc:-/nonexistent}" status --porcelain 2>/dev/null)"
touch "${wt_oc:-/nonexistent}/.opencode/notes.txt"
git -C "${wt_oc:-/nonexistent}" status --porcelain -u 2>/dev/null | grep -q '\.opencode/notes\.txt' \
  && pass "a worker's own .opencode/notes.txt stays visible in the opencode worktree" \
  || fail "the opencode exclude hides a worker's own file"
rm -f "${wt_oc:-/nonexistent}/.opencode/notes.txt"

echo "=== Test 3: a broad Kingpin-shaped line the user wrote survives a spawn ==="
printf '.agents/\n' >> "$proj_excl"
cp -p "$proj_excl" "$T/exclude.broad"
spawn_err=$("$KP_BIN/kingpin-spawn" demo-auto --issue 903 --id excl-broad --harness agy 2>&1 >/dev/null)
cmp -s "$proj_excl" "$T/exclude.broad" && pass "a spawn kept the user's own .agents/ line instead of deleting it" \
  || { fail "a spawn deleted the user's own .agents/ line"; diff -u "$T/exclude.broad" "$proj_excl" || true; }
echo "$spawn_err" | grep -qF "$proj_excl" && pass "the spawn names the broad line it will not touch" \
  || fail "the spawn said nothing about the broad line in $proj_excl"

echo "=== Test 4: the ignore file the worktree would inherit is mirrored, not dropped ==="
# A worktree-scoped core.excludesFile replaces the file git would otherwise read, so a
# pattern the project hides must survive in the task's exclude file (the Risk this fix
# takes on: a worker that started seeing those paths would dirty its tree, and
# kingpin done refuses a dirty tree).
printf 'project-ignore.log\n' > "$T/project-ignore"
git -C "$T/proj" config core.excludesFile "$T/project-ignore"
"$KP_BIN/kingpin-spawn" demo-auto --issue 904 --id excl-mirror --harness agy >/dev/null
wt_mirror=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-mirror/task.env" || true)
grep -qx 'project-ignore\.log' "$(task_exclude_of excl-mirror)" 2>/dev/null \
  && pass "the task's exclude file mirrors the project's own ignore file" \
  || fail "the task's exclude file dropped the project's own ignore file"
git -C "${wt_mirror:-/nonexistent}" check-ignore -v project-ignore.log 2>/dev/null | grep -qF "$(task_exclude_of excl-mirror)" \
  && pass "the worktree still ignores a path the project's own ignore file hides" \
  || fail "the worktree stopped ignoring a path the project's own ignore file hides"
[ -z "$(git -C "${wt_mirror:-/nonexistent}" status --porcelain 2>/dev/null)" ] \
  && pass "the mirroring worktree is clean" || fail "the mirroring worktree is dirty"
git -C "$T/proj" config --unset core.excludesFile

echo "=== Test 5: kingpin done leaves no Kingpin exclude entry behind ==="
for t in excl-agy excl-oc excl-broad excl-mirror; do
  "$KP_BIN/kingpin-done" "$t" --force >/dev/null 2>&1 || true
done
cmp -s "$proj_excl" "$T/exclude.broad" && pass "done left the main checkout's .git/info/exclude byte-identical" \
  || { fail "done rewrote the main checkout's .git/info/exclude"; diff -u "$T/exclude.broad" "$proj_excl" || true; }
for t in excl-agy excl-oc excl-broad excl-mirror; do
  [ ! -e "$(task_exclude_of "$t")" ] && pass "no Kingpin exclude file left in the live task folder of $t" \
    || fail "the live task folder of $t still carries its exclude file"
  [ ! -e "$KINGPIN_HOME/archive/$t/exclude" ] && pass "no Kingpin exclude file archived for $t" \
    || fail "the archived task folder of $t carries its exclude file"
done
[ -z "$(git -C "$T/proj" config --get core.excludesFile 2>/dev/null || true)" ] && pass "the main checkout has no Kingpin core.excludesFile" \
  || fail "the main checkout carries core.excludesFile=$(git -C "$T/proj" config --get core.excludesFile 2>/dev/null || true)"
for wt in "$wt_agy" "$wt_oc"; do
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  [ -z "$(git -C "$wt" config --get --worktree core.excludesFile 2>/dev/null || true)" ] \
    && pass "the returned worktree $wt no longer points at a Kingpin exclude file" \
    || fail "the returned worktree $wt still points at a Kingpin exclude file"
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null || true)" ] \
    && pass "the returned worktree $wt is clean for the next lease" \
    || fail "the returned worktree $wt still reports: $(git -C "$wt" status --porcelain 2>/dev/null | tr '\n' ' ')"
  [ ! -e "$wt/.agents/hooks.json" ] && [ ! -e "$wt/.opencode/opencode.json" ] \
    && pass "the returned worktree $wt carries no Kingpin harness file" \
    || fail "the returned worktree $wt still carries a Kingpin harness file"
done

echo "=== Test 6: a spawn that fails after injecting its files leaves the slot clean ==="
# The opencode branch writes its config, then kingpin-scope refuses the launch because a
# global instruction file carries the contract (issue #96). The failure trap must undo
# the injection before treehouse gets the slot back, or the next task inherits it.
mkdir -p "$XDG_CONFIG_HOME/opencode"
printf '# Kingpin\n\nYou are the underboss (the consigliere).\n' > "$XDG_CONFIG_HOME/opencode/AGENTS.md"
rc=0
spawn_err=$("$KP_BIN/kingpin-spawn" demo-auto --issue 906 --id excl-fail --harness opencode 2>&1 >/dev/null) || rc=$?
[ "$rc" -ne 0 ] && pass "a spawn that fails its instruction check exits nonzero" || fail "the failing spawn exited 0"
echo "$spawn_err" | grep -qF "$XDG_CONFIG_HOME/opencode/AGENTS.md" \
  && pass "the refusal names the global instruction file" || fail "the refusal does not name the global instruction file: $spawn_err"
[ ! -d "$KINGPIN_HOME/tasks/excl-fail" ] && pass "the failed spawn left no task folder" || fail "the failed spawn left a task folder"
cmp -s "$proj_excl" "$T/exclude.broad" && pass "the failed spawn left the main checkout's .git/info/exclude byte-identical" \
  || { fail "the failed spawn rewrote the main checkout's .git/info/exclude"; diff -u "$T/exclude.broad" "$proj_excl" || true; }
rm -f "$XDG_CONFIG_HOME/opencode/AGENTS.md"
slots=0
for slot in "$T"/pool/.treehouse/*/*/*; do
  [ -d "$slot" ] || continue
  slots=$((slots + 1))
  [ -z "$(git -C "$slot" config --get --worktree core.excludesFile 2>/dev/null || true)" ] \
    && pass "the leased slot $slot has no Kingpin exclude pointer after the failed spawn" \
    || fail "the leased slot $slot still points at a Kingpin exclude file"
  [ -z "$(git -C "$slot" status --porcelain 2>/dev/null || true)" ] \
    && pass "the leased slot $slot is clean after the failed spawn" \
    || fail "the leased slot $slot reports: $(git -C "$slot" status --porcelain 2>/dev/null | tr '\n' ' ')"
  leftovers=''
  for rel in .opencode/opencode.json .opencode/plugins/package.json \
             .opencode/plugins/kingpin-stop.js .agents/hooks.json .agents/rules/kingpin.md; do
    [ -e "$slot/$rel" ] && leftovers="$leftovers $rel"
  done
  [ -z "$leftovers" ] && pass "the leased slot $slot carries no Kingpin harness file after the failed spawn" \
    || fail "the leased slot $slot still carries:$leftovers"
done
[ "$slots" -gt 0 ] && pass "the suite inspected $slots leased slot(s)" || fail "no leased slot was found to inspect"

echo "=== Test 7: done never deletes an injected path the project tracks ==="
# The cleanup removes only what Kingpin injected and never a file the project owns: a
# tracked .agents/hooks.json survives even though the spawn overwrote it.
git init -q -b main "$T/tracked"
mkdir -p "$T/tracked/.agents"
printf '{"tracked": true}\n' > "$T/tracked/.agents/hooks.json"
git -C "$T/tracked" add -A
git -C "$T/tracked" commit -qm "track a harness file"
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/tracked" "" > "$KINGPIN_HOME/projects/demo-tracked.env"
"$KP_BIN/kingpin-spawn" demo-tracked --issue 907 --id excl-tracked --harness agy >/dev/null
wt_tracked=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-tracked/task.env" || true)
"$KP_BIN/kingpin-done" excl-tracked --force >/dev/null 2>&1 || true
[ -f "${wt_tracked:-/nonexistent}/.agents/hooks.json" ] \
  && pass "done kept .agents/hooks.json, which the project tracks" \
  || fail "done deleted an injected path the project tracks"
[ ! -e "${wt_tracked:-/nonexistent}/.agents/rules/kingpin.md" ] \
  && pass "done removed an injected path the project does not track" \
  || fail "done kept an injected path the project does not track"

echo "=== Test 8: a stale specific line an older Kingpin appended is named, never edited ==="
# The old append wrote five exact paths; they must be reported like the broad forms, and
# a harness that injects nothing (claude) must still get the warning about the shared file.
printf '.agents/hooks.json\n' >> "$proj_excl"
cp -p "$proj_excl" "$T/exclude.specific"
spawn_err=$("$KP_BIN/kingpin-spawn" demo-auto --issue 908 --id excl-stale --harness claude 2>&1 >/dev/null)
cmp -s "$proj_excl" "$T/exclude.specific" && pass "the spawn left the user's stale line in place" \
  || { fail "the spawn edited the user's stale line"; diff -u "$T/exclude.specific" "$proj_excl" || true; }
echo "$spawn_err" | grep -qF '.agents/hooks.json' && pass "the spawn names the stale exact path an older Kingpin appended" \
  || fail "the spawn said nothing about the stale exact path in $proj_excl: $spawn_err"
"$KP_BIN/kingpin-done" excl-stale --force >/dev/null 2>&1 || true

echo "=== Test 9: the XDG default ignore file is mirrored too ==="
# With no core.excludesFile set, git falls back to $XDG_CONFIG_HOME/git/ignore, and so
# must the task's exclude file.
mkdir -p "$XDG_CONFIG_HOME/git"
printf 'xdg-ignore.log\n' > "$XDG_CONFIG_HOME/git/ignore"
"$KP_BIN/kingpin-spawn" demo-auto --issue 909 --id excl-xdg --harness agy >/dev/null
wt_xdg=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-xdg/task.env" || true)
grep -qx 'xdg-ignore\.log' "$(task_exclude_of excl-xdg)" 2>/dev/null \
  && pass "the task's exclude file mirrors the XDG default ignore file" \
  || fail "the task's exclude file dropped the XDG default ignore file"
git -C "${wt_xdg:-/nonexistent}" check-ignore -q xdg-ignore.log 2>/dev/null \
  && pass "the worktree ignores a path the XDG default ignore file hides" \
  || fail "the worktree stopped ignoring a path the XDG default ignore file hides"
"$KP_BIN/kingpin-done" excl-xdg --force >/dev/null 2>&1 || true

echo "=== Test 10: a relative core.excludesFile is resolved where the worker runs ==="
# The spawn's own working directory is not the worktree, so a relative value must be
# resolved against the worktree before it is read.
git init -q -b main "$T/relproj"
(
  cd "$T/relproj" || exit 1
  printf 'code\n' > app.txt
  git add app.txt
  git commit -qm "init"
)
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/relproj" 'printf "relative-ignore.log\n" > relignore' \
  > "$KINGPIN_HOME/projects/demo-rel.env"
git -C "$T/relproj" config core.excludesFile relignore
"$KP_BIN/kingpin-spawn" demo-rel --issue 910 --id excl-relative --harness agy >/dev/null
wt_relative=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-relative/task.env" || true)
grep -qx 'relative-ignore\.log' "$(task_exclude_of excl-relative)" 2>/dev/null \
  && pass "the task's exclude file mirrors a relative core.excludesFile" \
  || fail "the task's exclude file dropped a relative core.excludesFile"
git -C "${wt_relative:-/nonexistent}" check-ignore -v relative-ignore.log 2>/dev/null | grep -qF "$(task_exclude_of excl-relative)" \
  && pass "the worktree ignores a path a relative core.excludesFile hides" \
  || fail "the worktree stopped ignoring a path a relative core.excludesFile hides"
"$KP_BIN/kingpin-done" excl-relative --force >/dev/null 2>&1 || true
git -C "$T/relproj" config --unset core.excludesFile

echo "=== Test 11: an unreadable ignore file refuses the spawn instead of dropping it ==="
# A file that exists but cannot be read would leave the user's rules out of the worker,
# which could then stage a path the user hides. Check the exit, the name and the cleanup.
if [ "$(id -u)" -eq 0 ]; then
  pass "unreadable ignore file case skipped (root reads mode 000)"
else
  printf 'secret-ignore.log\n' > "$T/unreadable-ignore"
  chmod 000 "$T/unreadable-ignore"
  git -C "$T/proj" config core.excludesFile "$T/unreadable-ignore"
  cp -p "$proj_excl" "$T/exclude.unreadable"
  rc=0
  spawn_err=$("$KP_BIN/kingpin-spawn" demo-auto --issue 911 --id excl-unreadable --harness agy 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] && pass "a spawn whose inherited ignore file cannot be read exits nonzero" \
    || fail "the spawn exited 0 with an unreadable ignore file"
  echo "$spawn_err" | grep -qF "$T/unreadable-ignore" \
    && pass "the refusal names the unreadable ignore file" \
    || fail "the refusal does not name the unreadable ignore file: $spawn_err"
  [ ! -d "$KINGPIN_HOME/tasks/excl-unreadable" ] && pass "the refused spawn left no task folder" \
    || fail "the refused spawn left a task folder"
  cmp -s "$proj_excl" "$T/exclude.unreadable" && pass "the refused spawn left the main checkout's .git/info/exclude byte-identical" \
    || { fail "the refused spawn rewrote the main checkout's .git/info/exclude"; diff -u "$T/exclude.unreadable" "$proj_excl" || true; }
  leftovers=''
  for slot in "$T"/pool/.treehouse/*/*/*; do
    [ -d "$slot" ] || continue
    for rel in .agents/rules/kingpin.md .agents/hooks.json \
               .opencode/opencode.json .opencode/plugins/package.json .opencode/plugins/kingpin-stop.js; do
      [ -e "$slot/$rel" ] || continue
      # A path the project tracks is the project's, as test 7 pins for done.
      git -C "$slot" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && continue
      leftovers="$leftovers $slot/$rel"
    done
    [ -z "$(git -C "$slot" config --get --worktree core.excludesFile 2>/dev/null || true)" ] \
      || leftovers="$leftovers $slot(core.excludesFile)"
  done
  [ -z "$leftovers" ] && pass "the refused spawn left no harness file or pointer in the pool" \
    || fail "the refused spawn left:$leftovers"
  chmod 644 "$T/unreadable-ignore"
  git -C "$T/proj" config --unset core.excludesFile
fi

echo "=== Test 12: done removes only the paths this spawn injected ==="
# A claude spawn injects no files, so a file someone left at an agy/opencode path in its
# worktree is not Kingpin's to delete when the slot goes back.
"$KP_BIN/kingpin-spawn" demo-auto --issue 912 --id excl-foreign --harness claude >/dev/null
wt_foreign=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-foreign/task.env" || true)
mkdir -p "${wt_foreign:-/nonexistent}/.agents"
printf '{"mine": true}\n' > "${wt_foreign:-/nonexistent}/.agents/hooks.json"
"$KP_BIN/kingpin-done" excl-foreign --force >/dev/null 2>&1 || true
[ -f "${wt_foreign:-/nonexistent}/.agents/hooks.json" ] \
  && pass "done kept .agents/hooks.json, which this claude spawn never injected" \
  || fail "done deleted .agents/hooks.json, which this claude spawn never injected"
rm -f "${wt_foreign:-/nonexistent}/.agents/hooks.json"

echo "=== Test 13: a checkout with kingpin guard install applied is silent ==="
# The guard owns the main checkout's contract copies and hides them in its own block of
# the shared exclude file (issue #123). An older install left those lines unmarked, so
# the install adopts them instead of adding a second copy.
git init -q -b main "$T/guard"
mkdir -p "$T/guard/orchestrator"
cp "$KP_ROOT/orchestrator/contract.md" "$T/guard/orchestrator/contract.md"
git -C "$T/guard" add -A
git -C "$T/guard" commit -qm "carry the orchestrator contract template"
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/guard" "" > "$KINGPIN_HOME/projects/demo-guard.env"
guard_excl=$(git -C "$T/guard" rev-parse --path-format=absolute --git-path info/exclude)
# The shape an older guard install left behind, plus a line the user owns.
printf 'guard-user-note.txt\n.agents/rules/kingpin.md\n.opencode/opencode.json\n' >> "$guard_excl"
"$KP_BIN/kingpin-guard" install --dir "$T/guard" >/dev/null
"$KP_BIN/kingpin-guard" install --dir "$T/guard" >/dev/null
sed -n '/^# kingpin guard$/,/^# end kingpin guard$/p' "$guard_excl" > "$T/guard.block"
[ "$(grep -cxF '# kingpin guard' "$T/guard.block")" = 1 ] \
  && pass "guard install wrote one # kingpin guard header" || fail "guard install wrote no single block header"
[ "$(grep -cxF '# end kingpin guard' "$T/guard.block")" = 1 ] \
  && pass "guard install wrote one # end kingpin guard footer" || fail "guard install wrote no single block footer"
for rel in .agents/rules/kingpin.md .opencode/opencode.json .claude/rules/kingpin-orchestrator.md; do
  [ "$(grep -cxF "$rel" "$guard_excl")" = 1 ] \
    && pass "two installs left one $rel line in the exclude file" \
    || fail "the exclude file carries $(grep -cxF "$rel" "$guard_excl") copies of $rel after two installs"
  grep -qxF "$rel" "$T/guard.block" \
    && pass "guard install adopted $rel into its block" \
    || fail "guard install left $rel outside its block"
done
grep -qxF 'guard-user-note.txt' "$guard_excl" \
  && pass "guard install kept the user's own exclude line" || fail "guard install dropped the user's own exclude line"
cp -p "$guard_excl" "$T/exclude.guard"
spawn_err=$("$KP_BIN/kingpin-spawn" demo-guard --issue 913 --id excl-guard --harness claude 2>&1 >/dev/null)
echo "$spawn_err" | grep -qF 'Kingpin-shaped exclude' \
  && fail "a guard-installed checkout still gets the stale-exclude warning: $spawn_err" \
  || pass "a checkout with kingpin guard install applied gets no stale-exclude warning"
for rel in .agents/rules/kingpin.md .opencode/opencode.json; do
  echo "$spawn_err" | grep -qF "$rel" \
    && fail "the warning still names the guard-owned $rel: $spawn_err" \
    || pass "the warning stays silent about the guard-owned $rel"
done
cmp -s "$guard_excl" "$T/exclude.guard" && pass "the spawn left the guard block byte-identical" \
  || { fail "the spawn rewrote the guard block"; diff -u "$T/exclude.guard" "$guard_excl" || true; }

echo "=== Test 14: an orphaned hand-added entry is still named ==="
# The block covers only what the guard writes: a path nothing maintains keeps getting
# named, because it hides files in every worktree (issue #123).
printf '.agents/hooks.json\n' >> "$guard_excl"
cp -p "$guard_excl" "$T/exclude.guard-orphan"
spawn_err=$("$KP_BIN/kingpin-spawn" demo-guard --issue 914 --id excl-guard-orphan --harness claude 2>&1 >/dev/null)
echo "$spawn_err" | grep -qF '.agents/hooks.json' \
  && pass "the warning still names the orphaned .agents/hooks.json" \
  || fail "the warning said nothing about the orphaned .agents/hooks.json: $spawn_err"
for rel in .agents/rules/kingpin.md .opencode/opencode.json; do
  echo "$spawn_err" | grep -qF "$rel" \
    && fail "the warning names the guard-owned $rel alongside the orphan: $spawn_err" \
    || pass "the orphan warning does not name the guard-owned $rel"
done
cmp -s "$guard_excl" "$T/exclude.guard-orphan" && pass "the spawn left the orphaned entry in place" \
  || { fail "the spawn edited the orphaned entry"; diff -u "$T/exclude.guard-orphan" "$guard_excl" || true; }

echo "=== Test 15: kingpin done leaves the guard block alone ==="
for t in excl-guard excl-guard-orphan; do
  "$KP_BIN/kingpin-done" "$t" --force >/dev/null 2>&1 || true
done
sed -n '/^# kingpin guard$/,/^# end kingpin guard$/p' "$guard_excl" > "$T/guard.block-after"
cmp -s "$T/guard.block" "$T/guard.block-after" && pass "done left the guard block byte-identical" \
  || { fail "done rewrote the guard block"; diff -u "$T/guard.block" "$T/guard.block-after" || true; }
grep -qxF '.agents/hooks.json' "$guard_excl" \
  && pass "done left the orphaned entry for the user to remove" || fail "done removed the user's orphaned entry"

echo "=== Test 16: a guard path as the exclude file's last line is adopted ==="
# The read loop must not take a matching last line as a read failure: that is the shape
# a user is left with after removing the loose lines an older warning named, and the
# failed read used to abort the install before it wrote the block (issue #123 review, H1).
git init -q -b main "$T/guard-last"
mkdir -p "$T/guard-last/orchestrator"
cp "$KP_ROOT/orchestrator/contract.md" "$T/guard-last/orchestrator/contract.md"
# The settings file is already ignored, so install adds no line after the seeded one and
# the seeded guard path really is the file's last line when the block is first written.
printf '.claude/settings.local.json\n' > "$T/guard-last/.gitignore"
git -C "$T/guard-last" add -A
git -C "$T/guard-last" commit -qm "carry the orchestrator contract template"
guard_last_excl=$(git -C "$T/guard-last" rev-parse --path-format=absolute --git-path info/exclude)
printf 'guard-last-note.txt\n.claude/rules/kingpin-orchestrator.md\n' >> "$guard_last_excl"
rc=0
install_err=$("$KP_BIN/kingpin-guard" install --dir "$T/guard-last" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 0 ] && pass "guard install accepts a guard path as the exclude file's last line" \
  || fail "guard install exited $rc with a guard path last: $install_err"
sed -n '/^# kingpin guard$/,/^# end kingpin guard$/p' "$guard_last_excl" > "$T/guard-last.block"
[ "$(grep -cxF '.claude/rules/kingpin-orchestrator.md' "$guard_last_excl")" = 1 ] \
  && pass "the seeded guard path appears once after the install" \
  || fail "the exclude file carries $(grep -cxF '.claude/rules/kingpin-orchestrator.md' "$guard_last_excl") copies of the seeded guard path"
grep -qxF '.claude/rules/kingpin-orchestrator.md' "$T/guard-last.block" \
  && pass "guard install adopted the seeded guard path into its block" \
  || fail "guard install left the seeded guard path outside its block"
grep -qxF 'guard-last-note.txt' "$guard_last_excl" \
  && pass "guard install kept the user's line above the seeded guard path" \
  || fail "guard install dropped the user's line above the seeded guard path"

echo "=== Test 17: a guard path appended after an existing block is adopted ==="
# An install that follows a loose guard path after the block footer must exit 0 and fold
# that copy into the block, not leave two lines or abort (issue #123 review, H1).
printf '.claude/rules/kingpin-orchestrator.md\n' >> "$guard_last_excl"
rc=0
install_err=$("$KP_BIN/kingpin-guard" install --dir "$T/guard-last" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 0 ] && pass "guard install accepts a guard path appended after its block" \
  || fail "guard install exited $rc with a guard path after the block: $install_err"
[ "$(grep -cxF '# kingpin guard' "$guard_last_excl")" = 1 ] \
  && pass "the install after the appended guard path left one block header" \
  || fail "the install after the appended guard path wrote $(grep -cxF '# kingpin guard' "$guard_last_excl") block headers"
sed -n '/^# kingpin guard$/,/^# end kingpin guard$/p' "$guard_last_excl" > "$T/guard-last.block-after"
grep -qxF '.claude/rules/kingpin-orchestrator.md' "$T/guard-last.block-after" \
  && pass "the appended guard path was folded into the block" \
  || fail "the appended guard path stayed outside the block"
[ "$(grep -cxF '.claude/rules/kingpin-orchestrator.md' "$guard_last_excl")" = 1 ] \
  && pass "the appended guard path left one line in the exclude file" \
  || fail "the exclude file carries $(grep -cxF '.claude/rules/kingpin-orchestrator.md' "$guard_last_excl") copies after the append"
grep -qxF 'guard-last-note.txt' "$guard_last_excl" \
  && pass "the install after the appended guard path kept the user's line" \
  || fail "the install after the appended guard path dropped the user's line"

kp_test_finish "SPAWN EXCLUDE"
