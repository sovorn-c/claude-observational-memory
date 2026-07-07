#!/usr/bin/env bash
# om-reflect.sh — PreCompact hook (also callable manually). Safety net: forces
# a reflect pass over any observations not yet covered by a reflection, right
# before compaction discards raw context. PreCompact fires on both manual
# `/compact` and Claude Code's own automatic auto-compaction, so this is the
# last chance to distill anything om-consolidate.sh's token-clock hasn't
# caught up to yet. The regular reflect cadence runs from om-consolidate.sh
# on the Stop hook — this just backstops it. Never blocks; always exits 0.
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
om_config_init

[ "$(om_config_get reflectOnPreCompact true)" = "true" ] || exit 0

INPUT="$(cat || true)"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
om_session_init "$SESSION_ID"

om_run_reflect_pass "$SESSION_ID"
exit 0
