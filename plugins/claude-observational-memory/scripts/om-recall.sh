#!/usr/bin/env bash
# om-recall.sh — fetch a memory entry by 12-char hex id, or text-search.
# Usage: om-recall.sh <id|query>
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"

QUERY="${1:-}"
[ -z "$QUERY" ] && { echo "Usage: om-recall.sh <id|query>"; exit 0; }

# Exact id lookup (12-char lowercase hex).
if printf '%s' "$QUERY" | grep -qE '^[0-9a-f]{12}$'; then
  MATCH=""
  for f in "$OM_REFLECTIONS" "$OM_OBSERVATIONS"; do
    [ -f "$f" ] || continue
    LINE=$(grep "\"id\":\"$QUERY\"" "$f" 2>/dev/null | head -1 || true)
    if [ -n "$LINE" ]; then
      MATCH="$LINE"
      break
    fi
  done
  if [ -n "$MATCH" ]; then
    printf '%s\n' "$MATCH" | jq -r '
      "FOUND " + (if .content then "reflection" else "observation" end) +
      " [" + .id + "] @ " + (.ts // "?") + "\n" +
      (.content // .summary // "(no content)")'
    exit 0
  fi
  echo "No memory entry found with id $QUERY"
  exit 0
fi

# Otherwise, text search across observations and reflections.
echo "Search results for: $QUERY"
for f in "$OM_OBSERVATIONS" "$OM_REFLECTIONS"; do
  [ -f "$f" ] || continue
  grep -i -- "$QUERY" "$f" 2>/dev/null | head -10 | while IFS= read -r line; do
    printf '%s\n' "$line" | jq -r '"- [" + .id + "] " + (.content // .summary // "")[0:140]' 2>/dev/null || true
  done || true
done
exit 0
