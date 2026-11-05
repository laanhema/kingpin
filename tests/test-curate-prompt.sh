#!/usr/bin/env bash
# Verification test for Kingpin: the curator prompt reaches the harness on stdin,
# so a batch past Linux's 128 KiB per-argument cap still launches (issue #200).
#
# The launch script used to run `claude "$(cat prompt.txt)"`, and once the collected
# batch passed MAX_ARG_STRLEN the exec failed with E2BIG and a bare exit 126. Each
# case here runs against a temp skills checkout and a fake curator, so nothing
# touches the real ~/.claude/skills or a real harness.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "curate-prompt"
kp_test_project

echo "=== Test 1: a prompt past the argument limit reaches the curator ==="
export KINGPIN_SKILLS_DIR=$T/skills
git init -q "$KINGPIN_SKILLS_DIR"
(
  cd "$KINGPIN_SKILLS_DIR" || exit 1
  git checkout -q -b main
  echo "# Skills" > SKILL.md
  git add SKILL.md
  git commit -qm "init"
)

# The fake records the argv it was given and the whole prompt it reads on stdin,
# then exits non-zero: the launch script must still write the named failed: line,
# and the critiques stay pending.
cat > "$T/fake-curator-stdin" << EOF_STDIN
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$T/curator-argv.txt"
cat > "$T/curator-stdin.txt"
exit 1
EOF_STDIN
chmod +x "$T/fake-curator-stdin"

# The record is reset between cases instead of going through `kingpin done`, so a
# case cannot inherit a window, a status or a launch script from the one before.
reset_curator() {
  tmux kill-window -t kingpin:curator 2>/dev/null || true
  rm -rf "$KINGPIN_HOME/tasks/curator" "$KINGPIN_HOME/curator"
}

status_has() {
  grep -qF -- "$1" "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null
}

# 200000 bytes is comfortably past MAX_ARG_STRLEN (131072) and the marker sits at
# the end, so a truncated prompt cannot pass the receipt check.
marker="END-OF-LARGE-PROMPT"
mkdir -p "$KINGPIN_HOME/tasks/large-prompt"
{
  head -c 200000 /dev/zero | tr '\0' 'x'
  printf '\n%s\n' "$marker"
} > "$KINGPIN_HOME/tasks/large-prompt/critique"

# A multi-word override with its own flag: the print flag is added after it, and
# the command still selects the curator (issue #200 criterion on the override).
export KINGPIN_CURATOR_CMD="$T/fake-curator-stdin --model test-model"
"$KP_BIN/kingpin" curate >/dev/null
kp_wait_until 20 status_has "failed: the curator exited with status 1 and opened no PR" \
  && pass "the large-prompt curator launched and the launch script finished" \
  || fail "no failed: line after a 200 KB prompt; status: $(cat "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null)"

if [ -f "$T/curator-stdin.txt" ]; then
  stdin_bytes=$(wc -c < "$T/curator-stdin.txt" | tr -d ' ')
  [ "$stdin_bytes" -gt 131072 ] \
    && pass "the harness received $stdin_bytes bytes of prompt on stdin" \
    || fail "the harness received only $stdin_bytes bytes on stdin"
  grep -qxF "$marker" "$T/curator-stdin.txt" \
    && pass "the whole prompt reached the harness, marker included" \
    || fail "the prompt tail is missing from stdin"
else
  fail "the harness read no prompt on stdin"
fi

if [ -f "$T/curator-argv.txt" ]; then
  grep -qw -- '-p' "$T/curator-argv.txt" \
    && pass "the launch adds the print flag the piped prompt needs" \
    || fail "the launch did not pass -p: $(cat "$T/curator-argv.txt")"
  grep -qF -- '--model test-model' "$T/curator-argv.txt" \
    && pass "a multi-word override keeps its own flags" \
    || fail "the override's flags were lost: $(cat "$T/curator-argv.txt")"
  ! grep -qF "$marker" "$T/curator-argv.txt" \
    && pass "the prompt is not on the command line" \
    || fail "the prompt travelled as a command-line argument"
else
  fail "the curator was never called"
fi

launch_file="$KINGPIN_HOME/curator/launch.sh"
[ -f "$launch_file" ] && pass "the launch script was written" || fail "no launch script at $launch_file"
# The literals the generated script must carry, not expansions in this suite.
# shellcheck disable=SC2016 # the stdin redirection the launch script has to show
stdin_form='< "$PROMPT_FILE"'
# shellcheck disable=SC2016 # the rejected argument form, matched literally
argument_form='$(cat "$PROMPT_FILE")'
grep -qF "$stdin_form" "$launch_file" \
  && pass "the launch script feeds the prompt on stdin" \
  || fail "the launch script does not read the prompt on stdin"
# The comment above the guard names the rejected form, so read the executable lines.
if grep -vE '^[[:space:]]*#' "$launch_file" | grep -qF "$argument_form"; then
  fail "the argument form is still in the launch script"
else
  pass "the launch script no longer passes the prompt as an argument"
fi
grep -qF 'MAX_ARG_STRLEN' "$launch_file" \
  && pass "the launch script records why the argument form is unsafe" \
  || fail "the launch script carries no MAX_ARG_STRLEN warning"

reset_curator
rm -rf "$KINGPIN_HOME/tasks/large-prompt"

echo "=== Test 2: a prompt past Kingpin's read cap is refused with a cause ==="
# The cap is a constant Kingpin picks, so read it from the source rather than
# duplicating the number here: a suite that hard-codes it would keep passing
# after the cap moved.
limit=$(sed -n 's/^CURATOR_PROMPT_MAX=\([0-9][0-9]*\)$/\1/p' "$KP_BIN/kingpin-curate")
case "$limit" in
  '' | *[!0-9]*) fail "no CURATOR_PROMPT_MAX constant in $KP_BIN/kingpin-curate"; limit=8388608 ;;
esac
mkdir -p "$KINGPIN_HOME/tasks/oversize"
head -c "$((limit + 1024))" /dev/zero | tr '\0' 'y' > "$KINGPIN_HOME/tasks/oversize/critique"
rm -f "$T/curator-argv.txt" "$T/curator-stdin.txt"
export KINGPIN_CURATOR_CMD="$T/fake-curator-stdin"
"$KP_BIN/kingpin" curate >/dev/null
kp_wait_until 20 status_has "over Kingpin's $limit-byte curator prompt cap" \
  && pass "an oversize prompt is refused with a named cause" \
  || fail "no size refusal; status: $(cat "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null)"
# The size in the diagnostic is what the operator acts on, so pin it to the file
# the launch script actually read rather than to a prefix.
if [ -f "$KINGPIN_HOME/curator/prompt.txt" ]; then
  prompt_bytes=$(wc -c < "$KINGPIN_HOME/curator/prompt.txt" | tr -d ' ')
  status_has "failed: the curator prompt is $prompt_bytes bytes" \
    && pass "the refusal names the $prompt_bytes bytes it read" \
    || fail "the refusal does not name the $prompt_bytes bytes it read; status: $(cat "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null)"
else
  fail "no prompt.txt to measure the refusal against"
fi
[ ! -f "$T/curator-argv.txt" ] \
  && pass "a refused launch never reaches the harness" \
  || fail "the harness ran for a prompt the launch refused"

list_out='' list_rc=0
kp_run list_out list_rc "$KP_BIN/kingpin" list
grep -qF "failed: the curator prompt is " <<< "$list_out" \
  && pass "kingpin list reports the refusal instead of a dead window" \
  || fail "kingpin list did not report the refusal (exit=$list_rc): $list_out"

reset_curator
rm -rf "$KINGPIN_HOME/tasks/oversize"

echo "=== Test 3: a prompt that vanishes before launch is refused with a cause ==="
mkdir -p "$KINGPIN_HOME/tasks/vanished"
echo "A critique whose prompt disappears" > "$KINGPIN_HOME/tasks/vanished/critique"
rm -f "$T/curator-argv.txt" "$T/curator-stdin.txt"
export KINGPIN_CURATOR_CMD="$T/fake-curator-stdin"
"$KP_BIN/kingpin" curate >/dev/null
kp_wait_until 20 status_has "failed: the curator exited with status 1 and opened no PR" \
  && pass "the launch script for the vanished-prompt case ran once" \
  || fail "the vanished-prompt launch never ran; status: $(cat "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null)"
# The window's run has finished, so run the same script once more by hand with the
# prompt gone: the guard that precedes the size check is then the only thing that
# can stop it, and the harness must never be reached.
: > "$KINGPIN_HOME/tasks/curator/status"
rm -f "$KINGPIN_HOME/curator/prompt.txt" "$T/curator-argv.txt"
launch_out='' launch_rc=0
kp_run launch_out launch_rc bash "$KINGPIN_HOME/curator/launch.sh"
[ "$launch_rc" -eq 0 ] \
  && pass "the launch script stops cleanly on a missing prompt" \
  || fail "the launch script exited $launch_rc on a missing prompt: $launch_out"
status_has "failed: the curator prompt $KINGPIN_HOME/curator/prompt.txt is missing, empty or unreadable" \
  && pass "a missing prompt is refused with a named cause" \
  || fail "no missing-prompt refusal; status: $(cat "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null)"
status_has "the curator did not start" \
  && pass "the refusal says the curator never started" \
  || fail "the refusal does not say the curator never started"
[ ! -f "$T/curator-argv.txt" ] \
  && pass "a launch with no prompt never reaches the harness" \
  || fail "the harness ran with no prompt"

reset_curator
rm -rf "$KINGPIN_HOME/tasks/vanished"

echo "=== Test 4: an unrunnable override names its cause ==="
mkdir -p "$KINGPIN_HOME/tasks/plain"
echo "A plain critique" > "$KINGPIN_HOME/tasks/plain/critique"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/not-executable"
chmod 644 "$T/not-executable"
export KINGPIN_CURATOR_CMD="$T/not-executable"
"$KP_BIN/kingpin" curate >/dev/null
kp_wait_until 20 status_has "the curator command could not be executed (status 126; check KINGPIN_CURATOR_CMD)" \
  && pass "an unrunnable curator command reports a named cause, not a bare 126" \
  || fail "no named 126 cause; status: $(cat "$KINGPIN_HOME/tasks/curator/status" 2>/dev/null)"

reset_curator
rm -rf "$KINGPIN_HOME/tasks/plain"

kp_test_finish CURATE-PROMPT
