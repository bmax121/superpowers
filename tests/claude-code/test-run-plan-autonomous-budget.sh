#!/usr/bin/env bash
# Budget flag parsing + weekly-spend wiring test for run-plan-autonomous.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/run-plan-autonomous.sh"

PASS=0; FAIL=0

# Fixture: tmp worktree with a minimal plan & fake costs
setup() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/docs/superpowers/plans" "$tmp/docs/superpowers/checkpoints"
  mkdir -p "$tmp/home/.claude/metrics"
  now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
  cat > "$tmp/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":50.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
  cat > "$tmp/home/.claude/superpowers-budget.yaml" <<EOF
weekly_cap_usd: 200
EOF
  cat > "$tmp/docs/superpowers/plans/dummy.md" <<'EOF'
---
plan_version: 1
final_goal: {template: all_tests_pass, verify_command: "true"}
status: in_progress
execution_mode: autonomous
current_task: 1
convergence_round: 0
checkpoint_pointer: docs/superpowers/checkpoints/dummy-checkpoint.json
autonomous_limits: {budget_pct: 30, max_convergence_rounds: 3, max_handoffs: 2, no_progress_abort_after: 2}
---
# Plan

## Task 1: dummy
**Tier:** mechanical
**Status:** done
EOF
  cat > "$tmp/docs/superpowers/checkpoints/dummy-checkpoint.json" <<'EOF'
{"tasks":[{"n":1,"status":"done"}]}
EOF
  echo "$tmp"
}

# Test 1: --budget-pct with plan under budget → allows run (dry-run continues)
t1=$(setup)
out=$(HOME="$t1/home" bash "$SCRIPT" "$t1/docs/superpowers/plans/dummy.md" --dry-run --budget-pct 30 --max-handoffs 1 2>&1)
if echo "$out" | grep -q "budget_pct=30"; then
  echo "  [PASS] --budget-pct flag is acknowledged in output"; PASS=$((PASS+1))
else
  echo "  [FAIL] --budget-pct not reflected — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t1"

# Test 2: weekly spent exceeds cap → refuses with status=budget_exhausted
t2=$(setup)
# Bump cost to $100 (50% of $200) and cap budget-pct at 20% — should refuse
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
cat > "$t2/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":100.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
out=$(HOME="$t2/home" bash "$SCRIPT" "$t2/docs/superpowers/plans/dummy.md" --dry-run --budget-pct 20 --max-handoffs 1 2>&1 || true)
if echo "$out" | grep -qE "budget.*(exceeded|exhausted)"; then
  echo "  [PASS] exceeds-cap refuses with budget-exhausted message"; PASS=$((PASS+1))
else
  echo "  [FAIL] exceeds-cap not detected — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t2"

# Test 3: --budget-pct none → unlimited, no check
t3=$(setup)
out=$(HOME="$t3/home" bash "$SCRIPT" "$t3/docs/superpowers/plans/dummy.md" --dry-run --budget-pct none --max-handoffs 1 2>&1)
if echo "$out" | grep -q "budget_pct=unlimited"; then
  echo "  [PASS] --budget-pct none reads as unlimited"; PASS=$((PASS+1))
else
  echo "  [FAIL] --budget-pct none not recognized — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t3"

# Test 4: --max-cost still works but warns deprecation
t4=$(setup)
out=$(HOME="$t4/home" bash "$SCRIPT" "$t4/docs/superpowers/plans/dummy.md" --dry-run --max-cost 50 --max-handoffs 1 2>&1)
if echo "$out" | grep -qi "deprecated"; then
  echo "  [PASS] --max-cost emits deprecation warning"; PASS=$((PASS+1))
else
  echo "  [FAIL] --max-cost deprecation warning missing — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t4"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
