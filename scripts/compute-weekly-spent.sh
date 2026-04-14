#!/usr/bin/env bash
# Compute weekly Claude Code spend from ~/.claude/metrics/costs.jsonl.
#
# Output: a single JSON line on stdout:
#   {"weekly_spent_usd": N, "window_days": D, "entries": E}
#   (+ "weekly_cap_usd" and "pct" when ~/.claude/superpowers-budget.yaml sets a cap)
#
# Usage:
#   scripts/compute-weekly-spent.sh [--window-days N]
#
# Exit codes:
#   0   succeeded (even if no data — emits zeros)
#   2   malformed superpowers-budget.yaml (missing or invalid weekly_cap_usd)

set -u

WINDOW_DAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-days) WINDOW_DAYS="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

COSTS_FILE="${HOME}/.claude/metrics/costs.jsonl"
BUDGET_FILE="${HOME}/.claude/superpowers-budget.yaml"

python3 - "$COSTS_FILE" "$BUDGET_FILE" "$WINDOW_DAYS" <<'PY'
import json, os, sys, datetime, pathlib

costs_path = sys.argv[1]
budget_path = sys.argv[2]
window_days = int(sys.argv[3])

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=window_days)

total = 0.0
entries = 0
if os.path.isfile(costs_path):
    with open(costs_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts_raw = rec.get("timestamp")
            cost = rec.get("estimated_cost_usd")
            if ts_raw is None or cost is None:
                continue
            try:
                ts = datetime.datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts >= cutoff:
                total += float(cost)
                entries += 1

out = {
    "weekly_spent_usd": round(total, 4),
    "window_days": window_days,
    "entries": entries,
}

if os.path.isfile(budget_path):
    # Minimal YAML parse: we only need `weekly_cap_usd: <number>` or `: null`.
    cap = None
    with open(budget_path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("weekly_cap_usd:"):
                raw = s.split(":", 1)[1].strip()
                # strip inline comment
                if "#" in raw:
                    raw = raw.split("#", 1)[0].strip()
                if raw.lower() in ("null", "~", ""):
                    cap = None
                else:
                    try:
                        cap = float(raw)
                    except ValueError:
                        print(f"ERROR: malformed weekly_cap_usd in {budget_path}", file=sys.stderr)
                        sys.exit(2)
                break
    if cap is not None:
        out["weekly_cap_usd"] = cap
        out["pct"] = round((total / cap) * 100.0, 4) if cap > 0 else 0.0

print(json.dumps(out))
PY
