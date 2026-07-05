#!/usr/bin/env bash
# om-observe.sh — PostToolUse / Stop / UserPromptSubmit hook.
# Reads hook JSON on stdin, distills a compact observation, appends to
# observations.jsonl. Never blocks; always exits 0.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

INPUT="$(cat || true)"
[ -z "$INPUT" ] && exit 0

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || echo "")
[ -z "$EVENT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
TS=$(date -u +%FT%TZ)
ID=$(om_new_id)

TOOL=""
KIND=""
SUMMARY=""

case "$EVENT" in
  PostToolUse)
    TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
    SUMMARY=$(printf '%s' "$INPUT" | jq -r '
      .tool_input |
      if .command      then "cmd: "    + (.command | tostring)
      elif .file_path  then "file: "   + (.file_path | tostring)
      elif .path       then "path: "   + (.path | tostring)
      elif .pattern    then "pattern: "+ (.pattern | tostring)
      elif .prompt     then "prompt: " + (.prompt | tostring)
      else tostring end
    ' 2>/dev/null | tr '\n' ' ' | head -c 200)
    KIND="tool"
    ;;
  Stop)
    TOOL="stop"
    SUMMARY="session stopped"
    KIND="stop"
    ;;
  UserPromptSubmit)
    TOOL="prompt"
    SUMMARY=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null | tr '\n' ' ' | head -c 200)
    KIND="prompt"
    ;;
  *)
    TOOL="$EVENT"
    SUMMARY="$EVENT event"
    KIND="event"
    ;;
esac

# Skip noisy internal task-management tools.
case "$TOOL" in
  TodoWrite|TaskCreate|TaskCreateMany|TaskUpdate|TaskGet|TaskList|TaskOutput|TaskStop|TaskExecute)
    exit 0
    ;;
esac

jq -nc \
  --arg id "$ID" \
  --arg ts "$TS" \
  --arg sid "$SESSION_ID" \
  --arg kind "$KIND" \
  --arg event "$EVENT" \
  --arg tool "$TOOL" \
  --arg summary "$SUMMARY" \
  --arg cwd "$CWD" \
  '{id:$id,ts:$ts,session_id:$sid,kind:$kind,event:$event,tool:$tool,summary:$summary,cwd:$cwd}' \
  >> "$OM_OBSERVATIONS" 2>/dev/null || om_log "observe: failed to append"

exit 0
