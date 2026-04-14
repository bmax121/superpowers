#!/usr/bin/env bash
# Autonomous loop driver for superpowers:subagent-driven-development.
#
# Usage:
#   scripts/run-plan-autonomous.sh <plan-or-checkpoint> [options]
#
# Arguments:
#   <plan-or-checkpoint>
#     Either a plan file (docs/superpowers/plans/X.md) for first run, or an
#     existing checkpoint (docs/superpowers/checkpoints/X-checkpoint.json)
#     to continue an already-started plan.
#
# Options:
#   --max-cost USD           total budget across all handoffs (default: 20)
#   --max-handoffs N         hard cap on loop iterations (default: 10)
#   --no-progress-abort N    stop if no task completed in N iterations (default: 2)
#   --log-dir PATH           per-session logs (default: docs/superpowers/checkpoints/logs)
#   --dry-run                show what would be spawned, don't actually run
#
# Contract:
#   - Spawns `claude -p` per iteration with SUPERPOWERS_AUTONOMOUS_LOOP=1
#   - Reads the checkpoint after each iteration to decide whether to continue
#   - Stops on: all tasks done, NEEDS_HUMAN.txt present, budget/handoff/no-progress cap, Ctrl-C
#   - Writes a summary to stderr at the end; per-iteration logs under --log-dir
#
# Exit codes:
#   0   plan completed (all tasks done)
#   1   stopped by limit (budget / handoffs / no-progress)
#   2   NEEDS_HUMAN.txt detected — user action required
#   3   invocation error (bad args, missing checkpoint/plan, etc.)
#  130  interrupted (Ctrl-C)

set -euo pipefail

# ---- defaults ----
BUDGET_PCT=""                  # empty = unset, "none" = unlimited, or number 1-100
BUDGET_CAP_USD=""              # empty = unset; overrides percent when set
MAX_COST_USD=""                # deprecated; still parsed but treated as budget-cap-usd + warning
MAX_HANDOFFS=10
NO_PROGRESS_ABORT=2
LOG_DIR=""
DRY_RUN=0
INPUT=""

usage() {
  # Print the leading comment block (skip shebang, stop at the first line
  # that does not start with `#`).
  awk '
    NR == 1 { next }                 # skip shebang
    !/^#/   { exit }                 # stop at first non-comment line (incl. blank)
    { sub(/^# ?/, ""); print }
  ' "$0"
  exit "${1:-0}"
}

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget-pct)          BUDGET_PCT="$2"; shift 2 ;;
    --budget-cap-usd)      BUDGET_CAP_USD="$2"; shift 2 ;;
    --max-cost)            MAX_COST_USD="$2"; shift 2 ;;
    --max-handoffs)        MAX_HANDOFFS="$2"; shift 2 ;;
    --no-progress-abort)   NO_PROGRESS_ABORT="$2"; shift 2 ;;
    --log-dir)             LOG_DIR="$2"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage 0 ;;
    -*)                    echo "ERROR: unknown option $1" >&2; usage 3 ;;
    *)
      if [[ -z "$INPUT" ]]; then INPUT="$1"; shift
      else echo "ERROR: multiple positional args" >&2; usage 3
      fi ;;
  esac
done

# Handle deprecated --max-cost: treat as --budget-cap-usd, warn.
if [[ -n "$MAX_COST_USD" ]]; then
  echo "[deprecated] --max-cost is deprecated; treating as --budget-cap-usd $MAX_COST_USD. Prefer --budget-pct against ~/.claude/superpowers-budget.yaml. --max-cost will be removed in 7.0.0." >&2
  if [[ -z "$BUDGET_CAP_USD" ]]; then
    BUDGET_CAP_USD="$MAX_COST_USD"
  fi
fi

# Reject conflicting budget inputs
if [[ -n "$BUDGET_PCT" && -n "$BUDGET_CAP_USD" ]]; then
  echo "ERROR: --budget-pct and --budget-cap-usd are mutually exclusive" >&2
  exit 3
fi

if [[ -z "$INPUT" ]]; then
  echo "ERROR: missing <plan-or-checkpoint>" >&2
  usage 3
fi

if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: input file not found: $INPUT" >&2
  exit 3
fi

# ---- derive paths ----
# If INPUT is a plan (.md in plans/), derive expected checkpoint path.
# If INPUT is a checkpoint (.json in checkpoints/), use it directly.
case "$INPUT" in
  *-checkpoint.json)
    CHECKPOINT="$INPUT"
    ;;
  *.md)
    base="$(basename "$INPUT" .md)"
    dir="$(dirname "$INPUT")"
    repo_root="$(cd "$dir/../../.." && pwd)"
    CHECKPOINT="$repo_root/docs/superpowers/checkpoints/${base}-checkpoint.json"
    ;;
  *)
    echo "ERROR: input must be a plan (.md) or checkpoint (.json)" >&2
    exit 3
    ;;
esac

CHECKPOINT_DIR="$(dirname "$CHECKPOINT")"
mkdir -p "$CHECKPOINT_DIR"

if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$CHECKPOINT_DIR/logs"
fi
mkdir -p "$LOG_DIR"

NEEDS_HUMAN_FILE="$CHECKPOINT_DIR/NEEDS_HUMAN.txt"
# Clear stale NEEDS_HUMAN from previous runs so we don't confuse ourselves.
rm -f "$NEEDS_HUMAN_FILE"

# ---- helpers ----
# Counts task statuses in the checkpoint's top-level tasks array. Works on
# both pretty-printed and minified JSON. Uses python3 (standard on macOS +
# every modern Linux with Python). If python3 isn't available we fall back
# to jq; if neither is present we fail loudly — these scripts can't run
# without a real JSON parser since the awk approach breaks on minified JSON.
_count_with_status() {
  # args: <checkpoint-path> <status-or-"*">
  local cp="$1" want="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$cp" "$want" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    tasks = d.get("tasks", [])
    want = sys.argv[2]
    if want == "*":
        print(len(tasks))
    else:
        print(sum(1 for t in tasks if t.get("status") == want))
except Exception:
    print(0)
PY
  elif command -v jq >/dev/null 2>&1; then
    if [[ "$want" == "*" ]]; then
      jq '.tasks | length' "$cp" 2>/dev/null || echo 0
    else
      jq --arg s "$want" '[.tasks[] | select(.status == $s)] | length' "$cp" 2>/dev/null || echo 0
    fi
  else
    echo "ERROR: need python3 or jq to parse checkpoint JSON" >&2
    exit 3
  fi
}

count_done_tasks()  { _count_with_status "$CHECKPOINT" "done"; }
count_total_tasks() { _count_with_status "$CHECKPOINT" "*"; }

# ---- budget helpers ----
# Emit one line: "budget_pct=<n>|none|unset; cap=<usd>|unset; spent=<usd>; limit=<usd>|inf"
# Returns 0 if run should proceed, 1 if over budget.
check_budget() {
  local pct="$1" cap="$2"
  local spent limit_usd
  local weekly_json
  weekly_json=$(bash "$(dirname "${BASH_SOURCE[0]}")/compute-weekly-spent.sh" 2>/dev/null || echo '{"weekly_spent_usd":0}')
  spent=$(echo "$weekly_json" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("weekly_spent_usd",0))')

  if [[ "$pct" == "none" ]]; then
    echo "[budget] budget_pct=unlimited cap=unset spent=\$$spent limit=inf"
    return 0
  elif [[ -n "$pct" ]]; then
    local cap_usd
    cap_usd=$(echo "$weekly_json" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("weekly_cap_usd",""))')
    if [[ -z "$cap_usd" ]]; then
      echo "ERROR: --budget-pct requires weekly_cap_usd in ~/.claude/superpowers-budget.yaml" >&2
      return 1
    fi
    limit_usd=$(python3 -c "print($cap_usd * $pct / 100.0)")
    echo "[budget] budget_pct=$pct cap=\$$cap_usd spent=\$$spent limit=\$$limit_usd"
    if (( $(python3 -c "print(1 if $spent >= $limit_usd else 0)") )); then
      echo "[budget] ❌ weekly spend \$$spent exceeded limit \$$limit_usd (budget_pct=$pct of cap \$$cap_usd) — plan status = budget_exhausted" >&2
      return 1
    fi
    return 0
  elif [[ -n "$cap" ]]; then
    echo "[budget] budget_pct=unset cap=\$$cap spent=\$$spent limit=\$$cap"
    if (( $(python3 -c "print(1 if $spent >= $cap else 0)") )); then
      echo "[budget] ❌ weekly spend \$$spent exceeded cap \$$cap — plan status = budget_exhausted" >&2
      return 1
    fi
    return 0
  else
    # No budget constraint set → behave like unlimited (legacy default 20 USD is gone)
    echo "[budget] budget_pct=unset cap=unset spent=\$$spent limit=inf"
    return 0
  fi
}

# ---- plan.md frontmatter helpers ----
# Read a single scalar key from plan.md YAML frontmatter (top-level or
# nested one level deep via "parent.key"). Empty string if absent.
read_plan_frontmatter() {
  local plan="$1" key="$2"
  python3 - "$plan" "$key" <<'PY' 2>/dev/null
import sys, re, os
plan_path, key = sys.argv[1], sys.argv[2]
if not os.path.isfile(plan_path):
    sys.exit(0)
with open(plan_path) as f:
    text = f.read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)
try:
    import yaml
    data = yaml.safe_load(fm) or {}
except Exception:
    # Fallback: line grep for top-level scalars and inline-dict values like {k: v, ...}
    import json as _json
    data = {}
    for line in fm.splitlines():
        s = line.strip()
        if s and not s.startswith("#") and ":" in s and not line.startswith(" "):
            k, _, v = s.partition(":")
            k, v = k.strip(), v.strip()
            if v.startswith("{") and v.endswith("}"):
                # Convert YAML flow-style dict to JSON by quoting bare keys
                try:
                    data[k] = _json.loads(re.sub(r'(\w+)\s*:', r'"\1":', v))
                    continue
                except Exception:
                    pass
            data[k] = v
# Walk dotted key
cur = data
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
print(cur)
PY
}

# ---- plan frontmatter override ----
# Plan-frontmatter override of autonomous_limits (CLI flags still win)
PLAN_FILE=""
case "$INPUT" in
  *.md) PLAN_FILE="$INPUT" ;;
  *)
    # Try to derive plan from checkpoint's plan_path field
    if [[ -f "$CHECKPOINT" ]] && command -v python3 >/dev/null 2>&1; then
      PLAN_FILE=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('plan_path',''))" "$CHECKPOINT" 2>/dev/null || echo "")
    fi
    ;;
esac

if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
  # Only apply when the user did NOT pass the corresponding CLI flag.
  if [[ "$MAX_HANDOFFS" == "10" ]]; then
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.max_handoffs")
    [[ -n "$fm_val" ]] && MAX_HANDOFFS="$fm_val"
  fi
  if [[ "$NO_PROGRESS_ABORT" == "2" ]]; then
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.no_progress_abort_after")
    [[ -n "$fm_val" ]] && NO_PROGRESS_ABORT="$fm_val"
  fi
  if [[ -z "$BUDGET_PCT" && -z "$BUDGET_CAP_USD" ]]; then
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.budget_pct")
    [[ -n "$fm_val" ]] && BUDGET_PCT="$fm_val"
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.budget_cap_usd")
    [[ -n "$fm_val" ]] && BUDGET_CAP_USD="$fm_val"
  fi
fi

echo "[autonomous-loop] effective limits: max_handoffs=$MAX_HANDOFFS no_progress_abort=$NO_PROGRESS_ABORT budget_pct=${BUDGET_PCT:-unset} budget_cap_usd=${BUDGET_CAP_USD:-unset}" >&2

# ---- bootstrap prompt ----
# If a checkpoint already exists, use /resume-plan. Otherwise start fresh
# from the plan file.
if [[ -f "$CHECKPOINT" ]]; then
  INITIAL_PROMPT="/resume-plan $CHECKPOINT"
else
  case "$INPUT" in
    *.md)
      INITIAL_PROMPT=$'Execute this plan using superpowers:subagent-driven-development in autonomous loop mode.\n\nPlan: '"$INPUT"$'\n\nYou are running under scripts/run-plan-autonomous.sh. Env var SUPERPOWERS_AUTONOMOUS_LOOP=1 is set. Do not call AskUserQuestion — write NEEDS_HUMAN.txt if a hard gate fires. At handoff, exit the turn cleanly.'
      ;;
    *)
      echo "ERROR: cannot start from non-plan input when checkpoint missing" >&2
      exit 3
      ;;
  esac
fi

cleanup() {
  echo "" >&2
  echo "[autonomous-loop] interrupted — checkpoint preserved at $CHECKPOINT" >&2
  exit 130
}
trap cleanup INT TERM

# ---- main loop ----
SESSION_N=0
NO_PROGRESS=0
PREV_DONE=$(count_done_tasks)
SPENT_SO_FAR=0

echo "[autonomous-loop] start. checkpoint=$CHECKPOINT budget_pct=${BUDGET_PCT:-unset} budget_cap=${BUDGET_CAP_USD:-unset} max_handoffs=$MAX_HANDOFFS" >&2

while [[ $SESSION_N -lt $MAX_HANDOFFS ]]; do
  SESSION_N=$((SESSION_N + 1))

  # Budget gate — runs every iteration
  if ! check_budget "$BUDGET_PCT" "$BUDGET_CAP_USD" >&2; then
    exit 1
  fi

  # Completion check (before spawning — if already done, exit clean)
  if [[ -f "$CHECKPOINT" ]]; then
    done_n=$(count_done_tasks)
    total_n=$(count_total_tasks)
    if [[ $total_n -gt 0 && $done_n -ge $total_n ]]; then
      echo "[autonomous-loop] ✅ plan complete ($done_n/$total_n tasks). total sessions: $((SESSION_N - 1))" >&2
      exit 0
    fi
  fi

  SESSION_UUID=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
  LOG_FILE="$LOG_DIR/session-$(printf '%03d' "$SESSION_N")-${SESSION_UUID}.log"

  per_session_budget=""
  if [[ -n "$BUDGET_CAP_USD" ]]; then
    # Divide remaining cap across remaining handoffs (floor $1).
    remaining=$((MAX_HANDOFFS - SESSION_N + 1))
    per_session_budget=$(python3 -c "print(max(1.0, ($BUDGET_CAP_USD - ${SPENT_SO_FAR:-0}) / $remaining))")
  fi

  echo "[autonomous-loop] session $SESSION_N/$MAX_HANDOFFS: uuid=$SESSION_UUID log=$LOG_FILE${per_session_budget:+ budget=\$$per_session_budget}" >&2

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would spawn: claude -p --session-id $SESSION_UUID ${per_session_budget:+--max-budget-usd $per_session_budget} --dangerously-skip-permissions --output-format stream-json -- '$INITIAL_PROMPT'" >&2
  else
    claude_args=(-p --session-id "$SESSION_UUID" --dangerously-skip-permissions --output-format stream-json --include-partial-messages)
    if [[ -n "$per_session_budget" ]]; then
      claude_args+=(--max-budget-usd "$per_session_budget")
    fi
    SUPERPOWERS_AUTONOMOUS_LOOP=1 \
      claude "${claude_args[@]}" -- "$INITIAL_PROMPT" \
      > "$LOG_FILE" 2>&1 || {
        rc=$?
        echo "[autonomous-loop] session $SESSION_N exited rc=$rc (may be budget-limit; continuing to inspect checkpoint)" >&2
      }
  fi

  # Inspect state after the session
  if [[ -f "$NEEDS_HUMAN_FILE" ]]; then
    echo "[autonomous-loop] ⚠ NEEDS_HUMAN.txt written. stopping loop." >&2
    cat "$NEEDS_HUMAN_FILE" >&2
    exit 2
  fi

  if [[ ! -f "$CHECKPOINT" ]]; then
    echo "[autonomous-loop] ❌ no checkpoint was written. session may have failed to start. see $LOG_FILE" >&2
    exit 1
  fi

  done_n=$(count_done_tasks)
  total_n=$(count_total_tasks)
  new_done=$((done_n - PREV_DONE))

  echo "[autonomous-loop]   tasks: $done_n/$total_n done ($new_done new this iteration)" >&2

  # No-progress detection
  if [[ $new_done -eq 0 ]]; then
    NO_PROGRESS=$((NO_PROGRESS + 1))
    echo "[autonomous-loop]   no-progress counter: $NO_PROGRESS/$NO_PROGRESS_ABORT" >&2
    if [[ $NO_PROGRESS -ge $NO_PROGRESS_ABORT ]]; then
      echo "[autonomous-loop] ❌ aborting: $NO_PROGRESS consecutive sessions with no new tasks completed" >&2
      exit 1
    fi
  else
    NO_PROGRESS=0
  fi
  PREV_DONE=$done_n

  # For resume iterations, prompt becomes /resume-plan
  INITIAL_PROMPT="/resume-plan $CHECKPOINT"
done

echo "[autonomous-loop] ❌ reached max_handoffs=$MAX_HANDOFFS without finishing" >&2
exit 1
