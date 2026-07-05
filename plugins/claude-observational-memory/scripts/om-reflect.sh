#!/usr/bin/env bash
# om-reflect.sh — PreCompact hook (also callable manually).
# Reads observations newer than the last reflection, asks an LLM to distill
# them into a durable reflection, and appends it to reflections.jsonl.
# Providers: "claude-cli" (default, uses `claude -p`) or "anthropic-api"
# (uses ANTHROPIC_API_KEY). Never blocks; always exits 0.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

INPUT="$(cat || true)"
[ -z "$INPUT" ] && INPUT='{}'

[ "$(om_config_get reflectOnPreCompact true)" = "true" ] || exit 0

# Timestamp of the most recent reflection (so we only reflect new observations).
LAST_TS=""
if [ -s "$OM_REFLECTIONS" ]; then
  LAST_TS=$(jq -r '.ts // "1970-01-01T00:00:00Z"' "$OM_REFLECTIONS" 2>/dev/null \
    | sort -r | head -1 || echo "1970-01-01T00:00:00Z")
fi
[ -z "$LAST_TS" ] && LAST_TS="1970-01-01T00:00:00Z"

# Observations strictly newer than the last reflection.
OBS_JSONL=""
if [ -s "$OM_OBSERVATIONS" ]; then
  OBS_JSONL=$(jq -c --arg t "$LAST_TS" 'select(.ts > $t)' "$OM_OBSERVATIONS" 2>/dev/null || true)
fi
[ -z "$OBS_JSONL" ] && exit 0

# Count non-empty lines.
COUNT=$(printf '%s\n' "$OBS_JSONL" | grep -c . 2>/dev/null || true)
[ "${COUNT:-0}" -lt 3 ] && exit 0

SRC_IDS=$(printf '%s\n' "$OBS_JSONL" | jq -s 'map(.id)' 2>/dev/null || echo '[]')

PROMPT="You are an observational memory reflector for a coding agent. Below are recent observations captured from a Claude Code session (JSONL). Condense them into a concise markdown summary (max ~200 words) of durable facts, decisions, constraints, bugs, and user preferences. Do not narrate the session; only output the distilled reflections that would still matter in future sessions.

Observations:
${OBS_JSONL}"

PROVIDER=$(om_config_get reflectionProvider claude-cli)
RESPONSE=""

case "$PROVIDER" in
  anthropic-api)
    API_KEY="${ANTHROPIC_API_KEY:-}"
    if [ -z "$API_KEY" ]; then
      om_log "reflect: ANTHROPIC_API_KEY not set; skipping"
      exit 0
    fi
    RESPONSE=$(printf '%s' "$PROMPT" | jq -Rs . | {
      read -r p
      curl -fsS https://api.anthropic.com/v1/messages \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$(jq -n --arg p "$p" '{model:"claude-3-5-haiku-latest",max_tokens:1024,messages:[{role:"user",content:$p}]}')" 2>/dev/null \
        | jq -r '.content[0].text // empty' 2>/dev/null
    } || true)
    ;;
  claude-cli|*)
    if ! command -v claude >/dev/null 2>&1; then
      om_log "reflect: claude CLI not found; skipping"
      exit 0
    fi
    RESPONSE=$(printf '%s' "$PROMPT" | claude -p --output-format text 2>/dev/null || true)
    ;;
esac

# Trim leading/trailing whitespace.
RESPONSE=$(printf '%s' "$RESPONSE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[ -z "$RESPONSE" ] && exit 0

RID=$(om_new_id)
NOW=$(date -u +%FT%TZ)

jq -nc \
  --arg id "$RID" \
  --arg ts "$NOW" \
  --arg content "$RESPONSE" \
  --argjson source_ids "${SRC_IDS:-[]}" \
  '{id:$id,ts:$ts,content:$content,source_ids:$source_ids}' \
  >> "$OM_REFLECTIONS" 2>/dev/null || om_log "reflect: failed to append"

om_log "reflect: wrote reflection $RID from $COUNT observations"
exit 0
