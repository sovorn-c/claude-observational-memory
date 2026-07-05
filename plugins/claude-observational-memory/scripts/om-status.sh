#!/usr/bin/env bash
# om-status.sh — print a concise status of observational memory storage.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

obs_count=0; refl_count=0; obs_size=0; refl_size=0
if [ -f "$OM_OBSERVATIONS" ]; then
  obs_count=$(grep -c . "$OM_OBSERVATIONS" 2>/dev/null || true); obs_count=${obs_count:-0}
  obs_size=$(wc -c < "$OM_OBSERVATIONS" 2>/dev/null | tr -d ' ' || true); obs_size=${obs_size:-0}
fi
if [ -f "$OM_REFLECTIONS" ]; then
  refl_count=$(grep -c . "$OM_REFLECTIONS" 2>/dev/null || true); refl_count=${refl_count:-0}
  refl_size=$(wc -c < "$OM_REFLECTIONS" 2>/dev/null | tr -d ' ' || true); refl_size=${refl_size:-0}
fi

echo "claude-observational-memory status"
echo "  data dir:      $OM_DIR"
echo "  observations:  ${obs_count} entries (${obs_size} bytes)"
echo "  reflections:   ${refl_count} entries (${refl_size} bytes)"
echo "  last injected: ${OM_LAST_INJECTED}"
if [ -f "$OM_CONFIG" ]; then
  echo "  config:"
  jq -r 'to_entries[] | "    \(.key): \(.value)"' "$OM_CONFIG" 2>/dev/null || cat "$OM_CONFIG" | sed 's/^/    /'
fi
exit 0
