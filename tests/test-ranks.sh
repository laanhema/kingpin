#!/usr/bin/env bash
# Verification test for the fleet's rank voice: the contract's Ranks section, the capo
# identity in the worker preamble, and status lines that stay free of rank flavor.
#
# The prompt surfaces are the product here (issue #91): the orchestrator reads the
# contract, a spawned worker reads the preamble, and both must keep the rank fiction in
# conversation while commits, issues, status fields and dossiers stay neutral. The last
# assertions are the AC5 guardrails: a capo that adopts the orchestrator's refusal to
# edit code is a dead worker, and a status field with flavor breaks every parser.
set -euo pipefail

. "$(dirname "$0")/lib.sh"
kp_test_setup ranks

CONTRACT="$KP_ROOT/orchestrator/contract.md"
PREAMBLE="$KP_ROOT/worker/preamble.md"
AGENTS="$KP_ROOT/AGENTS.md"
README="$KP_ROOT/README.md"

has() { grep -qF -- "$2" "$1" && pass "$3" || fail "$3"; }
hasnt() { ! grep -qF -- "$2" "$1" && pass "$3" || fail "$3"; }

# 1. The orchestrator contract carries the full Ranks section.
echo "=== Test 1: contract Ranks section ==="
has "$CONTRACT" "## The Ranks" "contract has the Ranks section"
has "$CONTRACT" "Kingpin: the user" "contract names the kingpin as the user"
has "$CONTRACT" "Underboss (consigliere)" "contract names the underboss"
has "$CONTRACT" "Caporegime (capo)" "contract names the caporegime"
has "$CONTRACT" "Soldier: the subagents" "contract names the soldiers"
has "$CONTRACT" "Voice: every rank speaks in character" "contract carries the voice rule"
has "$CONTRACT" "The record stays clean" "contract carries the neutrality rule"
has "$CONTRACT" "You are the underboss" "contract keeps its orchestrator persona"
has "$CONTRACT" "The user is the boss (the kingpin)" "contract keeps the boss address"

# 2. Seasoning is raised to full voice but keeps its two limits.
echo "=== Test 2: raised seasoning ==="
hasnt "$CONTRACT" "light syndicate seasoning" "contract no longer asks for light seasoning"
has "$CONTRACT" "never make it cartoonish or obscure technical facts" "contract keeps the facts-straight limit"
has "$CONTRACT" "Never put the voice in non-chat artifacts" "contract keeps the non-chat artifacts limit"

# 3. AGENTS.md stays persona-free (issue #96).
echo "=== Test 3: AGENTS.md is persona-free ==="
hasnt "$AGENTS" "underboss" "AGENTS.md carries no rank persona"
hasnt "$AGENTS" "Caporegime" "AGENTS.md carries no capo text"
hasnt "$AGENTS" "## The Ranks" "AGENTS.md carries no Ranks section"

# 4. The worker preamble opens as the capo identity and keeps both guardrails (AC5).
echo "=== Test 4: capo preamble guardrails ==="
has "$PREAMBLE" "caporegime" "preamble names the caporegime identity"
has "$PREAMBLE" "you DO edit code" "preamble keeps the edit-code guardrail"
has "$PREAMBLE" "never run kingpin spawn" "preamble keeps the no-orchestration guardrail"
has "$PREAMBLE" "Soldier: <job>" "preamble tells a capo how to label a soldier"
has "$PREAMBLE" "Status lines stay literal" "preamble keeps the literal status rule"
hasnt "$PREAMBLE" "You are the underboss" "preamble carries no orchestrator persona"
hasnt "$PREAMBLE" "Ignore AGENTS.md's orchestrator rules" "preamble drops the stale pre-#96 sentence"

# 5. The status-line examples carry no rank flavor, and the field names still parse (AC5).
echo "=== Test 5: neutral status lines ==="
status_block=$(sed -n '/^Report every event as one line/,/^Before you append/p' "$PREAMBLE")
[ -n "$status_block" ] && pass "status block found in the preamble" || fail "status block missing from the preamble"
if grep -Eqi 'underboss|caporegime|capo|consigliere|soldier|\bboss\b' <<< "$status_block"; then
  fail "rank flavor in the status-line examples"
else
  pass "status-line examples carry no rank flavor"
fi
grep -q 'ready: branch=<branch> review=<verdict>' <<< "$status_block" && pass "ready: field names unchanged" || fail "ready: field names changed"
grep -q 'fixed: high=<n> report=<review report path>' <<< "$status_block" && pass "fixed: field names unchanged" || fail "fixed: field names changed"
grep -q 'merged: pr=<PR URL>' <<< "$status_block" && pass "merged: field names unchanged" || fail "merged: field names changed"
grep -q 'failed: <the stopping skill' <<< "$status_block" && pass "failed: field names unchanged" || fail "failed: field names changed"

# 6. The README documents the fiction where a reader meets the commands.
echo "=== Test 6: README Ranks section ==="
has "$README" "## The Ranks" "README has the Ranks section"
has "$README" "**underboss**" "README names the underboss"
has "$README" "**caporegime**" "README names the caporegime"
has "$README" "**soldier**" "README names the soldier"
has "$README" "neutral and machine-readable" "README states the neutrality rule"

kp_test_finish RANKS
