#!/usr/bin/env bash
# om-inject.sh — SessionStart hook.
# Reads this session's reflections + observations and prints a compact memory
# summary to stdout. For SessionStart, plain-text stdout with exit 0 is
# injected into Claude's context. Also persists the same summary to
# last-injected.md.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

INPUT="$(cat || true)"
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null || echo "")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
om_session_init "$SESSION_ID"
om_set_current_session "$SESSION_ID"

[ "$(om_config_get injectOnSessionStart true)" = "true" ] || exit 0

MAX_TOKENS=$(om_config_get observationsPoolMaxTokens 20000)
BUDGET_CHARS=$(( MAX_TOKENS * 4 ))

# This session's own files only: memory carries forward across resume/compact
# of the same session lineage, but a genuinely new session starts blank, same
# as Pi's per-session-tree fold.
OBS_FILE=$(om_session_observations "$SESSION_ID")
REFL_FILE=$(om_session_reflections "$SESSION_ID")
DROPPED_FILE=$(om_session_dropped "$SESSION_ID")

DROPPED_IDS='[]'
[ -s "$DROPPED_FILE" ] && DROPPED_IDS=$(jq -s '[.[].id]' "$DROPPED_FILE" 2>/dev/null || echo '[]')

# Active (non-dropped) observation pool size — same accounting the dropper
# uses. Mirrors Pi's full-fold-when-oversized rule: if this has grown past
# observationsPoolMaxTokens, consolidation isn't keeping up, so show
# everything rather than risk an old-but-still-uncovered observation falling
# outside the incremental window.
ACTIVE_TOKENS=0
if [ -s "$OBS_FILE" ]; then
  ACTIVE_CHARS=$(jq -c --argjson dropped "$DROPPED_IDS" \
    'select(.id as $i | ($dropped | index($i)) | not) | .content' "$OBS_FILE" 2>/dev/null \
    | wc -c | tr -d ' ')
  ACTIVE_CHARS=${ACTIVE_CHARS:-0}
  ACTIVE_TOKENS=$(( ACTIVE_CHARS / 4 ))
fi

# lastFullFoldTs is this session's "last full-fold boundary" (Pi's own term):
# incremental injections show everything *since* that boundary, accumulating
# across multiple incremental injections — it only resets forward when a full
# fold actually happens, not on every injection. Empty means no fold has ever
# happened yet for this session, which is itself a full fold.
LAST_FULL_FOLD_TS=$(om_state_get "$SESSION_ID" lastFullFoldTs "")

if [ "$ACTIVE_TOKENS" -gt "$MAX_TOKENS" ] || [ -z "$LAST_FULL_FOLD_TS" ]; then
  MODE="full"
  CUTOFF="1970-01-01T00:00:00Z"
else
  MODE="incremental"
  CUTOFF="$LAST_FULL_FOLD_TS"
fi

# No item-count cap here — matching Pi, which bounds a fold purely by total
# token/size budget, not an arbitrary number of entries. Sorted newest-first
# so if the overall BUDGET_CHARS truncation below does cut something off,
# it's the oldest (least-recent) entries that fall off the end, not the
# newest.
REFL=""
if [ -s "$REFL_FILE" ]; then
  REFL=$(jq -rs --arg cutoff "$CUTOFF" 'map(select(.ts > $cutoff)) | sort_by(.ts) | reverse | .[] |
    "- [" + .id + "] " + ((.content // "") | gsub("\n"; " "))[0:200]' "$REFL_FILE" 2>/dev/null || true)
fi

OBS=""
if [ -s "$OBS_FILE" ]; then
  OBS=$(jq -rs --arg cutoff "$CUTOFF" --argjson dropped "$DROPPED_IDS" '
    map(select(.ts > $cutoff and (.id as $i | ($dropped | index($i)) | not))) |
    sort_by(.ts) | reverse | .[] |
    "- [" + .id + "] [" + (.relevance // "medium") + "] " + ((.content // "") | gsub("\n"; " "))[0:150]
  ' "$OBS_FILE" 2>/dev/null || true)
fi

# Build the summary. Plain text on stdout => injected as context for SessionStart.
{
  printf '# Observational Memory'
  if [ -n "$SOURCE" ]; then
    printf ' (source: %s, %s fold)' "$SOURCE" "$MODE"
  else
    printf ' (%s fold)' "$MODE"
  fi
  printf '\n\n'

  if [ -n "$REFL" ]; then
    printf '## Reflections\n'
    printf '%s\n\n' "$REFL"
  fi

  if [ -n "$OBS" ]; then
    printf '## Recent Observations\n'
    printf '%s\n\n' "$OBS"
  fi

  if [ -z "$REFL" ] && [ -z "$OBS" ]; then
    if [ "$MODE" = "incremental" ]; then
      printf '(nothing new since the last fold)\n\n'
    else
      printf '(no observations yet — memory will populate as sessions run)\n\n'
    fi
  fi

  printf 'Use `/claude-om:recall <id>` to retrieve full source context for any entry above.\n'
} 2>/dev/null | tee "$OM_LAST_INJECTED" | head -c "$BUDGET_CHARS" || true

if [ "$MODE" = "full" ]; then
  NOW=$(date -u +%FT%TZ)
  om_state_set "$SESSION_ID" lastFullFoldTs "\"$NOW\""
fi

exit 0
