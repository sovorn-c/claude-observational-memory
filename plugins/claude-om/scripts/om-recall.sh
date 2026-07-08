#!/usr/bin/env bash
# om-recall.sh — fetch a memory entry by 12-char hex id, or text-search.
# Usage: om-recall.sh [--all] <id|query>
# Id lookup always searches every session directory — an id is a unique key,
# so "which session" doesn't matter and there's nothing to scope. Text search
# defaults to the current session (per om_set_current_session's pointer file,
# stamped by every hook) since that matches the plugin's actual goal: keep
# one session coherent, not search across unrelated projects. --all (or no
# pointer yet) falls back to the old global-search behavior.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"

GLOBAL=0
if [ "${1:-}" = "--all" ]; then
  GLOBAL=1
  shift
fi
QUERY="${1:-}"
[ -z "$QUERY" ] && { echo "Usage: om-recall.sh [--all] <id|query>"; exit 0; }

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

# Otherwise, text search. Default to the current session (via the pointer
# hooks stamp on every Stop/SessionStart/PreCompact); --all, or no pointer
# recorded yet, searches every session directory instead.
CURRENT_SID=""
[ -f "$OM_CURRENT_SESSION_FILE" ] && CURRENT_SID=$(cat "$OM_CURRENT_SESSION_FILE" 2>/dev/null || true)

SEARCH_FILES=()
SCOPE="all sessions"
if [ "$GLOBAL" -eq 0 ] && [ -n "$CURRENT_SID" ] && [ -d "$(om_session_dir "$CURRENT_SID")" ]; then
  SCOPE="current session"
  for f in "$(om_session_observations "$CURRENT_SID")" "$(om_session_reflections "$CURRENT_SID")"; do
    [ -f "$f" ] && SEARCH_FILES+=("$f")
  done
else
  for f in "$OM_SESSIONS_DIR"/*/observations.jsonl "$OM_SESSIONS_DIR"/*/reflections.jsonl; do
    [ -f "$f" ] && SEARCH_FILES+=("$f")
  done
fi

echo "Search results for: $QUERY (${SCOPE})"
if [ "${#SEARCH_FILES[@]}" -gt 0 ]; then
  for f in "${SEARCH_FILES[@]}"; do
    grep -i -- "$QUERY" "$f" 2>/dev/null | head -10 | while IFS= read -r line; do
      printf '%s\n' "$line" | jq -r '"- [" + .id + "] " + (.content // "")[0:140]' 2>/dev/null || true
    done || true
  done
fi
if [ "$SCOPE" = "current session" ]; then
  echo "(searched current session only; pass --all to search every session)"
fi
exit 0
