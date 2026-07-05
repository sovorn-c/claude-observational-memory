#!/usr/bin/env bash
# om-recall.sh — fetch a memory entry by 12-char hex id, or text-search.
# Usage: om-recall.sh <id|query>
# Unlike every other script here, this deliberately searches across ALL
# session directories, not just the current session's own — it's a manual,
# on-demand lookup, not automatic context injection, so cross-session scoping
# doesn't apply.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"

QUERY="${1:-}"
[ -z "$QUERY" ] && { echo "Usage: om-recall.sh <id|query>"; exit 0; }

# Exact id lookup (12-char lowercase hex).
if printf '%s' "$QUERY" | grep -qE '^[0-9a-f]{12}$'; then
  MATCH_FILE=""
  if [ -d "$OM_SESSIONS_DIR" ]; then
    MATCH_FILE=$(grep -rl "\"id\":\"$QUERY\"" "$OM_SESSIONS_DIR" 2>/dev/null \
      | grep -v '/dropped\.jsonl$' | head -1 || true)
  fi
  if [ -n "$MATCH_FILE" ]; then
    SID=$(basename "$(dirname "$MATCH_FILE")")
    TYPE="observation"
    case "$MATCH_FILE" in */reflections.jsonl) TYPE="reflection" ;; esac
    MATCH=$(grep "\"id\":\"$QUERY\"" "$MATCH_FILE" 2>/dev/null | head -1 || true)
    STATUS=""
    DROPPED_FILE=$(om_session_dropped "$SID")
    if [ "$TYPE" = "observation" ] && [ -s "$DROPPED_FILE" ] \
       && grep -q "\"id\":\"$QUERY\"" "$DROPPED_FILE" 2>/dev/null; then
      STATUS=" (dropped from active memory, still recallable)"
    fi
    printf '%s\n' "$MATCH" | jq -r --arg type "$TYPE" --arg status "$STATUS" \
      '"FOUND " + $type + " [" + .id + "] @ " + (.ts // "?") + $status + "\n" + (.content // "(no content)")'
    exit 0
  fi
  echo "No memory entry found with id $QUERY"
  exit 0
fi

# Otherwise, text search across every session's observations and reflections.
echo "Search results for: $QUERY"
for f in "$OM_SESSIONS_DIR"/*/observations.jsonl "$OM_SESSIONS_DIR"/*/reflections.jsonl; do
  [ -f "$f" ] || continue
  grep -i -- "$QUERY" "$f" 2>/dev/null | head -10 | while IFS= read -r line; do
    printf '%s\n' "$line" | jq -r '"- [" + .id + "] " + (.content // "")[0:140]' 2>/dev/null || true
  done || true
done
exit 0
