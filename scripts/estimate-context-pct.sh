#!/usr/bin/env bash
# estimate-context-pct.sh — Report current Claude Code context usage.
#
# Usage:
#   scripts/estimate-context-pct.sh                  # auto-detect transcript
#   scripts/estimate-context-pct.sh <transcript>     # explicit transcript path
#
# Output (stdout): one JSON line, e.g.
#   {"pct":42,"input_tokens":421337,"window_size":1000000,
#    "model":"claude-opus-4-6","transcript":"/path/to/x.jsonl",
#    "source":"transcript"}
#
# On any failure (no transcript, parse error, etc.), still exits 0 and emits
#   {"pct":0,"source":"error","error":"..."}
# so the caller can degrade gracefully without branching on exit codes.
#
# Source of truth:
#   Reads the last assistant entry's message.usage from the transcript JSONL
#   and sums input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
#   This matches claude-hud's fallback calculation and Claude Code's /context.
#
# Context window size detection (first hit wins):
#   1. $SUPERPOWERS_CONTEXT_WINDOW_SIZE env override
#   2. Self-calibrating: if any prior turn in the transcript observed
#      total_tokens > 200_000 → treat as 1M mode
#   3. Default 200_000

set -u

EXPLICIT="${1:-}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJ_ROOT="$CLAUDE_DIR/projects"

emit_error() {
  python3 -c 'import json,sys; print(json.dumps({"pct":0,"source":"error","error":sys.argv[1]}))' "$1"
  exit 0
}

# Resolve transcript into $TRANSCRIPT at top level. Previously this lived
# inside a function called via $(...), where emit_error's `exit 0` only
# terminated the subshell — so the main script kept running and fed the
# error JSON to python3 as a file path. Inlining avoids that trap.
TRANSCRIPT=""
if [[ -n "$EXPLICIT" ]]; then
  [[ -f "$EXPLICIT" ]] || emit_error "transcript not found: $EXPLICIT"
  TRANSCRIPT="$EXPLICIT"
else
  [[ -d "$PROJ_ROOT" ]] || emit_error "project dir missing: $PROJ_ROOT"
  # Slug convention: absolute cwd with / replaced by -
  CWD_SLUG="$(pwd | sed -e 's|/|-|g')"
  SLUG_DIR="$PROJ_ROOT/$CWD_SLUG"
  if [[ -d "$SLUG_DIR" ]]; then
    TRANSCRIPT="$(ls -t "$SLUG_DIR"/*.jsonl 2>/dev/null | head -1)"
  fi
  # Fallback: newest jsonl across all projects (handles subagents whose cwd
  # differs from the controller's, or unusual slug encodings).
  if [[ -z "$TRANSCRIPT" ]]; then
    TRANSCRIPT="$(ls -t "$PROJ_ROOT"/*/*.jsonl 2>/dev/null | head -1)"
  fi
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || emit_error "no transcript under $PROJ_ROOT"
fi

python3 - "$TRANSCRIPT" "${SUPERPOWERS_CONTEXT_WINDOW_SIZE:-0}" <<'PY'
import json, sys

path = sys.argv[1]
try:
    override = int(sys.argv[2])
except Exception:
    override = 0

last_usage = None
last_model = None
max_total = 0

try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            msg = e.get("message") or {}
            usage = msg.get("usage")
            model = msg.get("model")
            if isinstance(usage, dict):
                total = (
                    (usage.get("input_tokens") or 0)
                    + (usage.get("cache_creation_input_tokens") or 0)
                    + (usage.get("cache_read_input_tokens") or 0)
                )
                last_usage = usage
                if model:
                    last_model = model
                if total > max_total:
                    max_total = total
except Exception as ex:
    print(json.dumps({"pct": 0, "source": "error",
                      "error": f"read failed: {ex}", "transcript": path}))
    sys.exit(0)

if not last_usage:
    print(json.dumps({"pct": 0, "source": "error",
                      "error": "no usage entries in transcript",
                      "transcript": path}))
    sys.exit(0)

total = (
    (last_usage.get("input_tokens") or 0)
    + (last_usage.get("cache_creation_input_tokens") or 0)
    + (last_usage.get("cache_read_input_tokens") or 0)
)

if override > 0:
    window = override
elif max_total > 200_000:
    window = 1_000_000
else:
    window = 200_000

pct = max(0, min(100, round(total / window * 100)))

print(json.dumps({
    "pct": pct,
    "input_tokens": total,
    "window_size": window,
    "model": last_model,
    "transcript": path,
    "source": "transcript",
}))
PY
