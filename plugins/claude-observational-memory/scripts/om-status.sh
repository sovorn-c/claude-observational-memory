#!/usr/bin/env bash
# om-status.sh — print a concise status of observational memory storage,
# aggregated across every session directory.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

session_count=0 obs_count=0 refl_count=0 dropped_count=0 total_size=0
if [ -d "$OM_SESSIONS_DIR" ]; then
  for dir in "$OM_SESSIONS_DIR"/*/; do
    [ -d "$dir" ] || continue
    session_count=$((session_count + 1))
    for name in observations.jsonl reflections.jsonl dropped.jsonl; do
      f="${dir}${name}"
      [ -f "$f" ] || continue
      c=$(grep -c . "$f" 2>/dev/null || true); c=${c:-0}
      s=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || true); s=${s:-0}
      total_size=$((total_size + s))
      case "$name" in
        observations.jsonl) obs_count=$((obs_count + c)) ;;
        reflections.jsonl) refl_count=$((refl_count + c)) ;;
        dropped.jsonl) dropped_count=$((dropped_count + c)) ;;
      esac
    done
  done
fi

echo "claude-observational-memory status"
echo "  data dir:      $OM_DIR"
echo "  sessions:      ${session_count}"
echo "  observations:  ${obs_count} entries, ${dropped_count} dropped from active pool"
echo "  reflections:   ${refl_count} entries"
echo "  total size:    ${total_size} bytes"
echo "  last injected: ${OM_LAST_INJECTED}"
if [ -f "$OM_CONFIG" ]; then
  echo "  config:"
  jq -r 'to_entries[] | "    \(.key): \(if (.key | test("key";"i")) then (if ((.value|tostring|length) > 0) then "(set)" else "(unset)" end) else .value end)"' \
    "$OM_CONFIG" 2>/dev/null || cat "$OM_CONFIG" | sed 's/^/    /'
fi
llm_key=$(om_config_get llmApiKey "")
if [ -n "$llm_key" ]; then
  llm_provider=$(om_config_get llmProvider "openai")
  llm_model=$(om_config_get llmModel "")
  [ -n "$llm_model" ] || llm_model=$(om_llm_default_model "$llm_provider")
  llm_base_url=$(om_config_get llmBaseUrl "")
  [ -n "$llm_base_url" ] || llm_base_url=$(om_llm_base_url "$llm_provider")
  llm_effort=$(om_config_get llmReasoningEffort "default")
  llm_schema_mode="json_schema"
  [ "$(om_model_caps_get "${llm_provider}:${llm_model}:schema")" = "object" ] && llm_schema_mode="json_object (fallback)"
  echo "  model route:  unified LLM (${llm_provider}: ${llm_model:-?} via ${llm_base_url:-?}, reasoning effort ${llm_effort}, structured output ${llm_schema_mode})"
else
  echo "  model route:  NOT CONFIGURED — set llmApiKey to enable observe/reflect"
fi
exit 0
