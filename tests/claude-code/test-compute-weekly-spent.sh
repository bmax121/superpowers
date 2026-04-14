#!/usr/bin/env bash
# Unit test for compute-weekly-spent.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/compute-weekly-spent.sh"

# shellcheck source=./test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

PASS=0
FAIL=0

# Create a fake costs.jsonl in a temp HOME
setup_mock_home() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude/metrics"
  echo "$tmp"
}

# Test 1: no costs.jsonl → weekly_spent_usd = 0, entries = 0
t1_dir=$(setup_mock_home)
out=$(HOME="$t1_dir" bash "$SCRIPT" 2>&1 | tail -1)
if echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["weekly_spent_usd"] == 0; assert d["entries"] == 0; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] empty-state returns zeros"; PASS=$((PASS+1))
else
  echo "  [FAIL] empty-state returns zeros — got: $out"; FAIL=$((FAIL+1))
fi
rm -rf "$t1_dir"

# Test 2: two entries within window + one outside window (10 days ago) → only two count
t2_dir=$(setup_mock_home)
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
past_iso=$(python3 -c 'import datetime,time; t=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=10); print(t.isoformat().replace("+00:00","Z"))')
cat > "$t2_dir/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":1.50,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
{"timestamp":"$now_iso","estimated_cost_usd":2.25,"session_id":"b","model":"opus","input_tokens":0,"output_tokens":0}
{"timestamp":"$past_iso","estimated_cost_usd":99.00,"session_id":"c","model":"opus","input_tokens":0,"output_tokens":0}
EOF
out=$(HOME="$t2_dir" bash "$SCRIPT" 2>&1 | tail -1)
if echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert abs(d["weekly_spent_usd"]-3.75)<0.01, d; assert d["entries"] == 2; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] window correctly excludes entries older than 7 days"; PASS=$((PASS+1))
else
  echo "  [FAIL] window inclusion — got: $out"; FAIL=$((FAIL+1))
fi
rm -rf "$t2_dir"

# Test 3: superpowers-budget.yaml with weekly_cap_usd attaches pct
t3_dir=$(setup_mock_home)
cat > "$t3_dir/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":50.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
cat > "$t3_dir/.claude/superpowers-budget.yaml" <<EOF
weekly_cap_usd: 200
EOF
out=$(HOME="$t3_dir" bash "$SCRIPT" 2>&1 | tail -1)
if echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["weekly_cap_usd"] == 200; assert abs(d["pct"]-25.0)<0.01, d; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] pct computed against weekly_cap_usd"; PASS=$((PASS+1))
else
  echo "  [FAIL] pct computation — got: $out"; FAIL=$((FAIL+1))
fi
rm -rf "$t3_dir"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
