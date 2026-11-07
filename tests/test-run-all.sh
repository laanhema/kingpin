#!/usr/bin/env bash
# tests/run-all.sh (issue #250): the one command that runs the lint and every suite, each in a
# private copy of the checkout, a bounded number at a time.
#
# The runner takes a --root <dir> argument, so this suite drives the real runner against small
# fixture roots of fake jobs, built here, instead of running the real suites (which the full
# sweep does). The fake jobs only write inside their own copy, the fixture or $T.
set -euo pipefail

. "$(dirname "$0")/lib.sh"

KP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER=$KP_ROOT/tests/run-all.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The runner makes its run directory under TMPDIR, so a private one shows what it leaves behind.
export TMPDIR=$T/tmp
mkdir -p "$TMPDIR"

# fake <fixture> <file>: write tests/<file> in the fixture from stdin, under a bash header.
fake() {
  { printf '#!/usr/bin/env bash\nset -euo pipefail\n'; cat; } > "$1/tests/$2"
  chmod +x "$1/tests/$2"
}

# fixture_init <fixture>: commit the fixture, so it is a git checkout the runner accepts.
fixture_init() {
  (
    cd "$1" || exit 1
    git init -q .
    git config user.email test@example.com
    git config user.name kingpin-test
    git add -A
    git commit -qm fixture
  )
}

# new_fixture <name>: a fixture root with a passing lint and two passing suites, not yet committed.
new_fixture() {
  local d=$T/$1
  mkdir -p "$d/tests" "$d/bin"
  printf 'ORIGINAL\n' > "$d/bin/kingpin-send"
  fake "$d" lint.sh <<< 'echo lint-ran'
  fake "$d" test-ok.sh <<< 'echo ok-ran'
  fake "$d" test-ok2.sh <<< 'echo ok2-ran'
  printf '%s\n' "$d"
}

# runner <args...>: run the real runner, setting RUN_RC and RUN_OUT without aborting the suite.
runner() {
  RUN_RC=0
  RUN_OUT=$("$RUNNER" "$@" 2>&1) || RUN_RC=$?
}

# leftover: the run directories the runner left in the private TMPDIR.
leftover() { compgen -G "$TMPDIR/ra.*" > /dev/null; }
no_leftover() { ! leftover; }

# not_alive <pid>: true once the process is gone.
not_alive() { ! kill -0 "$1" 2>/dev/null; }

# 1. A green fixture: a PASS line per job, the summary line, exit 0, lint first.
A=$(new_fixture green)
fixture_init "$A"
runner --root "$A" -j 1
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^PASS lint (' <<< "$RUN_OUT" \
  && grep -q '^PASS test-ok (' <<< "$RUN_OUT" \
  && grep -q '^PASS test-ok2 (' <<< "$RUN_OUT" \
  && [ "$(tail -n 1 <<< "$RUN_OUT")" = "run-all: ALL 3 JOBS PASSED" ]; then
  pass "a green fixture prints a PASS line per job and ALL 3 JOBS PASSED, exit 0"
else
  fail "the green fixture did not pass cleanly (rc=$RUN_RC): $RUN_OUT"
fi
order=$(grep -o '^PASS [a-z0-9-]*' <<< "$RUN_OUT" | tr '\n' ' ')
if [ "$order" = "PASS lint PASS test-ok PASS test-ok2 " ]; then
  pass "with -j 1 the lint runs first and the suites follow in alphabetical order"
else
  fail "the job order was: $order"
fi
runner --root "$A" test-ok
if [ "$RUN_RC" -eq 0 ] && grep -q 'ALL 1 JOBS PASSED' <<< "$RUN_OUT" && ! grep -q 'test-ok2\|lint' <<< "$RUN_OUT"; then
  pass "naming a job label runs only that job"
else
  fail "a named job did not run alone (rc=$RUN_RC): $RUN_OUT"
fi
if no_leftover; then
  pass "a finished run removes its run directory"
else
  fail "a run directory was left in $TMPDIR"
fi

# 2. A failing suite: non-zero exit, a FAIL line, its log, a last line that names it alone.
B=$(new_fixture red)
fake "$B" test-bad.sh <<< 'echo BOOM-MARKER; exit 3'
fixture_init "$B"
runner --root "$B"
last=$(tail -n 1 <<< "$RUN_OUT")
if [ "$RUN_RC" -eq 1 ] \
  && grep -q '^FAIL test-bad (rc=3' <<< "$RUN_OUT" \
  && grep -q '^==== test-bad ====$' <<< "$RUN_OUT" \
  && grep -q '^BOOM-MARKER$' <<< "$RUN_OUT" \
  && [ "$last" = "run-all: 1 of 4 FAILED: test-bad" ] \
  && grep -q '^PASS test-ok (' <<< "$RUN_OUT" \
  && ! grep -q '^==== test-ok' <<< "$RUN_OUT"; then
  pass "a failing suite exits 1, prints FAIL and its log, names only itself, and the green jobs still PASS"
else
  fail "the failing fixture was reported wrongly (rc=$RUN_RC): $RUN_OUT"
fi

# 3. The invoking checkout is untouched, and the jobs do not see each other's writes.
C=$(new_fixture swap)
SHARED=$T/shared-swap
mkdir -p "$SHARED"
for pair in a:b b:a; do
  name=${pair%%:*}
  other=${pair##*:}
  fake "$C" "test-swap-$name.sh" << EOF
# Overwrite a tracked bin/ file and never restore it, then wait until the other job has done
# the same in its own copy; each must still read its own text.
printf 'STUB-$name\n' > bin/kingpin-send
: > "$SHARED/$name.wrote"
n=0
while [ ! -f "$SHARED/$other.wrote" ]; do
  n=\$((n + 1))
  [ "\$n" -lt 200 ] || { echo "the other job never wrote"; exit 4; }
  sleep 0.1
done
saw=\$(cat bin/kingpin-send)
[ "\$saw" = "STUB-$name" ] || { echo "saw \$saw"; exit 5; }
EOF
done
fixture_init "$C"
runner --root "$C" -j 4
if [ "$RUN_RC" -eq 0 ] && grep -q 'ALL 5 JOBS PASSED' <<< "$RUN_OUT"; then
  pass "two jobs that overwrite the same tracked file at once each read their own write"
else
  fail "the jobs saw each other's write or never overlapped (rc=$RUN_RC): $RUN_OUT"
fi
if [ "$(cat "$C/bin/kingpin-send")" = "ORIGINAL" ] && [ -z "$(git -C "$C" status --porcelain)" ]; then
  pass "the invoking checkout is byte-identical and clean after the run"
else
  fail "the run changed the invoking checkout: $(git -C "$C" status --porcelain)"
fi

# The snapshot holds tracked and unignored files, drops ignored ones and a tracked file deleted
# in the working tree, and is itself a clean git checkout.
D=$(new_fixture snap)
printf 'tracked\n' > "$D/gone.txt"
printf 'ignored.txt\n' > "$D/.gitignore"
fake "$D" test-snap.sh <<'EOF'
[ -f untracked.txt ] || { echo "untracked file missing"; exit 1; }
[ ! -e ignored.txt ] || { echo "ignored file copied"; exit 1; }
[ ! -e gone.txt ] || { echo "deleted file copied"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "copy not clean"; git status --porcelain; exit 1; }
git ls-files --error-unmatch bin/kingpin-send > /dev/null
EOF
fixture_init "$D"
rm "$D/gone.txt"
printf 'new\n' > "$D/untracked.txt"
printf 'x\n' > "$D/ignored.txt"
runner --root "$D" test-snap
if [ "$RUN_RC" -eq 0 ]; then
  pass "a job's copy holds the untracked file, not the ignored or deleted one, and is a clean git checkout"
else
  fail "the snapshot was wrong (rc=$RUN_RC): $RUN_OUT"
fi

# 4. Two invocations at once do not interfere.
bg_runner() {
  local out=$1 rcf=$2
  shift 2
  (
    job_rc=0
    "$RUNNER" "$@" > "$out" 2>&1 || job_rc=$?
    echo "$job_rc" > "$rcf"
  ) &
}
rm -f "$T"/two-*.out "$T"/two-*.rc
bg_runner "$T/two-1.out" "$T/two-1.rc" --root "$A"
bg_runner "$T/two-2.out" "$T/two-2.rc" --root "$A"
if kp_wait_until 120 test -f "$T/two-1.rc" && kp_wait_until 120 test -f "$T/two-2.rc" \
  && [ "$(cat "$T/two-1.rc")" = 0 ] && [ "$(cat "$T/two-2.rc")" = 0 ] \
  && grep -q 'ALL 3 JOBS PASSED' "$T/two-1.out" && grep -q 'ALL 3 JOBS PASSED' "$T/two-2.out"; then
  pass "two runs at once both pass with complete output"
else
  fail "two runs at once interfered: $(cat "$T"/two-*.out "$T"/two-*.rc 2>&1)"
fi
if no_leftover; then
  pass "two runs at once leave no run directory behind"
else
  fail "a run directory was left in $TMPDIR"
fi

# 5. An interrupted run cleans up after itself.
E=$(new_fixture block)
fake "$E" test-block.sh << EOF
echo \$\$ > "$T/block.pid"
exec sleep 300
EOF
fixture_init "$E"
# A double fork keeps the runner from being a zombie of this shell once it exits.
( bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$T/runner.pid" "$RUNNER" --root "$E" test-block > "$T/block.out" 2>&1 & )
if kp_wait_until 30 test -s "$T/block.pid"; then
  RPID=$(cat "$T/runner.pid")
  kill -TERM "$RPID"
  if kp_wait_until 30 not_alive "$RPID" && kp_wait_until 10 no_leftover; then
    pass "TERM stops the runner and removes its run directory"
  else
    fail "the runner or its run directory survived TERM"
  fi
  BPID=$(cat "$T/block.pid")
  if kp_wait_until 10 not_alive "$BPID"; then
    pass "TERM stops the running job too"
  else
    fail "the job process $BPID survived the runner"
    kill -KILL "$BPID" 2>/dev/null || true
  fi
else
  fail "the blocking job never started: $(cat "$T/block.out")"
  kill -TERM "$(cat "$T/runner.pid")" 2>/dev/null || true
fi

# 6. -j bounds the pool: -j 1 never overlaps two jobs, -j 2 really runs two at once.
F=$(new_fixture serial)
LOG=$T/serial.log
: > "$LOG"
for name in s1 s2 s3; do
  fake "$F" "test-$name.sh" << EOF
echo "start $name" >> "$LOG"
sleep 0.3
echo "end $name" >> "$LOG"
EOF
done
fixture_init "$F"
runner --root "$F" -j 1 test-s1 test-s2 test-s3
shape=$(cut -d' ' -f1 "$LOG" | tr '\n' ' ')
if [ "$RUN_RC" -eq 0 ] && [ "$shape" = "start end start end start end " ]; then
  pass "-j 1 runs the jobs one at a time"
else
  fail "-j 1 overlapped jobs (rc=$RUN_RC, log: $shape): $RUN_OUT"
fi
G=$(new_fixture parallel)
PSH=$T/shared-par
mkdir -p "$PSH"
for pair in p1:p2 p2:p1; do
  me=${pair%%:*}
  other=${pair##*:}
  fake "$G" "test-$me.sh" << EOF
: > "$PSH/$me.started"
n=0
while [ ! -f "$PSH/$other.started" ]; do
  n=\$((n + 1))
  [ "\$n" -lt 200 ] || { echo "the other job never started"; exit 4; }
  sleep 0.1
done
EOF
done
fixture_init "$G"
runner --root "$G" -j 2 test-p1 test-p2
if [ "$RUN_RC" -eq 0 ] && grep -q 'ALL 2 JOBS PASSED' <<< "$RUN_OUT"; then
  pass "-j 2 runs two jobs at once"
else
  fail "-j 2 did not overlap two jobs (rc=$RUN_RC): $RUN_OUT"
fi

# 7. Usage errors exit 2 and say why.
usage_case() {
  local want=$1
  shift
  runner "$@"
  if [ "$RUN_RC" -eq 2 ] && grep -q -- "$want" <<< "$RUN_OUT"; then
    pass "usage error exits 2: $*"
  else
    fail "expected exit 2 with '$want' for: $* (rc=$RUN_RC): $RUN_OUT"
  fi
}
usage_case 'unknown job: test-nope (valid: lint test-ok test-ok2)' --root "$A" test-nope
usage_case 'positive number' --root "$A" -j 0
usage_case 'positive number' --root "$A" -j abc
usage_case '-j needs a number' --root "$A" -j
usage_case '--root needs a directory' --root
usage_case 'unknown argument: --bogus' --root "$A" --bogus
NOTGIT=$T/notgit
mkdir -p "$NOTGIT/tests"
usage_case 'not a git checkout' --root "$NOTGIT"
usage_case 'no such directory' --root "$T/missing"

# 8. The environment a worker carries does not reach a job; the job gets its own TMPDIR, and
# its TMPDIR and its working copy add only a short suffix to the caller's TMPDIR. A suite builds
# a tmux socket path under its TMPDIR and that path has a limit of about 107 characters, so a
# runner that nested its paths deep broke every suite that uses tmux.
H=$(new_fixture env)
OUTER=${#TMPDIR}
fake "$H" test-env.sh << EOF
for v in KINGPIN_HOME TMUX TMUX_PANE; do
  if [ -n "\${!v+x}" ]; then echo "ENV-LEAK \$v"; exit 1; fi
done
case \$TMPDIR in
  "$TMPDIR"/ra.*) ;;
  *) echo "TMPDIR is \$TMPDIR"; exit 1 ;;
esac
extra=\$(( \${#TMPDIR} - $OUTER ))
if [ "\$extra" -gt 16 ]; then echo "TMPDIR adds \$extra characters: \$TMPDIR"; exit 1; fi
extra=\$(( \${#PWD} - $OUTER ))
if [ "\$extra" -gt 16 ]; then echo "the copy adds \$extra characters: \$PWD"; exit 1; fi
EOF
fixture_init "$H"
kp_run out rc env KINGPIN_HOME=/nonexistent TMUX=x TMUX_PANE=%1 "$RUNNER" --root "$H" test-env
if [ "$rc" -eq 0 ]; then
  pass "TMUX, TMUX_PANE and KINGPIN_* are unset in a job, its TMPDIR is private, and its paths stay short"
else
  fail "the job saw the caller's environment or a deep path (rc=$rc): $out"
fi

# 9. A job past the time limit is reported as TIMEOUT and fails the run.
if command -v timeout > /dev/null 2>&1; then
  I=$(new_fixture slow)
  fake "$I" test-slow.sh <<< 'exec sleep 30'
  fixture_init "$I"
  kp_run out rc env RUN_ALL_TIMEOUT=1 "$RUNNER" --root "$I" test-slow
  if [ "$rc" -eq 1 ] && grep -q '^TIMEOUT test-slow (' <<< "$out" && grep -q '1 of 1 FAILED: test-slow' <<< "$out"; then
    pass "a job past RUN_ALL_TIMEOUT prints TIMEOUT and fails the run"
  else
    fail "the slow job was not reported as a timeout (rc=$rc): $out"
  fi
fi

# 10. A job whose runner is killed outright (SIGKILL, the OOM killer) publishes no result: the
# run must record it as rc 125 and finish, not poll for the result forever.
J=$(new_fixture dead)
fake "$J" test-dead.sh <<'EOF2'
# Find the job's runner (the first ancestor whose command line equals its parent's: the runner
# forks the job as a copy of itself) and kill it with KILL, while this suite is still running.
p=$PPID
while :; do
  pp=$(ps -o ppid= -p "$p" | tr -d ' ')
  [ -n "$pp" ] && [ "$pp" != 1 ] || { echo "no runner above the suite"; exit 6; }
  [ "$(ps -o args= -p "$p")" = "$(ps -o args= -p "$pp")" ] && break
  p=$pp
done
kill -KILL "$p"
sleep 2
EOF2
fixture_init "$J"
bound=()
if command -v timeout > /dev/null 2>&1; then bound=(timeout 60); fi
kp_run out rc "${bound[@]}" "$RUNNER" --root "$J" test-dead
if [ "$rc" -eq 1 ] \
  && grep -q '^FAIL test-dead (rc=125' <<< "$out" \
  && grep -q 'died without a result' <<< "$out" \
  && [ "$(tail -n 1 <<< "$out")" = "run-all: 1 of 1 FAILED: test-dead" ]; then
  pass "a job whose runner is killed is reported as FAIL rc=125 and the run ends instead of hanging"
else
  fail "the dead job was not reported (rc=$rc): $out"
fi

if no_leftover; then
  pass "no run directory is left in the private TMPDIR after the whole suite"
else
  fail "a run directory was left in $TMPDIR"
fi

kp_test_finish RUN-ALL
