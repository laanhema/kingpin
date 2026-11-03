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

echo "=== Test 18: a reused slot's provable Kingpin leftovers are removed ==="
# Issue #127. An older Kingpin hid its harness files through the main checkout's
# .git/info/exclude, so treehouse handed a slot with leftovers out as clean; removing
# those dead lines surfaced the files and the next task's done refused. Seed exactly
# that state in a one-slot pool: four files whose content proves Kingpin wrote them (two
# historical ones and the opencode plugin pair), one file at a Kingpin path whose content
# does not, and an unrelated file the user hides with a line of their own.
#
# generated_stop_plugin: the OpenCode Stop plugin exactly as `bin/kingpin-spawn` writes
# it, lifted from its heredoc so the fixture follows the script.
generated_stop_plugin() {
  sed -n "/EOF_OC_PLUG'$/,/^EOF_OC_PLUG\$/p" "$KP_BIN/kingpin-spawn" | sed '1d;$d'
}
git init -q --bare "$T/reuse-origin.git"
git clone -q "$T/reuse-origin.git" "$T/reuse-proj" 2>/dev/null
(
  cd "$T/reuse-proj" || exit 1
  git checkout -q -b main
  echo "reuse code" > app.txt
  git add app.txt
  git commit -qm "init"
  git push -q -u origin main
  git remote set-head origin main
)
printf 'PROJECT_PATH=%q\nSETUP_CMD=%q\n' "$T/reuse-proj" "" > "$KINGPIN_HOME/projects/demo-reuse.env"

"$KP_BIN/kingpin-spawn" demo-reuse --issue 915 --id excl-reuse-a --harness claude >/dev/null 2>&1
wt_reuse=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-reuse-a/task.env" || true)
"$KP_BIN/kingpin-done" excl-reuse-a >/dev/null 2>&1 || true
[ -n "$wt_reuse" ] && [ -d "$wt_reuse" ] && pass "the first task left one returned slot to reuse" \
  || fail "the first task left no worktree to reuse"

reuse_excl=$(git -C "$T/reuse-proj" rev-parse --path-format=absolute --git-path info/exclude)
printf '.agents/hooks.json\n.opencode/config.json\n.opencode/plugins/package.json\n.opencode/plugins/kingpin-stop.js\n.agents/rules/kingpin.md\nworker-note.txt\n' >> "$reuse_excl"
mkdir -p "${wt_reuse:-/nonexistent}/.agents/rules" "${wt_reuse:-/nonexistent}/.opencode/plugins"
cat > "${wt_reuse:-/nonexistent}/.agents/hooks.json" << 'EOF'
{
  "kingpin": {
    "Stop": [
      { "type": "command", "command": "true", "timeout": 30 }
    ]
  }
}
EOF
cat > "${wt_reuse:-/nonexistent}/.opencode/config.json" << EOF
{
  "permission": {
    "*": "allow"
  },
  "instructions": [
    "$KINGPIN_HOME/tasks/older/preamble.md"
  ]
}
EOF
printf '{ "private": true, "type": "module" }\n' > "${wt_reuse:-/nonexistent}/.opencode/plugins/package.json"
generated_stop_plugin > "${wt_reuse:-/nonexistent}/.opencode/plugins/kingpin-stop.js"
printf 'my own rules\n' > "${wt_reuse:-/nonexistent}/.agents/rules/kingpin.md"
printf 'do not delete me\n' > "${wt_reuse:-/nonexistent}/worker-note.txt"
[ -s "${wt_reuse:-/nonexistent}/.opencode/plugins/kingpin-stop.js" ] \
  && pass "the fixture carries the plugin the spawn really writes" \
  || fail "could not lift the Stop plugin out of bin/kingpin-spawn"
[ -z "$(git -C "${wt_reuse:-/nonexistent}" status --porcelain -uall 2>/dev/null)" ] \
  && pass "the stale lines keep the seeded slot clean for treehouse" \
  || fail "the seeded slot is already dirty before the spawn"

spawn_err=$("$KP_BIN/kingpin-spawn" demo-reuse --issue 916 --id excl-reuse-b --harness claude 2>&1 >/dev/null)
wt_reuse_b=$(sed -n 's/^WORKTREE=//p' "$KINGPIN_HOME/tasks/excl-reuse-b/task.env" || true)
[ -n "$wt_reuse_b" ] && [ "$wt_reuse_b" = "$wt_reuse" ] \
  && pass "the second spawn leased the seeded slot again" \
  || fail "the second spawn leased '${wt_reuse_b:-nothing}' instead of $wt_reuse"
for rel in .agents/hooks.json .opencode/config.json .opencode/plugins/package.json .opencode/plugins/kingpin-stop.js; do
  echo "$spawn_err" | grep -qF "removed $rel" \
    && pass "the spawn removed the provable earlier-task $rel" \
    || fail "the spawn does not name $rel as removed: $spawn_err"
  [ ! -e "${wt_reuse:-/nonexistent}/$rel" ] \
    && pass "the provable leftover $rel is gone from the slot" \
    || fail "the provable leftover $rel is still in the slot"
done
echo "$spawn_err" | grep -qF "left .agents/rules/kingpin.md" \
  && pass "the spawn names the file whose content does not prove Kingpin wrote it" \
  || fail "the spawn does not name the unprovable Kingpin-path file: $spawn_err"
[ -f "${wt_reuse:-/nonexistent}/.agents/rules/kingpin.md" ] \
  && pass "the unprovable Kingpin-path file is left in place" \
  || fail "the spawn deleted a file it cannot prove it wrote"

# The user acts on the warning and removes their file, then removes the dead Kingpin
# lines, the change that surfaced the leftovers in the incident. The unrelated file keeps
# its own line, so it never dirties the tree.
rm -f "${wt_reuse:-/nonexistent}/.agents/rules/kingpin.md"
grep -v -x -e '.agents/hooks.json' -e '.opencode/config.json' \
  -e '.opencode/plugins/package.json' -e '.opencode/plugins/kingpin-stop.js' \
  -e '.agents/rules/kingpin.md' \
  "$reuse_excl" > "$T/reuse.excl" || true
cat "$T/reuse.excl" > "$reuse_excl"
reuse_status=$(git -C "${wt_reuse:-/nonexistent}" status --porcelain -uall 2>/dev/null || true)
echo "$reuse_status" | grep -qF '.agents/hooks.json' \
  && fail "the worker's git status names the stale .agents/hooks.json" \
  || pass "the worker's git status stays silent about .agents/hooks.json after the lines are gone"
echo "$reuse_status" | grep -qF '.opencode/config.json' \
  && fail "the worker's git status names the stale .opencode/config.json" \
  || pass "the worker's git status stays silent about .opencode/config.json after the lines are gone"
echo "$reuse_status" | grep -qF '.opencode/plugins' \
  && fail "the worker's git status names the stale .opencode/plugins pair" \
  || pass "the worker's git status stays silent about .opencode/plugins after the lines are gone"

rc=0
done_out=$("$KP_BIN/kingpin-done" excl-reuse-b 2>&1) || rc=$?
[ "$rc" -eq 0 ] && pass "done returned the reused slot without --force" \
  || fail "done refused the reused slot (rc=$rc): $done_out"
echo "$done_out" | grep -q 'cleanup-refused' \
  && fail "done recorded a cleanup-refused for the reused slot" \
  || pass "done recorded no cleanup-refused for the reused slot"
[ -f "$KINGPIN_HOME/archive/excl-reuse-b/status" ] \
  && ! grep -q 'cleanup-refused' "$KINGPIN_HOME/archive/excl-reuse-b/status" \
  && pass "the archived task carries no cleanup-refused status line" \
  || fail "the archived task carries a cleanup-refused status line"
[ -z "$(git -C "${wt_reuse:-/nonexistent}" status --porcelain -uall 2>/dev/null)" ] \
  && pass "the returned slot is clean for the next lease" \
  || fail "the returned slot still reports: $(git -C "${wt_reuse:-/nonexistent}" status --porcelain -uall 2>/dev/null | tr '\n' ' ')"
[ -f "${wt_reuse:-/nonexistent}/worker-note.txt" ] \
  && pass "done kept the unrelated untracked file" \
  || fail "done deleted the unrelated untracked file"
rm -f "${wt_reuse:-/nonexistent}/worker-note.txt"

echo "=== Test 19: the leftover prover accepts only the shapes Kingpin writes ==="
# The spawn deletes an earlier task's file only on proof (issue #127). These are the
# shapes that count, and the near misses a user's own file can take.
proves() { node "$KP_ROOT/lib/leftover.mjs" "$T/prover" "$1" "$KINGPIN_HOME"; }
mkdir -p "$T/prover/.agents/rules" "$T/prover/.opencode/plugins"
printf '{"kingpin":{"Stop":[]}}\n' > "$T/prover/.agents/hooks.json"
proves .agents/hooks.json && pass "a hooks.json whose only key is kingpin is Kingpin's" \
  || fail "the prover rejected a hooks.json whose only key is kingpin"
printf '{"kingpin":{"Stop":[]},"mine":{}}\n' > "$T/prover/.agents/hooks.json"
proves .agents/hooks.json && fail "the prover accepted a hooks.json with another key" \
  || pass "a hooks.json with another key is not Kingpin's"
printf '{"permission":{"*":"allow"},"instructions":["%s/tasks/old/preamble.md"]}\n' "$KINGPIN_HOME" \
  > "$T/prover/.opencode/config.json"
proves .opencode/config.json && pass "an old config.json pointing into KINGPIN_HOME is Kingpin's" \
  || fail "the prover rejected an old config.json pointing into KINGPIN_HOME"
printf '{"instructions":["/etc/passwd"]}\n' > "$T/prover/.opencode/config.json"
proves .opencode/config.json && fail "the prover accepted a config.json pointing outside KINGPIN_HOME" \
  || pass "a config.json pointing outside KINGPIN_HOME is not Kingpin's"
printf '{"permission":{},"instructions":["%s/tasks/old/preamble.md"],"model":"x"}\n' "$KINGPIN_HOME" \
  > "$T/prover/.opencode/config.json"
proves .opencode/config.json && fail "the prover accepted a config.json with another key" \
  || pass "a config.json with another key is not Kingpin's"
printf 'not json\n' > "$T/prover/.opencode/config.json"
proves .opencode/config.json && fail "the prover accepted a config.json that is not JSON" \
  || pass "a config.json that is not JSON is not Kingpin's"

# The agy rules file: Kingpin's trigger frontmatter above the worker preamble.
{
  printf -- '---\ntrigger: always_on\ndescription: Kingpin worker preamble\n---\n\n'
  sed -n '1,2p' "$KP_ROOT/worker/preamble.md"
} > "$T/prover/.agents/rules/kingpin.md"
proves .agents/rules/kingpin.md \
  && pass "a rules file with the trigger frontmatter and the preamble heading is Kingpin's" \
  || fail "the prover rejected the rules file Kingpin generates"
printf -- '---\ntrigger: always_on\ndescription: my project rules\n---\n\n# My rules\n' \
  > "$T/prover/.agents/rules/kingpin.md"
proves .agents/rules/kingpin.md && fail "the prover accepted a rules file without the Kingpin preamble" \
  || pass "a user's rules file with the trigger frontmatter is not Kingpin's"
printf -- '---\ndescription: Kingpin worker preamble\n---\n\n# Kingpin worker\n' \
  > "$T/prover/.agents/rules/kingpin.md"
proves .agents/rules/kingpin.md && fail "the prover accepted a rules file without trigger: always_on" \
  || pass "a rules file without the agy trigger is not Kingpin's"

# The opencode plugin pair: the exact package object, and the stop plugin's own lines.
printf '{ "private": true, "type": "module" }\n' > "$T/prover/.opencode/plugins/package.json"
proves .opencode/plugins/package.json && pass "the package file exact object is Kingpin's" \
  || fail "the prover rejected the package file Kingpin writes"
printf '{"private":true,"type":"module","name":"our-plugins"}\n' > "$T/prover/.opencode/plugins/package.json"
proves .opencode/plugins/package.json && fail "the prover accepted a package file with another field" \
  || pass "an opencode plugin package file of the user's own is not Kingpin's"
generated_stop_plugin > "$T/prover/.opencode/plugins/kingpin-stop.js"
proves .opencode/plugins/kingpin-stop.js \
  && pass "the stop plugin Kingpin writes proves its own path" \
  || fail "the prover rejected the stop plugin Kingpin writes"
sed -e 's/kingpin\.stop/our.plugin/' \
  "$T/prover/.opencode/plugins/kingpin-stop.js" > "$T/prover/plugin.miss"
cp "$T/prover/plugin.miss" "$T/prover/.opencode/plugins/kingpin-stop.js"
proves .opencode/plugins/kingpin-stop.js && fail "the prover accepted a stop plugin under another id" \
  || pass "an opencode plugin of the user's own is not Kingpin's"

echo "=== Test 20: a slot's visible untracked file is named and kept ==="
# treehouse will not lease a slot that is already dirty, so the sweep above never sees a
# visible untracked file in the incident's state. A stubbed `treehouse get` hands this
# spawn a linked worktree that carries one, which is the state a user's own file was in
# before the spawn: it must be named on stderr and left alone.
git -C "$T/proj" worktree add -q -b kingpin/excl-visible "$T/visible-slot"
printf 'already here\n' > "$T/visible-slot/kept-note.txt"
mkdir -p "$T/stub-treehouse"
cat > "$T/stub-treehouse/treehouse" <<EOF
#!/usr/bin/env bash
# Only \`get\` matters here: hand back the slot prepared above.
case "\${1:-}" in
  get) printf '%s\n' "$T/visible-slot" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/stub-treehouse/treehouse"
rc=0
spawn_err=$(PATH="$T/stub-treehouse:$PATH" "$KP_BIN/kingpin-spawn" demo-auto \
  --issue 920 --id excl-visible --harness claude 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 0 ] && pass "a spawn whose slot carries a visible untracked file still launches" \
  || fail "the spawn failed on a slot with a visible untracked file (rc=$rc): $spawn_err"
echo "$spawn_err" | grep -qF "kept-note.txt was already untracked" \
  && pass "the spawn names the visible untracked file it did not write" \
  || fail "the spawn did not name the visible untracked file: $spawn_err"
echo "$spawn_err" | grep -qF "left in place" \
  && pass "the spawn says the visible untracked file stays" \
  || fail "the spawn does not say the visible untracked file stays: $spawn_err"
[ -f "$T/visible-slot/kept-note.txt" ] \
  && pass "the spawn left the visible untracked file in the slot" \
  || fail "the spawn deleted the visible untracked file"
PATH="$T/stub-treehouse:$PATH" "$KP_BIN/kingpin-done" excl-visible --force >/dev/null 2>&1 || true

kp_test_finish "SPAWN EXCLUDE"
