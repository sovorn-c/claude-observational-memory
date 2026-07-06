#!/usr/bin/env bash
# om-consolidate.sh — Stop hook. Runs observe -> reflect -> dropper, gated by
# real context-size growth (from each assistant turn's recorded token usage)
# in the session transcript, read from `transcript_path` in the hook payload.
# This mirrors Pi's turn_end consolidation trigger, adapted to the one
# per-turn checkpoint Claude Code hooks actually expose. No LLM call happens
# on any other hook, so tool calls are never slowed down. Never blocks;
# always exits 0.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

INPUT="$(cat || true)"
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

om_session_init "$SESSION_ID"
OBS_FILE=$(om_session_observations "$SESSION_ID")

TOTAL_LINES=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
[ -z "$TOTAL_LINES" ] && exit 0

OBSERVE_AFTER=$(om_config_get observeAfterTokens 5000)
REFLECT_AFTER=$(om_config_get reflectAfterTokens 10000)
OBSERVE_FIRED=0

CURRENT_TOKENS=$(om_usage_tokens_at_line "$TRANSCRIPT" "$TOTAL_LINES")

# ---- Observe stage ----
OBS_LINE=$(om_state_get "$SESSION_ID" observeLine 0)

if [ "$TOTAL_LINES" -gt "$OBS_LINE" ]; then
  OBS_LINE_TOKENS=$(om_usage_tokens_at_line "$TRANSCRIPT" "$OBS_LINE")
  EST_TOKENS=$(( CURRENT_TOKENS - OBS_LINE_TOKENS ))
  [ "$EST_TOKENS" -lt 0 ] && EST_TOKENS=0

  if [ "$EST_TOKENS" -ge "$OBSERVE_AFTER" ]; then
    CHUNK=$(tail -n +"$((OBS_LINE + 1))" "$TRANSCRIPT" 2>/dev/null | head -c 60000 || true)
    if [ -n "$CHUNK" ]; then
      SCHEMA='{"type":"object","properties":{"observations":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"relevance":{"type":"string","enum":["low","medium","high","critical"]}},"required":["content","relevance"]}}},"required":["observations"]}'
      SYS="You extract durable observations from a raw Claude Code session transcript (JSONL, one event per line). Each observation is one plain-text sentence describing a concrete thing that happened: a decision, a completed task, a constraint, an error, a user preference. Skip routine tool mechanics and anything obvious from file paths alone. Tag each with relevance: low, medium, high, or critical. Emit zero observations if nothing durable happened."
      USER="Transcript chunk:
${CHUNK}"
      RESP=$(om_call_model "$SYS" "$USER" "$SCHEMA")
      COUNT_ADDED=0
      if [ -n "$RESP" ]; then
        NOW=$(date -u +%FT%TZ)
        while IFS= read -r item; do
          [ -z "$item" ] && continue
          CONTENT=$(printf '%s' "$item" | jq -r '.content // empty' 2>/dev/null)
          RELEVANCE=$(printf '%s' "$item" | jq -r '.relevance // "medium"' 2>/dev/null)
          [ -z "$CONTENT" ] && continue
          case "$RELEVANCE" in low|medium|high|critical) ;; *) RELEVANCE="medium" ;; esac
          OID=$(om_new_id)
          jq -nc --arg id "$OID" --arg ts "$NOW" --arg sid "$SESSION_ID" \
            --arg content "$CONTENT" --arg relevance "$RELEVANCE" \
            '{id:$id,ts:$ts,session_id:$sid,content:$content,relevance:$relevance}' \
            >> "$OBS_FILE" 2>/dev/null && COUNT_ADDED=$((COUNT_ADDED + 1))
        done < <(printf '%s' "$RESP" | jq -c '.observations[]?' 2>/dev/null || true)
      fi
      om_log "observe: chunk ~${EST_TOKENS} tokens, ${COUNT_ADDED} observation(s) recorded (session $SESSION_ID)"
    fi
    om_state_set "$SESSION_ID" observeLine "$TOTAL_LINES"
    OBS_LINE="$TOTAL_LINES"
    OBSERVE_FIRED=1
  fi
fi

# ---- Reflect stage (requires observe to have covered at least once; skipped
# on any turn where observe just ran, matching Pi's observer-priority rule so
# a single Stop invocation never stacks two model calls back to back) ----
if [ "$OBSERVE_FIRED" -eq 0 ] && [ "$OBS_LINE" -gt 0 ]; then
  REFL_LINE=$(om_state_get "$SESSION_ID" reflectLine 0)

  if [ "$OBS_LINE" -gt "$REFL_LINE" ]; then
    OBS_LINE_TOKENS=$(om_usage_tokens_at_line "$TRANSCRIPT" "$OBS_LINE")
    REFL_LINE_TOKENS=$(om_usage_tokens_at_line "$TRANSCRIPT" "$REFL_LINE")
    REFLECT_EST_TOKENS=$(( OBS_LINE_TOKENS - REFL_LINE_TOKENS ))
    [ "$REFLECT_EST_TOKENS" -lt 0 ] && REFLECT_EST_TOKENS=0

    if [ "$REFLECT_EST_TOKENS" -ge "$REFLECT_AFTER" ]; then
      om_run_reflect_pass "$SESSION_ID"
      om_state_set "$SESSION_ID" reflectLine "$OBS_LINE"
    fi
  fi
fi

om_run_retention_pass
exit 0
