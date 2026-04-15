#!/usr/bin/env bash
# Integration test: a plan.md with frontmatter flows cleanly through
# detect-model-providers.sh, compute-weekly-spent.sh, and run-plan-autonomous.sh
# in --dry-run mode, and the plan's frontmatter.status is written on exit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0

# Fixture
tmp=$(mktemp -d)
mkdir -p "$tmp/docs/superpowers/plans" "$tmp/docs/superpowers/checkpoints" "$tmp/home/.claude/metrics"
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
cat > "$tmp/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":5.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
cat > "$tmp/home/.claude/superpowers-budget.yaml" <<EOF
weekly_cap_usd: 200
EOF
cat > "$tmp/docs/superpowers/plans/foo.md" <<'EOF'
---
plan_version: 1
final_goal:
  template: all_tests_pass
  verify_command: "true"
status: in_progress
execution_mode: autonomous
current_task: 1
convergence_round: 0
last_handoff: {pct: 0, ts: null}
checkpoint_pointer: docs/superpowers/checkpoints/foo-checkpoint.json
autonomous_limits: {budget_pct: 40, max_convergence_rounds: 3, max_handoffs: 1, no_progress_abort_after: 1}
---
# foo plan
## Task 1: noop
**Tier:** mechanical
**Status:** done
EOF
cat > "$tmp/docs/superpowers/checkpoints/foo-checkpoint.json" <<EOF
{"tasks":[{"n":1,"status":"done"}],"plan_path":"$tmp/docs/superpowers/plans/foo.md"}
EOF

# Test A: detect-model-providers still works
out=$(HOME="$tmp/home" bash "$REPO_ROOT/scripts/detect-model-providers.sh" 2>&1)
if echo "$out" | tail -1 | python3 -c "import json,sys; json.loads(sys.stdin.read())" >/dev/null 2>&1; then
  echo "  [PASS] detect-model-providers emits valid JSON tail"; PASS=$((PASS+1))
else
  echo "  [FAIL] detect-model-providers broken"; FAIL=$((FAIL+1))
fi

# Test B: compute-weekly-spent reads mock costs
out=$(HOME="$tmp/home" bash "$REPO_ROOT/scripts/compute-weekly-spent.sh" 2>&1)
if echo "$out" | tail -1 | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["weekly_spent_usd"]==5.0; assert d["pct"]==2.5; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] compute-weekly-spent reads mock HOME"; PASS=$((PASS+1))
else
  echo "  [FAIL] compute-weekly-spent returned: $out"; FAIL=$((FAIL+1))
fi

# Test C: outer script PROPAGATES a terminal frontmatter.status written by controller.
# Simulate: plan already marked `goal_met` — outer script must exit 0 without spawning.
python3 -c "
import re
p = '$tmp/docs/superpowers/plans/foo.md'
t = open(p).read()
t = re.sub(r'^status:\s*\S+', 'status: goal_met', t, count=1, flags=re.MULTILINE)
open(p,'w').write(t)
"
HOME="$tmp/home" bash "$REPO_ROOT/scripts/run-plan-autonomous.sh" "$tmp/docs/superpowers/plans/foo.md" --dry-run --budget-pct 40 >/dev/null 2>&1
rc=$?
got=$(python3 -c "
import re
t = open('$tmp/docs/superpowers/plans/foo.md').read()
m = re.search(r'^status:\s*(\S+)', t, re.MULTILINE)
print(m.group(1) if m else 'unset')
")
if [[ "$rc" -eq 0 && "$got" == "goal_met" ]]; then
  echo "  [PASS] outer script propagates terminal frontmatter.status=goal_met (rc=0)"; PASS=$((PASS+1))
else
  echo "  [FAIL] propagation: rc=$rc, status=$got (want rc=0, status=goal_met)"; FAIL=$((FAIL+1))
fi

# Test D: in_progress plan with all tasks done but NO controller convergence → outer loops, eventually stalls
python3 -c "
import re
p = '$tmp/docs/superpowers/plans/foo.md'
t = open(p).read()
t = re.sub(r'^status:\s*\S+', 'status: in_progress', t, count=1, flags=re.MULTILINE)
open(p,'w').write(t)
"
HOME="$tmp/home" bash "$REPO_ROOT/scripts/run-plan-autonomous.sh" "$tmp/docs/superpowers/plans/foo.md" --dry-run --budget-pct 40 --no-progress-abort 1 --max-handoffs 2 >/dev/null 2>&1
rc=$?
got=$(python3 -c "
import re
t = open('$tmp/docs/superpowers/plans/foo.md').read()
m = re.search(r'^status:\s*(\S+)', t, re.MULTILINE)
print(m.group(1) if m else 'unset')
")
if [[ "$rc" -eq 1 && "$got" == "stalled" ]]; then
  echo "  [PASS] in_progress without controller progress → stalled rc=1"; PASS=$((PASS+1))
else
  echo "  [FAIL] stall detection: rc=$rc, status=$got (want rc=1, status=stalled)"; FAIL=$((FAIL+1))
fi

rm -rf "$tmp"
echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
