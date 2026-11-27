#!/usr/bin/env bash
# Verification test for `kingpin queue` (bin/kingpin-queue), the issue-queue runner.
#
# The runner keeps the fleet at N workers by spawning the next open issue in review mode.
# The suite drives one pass at a time through `--once`, with `kingpin list` and
# `kingpin spawn` replaced by a fake dispatcher in the private bin copy and `gh` replaced
# through KINGPIN_GH by a fake that answers from JSON files in the shape the real
# `gh --json number,labels` and `gh --json state,labels` print. So the label filter in
# lib/queue-issues.mjs runs for real, and nothing reaches the network or a tmux server.
#
# Test 1 is the race of issue #255: a worker filed its own issue through /create-issue,
# the issue carried `kingpin:claimed` from the create call, and its `issue:` line had
# not landed yet. The runner must not spawn a second worker for it.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
kp_test_setup "queue"
kp_test_private_bin
kp_test_project

Q=$KINGPIN_HOME/queue
# kp_run fills these through printf -v.
out=''
rc=0

# The fake dispatcher: `list` prints the fleet rows in $T/fleet.txt, `spawn` records its
# argv and fails while $T/spawn-fail exists, and any other command is a call this suite
# did not expect.
cat > "$KP_BIN/kingpin" << EOF
#!/usr/bin/env bash
case "\${1:-}" in
  list) cat "$T/fleet.txt" 2>/dev/null; exit 0 ;;
  spawn)
    shift
    printf '%s\n' "\$*" >> "$T/spawn-calls"
    if [ -e "$T/spawn-fail" ]; then echo "kingpin-spawn: fake failure" >&2; exit 1; fi
    echo "OK: spawned fake"
    exit 0
    ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$KP_BIN/kingpin"
: > "$T/fleet.txt"

git -C "$T/proj" config remote.origin.url https://github.com/acme/widgets.git

mkdir -p "$T/gh"
cat > "$T/fake-gh" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh-calls"
[ -e "$T/gh/down" ] && exit 1
case "\${1:-} \${2:-}" in
  "issue list") cat "$T/gh/list.json" ;;
  "issue view")
    f="$T/gh/view-\$3.json"
    [ -f "\$f" ] || exit 1
    cat "\$f"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fake-gh"
export KINGPIN_GH=$T/fake-gh

# gh_issue <n> <OPEN|CLOSED> [label...]: write the `issue view` answer for <n> and rebuild
# the `issue list` answer from every open issue, in gh's own shape.
gh_issue() {
  local n=$1 state=$2 labels='' l f list='' entry num
  shift 2
  for l in "$@"; do
    labels="$labels${labels:+,}{\"name\":\"$l\"}"
  done
  printf '{"labels":[%s],"state":"%s"}\n' "$labels" "$state" > "$T/gh/view-$n.json"
  printf '%s\n' "$labels" > "$T/gh/labels-$n"
  for f in "$T"/gh/view-*.json; do
    [ -f "$f" ] || continue
    grep -q '"state":"OPEN"' "$f" || continue
    num=${f##*/view-}
    num=${num%.json}
    entry="{\"labels\":[$(cat "$T/gh/labels-$num")],\"number\":$num}"
    list="$list${list:+,}$entry"
  done
  printf '[%s]\n' "$list" > "$T/gh/list.json"
}

gh_reset() {
  rm -f "$T"/gh/view-*.json "$T"/gh/labels-* "$T/gh/down"
  printf '[]\n' > "$T/gh/list.json"
}

# Every pass starts with no recorded calls; reset_queue also empties the runner's state.
clear_calls() { : > "$T/spawn-calls"; : > "$T/gh-calls"; }
reset_queue() {
  clear_calls
  mkdir -p "$Q"
  : > "$Q/queue"; : > "$Q/started"; : > "$Q/skip"
  rm -f "$Q/pause" "$Q/log"
}

stamp_today() {
  mkdir -p "$KINGPIN_HOME/curator"
  printf '%s\n%s\n' "$(date +%s)" "$(date +%F)" > "$KINGPIN_HOME/curator/last-run"
}

# queue_once [flag...]: one pass of the real command, output in $out, status in $rc.
queue_once() {
  clear_calls
  kp_run out rc "$KP_BIN/kingpin-queue" demo-auto --once "$@"
}

spawned() { grep -qx -- "demo-auto --issue $1 --mode review" "$T/spawn-calls"; }
spawn_count() { grep -c . "$T/spawn-calls" || true; }

mk_task() { # mk_task <id> [ISSUE value]
  mkdir -p "$KINGPIN_HOME/tasks/$1"
  printf 'TASK_ID=%s\nPROJECT=demo-auto\nISSUE=%s\nMODE=review\n' "$1" "${2:-}" > "$KINGPIN_HOME/tasks/$1/task.env"
}

stamp_today
gh_reset

# Test 1: the #255 timing (the red gate)
# ---------------------------------------------------------------------------
echo "--- Test 1: a claimed issue whose issue: line has not landed is not spawned ---"
reset_queue
mk_task kp-filer
printf 'needs-input: approve the draft\n' > "$KINGPIN_HOME/tasks/kp-filer/status"
printf 'kp-filer demo-auto agy review -\n' > "$T/fleet.txt"
gh_issue 255 OPEN bug kingpin:claimed
queue_once
[ "$rc" -eq 0 ] && pass "t1: the pass exits 0" || fail "t1: rc=$rc out=$out"
[ "$(spawn_count)" -eq 0 ] && pass "t1: nothing is spawned for the claimed #255" || fail "t1: spawned: $(cat "$T/spawn-calls")"
grep -qx 255 "$Q/queue" && fail "t1: the refill queued the claimed #255" || pass "t1: the refill skips the claimed #255"
grep -q 'nothing spawned' <<< "$out" && pass "t1: the pass says nothing was spawned" || fail "t1: out=$out"

echo "--- Test 1b: a claimed issue already in the queue is re-read before the spawn ---"
printf '255\n' >> "$Q/queue"
queue_once
[ "$(spawn_count)" -eq 0 ] && pass "t1b: nothing is spawned for the queued, claimed #255" || fail "t1b: spawned: $(cat "$T/spawn-calls")"
grep -q '^issue view 255 ' "$T/gh-calls" && pass "t1b: the label is read right before the spawn" || fail "t1b: gh calls: $(cat "$T/gh-calls")"

# Test 2: the next pass picks up an unlabelled issue; removing the label releases one
# ---------------------------------------------------------------------------
echo "--- Test 2: an unlabelled issue is spawned on the next pass ---"
gh_issue 256 OPEN enhancement
queue_once
[ "$rc" -eq 0 ] && pass "t2: the pass exits 0" || fail "t2: rc=$rc out=$out"
spawned 256 && pass "t2: #256 is spawned in review mode" || fail "t2: spawn calls: $(cat "$T/spawn-calls")"
[ "$(spawn_count)" -eq 1 ] && pass "t2: one spawn per pass" || fail "t2: spawn calls: $(cat "$T/spawn-calls")"
grep -qx 256 "$Q/started" && pass "t2: started records #256" || fail "t2: started: $(cat "$Q/started")"
grep -q 'spawned #256' "$Q/log" && pass "t2: the log names the spawn" || fail "t2: log: $(cat "$Q/log")"
grep -q 'OK: spawned #256' <<< "$out" && pass "t2: --once prints the spawned issue" || fail "t2: out=$out"
queue_once
[ "$(spawn_count)" -eq 0 ] && pass "t2: a second pass spawns nothing new" || fail "t2: spawned again: $(cat "$T/spawn-calls")"
gh_issue 255 OPEN bug
sed -i.bak '/^255$/d' "$Q/queue"
queue_once
spawned 255 && pass "t2: removing the label releases #255 to the next pass" || fail "t2: spawn calls: $(cat "$T/spawn-calls") out=$out"
rm -rf "$KINGPIN_HOME/tasks/kp-filer"

# Test 3: live holders
# ---------------------------------------------------------------------------
echo "--- Test 3: an issue a live task record holds is never spawned ---"
reset_queue
gh_reset
: > "$T/fleet.txt"
mk_task kp-a 260
mk_task kp-b
printf 'issue: #261\n' > "$KINGPIN_HOME/tasks/kp-b/status"
mk_task kp-c 25
printf 'issue: #25 https://github.com/acme/widgets/issues/25\n' > "$KINGPIN_HOME/tasks/kp-c/status"
mkdir -p "$KINGPIN_HOME/archive/kp-d"
printf 'ISSUE=262\n' > "$KINGPIN_HOME/archive/kp-d/task.env"
printf 'issue: #262 https://github.com/acme/widgets/issues/262\n' > "$KINGPIN_HOME/archive/kp-d/status"
ln -s "$KINGPIN_HOME/archive/kp-d" "$KINGPIN_HOME/tasks/kp-d"
gh_issue 255 OPEN
gh_issue 260 OPEN
gh_issue 261 OPEN
gh_issue 262 OPEN
: > "$T/spawn-all"
for _ in 1 2 3 4; do
  queue_once
  cat "$T/spawn-calls" >> "$T/spawn-all"
done
grep -qx 'demo-auto --issue 255 --mode review' "$T/spawn-all" && pass "t3: #25 in a record does not hold #255" || fail "t3: spawns: $(cat "$T/spawn-all")"
grep -qx 'demo-auto --issue 262 --mode review' "$T/spawn-all" && pass "t3: an archived link holds nothing (#262 spawned)" || fail "t3: spawns: $(cat "$T/spawn-all")"
grep -q -- '--issue 260 ' "$T/spawn-all" && fail "t3: #260, held through task.env ISSUE=, was spawned" || pass "t3: task.env ISSUE=260 holds #260"
grep -q -- '--issue 261 ' "$T/spawn-all" && fail "t3: #261, held by a bare issue: line, was spawned" || pass "t3: a bare 'issue: #261' line holds #261"
[ "$(grep -c . "$T/spawn-all")" -eq 2 ] && pass "t3: exactly two spawns over four passes" || fail "t3: spawns: $(cat "$T/spawn-all")"
rm -rf "$KINGPIN_HOME/tasks/kp-a" "$KINGPIN_HOME/tasks/kp-b" "$KINGPIN_HOME/tasks/kp-c" "$KINGPIN_HOME/tasks/kp-d" "$KINGPIN_HOME/archive/kp-d"

# Test 4: pause, a full fleet, the stalled warning
# ---------------------------------------------------------------------------
echo "--- Test 4: pause, slot limit and the stalled warning ---"
reset_queue
gh_reset
gh_issue 270 OPEN
: > "$Q/pause"
queue_once
[ "$rc" -eq 0 ] && pass "t4: a paused pass exits 0" || fail "t4: rc=$rc out=$out"
[ "$(spawn_count)" -eq 0 ] && pass "t4: a paused pass spawns nothing" || fail "t4: spawned while paused"
[ ! -s "$T/gh-calls" ] && pass "t4: a paused pass calls no gh" || fail "t4: gh calls while paused: $(cat "$T/gh-calls")"
grep -q '(paused)' <<< "$out" && pass "t4: the pass names the pause" || fail "t4: out=$out"
rm -f "$Q/pause"

mk_task kp-f1
printf 'issue: #1\nfailed: boom\n' > "$KINGPIN_HOME/tasks/kp-f1/status"
printf 'kp-f1 demo-auto\nkp-f2 demo-auto\nkp-f3 demo-auto\n' > "$T/fleet.txt"
queue_once
[ "$(spawn_count)" -eq 0 ] && pass "t4: a fleet at the default limit of 3 spawns nothing" || fail "t4: spawned with a full fleet"
grep -q '(full)' <<< "$out" && pass "t4: the pass names the full fleet" || fail "t4: out=$out"
[ "$(grep -c 'stalled: kp-f1 holds a slot' "$Q/log")" -eq 1 ] && pass "t4: a failed: task is named once in the log" || fail "t4: log: $(cat "$Q/log")"
kp_run out rc env KINGPIN_QUEUE_MAX=4 "$KP_BIN/kingpin-queue" demo-auto --once
spawned 270 && pass "t4: KINGPIN_QUEUE_MAX=4 frees a slot" || fail "t4: spawn calls: $(cat "$T/spawn-calls") out=$out"
[ "$(grep -c 'stalled: kp-f1 holds a slot' "$Q/log")" -eq 1 ] && pass "t4: a second pass inside ten minutes does not warn again" || fail "t4: log: $(cat "$Q/log")"
rm -rf "$KINGPIN_HOME/tasks/kp-f1"
: > "$T/fleet.txt"

# Test 5: the curator yield
# ---------------------------------------------------------------------------
echo "--- Test 5: an idle fleet yields to the daily curator ---"
reset_queue
rm -f "$KINGPIN_HOME/curator/last-run"
kp_run out rc env KINGPIN_CURATOR_AUTO=1 "$KP_BIN/kingpin-queue" demo-auto --once
[ "$rc" -eq 0 ] && pass "t5: a yielding pass exits 0" || fail "t5: rc=$rc out=$out"
[ "$(spawn_count)" -eq 0 ] && pass "t5: an idle fleet with the curator due spawns nothing" || fail "t5: spawned while the curator is due"
grep -q '(curator)' <<< "$out" && pass "t5: the pass names the curator yield" || fail "t5: out=$out"
stamp_today
clear_calls
kp_run out rc env KINGPIN_CURATOR_AUTO=1 "$KP_BIN/kingpin-queue" demo-auto --once
spawned 270 && pass "t5: with today's curator run stamped, the pass spawns" || fail "t5: spawn calls: $(cat "$T/spawn-calls") out=$out"
reset_queue
rm -f "$KINGPIN_HOME/curator/last-run"
kp_run out rc env KINGPIN_CURATOR_AUTO=0 "$KP_BIN/kingpin-queue" demo-auto --once
spawned 270 && pass "t5: KINGPIN_CURATOR_AUTO=0 skips the yield" || fail "t5: spawn calls: $(cat "$T/spawn-calls") out=$out"
stamp_today

# Test 6: the repository
# ---------------------------------------------------------------------------
echo "--- Test 6: every gh call names the repository ---"
reset_queue
queue_once
grep -q '^issue ' "$T/gh-calls" && pass "t6: the pass reads issues through gh" || fail "t6: no gh issue call"
if grep '^issue ' "$T/gh-calls" | grep -vq -- '--repo acme/widgets'; then
  fail "t6: a gh call without --repo acme/widgets: $(cat "$T/gh-calls")"
else
  pass "t6: every issue call carries --repo acme/widgets (from the origin)"
fi
reset_queue
queue_once --repo other/thing
if grep '^issue ' "$T/gh-calls" | grep -vq -- '--repo other/thing'; then
  fail "t6: --repo did not reach every call: $(cat "$T/gh-calls")"
else
  pass "t6: --repo other/thing overrides the origin"
fi
git -C "$T/proj" config remote.origin.url "$T/origin.git"
reset_queue
queue_once
[ "$rc" -eq 1 ] && pass "t6: a local-path origin with no --repo exits 1" || fail "t6: rc=$rc out=$out"
grep -q -- '--repo' <<< "$out" && pass "t6: the refusal names --repo" || fail "t6: out=$out"
[ "$(spawn_count)" -eq 0 ] && pass "t6: the refusal spawns nothing" || fail "t6: spawned on a refusal"
git -C "$T/proj" config remote.origin.url https://github.com/acme/widgets.git

# Test 7: the session
# ---------------------------------------------------------------------------
echo "--- Test 7: the session reaches kingpin spawn ---"
reset_queue
queue_once --tmux-session S9
grep -qx 'demo-auto --issue 270 --mode review --tmux-session S9' "$T/spawn-calls" && pass "t7: --tmux-session S9 is forwarded" || fail "t7: spawn calls: $(cat "$T/spawn-calls")"
reset_queue
queue_once
grep -q -- '--tmux-session' "$T/spawn-calls" && fail "t7: a session was forwarded without --tmux-session" || pass "t7: without the flag spawn resolves its own session"
raw_tmux=$(grep -nE '(^|[;&|!]|\$\()[[:space:]]*tmux([[:space:]]|$)' "$KP_ROOT/bin/kingpin-queue" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
[ -z "$raw_tmux" ] && pass "t7: bin/kingpin-queue runs no tmux of its own" || fail "t7: raw tmux calls: $raw_tmux"

# Test 8: the dry run
# ---------------------------------------------------------------------------
echo "--- Test 8: --dry-run spawns nothing and names the skips ---"
reset_queue
gh_reset
gh_issue 255 OPEN kingpin:claimed
gh_issue 256 OPEN
gh_issue 257 OPEN
mk_task kp-x 256
printf 'kp-x demo-auto\n' > "$T/fleet.txt"
printf '255\n' > "$Q/queue"
kp_run out rc "$KP_BIN/kingpin-queue" demo-auto --dry-run
[ "$rc" -eq 0 ] && pass "t8: --dry-run exits 0" || fail "t8: rc=$rc out=$out"
grep -qx 'live=1' <<< "$out" && pass "t8: --dry-run prints the live count" || fail "t8: out=$out"
[ "$(tail -n 1 <<< "$out")" = 257 ] && pass "t8: --dry-run prints the next issue" || fail "t8: out=$out"
grep -q 'skip #255: claimed' <<< "$out" && pass "t8: a claimed skip is named" || fail "t8: out=$out"
grep -q 'skip #256: held by kp-x' <<< "$out" && pass "t8: a held skip is named with its holder" || fail "t8: out=$out"
[ "$(spawn_count)" -eq 0 ] && pass "t8: --dry-run spawns nothing" || fail "t8: spawned on a dry run"
[ ! -s "$Q/started" ] && pass "t8: --dry-run records no start" || fail "t8: started: $(cat "$Q/started")"
gh_issue 257 CLOSED
clear_calls
kp_run out rc "$KP_BIN/kingpin-queue" demo-auto --dry-run
[ "$(tail -n 1 <<< "$out")" = none ] && pass "t8: --dry-run prints none when nothing is spawnable" || fail "t8: out=$out"
kp_run out rc "$KP_BIN/kingpin-queue" demo-auto --dry-run --once
[ "$rc" -eq 2 ] && pass "t8: --dry-run with --once exits 2" || fail "t8: rc=$rc out=$out"
rm -rf "$KINGPIN_HOME/tasks/kp-x"
: > "$T/fleet.txt"

# Test 9: a failed spawn
# ---------------------------------------------------------------------------
echo "--- Test 9: a failed spawn exits 1 and records no start ---"
reset_queue
gh_reset
gh_issue 280 OPEN
: > "$T/spawn-fail"
queue_once
[ "$rc" -eq 1 ] && pass "t9: a failed spawn exits 1" || fail "t9: rc=$rc out=$out"
grep -qx 280 "$Q/started" && fail "t9: started gained #280" || pass "t9: started does not gain the failed issue"
grep -q 'spawn failed for #280' "$Q/log" && pass "t9: the log names the failed spawn" || fail "t9: log: $(cat "$Q/log")"
grep -q 'fake failure' "$Q/log" && pass "t9: the spawn's own output reaches the log" || fail "t9: log: $(cat "$Q/log")"
rm -f "$T/spawn-fail"

# Test 10: arguments
# ---------------------------------------------------------------------------
echo "--- Test 10: arguments ---"
rm -rf "$Q"
kp_run out rc "$KP_BIN/kingpin-queue" --help
[ "$rc" -eq 0 ] && grep -qi usage <<< "$out" && pass "t10: --help exits 0 with usage" || fail "t10: rc=$rc out=$out"
[ ! -e "$Q" ] && pass "t10: --help creates no queue directory" || fail "t10: --help created $Q"
kp_run out rc "$KP_BIN/kingpin-queue" demo-auto --bogus
[ "$rc" -eq 2 ] && pass "t10: an unknown flag exits 2" || fail "t10: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin-queue" --once
[ "$rc" -eq 2 ] && pass "t10: a missing project exits 2" || fail "t10: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin-queue" demo-auto extra --once
[ "$rc" -eq 2 ] && pass "t10: a second positional exits 2" || fail "t10: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin-queue" no-such-project --once
[ "$rc" -eq 1 ] && pass "t10: an unknown project exits 1" || fail "t10: rc=$rc out=$out"
kp_run out rc env KINGPIN_QUEUE_MAX=0 "$KP_BIN/kingpin-queue" demo-auto --once
[ "$rc" -eq 2 ] && pass "t10: KINGPIN_QUEUE_MAX=0 exits 2" || fail "t10: rc=$rc out=$out"
kp_run out rc env KINGPIN_QUEUE_MAX=x "$KP_BIN/kingpin-queue" demo-auto --once
[ "$rc" -eq 2 ] && pass "t10: KINGPIN_QUEUE_MAX=x exits 2" || fail "t10: rc=$rc out=$out"
kp_run out rc "$KP_BIN/kingpin-queue" demo-auto --repo
[ "$rc" -eq 2 ] && pass "t10: --repo with no value exits 2" || fail "t10: rc=$rc out=$out"

# Test 11: the shipped unit
# ---------------------------------------------------------------------------
echo "--- Test 11: the shipped kingpin-queue user unit ---"
unit="$KP_ROOT/systemd/kingpin-queue.service"
[ -f "$unit" ] && pass "t11: the unit file ships with the checkout" || fail "t11: missing $unit"
if [ -f "$unit" ]; then
  [ "$(grep -c '^ExecStart=' "$unit")" = "1" ] && pass "t11: the unit has exactly one ExecStart" || fail "t11: ExecStart lines: $(grep -c '^ExecStart=' "$unit")"
  grep -qE '^ExecStart=.*bin/kingpin queue [a-z0-9_-]+$' "$unit" && pass "t11: ExecStart runs the queue daemon for one project" || fail "t11: ExecStart does not run 'kingpin queue <project>'"
  grep -qE '^ExecStart=.*(--once|--dry-run)' "$unit" && fail "t11: ExecStart passes a one-shot flag" || pass "t11: ExecStart passes no --once or --dry-run"
  grep -qx 'Type=simple' "$unit" && pass "t11: the unit is Type=simple" || fail "t11: no Type=simple"
  grep -qx 'Restart=always' "$unit" && pass "t11: the unit restarts on every exit" || fail "t11: no Restart=always"
  grep -qx 'RestartSec=30' "$unit" && pass "t11: the unit waits 30s between restarts" || fail "t11: no RestartSec=30"
  grep -qE '^Environment=PATH=' "$unit" && pass "t11: the unit carries a PATH" || fail "t11: no Environment=PATH"
  grep -qx 'WantedBy=default.target' "$unit" && pass "t11: the unit installs for the default target" || fail "t11: no WantedBy=default.target"
fi

# Test 12: the preamble claim and the real dispatcher
# ---------------------------------------------------------------------------
echo "--- Test 12: the worker preamble tells a filer to claim its issue ---"
preamble="$KP_ROOT/worker/preamble.md"
grep -q 'kingpin:claimed' "$preamble" && pass "t12: the preamble names kingpin:claimed" || fail "t12: no kingpin:claimed in $preamble"
grep -q 'gh issue create' "$preamble" && grep -q -- '--label kingpin:claimed' "$preamble" \
  && pass "t12: the preamble claims in the gh issue create call" || fail "t12: no 'gh issue create' with '--label kingpin:claimed'"
grep -q 'gh label create' "$preamble" && pass "t12: the preamble creates the label first" || fail "t12: no gh label create"
kp_run out rc "$KP_ROOT/bin/kingpin" queue --help
[ "$rc" -eq 0 ] && grep -qi usage <<< "$out" && pass "t12: kingpin queue --help reaches the command" || fail "t12: rc=$rc out=$out"

kp_test_finish QUEUE
