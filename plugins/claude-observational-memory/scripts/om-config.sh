#!/usr/bin/env bash
# om-config.sh — shared config and helpers for claude-observational-memory.
# Source this file from other scripts:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
# It also works when run standalone (sets CLAUDE_PLUGIN_ROOT fallback).

# Fallback so scripts remain testable outside a Claude Code hook context.
: "${CLAUDE_PLUGIN_ROOT:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

: "${OM_DIR:="${HOME}/.local/share/claude-observational-memory"}"
: "${OM_OBSERVATIONS:="${OM_DIR}/observations.jsonl"}"
: "${OM_REFLECTIONS:="${OM_DIR}/reflections.jsonl"}"
: "${OM_CONFIG:="${OM_DIR}/config.json"}"
: "${OM_LOG:="${OM_DIR}/debug/om.log"}"
: "${OM_LAST_INJECTED:="${OM_DIR}/last-injected.md"}"

# om_config_get <key> [default] — prints a config value or its default.
# Note: use has($k) so a boolean false is returned as "false", not treated as absent
# (jq's `//` operator would otherwise treat false like null).
om_config_get() {
  local key="$1" default="${2:-}"
  [ -f "${OM_CONFIG}" ] || { printf '%s' "$default"; return 0; }
  local raw
  raw=$(jq -r --arg k "$key" 'if has($k) then (.[$k] | tostring) else "__OM_ABSENT__" end' "${OM_CONFIG}" 2>/dev/null)
  if [ -z "$raw" ] || [ "$raw" = "__OM_ABSENT__" ] || [ "$raw" = "null" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$raw"
  fi
}

# om_config_init — ensure data dir, files, and default config exist.
om_config_init() {
  mkdir -p "${OM_DIR}" "${OM_DIR}/debug"
  [ -f "${OM_OBSERVATIONS}" ] || : > "${OM_OBSERVATIONS}"
  [ -f "${OM_REFLECTIONS}" ] || : > "${OM_REFLECTIONS}"
  if [ ! -f "${OM_CONFIG}" ]; then
    cat > "${OM_CONFIG}" <<'JSON'
{
  "observationsPoolMaxTokens": 4000,
  "reflectOnPreCompact": true,
  "injectOnSessionStart": true,
  "reflectionProvider": "claude-cli"
}
JSON
  fi
}

# om_log <msg...> — append a timestamped line to the debug log.
om_log() {
  mkdir -p "${OM_DIR}/debug"
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "${OM_LOG}" 2>/dev/null || true
}

# om_new_id — print a 12-char lowercase hex id (matches Pi OM id shape).
om_new_id() {
  openssl rand -hex 6 2>/dev/null \
    || head -c 6 /dev/urandom | xxd -p 2>/dev/null \
    || printf '%s' "$(date +%s%N | md5sum 2>/dev/null | cut -c1-12)" \
    || printf '%s' "$(date +%s)$RANDOM" | md5 2>/dev/null | cut -c1-12
}
