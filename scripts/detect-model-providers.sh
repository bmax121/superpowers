#!/usr/bin/env bash
# Probe which providers declared in config/models.yaml are actually
# invocable on this machine. Prints a human-readable summary followed by
# a single JSON line suitable for `... | tail -n1 | jq`.
#
# Usage:
#   scripts/detect-model-providers.sh [path/to/models.yaml]
#
# Exit codes:
#   0 - probe ran to completion (even if some providers are unavailable)
#   2 - config file missing or unparseable
#
# Dependencies:
#   - bash (4+)
#   - awk (POSIX; used as yq fallback)
#   - yq (optional, preferred if present)
#
# Design notes:
#   The parser is deliberately simple — it reads the `providers:` block only,
#   because availability depends on provider-level `type` and `command`, not
#   on the tier ordering. The controller is responsible for cross-referencing
#   tier entries with the availability map this script emits.

set -u

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:-$PLUGIN_ROOT/config/models.yaml}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 2
fi

# ---- Parse providers block ----
# Output lines: "<name>\t<type>\t<command-or-empty>"
parse_with_awk() {
  awk '
    BEGIN { in_providers = 0; cur = ""; type = ""; cmd = "" }
    /^[^[:space:]]/ {
      if ($0 ~ /^providers:/) { in_providers = 1; next }
      else { in_providers = 0 }
    }
    in_providers == 0 { next }

    # provider name: two-space indent, ends with colon, no value
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (cur != "") { print cur "\t" type "\t" cmd }
      cur = $1; sub(/:$/, "", cur)
      type = ""; cmd = ""
      next
    }
    # type: field
    /^    type:/ {
      type = $2
      next
    }
    # command: field (take everything after "command:")
    /^    command:/ {
      line = $0
      sub(/^[[:space:]]*command:[[:space:]]*/, "", line)
      # strip surrounding quotes if present
      if (line ~ /^".*"$/) { sub(/^"/, "", line); sub(/"$/, "", line) }
      else if (line ~ /^'"'"'.*'"'"'$/) { sub(/^'"'"'/, "", line); sub(/'"'"'$/, "", line) }
      cmd = line
      next
    }
    END {
      if (cur != "") { print cur "\t" type "\t" cmd }
    }
  ' "$CONFIG_FILE"
}

parse_with_yq() {
  # yq v4 syntax. Output: "<name>\t<type>\t<command>"
  yq -r '.providers | to_entries[] | "\(.key)\t\(.value.type // "")\t\(.value.command // "")"' "$CONFIG_FILE"
}

if command -v yq >/dev/null 2>&1; then
  PROVIDERS_RAW="$(parse_with_yq 2>/dev/null || true)"
  if [[ -z "$PROVIDERS_RAW" ]]; then
    # yq failed (maybe v3 or different tool named yq) — fall back
    PROVIDERS_RAW="$(parse_with_awk)"
  fi
else
  PROVIDERS_RAW="$(parse_with_awk)"
fi

if [[ -z "$PROVIDERS_RAW" ]]; then
  echo "ERROR: no providers parsed from $CONFIG_FILE" >&2
  exit 2
fi

# ---- Probe each provider ----
echo "─── Model provider detection ───"

JSON_PARTS=()
while IFS=$'\t' read -r name ptype cmd; do
  [[ -z "$name" ]] && continue
  case "$ptype" in
    agent_tool)
      # Always available inside Claude Code runtime.
      echo "  $name (agent_tool): ✅ available"
      JSON_PARTS+=("\"$name\":{\"type\":\"agent_tool\",\"available\":true}")
      ;;
    cli_wrapper)
      # First token of command template is the executable.
      bin="$(echo "$cmd" | awk '{print $1}')"
      if [[ -z "$bin" ]]; then
        echo "  $name (cli_wrapper): ❌ no command template"
        JSON_PARTS+=("\"$name\":{\"type\":\"cli_wrapper\",\"available\":false,\"reason\":\"no command template\"}")
      elif command -v "$bin" >/dev/null 2>&1; then
        resolved="$(command -v "$bin")"
        echo "  $name (cli_wrapper, $bin): ✅ found at $resolved"
        JSON_PARTS+=("\"$name\":{\"type\":\"cli_wrapper\",\"available\":true,\"binary\":\"$resolved\"}")
      else
        echo "  $name (cli_wrapper, $bin): ❌ not found on PATH"
        JSON_PARTS+=("\"$name\":{\"type\":\"cli_wrapper\",\"available\":false,\"reason\":\"binary $bin not on PATH\"}")
      fi
      ;;
    "")
      echo "  $name: ⚠ provider has no 'type' field — skipping"
      JSON_PARTS+=("\"$name\":{\"type\":\"\",\"available\":false,\"reason\":\"missing type\"}")
      ;;
    *)
      echo "  $name ($ptype): ⚠ unknown provider type"
      JSON_PARTS+=("\"$name\":{\"type\":\"$ptype\",\"available\":false,\"reason\":\"unknown type\"}")
      ;;
  esac
done <<< "$PROVIDERS_RAW"

# ---- Emit JSON map on final line for controller consumption ----
IFS=','
echo "{${JSON_PARTS[*]}}"
