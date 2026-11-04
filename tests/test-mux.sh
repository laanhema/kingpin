#!/usr/bin/env bash
# The multiplexer adapter (issue #144): KINGPIN_MUX selection, the per-record mux
# reader, every verb's argv against a fake herdr, and the two static checks that
# keep a backend call inside its own file.
#
# The fake herdr comes from tests/lib.sh: it answers from the state this suite
# declares with kp_test_fake_herdr_state, records every call's argv, and refuses to
# answer until that state exists. No part of this suite can reach a real Herdr
# server.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "mux"

# shellcheck source=../lib/mux.sh
. "$KP_ROOT/lib/mux.sh"

mock_herdr() {
  local id=${1:?} label=${2:-} revision=${3:-3}
  kp_test_herdr_pane "$id" "$label" "$revision"
}

log_has() {
  grep -qxF -- "$1" "$KP_TEST_HERDR_CALLS"
}

# Test 1: KINGPIN_MUX selection
# ---------------------------------------------------------------------------
echo "--- Test 1: KINGPIN_MUX selection ---"
sel=$(unset KINGPIN_MUX KP_MUX; unset HERDR_ENV; kp_mux_name)
[ "$sel" = "tmux" ] && pass "t1: unset KINGPIN_MUX outside Herdr reads tmux" || fail "t1: unset read '$sel'"
sel=$(unset KINGPIN_MUX KP_MUX; HERDR_ENV=1 kp_mux_name)
[ "$sel" = "herdr" ] && pass "t1: auto inside a Herdr pane reads herdr" || fail "t1: auto inside Herdr read '$sel'"
sel=$(unset KP_MUX; KINGPIN_MUX=tmux HERDR_ENV=1 kp_mux_name)
[ "$sel" = "tmux" ] && pass "t1: an explicit tmux wins inside a Herdr pane" || fail "t1: explicit tmux read '$sel'"
sel=$(unset KP_MUX; KINGPIN_MUX=herdr kp_mux_name)
[ "$sel" = "herdr" ] && pass "t1: an explicit herdr reads herdr" || fail "t1: explicit herdr read '$sel'"
sel=''
rc=0
sel=$(unset KP_MUX; KINGPIN_MUX=hero kp_mux_name 2>/dev/null) || rc=$?
[ "$rc" -eq 1 ] && pass "t1: an unknown KINGPIN_MUX exits 1" || fail "t1: unknown KINGPIN_MUX exited $rc"
err=$(unset KP_MUX; KINGPIN_MUX=hero kp_mux_name 2>&1 >/dev/null || true)
case "$err" in
  *"KINGPIN_MUX must be auto, tmux or herdr"*"'hero'"*) pass "t1: the refusal names the bad value" ;;
  *) fail "t1: refusal did not name the value: $err" ;;
esac

# Test 2: the record decides, not the environment
# ---------------------------------------------------------------------------
echo "--- Test 2: the mux belongs to the record ---"
t2_herdr="$T/tasks/t2-herdr"
mkdir -p "$t2_herdr"
printf 'TASK_ID=t2-herdr\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w1:p3\nMUX_LABEL=kp-144-t2\n' > "$t2_herdr/task.env"
got=$(KP_MUX='' KINGPIN_MUX=tmux kp_mux_record "$t2_herdr")
[ "$got" = "herdr" ] && pass "t2: MUX=herdr reads as herdr under KINGPIN_MUX=tmux" || fail "t2: record read '$got'"
t2_tmux="$T/tasks/t2-tmux"
mkdir -p "$t2_tmux"
printf 'TASK_ID=t2-tmux\nTMUX_TARGET=kingpin:t2-tmux\n' > "$t2_tmux/task.env"
got=$(KP_MUX='' KINGPIN_MUX=herdr kp_mux_record "$t2_tmux")
[ "$got" = "tmux" ] && pass "t2: a record with no MUX= reads as tmux, forever" || fail "t2: old record read '$got'"
t2_bad="$T/tasks/t2-bad"
mkdir -p "$t2_bad"
printf 'TASK_ID=t2-bad\nMUX=screen\n' > "$t2_bad/task.env"
got=''
rc=0
got=$(KP_MUX='' kp_mux_record "$t2_bad" 2>/dev/null) || rc=$?
[ "$rc" -eq 1 ] && pass "t2: an unknown record mux is refused" || fail "t2: unknown record mux exited $rc (read '$got')"
t2_bad_err=$(KP_MUX='' kp_mux_record "$t2_bad" 2>&1 >/dev/null || true)
case "$t2_bad_err" in
  *"unknown mux 'screen'"*) pass "t2: the refusal names the record and the value" ;;
  *) fail "t2: record refusal: $t2_bad_err" ;;
esac

# Test 3: a Herdr session name
# ---------------------------------------------------------------------------
echo "--- Test 3: the Herdr session name ---"
got=$(unset KP_MUX KINGPIN_HERDR_SESSION HERDR_ENV HERDR_SESSION; KINGPIN_MUX=herdr kp_mux_session_name)
[ "$got" = "kingpin" ] && pass "t3: the fleet Herdr session defaults to kingpin" || fail "t3: default session '$got'"
got=$(unset KP_MUX HERDR_ENV HERDR_SESSION; KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION=fleet kp_mux_session_name)
[ "$got" = "fleet" ] && pass "t3: KINGPIN_HERDR_SESSION overrides the name" || fail "t3: override read '$got'"
got=$(unset KP_MUX KINGPIN_HERDR_SESSION; KINGPIN_MUX=herdr HERDR_ENV=1 HERDR_SESSION=inside kp_mux_session_name)
[ "$got" = "inside" ] && pass "t3: inside a pane the inherited session is used" || fail "t3: inherited session read '$got'"
got=$(unset KP_MUX HERDR_ENV HERDR_SESSION; KINGPIN_MUX=herdr KINGPIN_HERDR_SESSION=fleet kp_mux_self)
[ -z "$got" ] && pass "t3: kp_mux_self is empty outside a pane" || fail "t3: kp_mux_self read '$got'"
got=$(unset KP_MUX KINGPIN_HERDR_SESSION; KINGPIN_MUX=herdr HERDR_ENV=1 HERDR_PANE_ID=w1:p9 kp_mux_self)
[ "$got" = "w1:p9" ] && pass "t3: kp_mux_self is the Herdr pane id inside a pane" || fail "t3: kp_mux_self read '$got'"

# Test 4: kp_mux_find on the fake, by label first and by id second
# ---------------------------------------------------------------------------
echo "--- Test 4: kp_mux_find ---"
kp_test_fake_herdr_state
mock_herdr w1:p2 kp-144-other 1
mock_herdr w1:p3 kp-144-t4 2
t4="$T/tasks/t4-find"
mkdir -p "$t4"
printf 'TASK_ID=t4-find\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w2:p9\nMUX_LABEL=kp-144-t4\n' > "$t4/task.env"

if kp_mux_find "$t4"; then
  pass "t4: a stale MUX_TARGET still resolves by label"
else
  fail "t4: find by label failed"
fi
[ "$KP_MUX" = herdr ] && [ "$KP_WINDOW_ID" = w1:p3 ] && pass "t4: find publishes the pane id and the backend" || fail "t4: find published mux=$KP_MUX id=$KP_WINDOW_ID"
[ "$KP_MUX_SESSION" = kp144 ] && pass "t4: find publishes the record's session" || fail "t4: find published session '$KP_MUX_SESSION'"
case "$KP_WINDOW_LABEL" in
  "kp144:kp-144-t4 (w1:p3)") pass "t4: the label names session, pane label and id" ;;
  *) fail "t4: label reads '$KP_WINDOW_LABEL'" ;;
esac
grep -qx 'MUX_TARGET=w1:p3' "$t4/task.env" && pass "t4: a stale id is rewritten through the record" || fail "t4: record still says $(grep MUX_TARGET "$t4/task.env")"
log_has "--session kp144 pane list" && pass "t4: the find reads the record's session" || fail "t4: pane list argv: $(cat "$KP_TEST_HERDR_CALLS")"

# The recorded id is the fallback: a hand-renamed pane keeps resolving.
kp_test_herdr_pane w1:p3 kp-144-renamed 3
if kp_mux_find "$t4"; then
  [ "$KP_WINDOW_ID" = w1:p3 ] && pass "t4: the label match follows a rename" || fail "t4: find after rename published '$KP_WINDOW_ID'"
else
  fail "t4: find after a rename failed"
fi
# A record whose label is gone but whose recorded id is alive still resolves.
t4b="$T/tasks/t4-id-only"
mkdir -p "$t4b"
printf 'TASK_ID=t4-id-only\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w1:p2\nMUX_LABEL=kp-144-gone\n' > "$t4b/task.env"
if kp_mux_find "$t4b"; then
  [ "$KP_WINDOW_ID" = w1:p2 ] && pass "t4: a recorded id resolves when the label is gone" || fail "t4: id fallback published '$KP_WINDOW_ID'"
else
  fail "t4: id fallback failed"
fi
# Neither: a refusal that names the label and the session.
t4c="$T/tasks/t4-missing"
mkdir -p "$t4c"
printf 'TASK_ID=t4-missing\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w9:p9\nMUX_LABEL=kp-144-missing\n' > "$t4c/task.env"
rc=0
t4_err=$(kp_mux_find "$t4c" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] && pass "t4: a missing pane exits 1" || fail "t4: missing pane exited $rc"
case "$t4_err" in
  *"w9:p9 is gone"*kp-144-missing*) pass "t4: the refusal names the id, the label and the session" ;;
  *) fail "t4: refusal reads: $t4_err" ;;
esac

# An unlabelled pane is listed with an empty label, never the literal `null`
# herdr 0.9.3 prints in its JSON (L4).
mock_herdr w1:p9 "" 1
t4d_json=$(KP_MUX=herdr KP_MUX_SESSION=kp144 _kp_herdr pane list)
case "$t4d_json" in
  *'"label":null'*) pass "t4: the fake prints label null, as herdr 0.9.3 does" ;;
  *) fail "t4: the fake's unlabelled pane does not carry label null: $t4d_json" ;;
esac
printf '%s\n' "$t4d_json" | _kp_herdr_pane_pairs | awk -F '\t' '$1 == "w1:p9" && $2 == "" { found = 1 } END { exit !found }' \
  && pass "t4: an unlabelled pane reads as an empty label, not 'null'" \
  || fail "t4: unlabelled pane pairs: $(printf '%s\n' "$t4d_json" | _kp_herdr_pane_pairs)"

# Test 5: verbs -> exact argv
# ---------------------------------------------------------------------------
echo "--- Test 5: each verb's argv ---"
kp_mux_find "$t4" >/dev/null
: > "$KP_TEST_HERDR_CALLS"
kp_test_herdr_read w1:p3 "line one
line two"
cap=$(kp_mux_capture "$KP_WINDOW_ID" --scrollback 40)
log_has "--session kp144 pane read w1:p3 --source recent-unwrapped --lines 40" \
  && pass "t5: capture reads recent-unwrapped with the requested line count" \
  || fail "t5: capture argv: $(cat "$KP_TEST_HERDR_CALLS")"
case "$cap" in
  *"line one"*"line two"*) pass "t5: capture returns the pane text" ;;
  *) fail "t5: capture returned '$cap'" ;;
esac

: > "$KP_TEST_HERDR_CALLS"
kp_mux_send_text "$KP_WINDOW_ID" "hello there"
kp_mux_send_enter "$KP_WINDOW_ID"
log_has "--session kp144 pane send-text w1:p3 hello there" && pass "t5: send-text passes the literals through" || fail "t5: send-text argv: $(cat "$KP_TEST_HERDR_CALLS")"
log_has "--session kp144 pane send-keys w1:p3 enter" && pass "t5: send-enter presses enter" || fail "t5: send-keys argv: $(cat "$KP_TEST_HERDR_CALLS")"

: > "$KP_TEST_HERDR_CALLS"
kp_mux_rename "$KP_WINDOW_ID" kp-144-moved
log_has "--session kp144 pane rename w1:p3 kp-144-moved" && pass "t5: rename names the pane and the label" || fail "t5: rename argv: $(cat "$KP_TEST_HERDR_CALLS")"
grep -q "w1:p3.*kp-144-moved" "$KP_TEST_HERDR_STATE/panes.tsv" && pass "t5: the fake recorded the new label" || fail "t5: fake pane table: $(cat "$KP_TEST_HERDR_STATE/panes.tsv")"
[ "$(kp_mux_target_state "$KP_WINDOW_ID")" = alive ] && pass "t5: a live pane reads alive" || fail "t5: target state wrong"

t5_token=$(kp_mux_activity "$KP_WINDOW_ID")
[ -n "$t5_token" ] && pass "t5: activity prints a token" || fail "t5: activity printed nothing"
kp_test_herdr_read w1:p3 "changed output"
t5_token2=$(kp_mux_activity "$KP_WINDOW_ID")
[ "$t5_token" != "$t5_token2" ] && pass "t5: the token changes when the pane output changes" || fail "t5: the token did not change"

: > "$KP_TEST_HERDR_CALLS"
kp_mux_kill "$KP_WINDOW_ID"
log_has "--session kp144 pane close w1:p3" && pass "t5: kill closes the pane" || fail "t5: kill argv: $(cat "$KP_TEST_HERDR_CALLS")"
[ "$(kp_mux_target_state w1:p3)" = none ] && pass "t5: a closed pane reads none, never dead" || fail "t5: closed pane read '$(kp_mux_target_state w1:p3)'"

# Test 6: activity age through the token file
# ---------------------------------------------------------------------------
echo "--- Test 6: kp_mux_activity_age ---"
kp_test_fake_herdr_state
mock_herdr w1:p5 kp-144-t6 1
kp_test_herdr_read w1:p5 "steady output"
t6="$T/tasks/t6-age"
mkdir -p "$t6"
printf 'TASK_ID=t6-age\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w1:p5\nMUX_LABEL=kp-144-t6\n' > "$t6/task.env"
age=$(kp_mux_activity_age "$t6")
[ "$age" = "0" ] && pass "t6: a first read reports 0 seconds" || fail "t6: first age '$age'"
[ -f "$t6/mux.activity" ] && pass "t6: the token file is stamped" || fail "t6: no mux.activity"
age=$(kp_mux_activity_age "$t6")
[ "$age" -le 1 ] && pass "t6: an unchanged token still reports about 0" || fail "t6: second age '$age'"
token=$(kp_mux_activity w1:p5)
printf '%s %s\n' "$(( $(date +%s) - 50 ))" "$token" > "$t6/mux.activity"
age=$(kp_mux_activity_age "$t6")
[ "$age" -ge 48 ] && pass "t6: an unchanged token ages from its stamp" || fail "t6: aged read '$age'"
kp_test_herdr_read w1:p5 "output moved on"
age=$(kp_mux_activity_age "$t6")
[ "$age" = "0" ] && pass "t6: a changed token resets the age" || fail "t6: changed-token age '$age'"

# Test 7: harness identity through pane process-info
# ---------------------------------------------------------------------------
echo "--- Test 7: kp_mux_harness_live ---"
t7="$T/tasks/t7-live"
mkdir -p "$t7"
printf 'TASK_ID=t7-live\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w1:p5\nMUX_LABEL=kp-144-t6\n' > "$t7/task.env"
# The check asks the kernel whether the recorded pid is alive, so use real pids: this
# shell for the harness and a live child for the foreign one. A made-up number is alive
# on some hosts and dead on others, which made this suite pass here and fail on CI.
live_pid=$$
sleep 30 &
other_pid=$!
kp_test_herdr_process w1:p5 "$live_pid" bash
printf '%s\n' "$live_pid" > "$t7/harness.pid"
kp_mux_harness_live "$t7" && pass "t7: a recorded pid that leads the pane is live" || fail "t7: live harness not found"
kp_test_herdr_process w1:p5 "$other_pid" bash
kp_mux_harness_live "$t7" && fail "t7: a foreign pid read as live" || pass "t7: a pane running another pid is not this harness"
rm -f "$t7/harness.pid"
kp_mux_harness_live "$t7" && fail "t7: a plain shell read as a live harness" || pass "t7: without harness.pid a plain shell is not a harness"
kp_test_herdr_process w1:p5 "$other_pid" claude
kp_mux_harness_live "$t7" && pass "t7: a foreground harness is live without harness.pid" || fail "t7: foreground harness not found"
kill "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true

# Test 8: record writes, the create refusal and session reachability
# ---------------------------------------------------------------------------
echo "--- Test 8: record id, create refusal, reachability ---"
kp_mux_record_id "$t7" w1:p5
grep -qx 'MUX_TARGET=w1:p5' "$t7/task.env" && pass "t8: kp_mux_record_id writes MUX_TARGET" || fail "t8: record: $(cat "$t7/task.env")"
rc=0
t8_err=$(kp_mux_create "$t7" kingpin curator "$T" "$T/bin/tmux" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] && pass "t8: creating a Herdr terminal is refused" || fail "t8: create exited $rc"
case "$t8_err" in
  *"(issue #144 phase E); run with KINGPIN_MUX=tmux"*) pass "t8: the refusal names the phase and the way back" ;;
  *) fail "t8: refusal reads: $t8_err" ;;
esac

kp_test_herdr_down
kp_mux_reachable "$t7" && fail "t8: an unreachable session read as reachable" || pass "t8: an unreachable session is not reachable"
# A stopped session answers `server_not_running` on every pane verb, as the real
# binary does, so "server down" never reads as "no such pane".
for t8_verb in "pane get w1:p5" "pane list" "pane read w1:p5 --lines 5"; do
  t8_rc=0
  # shellcheck disable=SC2086 # the verb's argv is split on purpose
  t8_err=$(KP_MUX=herdr KP_MUX_SESSION=kp144 _kp_herdr $t8_verb 2>&1 >/dev/null) || t8_rc=$?
  [ "$t8_rc" -eq 1 ] && case "$t8_err" in
    *server_not_running*) pass "t8: '$t8_verb' reports server_not_running while the session is down" ;;
    *) fail "t8: '$t8_verb' failed with '$t8_err'" ;;
  esac || fail "t8: '$t8_verb' exited $t8_rc while the session is down"
done
rc=0
t8_ensure=$(kp_mux_ensure_session kp144 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] && pass "t8: ensure refuses a session that is not running" || fail "t8: ensure exited $rc"
case "$t8_ensure" in
  *"herdr session 'kp144' is not running"*"herdr --session kp144 server"*) pass "t8: the refusal names the session and how to start it" ;;
  *) fail "t8: ensure refusal reads: $t8_ensure" ;;
esac
kp_test_herdr_up
kp_mux_reachable "$t7" && pass "t8: a running session is reachable" || fail "t8: running session read as unreachable"
kp_mux_ensure_session kp144 && pass "t8: ensure accepts a running session" || fail "t8: ensure refused a running session"

# Test 9: `pane read` text is passed through, never parsed as JSON
# ---------------------------------------------------------------------------
echo "--- Test 9: plain text is not JSON ---"
kp_test_fake_herdr_state
mock_herdr w1:p6 kp-144-t9 1
json_body='{"result":{"panes":[{"pane_id":"w1:p6","label":"not json"}]},"type":"pane_list"}'
kp_test_herdr_read w1:p6 "$json_body"
out=$(KP_MUX=herdr KP_MUX_SESSION=kp144 kp_mux_capture w1:p6 --tail 5)
[ "$out" = "$json_body" ] && pass "t9: a JSON-looking pane body comes out verbatim" || fail "t9: capture rewrote the body: $out"

# Test 10: in herdr mode no tmux command runs
# ---------------------------------------------------------------------------
echo "--- Test 10: herdr mode runs no tmux ---"
mkdir -p "$T/mux-shim"
cat > "$T/mux-shim/tmux" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/mux-tmux.log"
exec "$T/bin/tmux" "\$@"
EOF
chmod +x "$T/mux-shim/tmux"
: > "$T/mux-tmux.log"
t10="$T/tasks/t10-herdr"
mkdir -p "$t10"
printf 'TASK_ID=t10-herdr\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w1:p6\nMUX_LABEL=kp-144-t9\n' > "$t10/task.env"
PATH="$T/mux-shim:$PATH" kp_mux_find "$t10" >/dev/null \
  && PATH="$T/mux-shim:$PATH" kp_mux_capture "$KP_WINDOW_ID" --scrollback 10 >/dev/null \
  && PATH="$T/mux-shim:$PATH" kp_mux_send_text "$KP_WINDOW_ID" hi >/dev/null \
  && PATH="$T/mux-shim:$PATH" kp_mux_send_enter "$KP_WINDOW_ID" >/dev/null \
  && PATH="$T/mux-shim:$PATH" kp_mux_activity "$KP_WINDOW_ID" >/dev/null \
  && PATH="$T/mux-shim:$PATH" kp_mux_target_state "$KP_WINDOW_ID" >/dev/null \
  && pass "t10: the herdr verbs ran" || fail "t10: a herdr verb failed"
[ -s "$T/mux-tmux.log" ] && fail "t10: herdr mode ran tmux: $(cat "$T/mux-tmux.log")" || pass "t10: herdr mode issued zero tmux commands"

# Test 11: no backend call outside its own file
# ---------------------------------------------------------------------------
echo "--- Test 11: backend calls stay in the backend files ---"
raw=$(grep -rnE '(^|[;&|!]|\$\()[[:space:]]*herdr([[:space:]]|$)' \
  "$KP_ROOT/bin" "$KP_ROOT/lib" \
  | grep -v "^$KP_ROOT/lib/mux-herdr.sh:" \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -z "$raw" ]; then
  pass "t11: no command calls herdr outside lib/mux-herdr.sh"
else
  fail "t11: these call herdr without the adapter: $raw"
fi
raw=$(grep -rnE '(^|[;&|!]|\$\()[[:space:]]*tmux([[:space:]]|$)' \
  "$KP_ROOT/bin" "$KP_ROOT/lib" \
  | grep -v "^$KP_ROOT/lib/tmux.sh:" \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -z "$raw" ]; then
  pass "t11: no command calls tmux outside lib/tmux.sh"
else
  fail "t11: these call tmux without kp_tmux: $raw"
fi
# A hard-coded absolute binary path is the one way around the PATH shim, and the
# pane environment injects HERDR_BIN_PATH, so nothing may read it.
raw=$(grep -rn 'HERDR_BIN_PATH' "$KP_ROOT/bin" "$KP_ROOT/lib" || true)
if [ -z "$raw" ]; then
  pass "t11: nothing addresses herdr by an absolute binary path"
else
  fail "t11: these read HERDR_BIN_PATH: $raw"
fi

# Test 12: the CLI against a MUX=herdr record, with a logging tmux first on PATH
# ---------------------------------------------------------------------------
echo "--- Test 12: the CLI reaches a Herdr record with no tmux call ---"
kp_test_fake_herdr_state
mock_herdr w1:p7 kp-144-cli 1
kp_test_herdr_read w1:p7 "cli-pane-one
cli-pane-two"
t12_peek="$KINGPIN_HOME/tasks/t12-peek"
mkdir -p "$t12_peek"
# The recorded id is stale; the label is what resolves, and peek must not write
# the resolved id back.
printf 'TASK_ID=t12-peek\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w9:p9\nMUX_LABEL=kp-144-cli\n' > "$t12_peek/task.env"
t12_send="$KINGPIN_HOME/tasks/t12-send"
mkdir -p "$t12_send"
printf 'TASK_ID=t12-send\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w1:p7\nMUX_LABEL=kp-144-cli\n' > "$t12_send/task.env"
t12_gone="$KINGPIN_HOME/tasks/t12-gone"
mkdir -p "$t12_gone"
printf 'TASK_ID=t12-gone\nMUX=herdr\nMUX_SESSION=kp144\nMUX_TARGET=w8:p8\nMUX_LABEL=kp-144-gone\nHARNESS=claude\nCREATED=%s\n' \
  "$(kp_test_iso_ago 100)" > "$t12_gone/task.env"

: > "$T/mux-tmux.log"
t12_before=$(cksum "$t12_peek/task.env")
t12_peek_out=$(PATH="$T/mux-shim:$PATH" "$KP_BIN/kingpin-peek" t12-peek --lines 5)
t12_peek_rc=$?
t12_after=$(cksum "$t12_peek/task.env")
[ "$t12_peek_rc" -eq 0 ] && pass "t12: peek exits 0 on a Herdr record" || fail "t12: peek exited $t12_peek_rc"
case "$t12_peek_out" in
  *"cli-pane-one"*"cli-pane-two"*) pass "t12: peek reads the Herdr pane text" ;;
  *) fail "t12: peek printed '$t12_peek_out'" ;;
esac
# M1: peek is read-only, so a stale MUX_TARGET stays stale rather than being
# rewritten by a reader.
[ "$t12_before" = "$t12_after" ] \
  && pass "t12: peek leaves the record byte-identical (stale MUX_TARGET kept)" \
  || fail "t12: peek rewrote task.env: $(grep MUX_TARGET "$t12_peek/task.env")"

t12_send_out=$(PATH="$T/mux-shim:$PATH" "$KP_BIN/kingpin-send" t12-send "hello cli")
t12_send_rc=$?
[ "$t12_send_rc" -eq 0 ] && pass "t12: send exits 0 on a Herdr record" || fail "t12: send exited $t12_send_rc"
[ "$t12_send_out" = "OK: sent to kp144:kp-144-cli (w1:p7)" ] \
  && pass "t12: send names the Herdr pane label and id" \
  || fail "t12: send printed '$t12_send_out'"
log_has "--session kp144 pane send-text w1:p7 hello cli" \
  && pass "t12: send typed through the Herdr backend" \
  || fail "t12: herdr calls: $(cat "$KP_TEST_HERDR_CALLS")"
log_has "--session kp144 pane send-keys w1:p7 enter" \
  && pass "t12: send pressed Enter through the Herdr backend" \
  || fail "t12: herdr calls: $(cat "$KP_TEST_HERDR_CALLS")"

t12_gone_out=$(PATH="$T/mux-shim:$PATH" "$KP_BIN/kingpin-launch-check" "$t12_gone")
t12_gone_rc=$?
[ "$t12_gone_rc" -eq 0 ] && pass "t12: launch-check records a Herdr worker that never reported" || fail "t12: launch-check exited $t12_gone_rc"
case "$t12_gone_out" in
  "failed: no status: t12-gone (claude) exited, herdr pane gone;"*) pass "t12: the failure line names the Herdr pane" ;;
  *) fail "t12: launch-check printed '$t12_gone_out'" ;;
esac
grep -qF "$t12_gone_out" "$t12_gone/status" \
  && pass "t12: launch-check appended the line to the status file" \
  || fail "t12: status file: $(cat "$t12_gone/status" 2>/dev/null || true)"
[ -s "$T/mux-tmux.log" ] \
  && fail "t12: the Herdr CLI ran tmux: $(cat "$T/mux-tmux.log")" \
  || pass "t12: the Herdr CLI issued zero tmux commands"

# Test 13: the curator gate reads the record's mux, and refuses an unknown one
# ---------------------------------------------------------------------------
echo "--- Test 13: the curator window check and the record's mux ---"
# shellcheck source=../lib/curator.sh
. "$KP_ROOT/lib/curator.sh"
kp_test_fake_herdr_state
mock_herdr w1:p8 curator 1
t13_dir="$KINGPIN_HOME/tasks/curator"
mkdir -p "$t13_dir"
# No MUX_SESSION: the session fallback must resolve from the record's mux (herdr),
# not from the tmux socket the environment names.
printf 'TASK_ID=curator\nMUX=herdr\nMUX_TARGET=w1:p8\nMUX_LABEL=curator\n' > "$t13_dir/task.env"
t13_old_sock=$KINGPIN_TMUX_SOCKET
export KINGPIN_TMUX_SOCKET=kingpin-other
: > "$KP_TEST_HERDR_CALLS"
t13_state=$(KP_MUX='' kp_curate_window_state "$KINGPIN_HOME")
export KINGPIN_TMUX_SOCKET=$t13_old_sock
[ "$t13_state" = "alive" ] && pass "t13: a Herdr curator record reads alive" || fail "t13: curator state '$t13_state'"
log_has "--session kingpin pane get w1:p8" \
  && pass "t13: the session fallback reads the record's mux, not KINGPIN_MUX" \
  || fail "t13: herdr calls: $(cat "$KP_TEST_HERDR_CALLS")"
# L2: an unreadable MUX= is reported as unknown, never guessed as tmux.
printf 'TASK_ID=curator\nMUX=screen\nMUX_TARGET=w1:p8\n' > "$t13_dir/task.env"
t13_bad=$(KP_MUX='' kp_curate_window_state "$KINGPIN_HOME" 2>/dev/null)
[ "$t13_bad" = "unknown" ] \
  && pass "t13: an unreadable record mux reads unknown, not tmux" \
  || fail "t13: unreadable record read '$t13_bad'"
rm -rf "$t13_dir"

# Test 14: the real-Herdr guard's failure path
# ---------------------------------------------------------------------------
echo "--- Test 14: the real-Herdr guard ---"
printf 'api snapshot\n' > "$T/unexpected-herdr-real.log"
if ( KP_TEST_HERDR_REAL_LOG="$T/unexpected-herdr-real.log"; kp_test_check_herdr_real ) > "$T/unexpected-herdr-real.out" 2>&1; then
  fail "an undeclared real herdr call did not fail the run"
else
  grep -Fq "herdr api snapshot" "$T/unexpected-herdr-real.out" \
    && pass "an undeclared real herdr call fails the run and names the arguments" \
    || fail "the real-herdr failure does not name the arguments: $(cat "$T/unexpected-herdr-real.out")"
fi
if ( KP_TEST_ALLOW_REAL_HERDR=1 KP_TEST_HERDR_REAL_LOG="$T/unexpected-herdr-real.log"; kp_test_check_herdr_real ) >/dev/null 2>&1; then
  pass "a declared real herdr call passes the guard"
else
  fail "the opt-in declaration did not pass the real-herdr guard"
fi

kp_test_finish MUX
