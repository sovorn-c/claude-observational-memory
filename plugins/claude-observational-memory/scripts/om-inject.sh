#!/usr/bin/env bash
# om-inject.sh — SessionStart hook.
# Reads recent reflections + observations and prints a compact memory summary
# to stdout. For SessionStart, plain-text stdout with exit 0 is injected into
# Claude's context. Also persists the same summary to last-injected.md.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

INPUT="$(cat || true)"
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null || echo "")

[ "$(om_config_get injectOnSessionStart true)" = "true" ] || exit 0

BUDGET_CHARS=$(( $(om_config_get observationsPoolMaxTokens 4000) * 4 ))

REFL=""
if [ -s "$OM_REFLECTIONS" ]; then
  REFL=$(jq -rs 'sort_by(.ts) | reverse | .[0:20] | .[] |
    "- [" + .id + "] " + ((.content // "") | gsub("\n"; " "))[0:200]' "$OM_REFLECTIONS" 2>/dev/null || true)
fi

OBS=""
if [ -s "$OM_OBSERVATIONS" ]; then
  OBS=$(jq -rs 'sort_by(.ts) | reverse | .[0:30] | .[] |
    "- [" + .id + "] " + .tool + ": " + ((.summary // "") | gsub("\n"; " "))[0:150]' "$OM_OBSERVATIONS" 2>/dev/null || true)
fi

# Build the summary. Plain text on stdout => injected as context for SessionStart.
{
  printf '# Observational Memory'
  [ -n "$SOURCE" ] && printf ' (source: %s)' "$SOURCE"
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
    printf '(no observations yet — memory will populate as sessions run)\n\n'
  fi

  printf 'Use `/claude-observational-memory:recall <id>` to retrieve full source context for any entry above.\n'
} 2>/dev/null | tee "$OM_LAST_INJECTED" | head -c "$BUDGET_CHARS"

exit 0
