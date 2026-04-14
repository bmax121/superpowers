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
MAX_COST_USD=20
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
    --max-cost)            MAX_COST_USD="$2"; shift 2 ;;
    --max-handoffs)        MAX_HANDOFFS="$2"; shift 2 ;;
    --no-progress-abort)   NO_PROGRESS_ABORT="$2"; shift 2 ;;
    --log-dir)             LOG_DIR="$2"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage 0 ;;
    -*)
      echo "ERROR: unknown option $1" >&2; usage 3 ;;
    *)
      if [[ -z "$INPUT" ]]; then INPUT="$1"; shift
      else echo "ERROR: multiple positional args" >&2; usage 3
      fi ;;
  esac
done

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

cleanup() {
  echo "" >&2
  echo "[autonomous-loop] interrupted — checkpoint preserved at $CHECKPOINT" >&2
  exit 130
}
trap cleanup INT TERM

# ---- main loop ----
SESSION_N=0
NO_PROGRESS=0
REMAINING_BUDGET="$MAX_COST_USD"
PREV_DONE=$(count_done_tasks)

echo "[autonomous-loop] start. checkpoint=$CHECKPOINT budget=\$${MAX_COST_USD} max_handoffs=$MAX_HANDOFFS" >&2

while [[ $SESSION_N -lt $MAX_HANDOFFS ]]; do
  SESSION_N=$((SESSION_N + 1))

  # Completion check (before spawning — if already done, exit clean)
  if [[ -f "$CHECKPOINT" ]]; then
    done_n=$(count_done_tasks)
    total_n=$(count_total_tasks)
    if [[ $total_n -gt 0 && $done_n -ge $total_n ]]; then
      echo "[autonomous-loop] ✅ plan complete ($done_n/$total_n tasks). total sessions: $((SESSION_N - 1))" >&2
      exit 0
    fi
  fi

  # Allocate per-session budget (remaining / expected remaining handoffs, min $1)
  remaining_handoffs=$((MAX_HANDOFFS - SESSION_N + 1))
  per_session_budget=$(awk -v r="$REMAINING_BUDGET" -v h="$remaining_handoffs" \
    'BEGIN { v = r / h; if (v < 1) v = 1; printf "%.2f", v }')

  SESSION_UUID=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
  LOG_FILE="$LOG_DIR/session-$(printf '%03d' "$SESSION_N")-${SESSION_UUID}.log"

  echo "[autonomous-loop] session $SESSION_N/$MAX_HANDOFFS: uuid=$SESSION_UUID budget=\$$per_session_budget log=$LOG_FILE" >&2

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would spawn: claude -p --session-id $SESSION_UUID --max-budget-usd $per_session_budget --dangerously-skip-permissions --output-format stream-json -- '$INITIAL_PROMPT'" >&2
  else
    SUPERPOWERS_AUTONOMOUS_LOOP=1 \
      claude -p \
        --session-id "$SESSION_UUID" \
        --max-budget-usd "$per_session_budget" \
        --dangerously-skip-permissions \
        --output-format stream-json \
        --include-partial-messages \
        -- "$INITIAL_PROMPT" \
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

  # Budget tracking is approximate — claude -p's exact spend isn't easily
  # readable from here, so we subtract the per-session cap as a worst case.
  REMAINING_BUDGET=$(awk -v r="$REMAINING_BUDGET" -v s="$per_session_budget" \
    'BEGIN { v = r - s; if (v < 0) v = 0; printf "%.2f", v }')
  if [[ "$(awk -v v="$REMAINING_BUDGET" 'BEGIN { print (v <= 0) }')" -eq 1 ]]; then
    echo "[autonomous-loop] ❌ budget exhausted" >&2
    exit 1
  fi

  # For resume iterations, prompt becomes /resume-plan
  INITIAL_PROMPT="/resume-plan $CHECKPOINT"
done

echo "[autonomous-loop] ❌ reached max_handoffs=$MAX_HANDOFFS without finishing" >&2
exit 1
